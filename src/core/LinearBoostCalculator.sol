// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBoostCalculator} from "../interfaces/IBoostCalculator.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LinearBoostCalculator — boost rises linearly with coverage to a cap
/// @notice `boost = floorBps + (maxBoostBps − floorBps) × coverage / maxCoverageBps`, clamped at
///         `maxBoostBps` from `maxCoverageBps` onward. Coverage is moneyValue/eusdStaked in bps.
///         Linear-in-coverage weight is additively separable, so splitting a position across
///         accounts never changes its total weight. Immutable — deploy a new calculator and swap
///         it in via {OwnStakingV2.setBoostCalculator} to change the shape.
contract LinearBoostCalculator is IBoostCalculator {
    error InvalidParams();

    /// @notice Boost at zero coverage, in bps.
    uint256 public immutable floorBps;
    /// @notice Boost at and beyond `maxCoverageBps`, in bps.
    uint256 public immutable maxBoostBps;
    /// @notice Coverage at which the boost reaches `maxBoostBps`, in bps.
    uint256 public immutable maxCoverageBps;

    constructor(uint256 floorBps_, uint256 maxBoostBps_, uint256 maxCoverageBps_) {
        if (maxBoostBps_ < floorBps_ || maxCoverageBps_ == 0) revert InvalidParams();
        floorBps = floorBps_;
        maxBoostBps = maxBoostBps_;
        maxCoverageBps = maxCoverageBps_;
    }

    /// @inheritdoc IBoostCalculator
    function boostBps(uint256 moneyValue, uint256 eusdStaked) external view override returns (uint256) {
        if (eusdStaked == 0) return 0;
        uint256 coverageBps = Math.mulDiv(moneyValue, BPS, eusdStaked);
        if (coverageBps >= maxCoverageBps) return maxBoostBps;
        return floorBps + (maxBoostBps - floorBps) * coverageBps / maxCoverageBps;
    }
}
