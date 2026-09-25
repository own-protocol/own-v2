// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBoostCalculator} from "./IBoostCalculator.sol";

/// @title ITieredBoostCalculator — size-tiered boost curve for OwnStakingV2
/// @notice Linear-in-coverage boost whose full-boost coverage steps down as a position's staked
///         eUSD grows: `boost = floorBps + (maxBoostBps − floorBps) × coverage / tierCoverage`,
///         clamped at `maxBoostBps`, where `tierCoverage` is the `maxCoverageBps` of the highest
///         tier whose `minEusd` the position's staked eUSD reaches.
/// @dev Tiers ascend in `minEusd` (first tier at 0) with non-increasing `maxCoverageBps`. That
///      ordering keeps weight (`eusd × boost`) monotone in staked eUSD (A5-H-01) and makes
///      splitting a position across accounts never weight-profitable (A5-M-05).
interface ITieredBoostCalculator is IBoostCalculator {
    /// @notice One size tier.
    /// @param minEusd        Staked eUSD (1e18) at and above which this tier applies.
    /// @param maxCoverageBps Coverage (bps) at which a position in this tier reaches `maxBoostBps`.
    struct Tier {
        uint128 minEusd;
        uint128 maxCoverageBps;
    }

    /// @notice `maxBoostBps` is below `floorBps`.
    error InvalidBoostRange();

    /// @notice Tier count is zero or above {MAX_TIERS}.
    error InvalidTierCount();

    /// @notice The first tier's `minEusd` is not zero, so small positions would have no tier.
    error FirstTierNotZero();

    /// @notice Tier `index` does not strictly raise `minEusd` over the previous tier.
    /// @param index Offending tier index.
    error TiersNotAscending(uint256 index);

    /// @notice Tier `index` raises `maxCoverageBps` over the previous tier, or sets it to zero.
    /// @param index Offending tier index.
    error InvalidTierCoverage(uint256 index);

    /// @notice Upper bound on the number of tiers, bounding the lookup a staking touch pays for.
    function MAX_TIERS() external view returns (uint256);

    /// @notice Boost at zero coverage, in bps.
    function floorBps() external view returns (uint256);

    /// @notice Boost at and beyond a tier's `maxCoverageBps`, in bps.
    function maxBoostBps() external view returns (uint256);

    /// @notice All tiers, ascending by `minEusd`.
    /// @return The tier table.
    function tiers() external view returns (Tier[] memory);

    /// @notice Full-boost coverage for a position with `eusdStaked` staked.
    /// @param eusdStaked Staked eUSD (1e18).
    /// @return Coverage in bps at which that position reaches `maxBoostBps`.
    function maxCoverageFor(
        uint256 eusdStaked
    ) external view returns (uint256);
}
