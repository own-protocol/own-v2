// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BPS} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {Test} from "forge-std/Test.sol";

/// @dev External wrapper so `vm.expectRevert` can observe library reverts.
contract InterestRateModelHarness {
    function premium(uint256 u, InterestRateModel.Params calldata p) external pure returns (uint256) {
        return InterestRateModel.premium(u, p);
    }
}

/// @title InterestRateModel Library Unit Tests
/// @notice Validates the two-slope premium curve at the kink, ends, and across
///         the bend, plus parameter validation.
contract InterestRateModelTest is Test {
    using InterestRateModel for uint256;

    InterestRateModelHarness internal harness = new InterestRateModelHarness();

    function _defaultParams() internal pure returns (InterestRateModel.Params memory) {
        // basePremium = 1%, optimal = 80%, slope1 = 4% (over 0→80% range),
        // slope2 = 75% (over 80→100% range). Matches the example in leverage-design.md.
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function test_premium_atZero_isBase() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        assertEq(InterestRateModel.premium(0, p), p.basePremiumBps);
    }

    function test_premium_atKink_isBasePlusSlope1() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        // 80% utilization → base + slope1 = 1% + 4% = 5%
        assertEq(InterestRateModel.premium(p.optimalUtilBps, p), uint256(p.basePremiumBps) + p.slope1Bps);
    }

    function test_premium_atFullUtil_isBasePlusBothSlopes() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        // 100% utilization → base + slope1 + slope2 = 1% + 4% + 75% = 80%
        assertEq(InterestRateModel.premium(BPS, p), uint256(p.basePremiumBps) + p.slope1Bps + p.slope2Bps);
    }

    function test_premium_belowKink_isLinear() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        // 50% utilization → base + slope1 * 50/80 = 1% + 4% * 0.625 = 3.5%
        uint256 expected = uint256(p.basePremiumBps) + (uint256(p.slope1Bps) * 5000) / p.optimalUtilBps;
        assertEq(InterestRateModel.premium(5000, p), expected);
    }

    function test_premium_aboveKink_isSteep() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        // 95% utilization → base + slope1 + slope2 * 15/20 = 1% + 4% + 75% * 0.75 = 61.25%
        uint256 expected =
            uint256(p.basePremiumBps) + p.slope1Bps + (uint256(p.slope2Bps) * (9500 - 8000)) / (BPS - 8000);
        assertEq(InterestRateModel.premium(9500, p), expected);
    }

    function test_premium_aboveFullUtil_clampsTo100() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        uint256 capped = InterestRateModel.premium(BPS, p);
        assertEq(InterestRateModel.premium(BPS + 1, p), capped, "clamps to 100% util");
        assertEq(InterestRateModel.premium(type(uint256).max, p), capped);
    }

    function test_premium_isMonotonicallyIncreasing() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        uint256 prev = InterestRateModel.premium(0, p);
        for (uint256 u = 500; u <= BPS; u += 500) {
            uint256 cur = InterestRateModel.premium(u, p);
            assertGe(cur, prev, "monotonic non-decreasing");
            prev = cur;
        }
    }

    function test_premium_optimalZero_reverts() public {
        InterestRateModel.Params memory p = _defaultParams();
        p.optimalUtilBps = 0;
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        harness.premium(5000, p);
    }

    function test_premium_optimalAtBPS_reverts() public {
        InterestRateModel.Params memory p = _defaultParams();
        p.optimalUtilBps = uint64(BPS);
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        harness.premium(5000, p);
    }

    function test_totalRate_addsUnderlying() public pure {
        InterestRateModel.Params memory p = _defaultParams();
        uint256 underlying = 350; // 3.5% APR
        uint256 prem = InterestRateModel.premium(5000, p);
        assertEq(InterestRateModel.totalRate(5000, underlying, p), underlying + prem);
    }

    function testFuzz_premium_inRange(
        uint256 utilization
    ) public pure {
        utilization = bound(utilization, 0, BPS);
        InterestRateModel.Params memory p = _defaultParams();
        uint256 prem = InterestRateModel.premium(utilization, p);
        assertGe(prem, p.basePremiumBps);
        assertLe(prem, uint256(p.basePremiumBps) + p.slope1Bps + p.slope2Bps);
    }
}
