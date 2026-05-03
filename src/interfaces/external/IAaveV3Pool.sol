// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3Pool — Minimal Aave V3 Pool interface
/// @notice The subset of Aave V3 Pool functions used by Own Protocol periphery
///         contracts (AaveRouter for supplies/withdrawals, AaveBorrowManager for
///         delegated borrowing and repayment, plus account-data reads).
interface IAaveV3Pool {
    /// @notice Supply `amount` of `asset` to the Aave reserve, crediting `onBehalfOf`
    ///         with the matching aTokens.
    /// @param asset       The reserve asset to supply (e.g. wstETH).
    /// @param amount      Amount of `asset` (in `asset` decimals).
    /// @param onBehalfOf  Address that receives the aTokens.
    /// @param referralCode Aave referral code (0 if unused).
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraw `amount` of `asset` from the Aave reserve, burning the
    ///         caller's aTokens. Pass `type(uint256).max` to withdraw the full balance.
    /// @param asset  The reserve asset to withdraw.
    /// @param amount Amount of `asset` to withdraw.
    /// @param to     Address that receives the underlying `asset`.
    /// @return The actual amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Borrow `amount` of `asset` against `onBehalfOf`'s collateral position.
    ///         For credit-delegated borrows, the caller must have a non-zero borrow
    ///         allowance from `onBehalfOf` on the corresponding debt token.
    /// @param asset             The reserve asset to borrow (e.g. USDC).
    /// @param amount            Amount of `asset` to borrow.
    /// @param interestRateMode  1 = stable, 2 = variable.
    /// @param referralCode      Aave referral code (0 if unused).
    /// @param onBehalfOf        Address whose collateral backs the borrow and whose
    ///                          debt token balance increases.
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    /// @notice Repay `amount` of debt against `onBehalfOf`'s position. Pass
    ///         `type(uint256).max` to repay the full debt balance.
    /// @param asset             The borrowed reserve asset.
    /// @param amount            Amount to repay.
    /// @param interestRateMode  1 = stable, 2 = variable (must match the debt mode).
    /// @param onBehalfOf        Address whose debt is reduced.
    /// @return The actual amount repaid.
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);

    /// @notice Mark `asset` as collateral / non-collateral for the caller's
    ///         Aave position. Requires a non-zero aToken balance for `asset`.
    /// @param asset       Reserve underlying.
    /// @param useAsCollateral True to enable, false to disable.
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

    /// @notice Return aggregated account data for `user`.
    /// @return totalCollateralBase     Total collateral in the base currency (1e8 USD).
    /// @return totalDebtBase           Total debt in the base currency (1e8 USD).
    /// @return availableBorrowsBase    Remaining borrowing capacity in the base currency.
    /// @return currentLiquidationThreshold Weighted liquidation threshold (BPS).
    /// @return ltv                     Weighted loan-to-value (BPS).
    /// @return healthFactor            Aave health factor (1e18 = 1.0).
    function getUserAccountData(
        address user
    )
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
