// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBorrowManagerFactory} from "../interfaces/IBorrowManagerFactory.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultBorrowCoordinator} from "../interfaces/IVaultBorrowCoordinator.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {InterestRateModel} from "../libraries/InterestRateModel.sol";
import {AaveBorrowManager} from "./AaveBorrowManager.sol";
import {LPBorrowManager} from "./LPBorrowManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BorrowManagerFactory — Deploys and tracks per-vault borrow managers
/// @notice Admin-gated. Per vault, deploys BOTH a user-borrow manager
///         (`AaveBorrowManager`) and an LP-borrow manager (`LPBorrowManager`)
///         in a single call. 1:1 binding per role per vault. Reverts if the
///         vault is unknown to the VaultFactory or already has a pair.
contract BorrowManagerFactory is IBorrowManagerFactory {
    /// @inheritdoc IBorrowManagerFactory
    address public immutable override aavePool;
    /// @inheritdoc IBorrowManagerFactory
    address public immutable override registry;

    mapping(address => address) internal _borrowManagerOf;
    mapping(address => address) internal _lpBorrowManagerOf;
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
        address coordinator,
        address market,
        bytes32 collateralAsset,
        InterestRateModel.Params calldata rateParams
    ) external onlyAdmin returns (address userBorrowManager, address lpBorrowManager) {
        if (
            vault == address(0) || stablecoin == address(0) || debtToken == address(0) || coordinator == address(0)
                || market == address(0)
        ) revert ZeroAddress();
        if (_borrowManagerOf[vault] != address(0)) revert VaultAlreadyHasBorrowManager(vault);

        address coordVault = IVaultBorrowCoordinator(coordinator).vault();
        if (coordVault != vault) revert CoordinatorVaultMismatch(coordVault, vault);

        // Defensive: only deploy managers for vaults the protocol acknowledges.
        address vf = IProtocolRegistry(registry).vaultFactory();
        if (vf != address(0) && !IVaultFactory(vf).isRegisteredVault(vault)) revert UnknownVault(vault);

        userBorrowManager =
            address(new AaveBorrowManager(vault, stablecoin, debtToken, aavePool, registry, coordinator, rateParams));

        lpBorrowManager = address(
            new LPBorrowManager(
                vault, stablecoin, debtToken, aavePool, market, registry, coordinator, collateralAsset, rateParams
            )
        );

        _borrowManagerOf[vault] = userBorrowManager;
        _lpBorrowManagerOf[vault] = lpBorrowManager;
        _vaultOf[userBorrowManager] = vault;
        _vaultOf[lpBorrowManager] = vault;

        emit BorrowManagersCreated(vault, userBorrowManager, lpBorrowManager);
    }

    /// @inheritdoc IBorrowManagerFactory
    function borrowManagerOf(
        address vault
    ) external view returns (address) {
        return _borrowManagerOf[vault];
    }

    /// @inheritdoc IBorrowManagerFactory
    function lpBorrowManagerOf(
        address vault
    ) external view returns (address) {
        return _lpBorrowManagerOf[vault];
    }

    /// @inheritdoc IBorrowManagerFactory
    function vaultOf(
        address manager
    ) external view returns (address) {
        return _vaultOf[manager];
    }
}
