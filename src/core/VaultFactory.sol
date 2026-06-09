// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {OwnVault} from "./OwnVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title VaultFactory — Admin-controlled vault deployment and registry
/// @notice Protocol admin creates vaults with chosen collateral and VM.
///         OwnMarket verifies vaults are registered here before processing orders.
contract VaultFactory is IVaultFactory, Ownable {
    IProtocolRegistry public immutable registry;

    address[] private _vaults;
    mapping(address => bool) private _isRegistered;

    constructor(address admin_, address registry_) Ownable(admin_) {
        registry = IProtocolRegistry(registry_);
    }

    /// @inheritdoc IVaultFactory
    function createVault(
        address collateral,
        address manager,
        string calldata name,
        string calldata symbol,
        bytes32 collateralAsset
    ) external onlyOwner returns (address vault) {
        if (collateral == address(0)) revert ZeroAddress();
        if (manager == address(0)) revert ZeroAddress();

        vault = address(new OwnVault(collateral, name, symbol, address(registry), manager));

        _isRegistered[vault] = true;
        _vaults.push(vault);

        IVaultManager(registry.vaultManager()).registerVault(vault, collateralAsset);

        emit VaultCreated(vault, collateral, manager);
    }

    /// @inheritdoc IVaultFactory
    function deregisterVault(
        address vault
    ) external onlyOwner {
        if (!_isRegistered[vault]) revert VaultNotRegistered(vault);
        _isRegistered[vault] = false;
        IVaultManager(registry.vaultManager()).deregisterVault(vault);
        emit VaultDeregistered(vault);
    }

    /// @inheritdoc IVaultFactory
    function isRegisteredVault(
        address vault
    ) external view returns (bool) {
        return _isRegistered[vault];
    }

    /// @inheritdoc IVaultFactory
    function getAllVaults() external view returns (address[] memory) {
        return _vaults;
    }
}
