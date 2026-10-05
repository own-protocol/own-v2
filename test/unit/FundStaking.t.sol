// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {YieldPoint} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";

contract FundStakingTest is FundTestBase {
    uint256 internal staked;
    uint256 internal bobLiquid;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        staked = launch.claim(true);
        vm.prank(bob);
        bobLiquid = launch.claim(false);
        // Most tests check the stakers' rate alone; the curator share on top has its own tests.
        vm.prank(admin);
        staking.setCuratorYield(0, 0);
    }

    function test_transferLocked_notLaunch_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFundStaking.NotLaunch.selector);
        staking.transferLocked(bob, 1);
    }

    function test_stake_oneToOneInitially() public view {
        assertEq(staking.balanceOf(alice), staked);
        // The launch keeps a wei of unclaimable rounding dust staked.
        assertApproxEqAbs(staking.totalAssets(), staked, 1);
    }

    function test_accrue_payCurveRateForPremium() public {
        // Premium is 30%: halfway between 0.1% a day at 10% and 0.2% a day at 50%.
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        // The pool TWAP puts the premium within a hair of 30%.
        assertApproxEqRel(minted, staked * 15 * 8 hours / (10_000 * 1 days), 0.001e18);
        assertApproxEqAbs(staking.totalAssets(), staked + minted, 1);
    }

    function test_accrue_donationEarnsNoYield() public {
        _passDepositorLock();
        staking.accrue();
        uint256 assets = staking.totalAssets();
        vm.prank(bob);
        fund.transfer(address(staking), bobLiquid);
        assertEq(staking.totalAssets(), assets);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        assertApproxEqRel(staking.accrue(), assets * 15 / 10_000 / 3, 0.001e18);
    }

    function test_accrue_lastPointRateAbovePremium() public {
        _setFeed(address(fund), _navPrice() * 21 / 10); // 110% premium: past the last point, 0.3% a day
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        assertEq(minted, staked * 30 * 8 hours / (10_000 * 1 days));
    }

    function test_accrue_noYieldBelowFirstPoint() public {
        _setFeed(address(fund), _navPrice() * 104 / 100); // 4% premium
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        assertEq(staking.accrue(), 0);
    }

    function test_accrue_noYieldAtDiscount() public {
        _setFeed(address(fund), _navPrice() * 8 / 10);
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        assertEq(staking.accrue(), 0);
    }

    function test_accrue_staleOracle_noYieldAndPeriodConsumed() public {
        vm.warp(block.timestamp + STALENESS + 1);
        assertEq(staking.accrue(), 0);
        assertEq(staking.lastAccrual(), block.timestamp);
    }

    function test_accrue_periodCapped() public {
        vm.warp(block.timestamp + 5 days);
        _refreshFeeds();
        uint256 minted = staking.accrue(); // one distribution period, not five days
        assertApproxEqRel(minted, staked * 15 * 8 hours / (10_000 * 1 days), 0.001e18);
    }

    function test_accrue_dilutesNonStakers() public {
        uint256 navBefore = fund.navPerShare();
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        staking.accrue();
        assertLt(fund.navPerShare(), navBefore);
    }

    function test_stake_lateStakerDoesNotCaptureAccruedYield() public {
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();

        vm.startPrank(bob);
        fund.approve(address(staking), 10_000e18);
        staking.stake(10_000e18, bob);
        uint256 back = staking.unstake(staking.balanceOf(bob), bob);
        vm.stopPrank();

        assertLe(back, 10_000e18);
        assertGt(staking.convertToAssets(staking.balanceOf(alice)), staked);
    }

    function test_unstake_returnsPrincipalPlusYield() public {
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        vm.prank(alice);
        uint256 assets = staking.unstake(staked, alice);
        assertApproxEqRel(assets - staked, staked * 15 * 8 hours / (10_000 * 1 days), 0.001e18);
        assertEq(fund.balanceOf(alice), assets);
    }

    function test_stake_zero_reverts() public {
        vm.expectRevert(IFundStaking.ZeroAmount.selector);
        staking.stake(0, bob);
    }

    function test_unstake_zero_reverts() public {
        vm.expectRevert(IFundStaking.ZeroAmount.selector);
        staking.unstake(0, bob);
    }

    function test_setYieldCurve_adminOnly() public {
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerYear: 25 * 365});
        vm.prank(keeper);
        vm.expectRevert(IFundStaking.NotAdmin.selector);
        staking.setYieldCurve(curve);

        vm.prank(admin);
        staking.setYieldCurve(curve);
        assertEq(staking.rateForPremium(3000), 25 * 365e14);
    }

    function test_setYieldCurve_rateAboveCap_reverts() public {
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerYear: 301 * 365});
        vm.prank(admin);
        vm.expectRevert(IFundStaking.InvalidYieldCurve.selector);
        staking.setYieldCurve(curve);
    }

    function test_setYieldCurve_notAscending_reverts() public {
        YieldPoint[] memory curve = new YieldPoint[](2);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerYear: 25 * 365});
        curve[1] = YieldPoint({premiumBps: 500, rateBpsPerYear: 50 * 365});
        vm.prank(admin);
        vm.expectRevert(IFundStaking.InvalidYieldCurve.selector);
        staking.setYieldCurve(curve);
    }

    function test_rateForPremium_interpolatesBetweenPoints() public view {
        assertEq(staking.rateForPremium(-100), 0);
        assertEq(staking.rateForPremium(999), 0);
        assertEq(staking.rateForPremium(1000), 10 * 365e14);
        assertEq(staking.rateForPremium(3000), 15 * 365e14);
        assertEq(staking.rateForPremium(5000), 20 * 365e14);
        assertEq(staking.rateForPremium(7500), 25 * 365e14);
        assertEq(staking.rateForPremium(10_000), 30 * 365e14);
        assertEq(staking.rateForPremium(20_000), 30 * 365e14);
    }

    function test_setYieldCurve_threePercentADayAllowed() public {
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerYear: 300 * 365});
        vm.prank(admin);
        staking.setYieldCurve(curve);
        assertEq(staking.rateForPremium(3000), 300 * 365e14);
    }

    function test_maxYieldRate_adminRaisesCap() public {
        vm.prank(admin);
        factory.setMaxYieldRate(500 * 365);
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerYear: 500 * 365});
        vm.prank(admin);
        staking.setYieldCurve(curve);
        assertEq(staking.rateForPremium(3000), 500 * 365e14);
    }

    function test_maxYieldRate_loweredCapClampsCurve() public {
        vm.prank(admin);
        factory.setMaxYieldRate(15 * 365);
        assertEq(staking.rateForPremium(20_000), 15 * 365e14);

        _setFeed(address(fund), _navPrice() * 21 / 10);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        assertEq(minted, staked * 15 / 10_000 / 3);
    }

    function test_maxYieldRate_zeroStopsYield() public {
        vm.prank(admin);
        factory.setMaxYieldRate(0);
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        assertEq(staking.accrue(), 0);
    }

    function test_accrue_fullCapPaysThreePercentADay() public {
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 0, rateBpsPerYear: 300 * 365});
        vm.prank(admin);
        staking.setYieldCurve(curve);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        assertEq(staking.accrue(), staked * 300 / 10_000 / 3);
    }

    function _setHump() internal {
        // Rises to 0.14% a day (about 1% a week) by 10%, holds to 30%, falls to zero at 100%.
        YieldPoint[] memory curve = new YieldPoint[](4);
        curve[0] = YieldPoint({premiumBps: 0, rateBpsPerYear: 0});
        curve[1] = YieldPoint({premiumBps: 1000, rateBpsPerYear: 14 * 365});
        curve[2] = YieldPoint({premiumBps: 3000, rateBpsPerYear: 14 * 365});
        curve[3] = YieldPoint({premiumBps: 10_000, rateBpsPerYear: 0});
        vm.prank(admin);
        staking.setYieldCurve(curve);
    }

    function test_rateForPremium_hump() public {
        _setHump();
        assertEq(staking.rateForPremium(-1), 0);
        assertEq(staking.rateForPremium(0), 0);
        assertEq(staking.rateForPremium(500), 7 * 365e14);
        assertEq(staking.rateForPremium(1000), 14 * 365e14);
        assertEq(staking.rateForPremium(2000), 14 * 365e14);
        assertEq(staking.rateForPremium(3000), 14 * 365e14);
        assertEq(staking.rateForPremium(6500), 7 * 365e14);
        assertEq(staking.rateForPremium(10_000), 0);
        assertEq(staking.rateForPremium(15_000), 0);
    }

    function test_rateForPremium_fallingSlopeRoundsDown() public {
        _setHump();
        // 14e14 * 6999 / 7000, rounded down.
        assertEq(staking.rateForPremium(3001), 14 * 365e14 - (uint256(14 * 365e14) + 6999) / 7000);
    }

    function test_accrue_humpPaysLessNearCeiling() public {
        _setHump();
        _setFeed(address(fund), _navPrice() * 19 / 10); // 90% premium: 0.02% a day
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        assertApproxEqRel(minted, staked * 2 * 8 hours / (10_000 * 1 days), 0.01e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Curator yield, minted on top
    // ──────────────────────────────────────────────────────────

    function test_curatorYield_defaultFifteenPercent() public {
        _createFund();
        assertEq(staking.curatorYieldBps(), 1500);
        assertEq(staking.curatorYieldCapBps(), 0);
    }

    function test_curatorYield_mintedOnTopOfStakers() public {
        vm.prank(admin);
        staking.setCuratorYield(1500, 0);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        uint256 base = staked * 15 * 8 hours / (10_000 * 1 days);
        assertApproxEqRel(minted, base * 115 / 100, 0.001e18);

        // Stakers keep the full curve rate; the curators' shares are worth the 15% on top.
        assertApproxEqRel(staking.convertToAssets(staking.balanceOf(alice)) - staked, base, 0.001e18);
        uint256 curatorShares = staking.balanceOf(address(curators));
        assertApproxEqRel(staking.convertToAssets(curatorShares), base * 15 / 100, 0.001e18);
        assertApproxEqAbs(staking.totalAssets(), staked + minted, 1);
    }

    function test_curatorYield_capped() public {
        vm.prank(admin);
        staking.setCuratorYield(1500, 100); // at most 1% of the staked balance a year
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        uint256 base = staked * 15 * 8 hours / (10_000 * 1 days);
        uint256 cap = staked * 100 * 8 hours / (10_000 * 365 days);
        assertApproxEqRel(minted, base + cap, 0.001e18);
        assertApproxEqRel(staking.convertToAssets(staking.balanceOf(address(curators))), cap, 0.001e18);
    }

    function test_curatorYield_noneWithoutStakerYield() public {
        vm.prank(admin);
        staking.setCuratorYield(1500, 0);
        _setFeed(address(fund), _navPrice() * 104 / 100); // under the curve's first point
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        assertEq(staking.accrue(), 0);
        assertEq(staking.balanceOf(address(curators)), 0);
    }

    function test_setCuratorYield_adminOnlyAndBounded() public {
        vm.prank(curatorA);
        vm.expectRevert(IFundStaking.NotAdmin.selector);
        staking.setCuratorYield(1000, 0);
        vm.startPrank(admin);
        vm.expectRevert(IFundStaking.InvalidCuratorYield.selector);
        staking.setCuratorYield(5001, 0);
        vm.expectEmit(address(staking));
        emit IFundStaking.CuratorYieldSet(5000, 200);
        staking.setCuratorYield(5000, 200);
        vm.stopPrank();
        assertEq(staking.curatorYieldBps(), 5000);
        assertEq(staking.curatorYieldCapBps(), 200);
    }

    function test_nameFollowsFundMetadata() public {
        assertEq(staking.name(), "Staked Own Curated Fund 1");
        assertEq(staking.symbol(), "sOCF1");
        vm.prank(admin);
        fund.setMetadata("Robin Fund", "ROBIN", "", "");
        assertEq(staking.name(), "Staked Robin Fund");
        assertEq(staking.symbol(), "sROBIN");
    }
}
