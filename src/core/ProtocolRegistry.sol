// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ProtocolRegistry — Central registry of all protocol contract addresses
/// @notice Stores addresses of all protocol contracts. Other contracts look up dependencies here
/// instead of storing individual references. All address changes require a timelock delay,
/// except for first-time initialization (setting a slot from address(0)).
/// @dev Owner is expected to be a governance multisig.
contract ProtocolRegistry is IProtocolRegistry, Ownable {
    // ──────────────────────────────────────────────────────────────
    //  Constants — contract slot keys
    // ──────────────────────────────────────────────────────────────

    bytes32 public constant ORACLE_VERIFIER = keccak256("ORACLE_VERIFIER");
    bytes32 public constant FEE_CALCULATOR = keccak256("FEE_CALCULATOR");
    bytes32 public constant MARKET = keccak256("MARKET");
    bytes32 public constant ASSET_REGISTRY = keccak256("ASSET_REGISTRY");
    bytes32 public constant TREASURY = keccak256("TREASURY");
    bytes32 public constant VAULT_FACTORY = keccak256("VAULT_FACTORY");

    // ──────────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────────

    /// @dev A pending timelocked address change.
    struct TimelockProposal {
        address newAddr;
        uint256 effectiveAt;
    }

    // ──────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────

    /// @dev Contract address storage: key → address.
    mapping(bytes32 => address) private _addresses;

    /// @dev Pending timelocked proposals: key → proposal.
    mapping(bytes32 => TimelockProposal) private _timelocks;

    /// @notice Minimum delay (seconds) before a timelocked change can be executed.
    uint256 public override timelockDelay;

    /// @dev Protocol's share of all order fees in BPS.
    uint256 private _protocolShareBps;

    // ──────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────

    /// @param admin_         Initial owner (governance multisig).
    /// @param timelockDelay_ Delay in seconds for timelocked changes (e.g. 172800 = 48 hours).
    constructor(address admin_, uint256 timelockDelay_) Ownable(admin_) {
        timelockDelay = timelockDelay_;
    }

    // ──────────────────────────────────────────────────────────────
    //  Getters
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolRegistry
    function oracleVerifier() external view override returns (address) {
        return _addresses[ORACLE_VERIFIER];
    }

    /// @inheritdoc IProtocolRegistry
    function feeCalculator() external view override returns (address) {
        return _addresses[FEE_CALCULATOR];
    }

    /// @inheritdoc IProtocolRegistry
    function market() external view override returns (address) {
        return _addresses[MARKET];
    }

    /// @inheritdoc IProtocolRegistry
    function assetRegistry() external view override returns (address) {
        return _addresses[ASSET_REGISTRY];
    }

    /// @inheritdoc IProtocolRegistry
    function treasury() external view override returns (address) {
        return _addresses[TREASURY];
    }

    /// @inheritdoc IProtocolRegistry
    function vaultFactory() external view override returns (address) {
        return _addresses[VAULT_FACTORY];
    }

    /// @inheritdoc IProtocolRegistry
    function protocolShareBps() external view override returns (uint256) {
        return _protocolShareBps;
    }

    /// @inheritdoc IProtocolRegistry
    function setProtocolShareBps(
        uint256 shareBps
    ) external override onlyOwner {
        require(shareBps <= 10_000, "ProtocolRegistry: share > 100%");
        _protocolShareBps = shareBps;
    }

    // ──────────────────────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolRegistry
    function setAddress(bytes32 key, address newAddr) external override onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        if (_addresses[key] != address(0)) revert AlreadyInitialized();
        _addresses[key] = newAddr;
        emit ContractInitialized(key, newAddr);
    }

    // ──────────────────────────────────────────────────────────────
    //  Timelocked Updates
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolRegistry
    function proposeAddress(bytes32 key, address newAddr) external override onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        if (newAddr == _addresses[key]) revert SameAddress();
        uint256 effectiveAt = block.timestamp + timelockDelay;
        _timelocks[key] = TimelockProposal({newAddr: newAddr, effectiveAt: effectiveAt});
        emit TimelockProposed(key, newAddr, effectiveAt);
    }

    /// @inheritdoc IProtocolRegistry
    function executeTimelock(
        bytes32 key
    ) external override {
        TimelockProposal memory proposal = _timelocks[key];
        if (proposal.newAddr == address(0)) revert TimelockNotProposed();
        if (block.timestamp < proposal.effectiveAt) revert TimelockNotReady();

        address oldAddr = _addresses[key];
        _addresses[key] = proposal.newAddr;
        delete _timelocks[key];

        emit TimelockExecuted(key, oldAddr, proposal.newAddr);
    }

    /// @inheritdoc IProtocolRegistry
    function cancelTimelock(
        bytes32 key
    ) external override onlyOwner {
        if (_timelocks[key].newAddr == address(0)) revert TimelockNotProposed();
        delete _timelocks[key];
        emit TimelockCancelled(key);
    }

    /// @inheritdoc IProtocolRegistry
    function pendingTimelockOf(
        bytes32 key
    ) external view override returns (address newAddr, uint256 effectiveAt) {
        TimelockProposal memory proposal = _timelocks[key];
        return (proposal.newAddr, proposal.effectiveAt);
    }
}
