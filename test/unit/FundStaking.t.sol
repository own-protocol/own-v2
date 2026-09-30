// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {YieldTier} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";

contract FundStakingTest is FundTestBase {
    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        launch.claim(true); // 60k MF1 staked
        vm.prank(bob);
        launch.claim(false); // 40k MF1 liquid
    }

    function test_stake_oneToOneInitially() public view {
        assertEq(staking.balanceOf(alice), 60_000e18);
        assertEq(staking.totalAssets(), 60_000e18);
    }

    function test_accrue_payTierRateForPremium() public {
        // Premium is 30%: tier 1 pays 0.1% a day.
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        assertEq(minted, uint256(60_000e18) * 10 * 8 hours / (10_000 * 1 days));
        assertEq(staking.totalAssets(), 60_000e18 + minted);
    }

    function test_accrue_donationEarnsNoYield() public {
        vm.prank(bob);
        fund.transfer(address(staking), 40_000e18);
        assertEq(staking.totalAssets(), 60_000e18);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        assertEq(staking.accrue(), uint256(60_000e18) * 10 / 10_000 / 3);
    }

    function test_accrue_higherTierAtHigherPremium() public {
        _setFeed(address(fund), 1.6e8); // NAV ~0.769, so ~108% premium: tier 3, 0.3% a day
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        assertEq(minted, uint256(60_000e18) * 30 * 8 hours / (10_000 * 1 days));
    }

    function test_accrue_noYieldBelowFirstTier() public {
        _setFeed(address(fund), 0.8e8); // ~4% premium
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        assertEq(staking.accrue(), 0);
    }

    function test_accrue_noYieldAtDiscount() public {
        _setFeed(address(fund), 0.5e8);
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
        assertEq(minted, uint256(60_000e18) * 10 * 8 hours / (10_000 * 1 days));
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
        assertGt(staking.convertToAssets(staking.balanceOf(alice)), 60_000e18);
    }

    function test_unstake_returnsPrincipalPlusYield() public {
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        vm.prank(alice);
        uint256 assets = staking.unstake(60_000e18, alice);
        assertApproxEqAbs(assets, 60_000e18 + uint256(60_000e18) * 10 * 8 hours / (10_000 * 1 days), 1);
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

    function test_setYieldTiers_adminOnly() public {
        YieldTier[] memory tiers = new YieldTier[](1);
        tiers[0] = YieldTier({minPremiumBps: 500, rateBpsPerDay: 25});
        vm.prank(creator);
        vm.expectRevert(IFundStaking.NotAdmin.selector);
        staking.setYieldTiers(tiers);

        vm.prank(admin);
        staking.setYieldTiers(tiers);
        assertEq(staking.rateForPremium(3000), 25);
    }

    function test_setYieldTiers_rateAboveCap_reverts() public {
        YieldTier[] memory tiers = new YieldTier[](1);
        tiers[0] = YieldTier({minPremiumBps: 500, rateBpsPerDay: 301});
        vm.prank(admin);
        vm.expectRevert(IFundStaking.InvalidTiers.selector);
        staking.setYieldTiers(tiers);
    }

    function test_setYieldTiers_notAscending_reverts() public {
        YieldTier[] memory tiers = new YieldTier[](2);
        tiers[0] = YieldTier({minPremiumBps: 500, rateBpsPerDay: 25});
        tiers[1] = YieldTier({minPremiumBps: 500, rateBpsPerDay: 50});
        vm.prank(admin);
        vm.expectRevert(IFundStaking.InvalidTiers.selector);
        staking.setYieldTiers(tiers);
    }

    function test_rateForPremium_tiers() public view {
        assertEq(staking.rateForPremium(-100), 0);
        assertEq(staking.rateForPremium(999), 0);
        assertEq(staking.rateForPremium(1000), 10);
        assertEq(staking.rateForPremium(5000), 20);
        assertEq(staking.rateForPremium(20_000), 30);
    }

    function test_setYieldTiers_threePercentADayAllowed() public {
        YieldTier[] memory tiers = new YieldTier[](1);
        tiers[0] = YieldTier({minPremiumBps: 500, rateBpsPerDay: 300});
        vm.prank(admin);
        staking.setYieldTiers(tiers);
        assertEq(staking.rateForPremium(3000), 300);
    }

    function test_maxYieldRate_adminRaisesCap() public {
        vm.prank(admin);
        factory.setMaxYieldRate(500);
        YieldTier[] memory tiers = new YieldTier[](1);
        tiers[0] = YieldTier({minPremiumBps: 500, rateBpsPerDay: 500});
        vm.prank(admin);
        staking.setYieldTiers(tiers);
        assertEq(staking.rateForPremium(3000), 500);
    }

    function test_maxYieldRate_loweredCapClampsExistingTiers() public {
        vm.prank(admin);
        factory.setMaxYieldRate(15);
        assertEq(staking.rateForPremium(20_000), 15);

        _setFeed(address(fund), 1.6e8);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 minted = staking.accrue();
        assertEq(minted, uint256(60_000e18) * 15 / 10_000 / 3);
    }

    function test_maxYieldRate_zeroStopsYield() public {
        vm.prank(admin);
        factory.setMaxYieldRate(0);
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        assertEq(staking.accrue(), 0);
    }

    function test_accrue_fullCapPaysThreePercentADay() public {
        YieldTier[] memory tiers = new YieldTier[](1);
        tiers[0] = YieldTier({minPremiumBps: 0, rateBpsPerDay: 300});
        vm.prank(admin);
        staking.setYieldTiers(tiers);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        assertEq(staking.accrue(), uint256(60_000e18) * 300 / 10_000 / 3);
    }

    function test_nameFollowsFundMetadata() public {
        assertEq(staking.name(), "Staked MONEY Market Fund 1");
        assertEq(staking.symbol(), "sMF1");
        vm.prank(creator);
        fund.setMetadata("Robin Fund", "ROBIN", "", "");
        assertEq(staking.name(), "Staked Robin Fund");
        assertEq(staking.symbol(), "sROBIN");
    }
}
