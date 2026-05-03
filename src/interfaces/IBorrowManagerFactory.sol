// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../libraries/InterestRateModel.sol";

/// @title IBorrowManagerFactory — Deploys and tracks per-vault borrow managers
/// @notice One borrow manager per vault (1:1 binding), mirroring the VM↔vault
///         model used elsewhere. Admin-gated: deployment of new managers is
///         restricted to the protocol admin so liquidity is only borrowed
///         against vaults that the protocol has explicitly opted in.
interface IBorrowManagerFactory {
    /// @notice Emitted when a new borrow manager is deployed for a vault.
    event BorrowManagerCreated(address indexed vault, address indexed borrowManager);

    error ZeroAddress();
    error OnlyAdmin();
    error VaultAlreadyHasBorrowManager(address vault);
    error UnknownVault(address vault);
    error CoordinatorVaultMismatch(address coordinatorVault, address vault);

    /// @notice Deploy a borrow manager for `vault`. One-shot per vault.
    /// @param vault       OwnVault to bind the borrow manager to.
    /// @param stablecoin  Stablecoin asset that will be borrowed (e.g. USDC).
    /// @param debtToken   Aave variable debt token paired with `stablecoin`.
    /// @param coordinator VaultBorrowCoordinator that mediates utilization /
    ///                    rate / hard cap across managers. Cannot be zero;
    ///                    its `vault()` must equal `vault`.
    /// @param rateParams  Initial interest rate curve parameters.
    /// @return borrowManager Address of the newly deployed AaveBorrowManager.
    function createBorrowManager(
        address vault,
        address stablecoin,
        address debtToken,
        address coordinator,
        InterestRateModel.Params calldata rateParams
    ) external returns (address borrowManager);

    /// @notice Address of the borrow manager bound to `vault`, or zero if none.
    function borrowManagerOf(
        address vault
    ) external view returns (address);

    /// @notice Vault bound to `borrowManager`, or zero if not a known manager.
    function vaultOf(
        address borrowManager
    ) external view returns (address);

    /// @notice Aave V3 Pool used by deployed borrow managers.
    function aavePool() external view returns (address);

    /// @notice Address of the ProtocolRegistry.
    function registry() external view returns (address);
}
