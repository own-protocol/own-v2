// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {BPS, VMConfig} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title VaultManager — VM registration, delegation, and configuration
/// @notice Manages the lifecycle of vault managers: registration with a vault,
///         spread and exposure settings, stablecoin acceptance, per-asset
///         off-market toggles, and the LP → VM delegation flow.
contract VaultManager is IVaultManager, Ownable {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol-enforced minimum spread in BPS.
    uint256 public override minSpread;

    /// @notice Authorised OwnMarket contract (only caller for updateExposure).
    address public immutable market;

    /// @dev VM address → configuration.
    mapping(address => VMConfig) private _vmConfigs;

    /// @dev VM address → registered vault.
    mapping(address => address) private _vmVaults;

    /// @dev VM → payment token → accepted.
    mapping(address => mapping(address => bool)) private _paymentAcceptance;

    /// @dev VM → asset → off-market enabled.
    mapping(address => mapping(bytes32 => bool)) private _assetOffMarket;

    /// @dev LP → proposed VM (pending delegation).
    mapping(address => address) private _delegationProposals;

    /// @dev LP → active delegated VM.
    mapping(address => address) private _delegatedVM;

    /// @dev VM → array of delegated LPs.
    mapping(address => address[]) private _delegatedLPs;

    /// @dev LP → index in _delegatedLPs[vm] (1-indexed for non-zero check).
    mapping(address => uint256) private _lpDelegationIndex;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyRegistered() {
        if (!_vmConfigs[msg.sender].registered) revert VMNotRegistered(msg.sender);
        _;
    }

    modifier onlyMarket() {
        require(msg.sender == market, "VaultManager: caller is not market");
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param admin_       Protocol admin.
    /// @param market_      OwnMarket contract address.
    /// @param minSpread_   Initial minimum spread in BPS.
    constructor(address admin_, address market_, uint256 minSpread_) Ownable(admin_) {
        market = market_;
        minSpread = minSpread_;
    }

    // ──────────────────────────────────────────────────────────
    //  VM registration
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function registerVM(
        address vault
    ) external {
        if (vault == address(0)) revert ZeroAddress();
        if (_vmConfigs[msg.sender].registered) revert VMAlreadyRegistered(msg.sender);

        _vmConfigs[msg.sender] = VMConfig({
            spread: 0,
            maxExposure: 0,
            maxOffMarketExposure: 0,
            currentExposure: 0,
            registered: true,
            active: true
        });
        _vmVaults[msg.sender] = vault;

        emit VaultManagerRegistered(msg.sender, vault);
    }

    /// @inheritdoc IVaultManager
    function deregisterVM() external onlyRegistered {
        address vault = _vmVaults[msg.sender];

        _vmConfigs[msg.sender].registered = false;
        _vmConfigs[msg.sender].active = false;
        delete _vmVaults[msg.sender];

        emit VaultManagerDeregistered(msg.sender, vault);
    }

    // ──────────────────────────────────────────────────────────
    //  VM configuration
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function setSpread(
        uint256 spreadBps
    ) external onlyRegistered {
        if (spreadBps > BPS) revert InvalidSpread();
        if (spreadBps < minSpread) revert SpreadBelowMinimum(spreadBps, minSpread);

        uint256 oldSpread = _vmConfigs[msg.sender].spread;
        _vmConfigs[msg.sender].spread = spreadBps;

        emit SpreadUpdated(msg.sender, oldSpread, spreadBps);
    }

    /// @inheritdoc IVaultManager
    function setExposureCaps(uint256 maxExposure, uint256 maxOffMarketExposure) external onlyRegistered {
        _vmConfigs[msg.sender].maxExposure = maxExposure;
        _vmConfigs[msg.sender].maxOffMarketExposure = maxOffMarketExposure;

        emit ExposureCapsUpdated(msg.sender, maxExposure, maxOffMarketExposure);
    }

    /// @inheritdoc IVaultManager
    function setPaymentTokenAcceptance(address token, bool accepted) external onlyRegistered {
        _paymentAcceptance[msg.sender][token] = accepted;

        emit PaymentTokenAcceptanceUpdated(msg.sender, token, accepted);
    }

    /// @inheritdoc IVaultManager
    function setAssetOffMarketEnabled(bytes32 asset, bool enabled) external onlyRegistered {
        _assetOffMarket[msg.sender][asset] = enabled;

        emit AssetOffMarketToggled(msg.sender, asset, enabled);
    }

    /// @inheritdoc IVaultManager
    function setVMActive(
        bool active
    ) external onlyRegistered {
        _vmConfigs[msg.sender].active = active;

        emit VMActiveStatusUpdated(msg.sender, active);
    }

    // ──────────────────────────────────────────────────────────
    //  Delegation
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function proposeDelegation(
        address vm
    ) external {
        if (!_vmConfigs[vm].registered) revert VMNotRegistered(vm);
        if (_delegatedVM[msg.sender] != address(0)) revert AlreadyDelegated(msg.sender);

        _delegationProposals[msg.sender] = vm;

        emit DelegationProposed(msg.sender, vm);
    }

    /// @inheritdoc IVaultManager
    function acceptDelegation(
        address lp
    ) external onlyRegistered {
        if (_delegationProposals[lp] != msg.sender) revert DelegationNotProposed(lp, msg.sender);

        delete _delegationProposals[lp];
        _delegatedVM[lp] = msg.sender;

        _delegatedLPs[msg.sender].push(lp);
        _lpDelegationIndex[lp] = _delegatedLPs[msg.sender].length; // 1-indexed

        emit DelegationAccepted(lp, msg.sender);
    }

    /// @inheritdoc IVaultManager
    function removeDelegation() external {
        address vm = _delegatedVM[msg.sender];
        require(vm != address(0), "VaultManager: not delegated");

        // Remove from _delegatedLPs via swap-and-pop
        uint256 idx = _lpDelegationIndex[msg.sender] - 1;
        uint256 lastIdx = _delegatedLPs[vm].length - 1;

        if (idx != lastIdx) {
            address lastLp = _delegatedLPs[vm][lastIdx];
            _delegatedLPs[vm][idx] = lastLp;
            _lpDelegationIndex[lastLp] = idx + 1;
        }
        _delegatedLPs[vm].pop();
        delete _lpDelegationIndex[msg.sender];
        delete _delegatedVM[msg.sender];

        emit DelegationRemoved(msg.sender, vm);
    }

    // ──────────────────────────────────────────────────────────
    //  Exposure tracking (restricted to OwnMarket)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function updateExposure(address vm, int256 delta) external onlyMarket {
        if (delta > 0) {
            _vmConfigs[vm].currentExposure += uint256(delta);
        } else {
            _vmConfigs[vm].currentExposure -= uint256(-delta);
        }

        emit ExposureUpdated(vm, _vmConfigs[vm].currentExposure);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function setMinSpread(
        uint256 minSpreadBps
    ) external onlyOwner {
        minSpread = minSpreadBps;
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IVaultManager
    function getVMConfig(
        address vm
    ) external view returns (VMConfig memory config) {
        return _vmConfigs[vm];
    }

    /// @inheritdoc IVaultManager
    function getVMVault(
        address vm
    ) external view returns (address vault) {
        return _vmVaults[vm];
    }

    /// @inheritdoc IVaultManager
    function getDelegatedVM(
        address lp
    ) external view returns (address vm) {
        return _delegatedVM[lp];
    }

    /// @inheritdoc IVaultManager
    function isPaymentTokenAccepted(address vm, address token) external view returns (bool) {
        return _paymentAcceptance[vm][token];
    }

    /// @inheritdoc IVaultManager
    function isAssetOffMarketEnabled(address vm, bytes32 asset) external view returns (bool) {
        return _assetOffMarket[vm][asset];
    }

    /// @inheritdoc IVaultManager
    function getDelegatedLPs(
        address vm
    ) external view returns (address[] memory lps) {
        return _delegatedLPs[vm];
    }
}
