// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IBoostCalculator — pluggable boost curve for OwnStakingV2
/// @notice Maps a position's staked $MONEY value and eUSD to a boost multiplier. Implementations
///         are pure pricing logic: no oracle reads, no state writes. The staking contract clamps
///         the result to its own `maxBoostBps` and holds a position's last snapshot if the
///         calculator reverts, so a calculator can misprice boost but never gate funds.
interface IBoostCalculator {
    /// @notice Boost for a position, in bps (10_000 = 1.0x).
    /// @param moneyValue USD value of the staked $MONEY (1e18).
    /// @param eusdStaked Staked eUSD (1e18).
    function boostBps(uint256 moneyValue, uint256 eusdStaked) external view returns (uint256);
}
