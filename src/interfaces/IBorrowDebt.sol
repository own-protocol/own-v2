// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IBorrowDebt — Borrow manager debt-reporting interface
/// @notice Implemented by every borrow manager that participates in a shared
///         `VaultBorrowCoordinator`. The coordinator sums `totalDebtUSD()`
///         across registered managers to compute the vault's total outstanding
///         protocol debt and the resulting utilization figure that feeds
///         every manager's interest-rate curve.
///
/// @dev    `totalDebtUSD()` MUST be in 18-decimal USD and MUST include accrued
///         interest up to (at least) the manager's last accrual point. Live
///         accrual is not required — the coordinator reads frequently enough
///         that any drift is absorbed by the next state-changing call.
interface IBorrowDebt {
    /// @notice Total outstanding protocol debt held by this manager, in USD
    ///         (18 decimals). Includes principal + accrued interest.
    function totalDebtUSD() external view returns (uint256);
}
