// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBoostCalculator} from "../interfaces/IBoostCalculator.sol";
import {ITieredBoostCalculator} from "../interfaces/ITieredBoostCalculator.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TieredBoostCalculator — boost rises linearly with coverage to a size-tiered cap
/// @notice Larger positions reach `maxBoostBps` at lower coverage: each tier sets the coverage at
///         which a position of at least `minEusd` staked eUSD is fully boosted. Immutable —
///         deploy a new calculator and swap it in via {OwnStakingV2.setBoostCalculator} to
///         change the floor, the max or the tier table.
contract TieredBoostCalculator is ITieredBoostCalculator {
    /// @inheritdoc ITieredBoostCalculator
    uint256 public constant override MAX_TIERS = 16;

    /// @inheritdoc ITieredBoostCalculator
    uint256 public immutable override floorBps;
    /// @inheritdoc ITieredBoostCalculator
    uint256 public immutable override maxBoostBps;

    Tier[] private _tiers;

    /// @param floorBps_    Boost at zero coverage, in bps.
    /// @param maxBoostBps_ Boost at and beyond a tier's full-boost coverage, in bps.
    /// @param tiers_       Tier table: first `minEusd` 0, `minEusd` strictly ascending,
    ///                     `maxCoverageBps` non-zero and non-increasing.
    constructor(uint256 floorBps_, uint256 maxBoostBps_, Tier[] memory tiers_) {
        if (maxBoostBps_ < floorBps_) revert InvalidBoostRange();
        uint256 len = tiers_.length;
        if (len == 0 || len > MAX_TIERS) revert InvalidTierCount();
        if (tiers_[0].minEusd != 0) revert FirstTierNotZero();
        for (uint256 i; i < len; ++i) {
            Tier memory t = tiers_[i];
            if (t.maxCoverageBps == 0) revert InvalidTierCoverage(i);
            if (i != 0) {
                if (t.minEusd <= tiers_[i - 1].minEusd) revert TiersNotAscending(i);
                if (t.maxCoverageBps > tiers_[i - 1].maxCoverageBps) revert InvalidTierCoverage(i);
            }
            _tiers.push(t);
        }
        floorBps = floorBps_;
        maxBoostBps = maxBoostBps_;
    }

    /// @inheritdoc IBoostCalculator
    /// @dev Single-floor form of `floor + span × coverage / tierCoverage`, so the result is at most
    ///      1 bps under the exact curve. The full-boost value rounds up: the cap is never reached
    ///      short of the tier's coverage.
    function boostBps(uint256 moneyValue, uint256 eusdStaked) external view override returns (uint256) {
        if (eusdStaked == 0) return 0;
        uint256 fullValue = Math.mulDiv(eusdStaked, maxCoverageFor(eusdStaked), BPS, Math.Rounding.Ceil);
        if (moneyValue >= fullValue) return maxBoostBps;
        return floorBps + Math.mulDiv(maxBoostBps - floorBps, moneyValue, fullValue);
    }

    /// @inheritdoc ITieredBoostCalculator
    function tiers() external view override returns (Tier[] memory) {
        return _tiers;
    }

    /// @inheritdoc ITieredBoostCalculator
    function maxCoverageFor(
        uint256 eusdStaked
    ) public view override returns (uint256) {
        uint256 i = _tiers.length;
        while (--i != 0) {
            Tier memory t = _tiers[i];
            if (eusdStaked >= t.minEusd) return t.maxCoverageBps;
        }
        return _tiers[0].maxCoverageBps;
    }
}
