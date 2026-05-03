// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBorrowManagerFactory} from "../interfaces/IBorrowManagerFactory.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {InterestRateModel} from "../libraries/InterestRateModel.sol";
import {AaveBorrowManager} from "./AaveBorrowManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BorrowManagerFactory — Deploys and tracks per-vault borrow managers
/// @notice Admin-gated. One borrow manager per vault (1:1 binding). Reverts if
///         the vault is unknown to the VaultFactory or already has a manager.
contract BorrowManagerFactory is IBorrowManagerFactory {
    /// @inheritdoc IBorrowManagerFactory
    address public immutable override aavePool;
    /// @inheritdoc IBorrowManagerFactory
    address public immutable override registry;

    mapping(address => address) internal _borrowManagerOf;
    mapping(address => address) internal _vaultOf;

    modifier onlyAdmin() {
        if (msg.sender != Ownable(registry).owner()) revert OnlyAdmin();
        _;
    }

    constructor(address aavePool_, address registry_) {
        if (aavePool_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        aavePool = aavePool_;
        registry = registry_;
    }

    /// @inheritdoc IBorrowManagerFactory
    function createBorrowManager(
        address vault,
        address stablecoin,
        address debtToken,
        InterestRateModel.Params calldata rateParams
    ) external onlyAdmin returns (address borrowManager) {
        if (vault == address(0) || stablecoin == address(0) || debtToken == address(0)) revert ZeroAddress();
        if (_borrowManagerOf[vault] != address(0)) revert VaultAlreadyHasBorrowManager(vault);

        // Defensive: only deploy managers for vaults the protocol acknowledges.
        address vf = IProtocolRegistry(registry).vaultFactory();
        if (vf != address(0) && !IVaultFactory(vf).isRegisteredVault(vault)) revert UnknownVault(vault);

        borrowManager = address(new AaveBorrowManager(vault, stablecoin, debtToken, aavePool, registry, rateParams));

        _borrowManagerOf[vault] = borrowManager;
        _vaultOf[borrowManager] = vault;

        emit BorrowManagerCreated(vault, borrowManager);
    }

    /// @inheritdoc IBorrowManagerFactory
    function borrowManagerOf(
        address vault
    ) external view returns (address) {
        return _borrowManagerOf[vault];
    }

    /// @inheritdoc IBorrowManagerFactory
    function vaultOf(
        address borrowManager
    ) external view returns (address) {
        return _vaultOf[borrowManager];
    }
}
