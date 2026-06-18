// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @title ProtocolRegistry — Central registry of all protocol contract addresses + role authority
/// @notice Stores all protocol contract addresses and is the single AccessControl authority for the
///         protocol. Every governed contract resolves permissions here via {hasRole}.
/// @dev `setAddress` and `setPriceMaxAge` are gated by `PROTOCOL_ADMIN` — the OZ `DEFAULT_ADMIN_ROLE`,
///      which also administers the protocol-wide `ADMIN` and `OPERATOR` roles. Expected to be held by a
///      TimelockController, so registry changes and all role grants are time-delayed. `PROTOCOL_ADMIN`
///      transfers use the 2-step + delayed flow from AccessControlDefaultAdminRules.
contract ProtocolRegistry is IProtocolRegistry, AccessControlDefaultAdminRules {
    // ──────────────────────────────────────────────────────────────
    //  Constants — contract slot keys
    // ──────────────────────────────────────────────────────────────

    bytes32 public constant MARKET = keccak256("MARKET");
    bytes32 public constant ASSET_REGISTRY = keccak256("ASSET_REGISTRY");
    bytes32 public constant PYTH_ORACLE = keccak256("PYTH_ORACLE");
    bytes32 public constant INHOUSE_ORACLE = keccak256("INHOUSE_ORACLE");
    bytes32 public constant ETOKEN_FACTORY = keccak256("ETOKEN_FACTORY");
    bytes32 public constant VAULT_MANAGER = keccak256("VAULT_MANAGER");
    bytes32 public constant TREASURY = keccak256("TREASURY");

    // ──────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────

    /// @dev Contract address storage: key → address.
    mapping(bytes32 => address) private _addresses;

    /// @dev Governance-tunable max age for inline "current price" proofs. See {priceMaxAge}.
    uint256 private _priceMaxAge;

    // ──────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────

    /// @param initialDefaultAdmin   Initial holder of `PROTOCOL_ADMIN` (the deployer during bootstrap;
    ///                              handed to the timelock at the end of deployment).
    /// @param ownAdminTransferDelay Delay (seconds) enforced on transferring `PROTOCOL_ADMIN`.
    /// @param priceMaxAge_          Max age (seconds) for inline "current price" proofs. Must be non-zero.
    constructor(
        address initialDefaultAdmin,
        uint48 ownAdminTransferDelay,
        uint256 priceMaxAge_
    ) AccessControlDefaultAdminRules(ownAdminTransferDelay, initialDefaultAdmin) {
        if (priceMaxAge_ == 0) revert InvalidPriceMaxAge();
        _priceMaxAge = priceMaxAge_;
    }

    // ──────────────────────────────────────────────────────────────
    //  Getters
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolRegistry
    function market() external view override returns (address) {
        return _addresses[MARKET];
    }

    /// @inheritdoc IProtocolRegistry
    function assetRegistry() external view override returns (address) {
        return _addresses[ASSET_REGISTRY];
    }

    /// @inheritdoc IProtocolRegistry
    function pythOracle() external view override returns (address) {
        return _addresses[PYTH_ORACLE];
    }

    /// @inheritdoc IProtocolRegistry
    function inhouseOracle() external view override returns (address) {
        return _addresses[INHOUSE_ORACLE];
    }

    /// @inheritdoc IProtocolRegistry
    function etokenFactory() external view override returns (address) {
        return _addresses[ETOKEN_FACTORY];
    }

    /// @inheritdoc IProtocolRegistry
    function vaultManager() external view override returns (address) {
        return _addresses[VAULT_MANAGER];
    }

    /// @inheritdoc IProtocolRegistry
    function treasury() external view override returns (address) {
        return _addresses[TREASURY];
    }

    /// @inheritdoc IProtocolRegistry
    function priceMaxAge() external view override returns (uint256) {
        return _priceMaxAge;
    }

    // ──────────────────────────────────────────────────────────────
    //  Setters (PROTOCOL_ADMIN — held by the timelock)
    // ──────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolRegistry
    function setAddress(bytes32 key, address newAddr) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAddr == address(0)) revert ZeroAddress();
        address old = _addresses[key];
        _addresses[key] = newAddr;
        emit AddressSet(key, old, newAddr);
    }

    /// @inheritdoc IProtocolRegistry
    function setPriceMaxAge(
        uint256 newMaxAge
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxAge == 0) revert InvalidPriceMaxAge();
        uint256 old = _priceMaxAge;
        _priceMaxAge = newMaxAge;
        emit PriceMaxAgeUpdated(old, newMaxAge);
    }
}
