// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBoostCalculator} from "../../src/interfaces/IBoostCalculator.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockLinearBoostCalculator — linear boost curve for staking tests
/// @notice `boost = floorBps + (maxBoostBps − floorBps) × coverage / maxCoverageBps`, clamped at
///         `maxBoostBps` from `maxCoverageBps` onward. Coverage is moneyValue/eusdStaked in bps.
contract MockLinearBoostCalculator is IBoostCalculator {
    error InvalidParams();

    uint256 public immutable floorBps;
    uint256 public immutable maxBoostBps;
    uint256 public immutable maxCoverageBps;

    constructor(uint256 floorBps_, uint256 maxBoostBps_, uint256 maxCoverageBps_) {
        if (maxBoostBps_ < floorBps_ || maxCoverageBps_ == 0) revert InvalidParams();
        floorBps = floorBps_;
        maxBoostBps = maxBoostBps_;
        maxCoverageBps = maxCoverageBps_;
    }

    function boostBps(uint256 moneyValue, uint256 eusdStaked) external view override returns (uint256) {
        if (eusdStaked == 0) return 0;
        uint256 coverageBps = Math.mulDiv(moneyValue, BPS, eusdStaked);
        if (coverageBps >= maxCoverageBps) return maxBoostBps;
        return floorBps + (maxBoostBps - floorBps) * coverageBps / maxCoverageBps;
    }
}
