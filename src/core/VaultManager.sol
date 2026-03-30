// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {VMConfig} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title VaultManager — VM registration and configuration
/// @notice Manages VM lifecycle: registration with a vault, exposure caps,
///         and active status. Each VM is bound 1:1 to a single vault.
contract VaultManager is IVaultManager, Ownable {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;

    mapping(address => VMConfig) private _vmConfigs;
    mapping(address => address) private _vmVaults;
    mapping(address => address) private _vaultVMs;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyRegistered() {
        if (!_vmConfigs[msg.sender].registered) revert VMNotRegistered(msg.sender);
        _;
    }

    error OnlyMarket();

    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

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

        _vmConfigs[msg.sender] = VMConfig({maxExposure: 0, currentExposure: 0, registered: true, active: true});
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
    function setExposureCaps(
        uint256 maxExposure
    ) external onlyRegistered {
        _vmConfigs[msg.sender].maxExposure = maxExposure;

        emit ExposureCapsUpdated(msg.sender, maxExposure);
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
    ) external view returns (VMConfig memory) {
        return _vmConfigs[vm];
    }

    /// @inheritdoc IVaultManager
    function getVMVault(
        address vm
    ) external view returns (address) {
        return _vmVaults[vm];
    }

    /// @inheritdoc IVaultManager
    function getVaultVM(
        address vault
    ) external view returns (address) {
        return _vaultVMs[vault];
    }
}
