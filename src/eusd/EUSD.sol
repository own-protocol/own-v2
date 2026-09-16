// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSD} from "../interfaces/IEUSD.sol";
import {IERC7802} from "../interfaces/external/IERC7802.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title EUSD — CDP stablecoin (ERC-20 + ERC-2612 Permit + ERC-7802 crosschain)
/// @notice Minimal stablecoin token. CDP supply changes go through MINTER_ROLE (held only by the
///         EUSDManager; burns are allowance-free so the manager can retire debt directly from the
///         payer). Crosschain transfers go through the ERC-7802 surface, authorized purely by
///         per-bridge rolling rate limits — a transport with zero limits can do nothing, and a
///         compromised one is bounded to its per-window limit and de-authorized by zeroing it.
///         Crosschain burns are likewise allowance-free: a bridge only burns from the user who
///         asked it to bridge, and its burn limit bounds any misuse to griefing within one window.
contract EUSD is IEUSD, ERC20Permit, AccessControl {
    /// @inheritdoc IEUSD
    bytes32 public constant override MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @inheritdoc IEUSD
    uint256 public constant override LIMIT_DURATION = 1 days;

    /// @inheritdoc IEUSD
    int256 public override netBridgedIn;

    /// @inheritdoc IEUSD
    /// @dev Defaults to 0 (fail-closed): no net inbound bridging until governance raises it.
    uint256 public override maxNetBridgedIn;

    mapping(address => BridgeConfig) private _bridges;

    /// @param admin Initial holder of DEFAULT_ADMIN_ROLE (grants/revokes MINTER_ROLE, sets
    ///              bridge limits).
    constructor(
        address admin
    ) ERC20("Own eUSD", "eUSD") ERC20Permit("Own eUSD") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ──────────────────────────────────────────────────────────
    //  Supply (MINTER_ROLE — the EUSDManager)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSD
    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IEUSD
    function burn(address from, uint256 amount) external override onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-7802 crosschain (rate-limited bridges)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IERC7802
    function crosschainMint(address to, uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        _consumeLimit(true, amount);
        int256 newNet = netBridgedIn + SafeCast.toInt256(amount);
        // Global ceiling: bounds total bridged-in eUSD beyond local CDP backing, no matter which
        // bridge or how slowly it accumulates (the per-bridge limit only bounds velocity).
        if (newNet > SafeCast.toInt256(maxNetBridgedIn)) revert GlobalBridgeCapExceeded(newNet, maxNetBridgedIn);
        netBridgedIn = newNet;
        _mint(to, amount);
        emit CrosschainMint(to, amount, msg.sender);
    }

    /// @inheritdoc IERC7802
    function crosschainBurn(address from, uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        _consumeLimit(false, amount);
        netBridgedIn -= SafeCast.toInt256(amount);
        _burn(from, amount);
        emit CrosschainBurn(from, amount, msg.sender);
    }

    /// @inheritdoc IEUSD
    function setBridgeLimits(
        address bridge,
        uint256 mintMaxLimit,
        uint256 burnMaxLimit
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bridge == address(0)) revert ZeroAddress();
        BridgeConfig storage cfg = _bridges[bridge];
        // A fresh authorization starts with a full window. An update to a live bridge settles what
        // it has accrued and clamps to the new maxima — never a refill, so lowering limits during
        // an incident takes effect immediately instead of handing out a second window.
        bool live = cfg.mintMaxLimit != 0 || cfg.burnMaxLimit != 0;
        uint256 mintRemaining = mintMaxLimit;
        uint256 burnRemaining = burnMaxLimit;
        if (live) {
            uint256 mintAvail = _available(cfg.mintRemaining, cfg.mintMaxLimit, cfg.lastUpdate);
            uint256 burnAvail = _available(cfg.burnRemaining, cfg.burnMaxLimit, cfg.lastUpdate);
            mintRemaining = mintAvail > mintMaxLimit ? mintMaxLimit : mintAvail;
            burnRemaining = burnAvail > burnMaxLimit ? burnMaxLimit : burnAvail;
        }
        _bridges[bridge] = BridgeConfig({
            mintMaxLimit: mintMaxLimit,
            burnMaxLimit: burnMaxLimit,
            mintRemaining: mintRemaining,
            burnRemaining: burnRemaining,
            lastUpdate: block.timestamp
        });
        emit BridgeLimitsSet(bridge, mintMaxLimit, burnMaxLimit);
    }

    /// @inheritdoc IEUSD
    function setMaxNetBridgedIn(
        uint256 newCap
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MaxNetBridgedInSet(maxNetBridgedIn, newCap);
        maxNetBridgedIn = newCap;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Settle the caller's rolling limits and consume `amount` from the mint or burn side.
    ///      Non-bridges have zero capacity and revert here — limits are the authorization.
    function _consumeLimit(bool isMint, uint256 amount) private {
        BridgeConfig storage cfg = _bridges[msg.sender];
        uint256 mintAvail = _available(cfg.mintRemaining, cfg.mintMaxLimit, cfg.lastUpdate);
        uint256 burnAvail = _available(cfg.burnRemaining, cfg.burnMaxLimit, cfg.lastUpdate);
        if (isMint) {
            if (amount > mintAvail) revert BridgeLimitExceeded(amount, mintAvail);
            mintAvail -= amount;
        } else {
            if (amount > burnAvail) revert BridgeLimitExceeded(amount, burnAvail);
            burnAvail -= amount;
        }
        cfg.mintRemaining = mintAvail;
        cfg.burnRemaining = burnAvail;
        cfg.lastUpdate = block.timestamp;
    }

    /// @dev Linear refill toward `maxLimit` over LIMIT_DURATION since `lastUpdate`.
    function _available(uint256 remaining, uint256 maxLimit, uint256 lastUpdate) private view returns (uint256) {
        if (maxLimit == 0) return 0;
        uint256 avail = remaining + maxLimit * (block.timestamp - lastUpdate) / LIMIT_DURATION;
        return avail > maxLimit ? maxLimit : avail;
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSD
    function bridgeConfig(
        address bridge
    ) external view override returns (BridgeConfig memory) {
        return _bridges[bridge];
    }

    /// @inheritdoc IEUSD
    function bridgeMintAvailable(
        address bridge
    ) external view override returns (uint256) {
        BridgeConfig storage cfg = _bridges[bridge];
        return _available(cfg.mintRemaining, cfg.mintMaxLimit, cfg.lastUpdate);
    }

    /// @inheritdoc IEUSD
    function bridgeBurnAvailable(
        address bridge
    ) external view override returns (uint256) {
        BridgeConfig storage cfg = _bridges[bridge];
        return _available(cfg.burnRemaining, cfg.burnMaxLimit, cfg.lastUpdate);
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IERC7802).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC20Permit
    function nonces(
        address owner
    ) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }
}
