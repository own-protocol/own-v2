// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITieredBoostCalculator} from "../../src/interfaces/ITieredBoostCalculator.sol";
import {LinearBoostCalculator} from "../../src/staking/LinearBoostCalculator.sol";
import {TieredBoostCalculator} from "../../src/staking/TieredBoostCalculator.sol";
import {Test} from "forge-std/Test.sol";

contract TieredBoostCalculatorTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FLOOR = 1000;
    uint256 internal constant MAX = 36_000;

    TieredBoostCalculator internal calc;

    function setUp() public {
        calc = new TieredBoostCalculator(FLOOR, MAX, _launchTiers());
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev <$10k: 3x, $10k: 2x, $25k: 1x, $50k: 0.2x, $100k+: 0.1x $MONEY for full boost.
    function _launchTiers() internal pure returns (ITieredBoostCalculator.Tier[] memory t) {
        t = new ITieredBoostCalculator.Tier[](5);
        t[0] = ITieredBoostCalculator.Tier(0, 30_000);
        t[1] = ITieredBoostCalculator.Tier(10_000e18, 20_000);
        t[2] = ITieredBoostCalculator.Tier(25_000e18, 10_000);
        t[3] = ITieredBoostCalculator.Tier(50_000e18, 2000);
        t[4] = ITieredBoostCalculator.Tier(100_000e18, 1000);
    }

    function _weight(uint256 moneyValue, uint256 eusd) internal view returns (uint256) {
        return eusd * calc.boostBps(moneyValue, eusd) / BPS;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_storesParams() public view {
        assertEq(calc.floorBps(), FLOOR);
        assertEq(calc.maxBoostBps(), MAX);
        assertEq(calc.MAX_TIERS(), 16);
        ITieredBoostCalculator.Tier[] memory t = calc.tiers();
        ITieredBoostCalculator.Tier[] memory want = _launchTiers();
        assertEq(t.length, want.length);
        for (uint256 i; i < t.length; ++i) {
            assertEq(t[i].minEusd, want[i].minEusd);
            assertEq(t[i].maxCoverageBps, want[i].maxCoverageBps);
        }
    }

    function test_constructor_maxBelowFloor_reverts() public {
        vm.expectRevert(ITieredBoostCalculator.InvalidBoostRange.selector);
        new TieredBoostCalculator(FLOOR, FLOOR - 1, _launchTiers());
    }

    function test_constructor_flatBoost_allowed() public {
        TieredBoostCalculator flat = new TieredBoostCalculator(FLOOR, FLOOR, _launchTiers());
        assertEq(flat.boostBps(0, 1e18), FLOOR);
        assertEq(flat.boostBps(1e30, 1e18), FLOOR);
    }

    function test_constructor_noTiers_reverts() public {
        vm.expectRevert(ITieredBoostCalculator.InvalidTierCount.selector);
        new TieredBoostCalculator(FLOOR, MAX, new ITieredBoostCalculator.Tier[](0));
    }

    function test_constructor_tooManyTiers_reverts() public {
        ITieredBoostCalculator.Tier[] memory t = new ITieredBoostCalculator.Tier[](17);
        for (uint256 i; i < t.length; ++i) {
            t[i] = ITieredBoostCalculator.Tier(uint128(i * 1e18), 1000);
        }
        vm.expectRevert(ITieredBoostCalculator.InvalidTierCount.selector);
        new TieredBoostCalculator(FLOOR, MAX, t);
    }

    function test_constructor_maxTiers_allowed() public {
        ITieredBoostCalculator.Tier[] memory t = new ITieredBoostCalculator.Tier[](16);
        for (uint256 i; i < t.length; ++i) {
            t[i] = ITieredBoostCalculator.Tier(uint128(i * 1e18), uint128(30_000 - i * 1000));
        }
        TieredBoostCalculator c = new TieredBoostCalculator(FLOOR, MAX, t);
        assertEq(c.tiers().length, 16);
        assertEq(c.maxCoverageFor(type(uint256).max), 15_000);
    }

    function test_constructor_firstTierNotZero_reverts() public {
        ITieredBoostCalculator.Tier[] memory t = _launchTiers();
        t[0].minEusd = 1;
        vm.expectRevert(ITieredBoostCalculator.FirstTierNotZero.selector);
        new TieredBoostCalculator(FLOOR, MAX, t);
    }

    function test_constructor_equalThresholds_reverts() public {
        ITieredBoostCalculator.Tier[] memory t = _launchTiers();
        t[2].minEusd = t[1].minEusd;
        vm.expectRevert(abi.encodeWithSelector(ITieredBoostCalculator.TiersNotAscending.selector, 2));
        new TieredBoostCalculator(FLOOR, MAX, t);
    }

    function test_constructor_descendingThresholds_reverts() public {
        ITieredBoostCalculator.Tier[] memory t = _launchTiers();
        t[4].minEusd = 40_000e18;
        vm.expectRevert(abi.encodeWithSelector(ITieredBoostCalculator.TiersNotAscending.selector, 4));
        new TieredBoostCalculator(FLOOR, MAX, t);
    }

    function test_constructor_risingCoverage_reverts() public {
        ITieredBoostCalculator.Tier[] memory t = _launchTiers();
        t[3].maxCoverageBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(ITieredBoostCalculator.InvalidTierCoverage.selector, 3));
        new TieredBoostCalculator(FLOOR, MAX, t);
    }

    function test_constructor_zeroCoverage_reverts() public {
        ITieredBoostCalculator.Tier[] memory t = _launchTiers();
        t[4].maxCoverageBps = 0;
        vm.expectRevert(abi.encodeWithSelector(ITieredBoostCalculator.InvalidTierCoverage.selector, 4));
        new TieredBoostCalculator(FLOOR, MAX, t);

        ITieredBoostCalculator.Tier[] memory single = new ITieredBoostCalculator.Tier[](1);
        vm.expectRevert(abi.encodeWithSelector(ITieredBoostCalculator.InvalidTierCoverage.selector, 0));
        new TieredBoostCalculator(FLOOR, MAX, single);
    }

    function test_constructor_equalCoverage_allowed() public {
        ITieredBoostCalculator.Tier[] memory t = _launchTiers();
        t[4].maxCoverageBps = t[3].maxCoverageBps;
        TieredBoostCalculator c = new TieredBoostCalculator(FLOOR, MAX, t);
        assertEq(c.maxCoverageFor(1e30), 2000);
    }

    // ──────────────────────────────────────────────────────────
    //  Tier lookup
    // ──────────────────────────────────────────────────────────

    function test_maxCoverageFor_tierEdges() public view {
        assertEq(calc.maxCoverageFor(0), 30_000);
        assertEq(calc.maxCoverageFor(10_000e18 - 1), 30_000);
        assertEq(calc.maxCoverageFor(10_000e18), 20_000);
        assertEq(calc.maxCoverageFor(25_000e18 - 1), 20_000);
        assertEq(calc.maxCoverageFor(25_000e18), 10_000);
        assertEq(calc.maxCoverageFor(50_000e18 - 1), 10_000);
        assertEq(calc.maxCoverageFor(50_000e18), 2000);
        assertEq(calc.maxCoverageFor(100_000e18 - 1), 2000);
        assertEq(calc.maxCoverageFor(100_000e18), 1000);
        assertEq(calc.maxCoverageFor(type(uint256).max), 1000);
    }

    // ──────────────────────────────────────────────────────────
    //  Boost
    // ──────────────────────────────────────────────────────────

    function test_boostBps_zeroEusd_isZero() public view {
        assertEq(calc.boostBps(1e24, 0), 0);
    }

    function test_boostBps_zeroMoney_isFloor() public view {
        assertEq(calc.boostBps(0, 1000e18), FLOOR);
        assertEq(calc.boostBps(0, 100_000e18), FLOOR);
    }

    function test_boostBps_fullBoostAtEachTier() public view {
        assertEq(calc.boostBps(3000e18, 1000e18), MAX); // <$10k: 3x
        assertEq(calc.boostBps(20_000e18, 10_000e18), MAX); // $10k: 2x
        assertEq(calc.boostBps(25_000e18, 25_000e18), MAX); // $25k: 1x
        assertEq(calc.boostBps(10_000e18, 50_000e18), MAX); // $50k: 0.2x
        assertEq(calc.boostBps(10_000e18, 100_000e18), MAX); // $100k: 0.1x
        assertEq(calc.boostBps(100_000e18, 1_000_000e18), MAX); // $1M: 0.1x
    }

    function test_boostBps_justShortOfFullBoost() public view {
        assertLt(calc.boostBps(3000e18 - 1e18, 1000e18), MAX);
        assertLt(calc.boostBps(20_000e18 - 1e18, 10_000e18), MAX);
        assertLt(calc.boostBps(25_000e18 - 1e18, 25_000e18), MAX);
        assertLt(calc.boostBps(10_000e18 - 1e18, 50_000e18), MAX);
        assertLt(calc.boostBps(10_000e18 - 1e18, 100_000e18), MAX);
    }

    function test_boostBps_aboveCoverage_clampsAtMax() public view {
        assertEq(calc.boostBps(1e30, 1000e18), MAX);
        assertEq(calc.boostBps(1e30, 100_000e18), MAX);
    }

    function test_boostBps_linearWithinTier() public view {
        // $100k at 0.05x of 0.1x -> halfway: 0.1 + 3.5 × 0.5 = 1.85x.
        assertEq(calc.boostBps(5000e18, 100_000e18), 18_500);
        // $1k at 1:1 of 3:1 -> 0.1 + 3.5 / 3 = 1.2666x.
        assertEq(calc.boostBps(1000e18, 1000e18), 12_666);
        // $10k at 1:1 of 2:1 -> 0.1 + 3.5 / 2 = 1.85x.
        assertEq(calc.boostBps(10_000e18, 10_000e18), 18_500);
    }

    function test_boostBps_crossingTierRaisesBoost() public view {
        // Same $10k $MONEY: $49,999 eUSD needs ~$50k for full boost, $50k eUSD needs $10k.
        uint256 below = calc.boostBps(10_000e18, 49_999e18);
        uint256 at = calc.boostBps(10_000e18, 50_000e18);
        assertEq(at, MAX);
        assertLt(below, 8100);
        assertGt(_weight(10_000e18, 50_000e18), _weight(10_000e18, 49_999e18));
    }

    function testFuzz_boostBps_withinFloorAndMax(uint256 moneyValue, uint256 eusd) public view {
        moneyValue = bound(moneyValue, 0, 1e36);
        eusd = bound(eusd, 1, 1e36);
        uint256 b = calc.boostBps(moneyValue, eusd);
        assertGe(b, FLOOR);
        assertLe(b, MAX);
    }

    function testFuzz_boostBps_monotoneInMoney(uint256 m1, uint256 m2, uint256 eusd) public view {
        m1 = bound(m1, 0, 1e30);
        m2 = bound(m2, m1, 1e30);
        eusd = bound(eusd, 1e18, 1e30);
        assertGe(calc.boostBps(m2, eusd), calc.boostBps(m1, eusd));
    }

    /// @dev Single-tier table reproduces the linear calculator up to its double-floor rounding.
    function testFuzz_singleTier_matchesLinear(uint256 moneyValue, uint256 eusd) public {
        moneyValue = bound(moneyValue, 0, 1e30);
        eusd = bound(eusd, 1e18, 1e30);
        ITieredBoostCalculator.Tier[] memory t = new ITieredBoostCalculator.Tier[](1);
        t[0] = ITieredBoostCalculator.Tier(0, 30_000);
        TieredBoostCalculator single = new TieredBoostCalculator(FLOOR, MAX, t);
        LinearBoostCalculator linear = new LinearBoostCalculator(FLOOR, MAX, 30_000);
        assertApproxEqAbs(single.boostBps(moneyValue, eusd), linear.boostBps(moneyValue, eusd), 3);
    }

    // ──────────────────────────────────────────────────────────
    //  Weight shape (A5-H-01 / A5-M-05)
    // ──────────────────────────────────────────────────────────

    /// @dev More eUSD at the same $MONEY never weighs less, within one bps of rounding.
    function testFuzz_weight_monotoneInEusd(uint256 moneyValue, uint256 e1, uint256 e2) public view {
        moneyValue = bound(moneyValue, 0, 1e30);
        e1 = bound(e1, 1e18, 1e30);
        e2 = bound(e2, e1, 1e30);
        assertGe(_weight(moneyValue, e2) + e2 / BPS + 1, _weight(moneyValue, e1));
    }

    /// @dev Splitting a position across two accounts never gains weight beyond one bps of rounding.
    function testFuzz_weight_splitNeverProfitable(uint256 m1, uint256 m2, uint256 e1, uint256 e2) public view {
        m1 = bound(m1, 0, 1e30);
        m2 = bound(m2, 0, 1e30);
        e1 = bound(e1, 1e18, 1e30);
        e2 = bound(e2, 1e18, 1e30);
        uint256 whole = _weight(m1 + m2, e1 + e2);
        uint256 parts = _weight(m1, e1) + _weight(m2, e2);
        assertGe(whole + (e1 + e2) / BPS + 2, parts);
    }
}
