// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Lending-venue authorization interface
/// @notice Minimal, generic shape for the on-behalf credit-delegation a collateral vault grants so
///         its borrow manager can borrow for it. The call registers the manager as a delegatee —
///         it moves none of the vault's assets. Matches Aave V3's variable-debt-token
///         `approveDelegation`. (In-house lending needs no such grant.)
interface ICreditDelegation {
    /// @notice Approve `delegatee` to incur debt on the caller's behalf, up to `amount`.
    function approveDelegation(address delegatee, uint256 amount) external;
}
