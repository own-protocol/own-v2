// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveDebtToken — Minimal credit-delegation interface for Aave V3 debt tokens
/// @notice Aave V3 variable/stable debt tokens implement EIP-style credit delegation:
///         the holder of a debt position can authorise another address to borrow on
///         their behalf via `approveDelegation`. The delegate's call to
///         `IAaveV3Pool.borrow(..., onBehalfOf=position)` then debits the position's
///         debt token while sending the borrowed asset to the delegate.
interface IAaveDebtToken {
    /// @notice Authorise `delegatee` to incur up to `amount` of debt on behalf of
    ///         the caller via `IAaveV3Pool.borrow`. Use `type(uint256).max` for
    ///         unlimited delegation; the caller's collateral and Aave LTV still
    ///         enforce the actual borrowing cap.
    /// @param delegatee Address that may borrow on behalf of the caller.
    /// @param amount    Borrow allowance in the underlying debt asset's decimals.
    function approveDelegation(address delegatee, uint256 amount) external;

    /// @notice Return the remaining delegation allowance from `fromUser` to `toUser`.
    function borrowAllowance(address fromUser, address toUser) external view returns (uint256);
}
