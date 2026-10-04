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
    }

    function test_stake_oneToOneInitially() public view {
        assertEq(staking.balanceOf(alice), staked);
        assertEq(staking.totalAssets(), staked);
    }

    function test_accrue_payCurveRateForPremium() public {
        // Premium is 30%: halfway between 0.1% a day at 10% and 0.2% a day at 50%.
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        // The pool TWAP puts the premium within a hair of 30%.
        assertApproxEqRel(minted, staked * 15 * 8 hours / (10_000 * 1 days), 0.001e18);
        assertEq(staking.totalAssets(), staked + minted);
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
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerDay: 25});
        vm.prank(keeper);
        vm.expectRevert(IFundStaking.NotAdmin.selector);
        staking.setYieldCurve(curve);

        vm.prank(admin);
        staking.setYieldCurve(curve);
        assertEq(staking.rateForPremium(3000), 25e14);
    }

    function test_setYieldCurve_rateAboveCap_reverts() public {
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerDay: 301});
        vm.prank(admin);
        vm.expectRevert(IFundStaking.InvalidYieldCurve.selector);
        staking.setYieldCurve(curve);
    }

    function test_setYieldCurve_notAscending_reverts() public {
        YieldPoint[] memory curve = new YieldPoint[](2);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerDay: 25});
        curve[1] = YieldPoint({premiumBps: 500, rateBpsPerDay: 50});
        vm.prank(admin);
        vm.expectRevert(IFundStaking.InvalidYieldCurve.selector);
        staking.setYieldCurve(curve);
    }

    function test_rateForPremium_interpolatesBetweenPoints() public view {
        assertEq(staking.rateForPremium(-100), 0);
        assertEq(staking.rateForPremium(999), 0);
        assertEq(staking.rateForPremium(1000), 10e14);
        assertEq(staking.rateForPremium(3000), 15e14);
        assertEq(staking.rateForPremium(5000), 20e14);
        assertEq(staking.rateForPremium(7500), 25e14);
        assertEq(staking.rateForPremium(10_000), 30e14);
        assertEq(staking.rateForPremium(20_000), 30e14);
    }

    function test_setYieldCurve_threePercentADayAllowed() public {
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerDay: 300});
        vm.prank(admin);
        staking.setYieldCurve(curve);
        assertEq(staking.rateForPremium(3000), 300e14);
    }

    function test_maxYieldRate_adminRaisesCap() public {
        vm.prank(admin);
        factory.setMaxYieldRate(500);
        YieldPoint[] memory curve = new YieldPoint[](1);
        curve[0] = YieldPoint({premiumBps: 500, rateBpsPerDay: 500});
        vm.prank(admin);
        staking.setYieldCurve(curve);
        assertEq(staking.rateForPremium(3000), 500e14);
    }

    function test_maxYieldRate_loweredCapClampsCurve() public {
        vm.prank(admin);
        factory.setMaxYieldRate(15);
        assertEq(staking.rateForPremium(20_000), 15e14);

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
        curve[0] = YieldPoint({premiumBps: 0, rateBpsPerDay: 300});
        vm.prank(admin);
        staking.setYieldCurve(curve);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        assertEq(staking.accrue(), staked * 300 / 10_000 / 3);
    }

    function _setHump() internal {
        // Rises to 0.14% a day (about 1% a week) by 10%, holds to 30%, falls to zero at 100%.
        YieldPoint[] memory curve = new YieldPoint[](4);
        curve[0] = YieldPoint({premiumBps: 0, rateBpsPerDay: 0});
        curve[1] = YieldPoint({premiumBps: 1000, rateBpsPerDay: 14});
        curve[2] = YieldPoint({premiumBps: 3000, rateBpsPerDay: 14});
        curve[3] = YieldPoint({premiumBps: 10_000, rateBpsPerDay: 0});
        vm.prank(admin);
        staking.setYieldCurve(curve);
    }

    function test_rateForPremium_hump() public {
        _setHump();
        assertEq(staking.rateForPremium(-1), 0);
        assertEq(staking.rateForPremium(0), 0);
        assertEq(staking.rateForPremium(500), 7e14);
        assertEq(staking.rateForPremium(1000), 14e14);
        assertEq(staking.rateForPremium(2000), 14e14);
        assertEq(staking.rateForPremium(3000), 14e14);
        assertEq(staking.rateForPremium(6500), 7e14);
        assertEq(staking.rateForPremium(10_000), 0);
        assertEq(staking.rateForPremium(15_000), 0);
    }

    function test_rateForPremium_fallingSlopeRoundsDown() public {
        _setHump();
        // 14e14 * 6999 / 7000, rounded down.
        assertEq(staking.rateForPremium(3001), 14e14 - (uint256(14e14) + 6999) / 7000);
    }

    function test_accrue_humpPaysLessNearCeiling() public {
        _setHump();
        _setFeed(address(fund), _navPrice() * 19 / 10); // 90% premium: 0.02% a day
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        assertApproxEqRel(minted, staked * 2 * 8 hours / (10_000 * 1 days), 0.01e18);
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
