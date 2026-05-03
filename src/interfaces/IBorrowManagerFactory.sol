// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../libraries/InterestRateModel.sol";

/// @title IBorrowManagerFactory — Deploys and tracks per-vault borrow managers
/// @notice One pair of borrow managers per vault (1:1 binding):
///         - AaveBorrowManager for users borrowing against eTokens.
///         - LPBorrowManager   for LPs borrowing against vault shares.
///
///         Both managers are deployed in a single admin-gated call so the
///         vault wiring (`enableLending` delegating to both) lines up with
///         the factory's bookkeeping.
interface IBorrowManagerFactory {
    /// @notice Emitted when a new pair of borrow managers is deployed.
    event BorrowManagersCreated(
        address indexed vault, address indexed userBorrowManager, address indexed lpBorrowManager
    );

    error ZeroAddress();
    error OnlyAdmin();
    error VaultAlreadyHasBorrowManager(address vault);
    error UnknownVault(address vault);
    error CoordinatorVaultMismatch(address coordinatorVault, address vault);

    /// @notice Deploy a (user, LP) borrow-manager pair for `vault`. One-shot per vault.
    /// @param vault            OwnVault to bind the managers to.
    /// @param stablecoin       Stablecoin asset that will be borrowed (e.g. USDC).
    /// @param debtToken        Aave variable debt token paired with `stablecoin`.
    /// @param coordinator      VaultBorrowCoordinator that mediates utilization /
    ///                         rate / hard cap across managers. Cannot be zero;
    ///                         its `vault()` must equal `vault`.
    /// @param market           OwnMarket address used by the LP manager when
    ///                         placing mint orders on the LP's behalf.
    /// @param collateralAsset  Vault's collateral oracle ticker (e.g. WSTETH)
    ///                         used by the LP manager for share valuation.
    /// @param rateParams       Initial interest-rate curve params (shared
    ///                         across both managers at deploy time).
    /// @return userBorrowManager Address of the deployed AaveBorrowManager.
    /// @return lpBorrowManager   Address of the deployed LPBorrowManager.
    function createBorrowManager(
        address vault,
        address stablecoin,
        address debtToken,
        address coordinator,
        address market,
        bytes32 collateralAsset,
        InterestRateModel.Params calldata rateParams
    ) external returns (address userBorrowManager, address lpBorrowManager);

    /// @notice Address of the user-borrow manager bound to `vault`, or zero if none.
    function borrowManagerOf(
        address vault
    ) external view returns (address);

    /// @notice Address of the LP-borrow manager bound to `vault`, or zero if none.
    function lpBorrowManagerOf(
        address vault
    ) external view returns (address);

    /// @notice Vault bound to `manager`, or zero if `manager` was not deployed
    ///         by this factory. Works for either manager type.
    function vaultOf(
        address manager
    ) external view returns (address);

    /// @notice Aave V3 Pool used by deployed borrow managers.
    function aavePool() external view returns (address);

    /// @notice Address of the ProtocolRegistry.
    function registry() external view returns (address);
}
