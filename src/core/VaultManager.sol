// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {VMConfig} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title VaultManager — VM registration and configuration
/// @notice Manages the lifecycle of vault managers: registration with a vault,
///         exposure settings, stablecoin acceptance, and per-asset off-market toggles.
///         Each VM is bound 1:1 to a single vault.
contract VaultManager is IVaultManager, Ownable {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol registry for resolving all contract addresses.
    IProtocolRegistry public immutable registry;

    /// @dev VM address → configuration.
    mapping(address => VMConfig) private _vmConfigs;

    /// @dev VM address → registered vault.
    mapping(address => address) private _vmVaults;

    /// @dev Vault address → bound VM (reverse lookup, enforces 1:1).
    mapping(address => address) private _vaultVMs;

    /// @dev VM → payment token → accepted.
    mapping(address => mapping(address => bool)) private _paymentAcceptance;

    /// @dev VM → asset → off-market enabled.
    mapping(address => mapping(bytes32 => bool)) private _assetOffMarket;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyRegistered() {
        if (!_vmConfigs[msg.sender].registered) revert VMNotRegistered(msg.sender);
        _;
    }

    modifier onlyMarket() {
        require(msg.sender == registry.market(), "VaultManager: caller is not market");
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param admin_       Protocol admin.
    /// @param registry_    ProtocolRegistry contract address.
    constructor(address admin_, address registry_) Ownable(admin_) {
        registry = IProtocolRegistry(registry_);
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
        if (_vaultVMs[vault] != address(0)) revert VaultAlreadyHasVM(vault);

        _vmConfigs[msg.sender] =
            VMConfig({maxExposure: 0, maxOffMarketExposure: 0, currentExposure: 0, registered: true, active: true});
        _vmVaults[msg.sender] = vault;
        _vaultVMs[vault] = msg.sender;

        emit VaultManagerRegistered(msg.sender, vault);
    }

    /// @inheritdoc IVaultManager
    function deregisterVM() external onlyRegistered {
        address vault = _vmVaults[msg.sender];

        _vmConfigs[msg.sender].registered = false;
        _vmConfigs[msg.sender].active = false;
        delete _vaultVMs[vault];
        delete _vmVaults[msg.sender];

        emit VaultManagerDeregistered(msg.sender, vault);
    }

    // ──────────────────────────────────────────────────────────
    //  VM configuration
    // ──────────────────────────────────────────────────────────

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
    function getVaultVM(
        address vault
    ) external view returns (address vm) {
        return _vaultVMs[vault];
    }

    /// @inheritdoc IVaultManager
    function isPaymentTokenAccepted(address vm, address token) external view returns (bool) {
        return _paymentAcceptance[vm][token];
    }

    /// @inheritdoc IVaultManager
    function isAssetOffMarketEnabled(address vm, bytes32 asset) external view returns (bool) {
        return _assetOffMarket[vm][asset];
    }
}
