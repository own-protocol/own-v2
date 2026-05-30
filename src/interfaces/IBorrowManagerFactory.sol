// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../libraries/InterestRateModel.sol";

/// @title IBorrowManagerFactory — Deploys and tracks per-vault borrow managers
/// @notice One UserBorrowManager per vault (1:1 binding) for users borrowing
///         against eTokens. Deployed in a single admin-gated call that lines up
///         with the vault wiring (`enableLending`).
interface IBorrowManagerFactory {
    /// @notice Emitted when a new borrow manager is deployed.
    event BorrowManagerCreated(address indexed vault, address indexed userBorrowManager);

    error ZeroAddress();
    error OnlyAdmin();
    error VaultAlreadyHasBorrowManager(address vault);
    error UnknownVault(address vault);

    /// @notice Deploy a UserBorrowManager for `vault`. One-shot per vault.
    /// @param vault            OwnVault to bind the manager to.
    /// @param stablecoin       Stablecoin asset that will be borrowed (e.g. USDC).
    /// @param debtToken        Aave variable debt token paired with `stablecoin`.
    /// @param targetLtvBps     Vault-wide target Aave LTV (BPS) backing the debt cap.
    /// @param rateParams       Initial interest-rate curve params.
    /// @return userBorrowManager Address of the deployed UserBorrowManager.
    function createBorrowManager(
        address vault,
        address stablecoin,
        address debtToken,
        uint256 targetLtvBps,
        InterestRateModel.Params calldata rateParams
    ) external returns (address userBorrowManager);

    /// @notice Address of the user-borrow manager bound to `vault`, or zero if none.
    function borrowManagerOf(
        address vault
    ) external view returns (address);

    /// @notice Vault bound to `manager`, or zero if `manager` was not deployed
    ///         by this factory.
    function vaultOf(
        address manager
    ) external view returns (address);

    /// @notice Aave V3 Pool used by deployed borrow managers.
    function aavePool() external view returns (address);

    /// @notice Address of the ProtocolRegistry.
    function registry() external view returns (address);
}
