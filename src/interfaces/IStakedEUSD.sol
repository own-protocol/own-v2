// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IStakedEUSD — the sEUSD surface consumed by OwnIncentives
/// @notice Minimal view of the staked-eUSD vault: which incentives controller (if any) is wired
///         to its balance-change hook. See {StakedEUSD} for the full vault.
interface IStakedEUSD {
    /// @notice OWN incentives controller notified on every balance change (address(0) = none).
    function incentivesController() external view returns (address);
}
