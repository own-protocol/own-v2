// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockYieldManager — minimal contract vault manager for tests
/// @notice Stands in for the production VaultYieldManager as `vault.manager`, which must be a
///         contract (the vault calls `syncYield()` on it when pricing LP entries and exits).
///         Tests prank manager-gated vault calls from this address.
contract MockYieldManager {
    /// @notice Number of times the vault synced yield through this manager.
    uint256 public syncYieldCalls;

    /// @notice No-op yield sync; counts calls so tests can assert the vault hook fired.
    function syncYield() external {
        syncYieldCalls++;
    }
}
