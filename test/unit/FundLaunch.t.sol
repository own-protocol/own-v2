// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundLaunch} from "../../src/interfaces/IFundLaunch.sol";
import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {CreateFundParams, LaunchConfig} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract FundLaunchTest is FundTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    // Raise $125k, pool share 20% (P = $25k), supply 130k: M = 25k * 130k / (1.3 * 125k + 25k).
    uint256 internal constant POOL_SHARES = uint256(25_000e18) * 130_000e18 / 187_500e18;
    uint256 internal constant DEPOSITOR_SHARES = 130_000e18 - POOL_SHARES;

    MockSwapRouter internal router;

    function setUp() public override {
        super.setUp();
        _createFund();
        router = new MockSwapRouter();
        vm.prank(admin);
        factory.setRouter(address(router), true);
    }

    // ──────────────────────────────────────────────────────────
    //  deposit
    // ──────────────────────────────────────────────────────────

    function test_deposit_basketAsset() public {
        uint256 received = _deposit(alice, address(net), 10e9);
        assertEq(received, 10e9);
        IFundLaunch.Deposit memory d = launch.depositOf(alice, address(net));
        assertEq(d.amount, 10e9);
        assertEq(d.timeWeight, 10e9 * 7 days);
        assertEq(launch.totalDeposited(address(net)), 10e9);
        assertEq(net.balanceOf(address(launch)), 10e9);
        assertEq(usdg.balanceOf(address(launch)), 0);
    }

    function test_deposit_usdgAlone() public {
        _deposit(alice, address(usdg), 5000e6);
        assertEq(launch.depositOf(alice, address(usdg)).amount, 5000e6);
        assertEq(launch.totalDeposited(address(usdg)), 5000e6);
        assertEq(usdg.balanceOf(address(launch)), 5000e6);
        assertEq(launch.raisedValue(), 5000e18);
    }

    function test_deposit_needsNoPrice() public {
        vm.warp(block.timestamp + STALENESS + 1);
        _deposit(alice, address(net), 1e9);
        assertEq(launch.totalDeposited(address(net)), 1e9);
    }

    function test_deposit_windowClosed_reverts() public {
        vm.warp(launch.endTime());
        net.mint(alice, 1e9);
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.WindowClosed.selector);
        launch.deposit(address(net), 1e9);
    }

    function test_deposit_notBasketAsset_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundLaunch.AssetNotAccepted.selector, address(spare)));
        launch.deposit(address(spare), 1e18);
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.ZeroAmount.selector);
        launch.deposit(address(net), 0);
    }

    function test_deposit_paused_reverts() public {
        vm.prank(admin);
        launch.setDepositsPaused(true);
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.DepositsPaused.selector);
        launch.deposit(address(net), 1e9);
    }

    function test_deposit_afterFinalize_reverts() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.WrongStatus.selector);
        launch.deposit(address(net), 1e9);
    }

    function test_setDepositsPaused_notOperator_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(IFundLaunch.NotOperator.selector);
        launch.setDepositsPaused(true);
    }

    function test_setDepositsPaused_operator() public {
        vm.prank(operator);
        launch.setDepositsPaused(true);
        assertTrue(launch.depositsPaused());
        vm.prank(operator);
        launch.setDepositsPaused(false);
        assertFalse(launch.depositsPaused());
    }

    // ──────────────────────────────────────────────────────────
    //  finalize
    // ──────────────────────────────────────────────────────────

    function test_finalize_windowOpen_reverts() public {
        _deposit(alice, address(net), 1000e9);
        _refreshFeeds();
        vm.expectRevert(IFundLaunch.WindowOpen.selector);
        launch.finalize();
    }

    function test_finalize_success_handsEverythingToFundWithoutPool() public {
        _finalizeTwoDepositors();

        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
        assertEq(launch.closedAt(), block.timestamp);
        assertTrue(fund.launched());
        assertEq(fund.depositorUnlockAt(), block.timestamp + 7 days);
        assertFalse(hook.isSeeded(address(fund)));
        assertFalse(launch.poolSeeded());

        assertApproxEqAbs(launch.poolShares(), POOL_SHARES, 1);
        assertApproxEqAbs(launch.depositorSupply(), DEPOSITOR_SHARES, 1);
        assertEq(launch.poolUsdg(), 25_000e6);
        assertEq(fund.totalSupply(), launch.depositorSupply());
        // The whole depositor allocation is staked by the launch at the close.
        assertEq(fund.balanceOf(address(staking)), launch.depositorSupply());
        assertEq(staking.balanceOf(address(launch)), launch.stakedShares());
        assertEq(launch.stakedShares(), launch.depositorSupply());

        assertEq(net.balanceOf(address(fund)), 120e9);
        assertEq(pons.balanceOf(address(fund)), 1_500_000e18);
        assertEq(tsla.balanceOf(address(fund)), 85e18);
        assertEq(fund.idleUsdg(), 25_000e6);

        // NAV = $125k over the depositors' tokens only.
        assertEq(fund.totalValue(), 125_000e18);
        assertEq(fund.navPerShare(), Math.mulDiv(125_000e18, 1e18, launch.depositorSupply()));
    }

    function test_finalize_depositorsGetNavEqualToWhatTheyBrought() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        // Alice brought $75k; bob's $200 haircut adds a sliver.
        uint256 aliceValue = Math.mulDiv(shares, fund.navPerShare(), 1e18);
        assertApproxEqRel(aliceValue, uint256(75_000e18) * 125_000 / 124_800, 1e12);
    }

    function test_finalize_overweightHaircutGoesToOthers() public {
        _finalizeTwoDepositors();
        // Basket targets are 80% of the weights: TSLA is $34k against $30k, bob loses 5% of $4k.
        assertEq(launch.rawValue(address(tsla)), 34_000e18);
        assertEq(launch.creditedValue(address(tsla)), 33_800e18);
        assertEq(launch.creditedValue(address(net)), 36_000e18);
        // USDG sits exactly on its 20% target.
        assertEq(launch.creditedValue(address(usdg)), 25_000e18);

        assertApproxEqRel(launch.claimable(alice), launch.depositorSupply() * 75_000 / 124_800, 1e12);
        assertApproxEqRel(launch.claimable(bob), launch.depositorSupply() * 49_800 / 124_800, 1e12);
    }

    function test_finalize_usdgAboveItsTargetIsHaircut() public {
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(alice, address(net), 100e9); // $30k
        _deposit(bob, address(usdg), 20_000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();

        // Raise $50k. USDG target 20% = $10k, $10k over; NET target 32% = $16k, $14k over.
        assertEq(launch.creditedValue(address(usdg)), 19_500e18);
        assertEq(launch.creditedValue(address(net)), 29_300e18);
        assertApproxEqRel(launch.claimable(bob), launch.depositorSupply() * 19_500 / 48_800, 1e12);
    }

    function test_finalize_earlyDepositEarnsExtraTokens() public {
        // Same deposits from both, alice at the open and bob at the close.
        _deposit(alice, address(net), 50e9);
        _deposit(alice, address(usdg), 10_000e6);
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(bob, address(net), 50e9);
        _deposit(bob, address(usdg), 10_000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();

        // 0.5% a day for 7 days: alice's points are 1.035x bob's.
        uint256 a = launch.claimable(alice);
        uint256 b = launch.claimable(bob);
        assertApproxEqRel(a * 1e18 / b, 1.035e18, 1e12);
        assertLe(a + b, launch.depositorSupply());
        assertApproxEqAbs(a + b, launch.depositorSupply(), 10);
    }

    function test_finalize_afterEndTime_servesTheWholeWindow() public {
        _deposit(alice, address(net), 50e9);
        _deposit(alice, address(usdg), 10_000e6);
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(bob, address(net), 50e9);
        _deposit(bob, address(usdg), 10_000e6);
        vm.warp(launch.endTime() + 1 days);
        _refreshFeeds();
        launch.finalize();

        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
        uint256 a = launch.claimable(alice);
        uint256 b = launch.claimable(bob);
        assertApproxEqRel(a * 1e18 / b, 1.035e18, 1e12);
        assertApproxEqAbs(a + b, launch.depositorSupply(), 10);
    }

    function test_finalize_belowMinimum_fails() public {
        _deposit(alice, address(net), 10e9); // $3k
        _deposit(alice, address(usdg), 6000e6); // $9k < $10k minimum
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Failed));
        assertFalse(fund.launched());
    }

    function test_finalize_usdgCountsTowardMinimum() public {
        _deposit(alice, address(net), 10e9); // $3k
        _deposit(alice, address(usdg), 7000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
    }

    function test_finalize_twice_reverts() public {
        _deposit(alice, address(net), 100e9);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
        vm.expectRevert(IFundLaunch.WrongStatus.selector);
        launch.finalize();
    }

    function test_finalize_afterDeadline_reverts() public {
        _deposit(alice, address(net), 100e9);
        vm.warp(launch.finalizeDeadline() + 1);
        _refreshFeeds();
        vm.expectRevert(IFundLaunch.FinalizeDeadlinePassed.selector);
        launch.finalize();
    }

    function test_finalize_usesClosingPrices() public {
        _deposit(alice, address(net), 100e9); // $30k at deposit
        _deposit(alice, address(usdg), 9000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        _setFeed(address(net), 150e8); // halves by the close
        launch.finalize();
        assertEq(launch.closePrice(address(net)), 150e18);
        assertEq(launch.rawValue(address(net)), 15_000e18);
        assertEq(fund.totalValue(), 24_000e18);
        assertEq(launch.claimable(alice), launch.depositorSupply());
    }

    // ──────────────────────────────────────────────────────────
    //  early close at the target raise
    // ──────────────────────────────────────────────────────────

    function test_finalize_targetReached_closesEarly() public {
        _createTargetFund(100_000e18);
        _deposit(alice, address(net), 200e9); // $60k at the open
        vm.warp(block.timestamp + 2 days);
        _refreshFeeds();
        _deposit(bob, address(usdg), 40_000e6);
        assertEq(launch.raisedValue(), 100_000e18);

        launch.finalize();
        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
        assertEq(launch.closedAt(), block.timestamp);
        assertLt(block.timestamp, launch.endTime());

        // The early bonus runs to the actual close: two days at 0.5% on alice's $60k, none for bob.
        // NET target is 80% of 40% = $32k of $100k, so alice's $28k over is haircut 5% ($1.4k).
        uint256 alicePoints = 58_600e18 + Math.mulDiv(60_000e18, 100, 10_000) * 58_600 / 60_000;
        uint256 bobPoints = 40_000e18 - 1000e18; // $20k over USDG's $20k target, 5% off
        assertApproxEqRel(launch.claimable(alice) * 1e18 / launch.claimable(bob), alicePoints * 1e18 / bobPoints, 1e12);
    }

    function test_finalize_belowTarget_beforeEnd_reverts() public {
        _createTargetFund(100_000e18);
        _deposit(alice, address(usdg), 99_999e6);
        vm.expectRevert(IFundLaunch.WindowOpen.selector);
        launch.finalize();
    }

    function test_finalize_targetCheckedAtClosingPrices() public {
        _createTargetFund(100_000e18);
        _deposit(alice, address(net), 340e9); // $102k
        assertGe(launch.raisedValue(), 100_000e18);
        _setFeed(address(net), 290e8); // now $98.6k
        vm.expectRevert(IFundLaunch.WindowOpen.selector);
        launch.finalize();
    }

    function test_finalize_noTarget_neverClosesEarly() public {
        _deposit(alice, address(usdg), 1_000_000e6);
        vm.expectRevert(IFundLaunch.WindowOpen.selector);
        launch.finalize();
    }

    // ──────────────────────────────────────────────────────────
    //  launch rebalance and seedPool
    // ──────────────────────────────────────────────────────────

    function test_seedPool_opensAtPremiumWithFixedSupply() public {
        _finalizeTwoDepositors();
        uint256 nav = fund.navPerShare();
        vm.prank(keeper);
        launch.seedPool();

        assertTrue(launch.poolSeeded());
        assertTrue(hook.isSeeded(address(fund)));
        // Full-range liquidity rounding leaves a few wei of fund tokens, which the hook burns.
        assertApproxEqAbs(fund.totalSupply(), 130_000e18, 1e7);
        assertApproxEqAbs(fund.balanceOf(address(poolManager)), POOL_SHARES, 1e7);
        assertApproxEqAbs(usdg.balanceOf(address(poolManager)), 25_000e6, 1);
        assertEq(fund.balanceOf(address(hook)), 0);
        assertEq(usdg.balanceOf(address(hook)), 0);
        assertApproxEqAbs(fund.idleUsdg(), 0, 1);

        // The position counts: NAV is unchanged by seeding, and the pool opens at 1.3x it.
        assertApproxEqRel(fund.effectiveSupply(), launch.depositorSupply(), 1e14);
        assertApproxEqRel(fund.totalValue(), 125_000e18, 1e14);
        assertApproxEqRel(fund.navPerShare(), nav, 1e14);
        assertApproxEqRel(_poolPrice(), nav * 13 / 10, 1e14);
    }

    function test_seedPool_byAdmin() public {
        _finalizeTwoDepositors();
        vm.prank(admin);
        launch.seedPool();
        assertTrue(hook.isSeeded(address(fund)));
    }

    function test_seedPool_notManager_reverts() public {
        _finalizeTwoDepositors();
        vm.prank(attacker);
        vm.expectRevert(IFundLaunch.NotManager.selector);
        launch.seedPool();
    }

    function test_seedPool_beforeSuccess_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(IFundLaunch.WrongStatus.selector);
        launch.seedPool();
    }

    function test_seedPool_twice_reverts() public {
        _finalizeTwoDepositors();
        vm.startPrank(keeper);
        launch.seedPool();
        vm.expectRevert(IFundLaunch.AlreadySeeded.selector);
        launch.seedPool();
        vm.stopPrank();
    }

    function test_seedPool_shortOfUsdg_rebalanceSellsTokensFirst() public {
        // Tokens only: $100k NET + $25k PONS, no USDG. The pool needs $25k.
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(alice, address(net), 333e9 + 333e6); // $100k
        _deposit(bob, address(pons), 1_250_000e18); // $25k
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();

        vm.prank(keeper);
        vm.expectRevert(IFundLaunch.InsufficientPoolUsdg.selector);
        launch.seedPool();

        // One $25k sale, 2.5x the 10% daily cap, is allowed before the pool opens.
        usdg.mint(address(router), 25_000e6);
        IFund.RebalanceParams memory p = IFund.RebalanceParams({
            sellAsset: address(net),
            sellAmount: 83_333_333_334,
            buyAsset: address(usdg),
            minBuyAmount: 25_000e6,
            router: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (address(net), 83_333_333_334, address(usdg), 25_000e6))
        });
        vm.prank(keeper);
        fund.rebalance(p);
        assertEq(fund.idleUsdg(), 25_000e6);

        vm.prank(keeper);
        launch.seedPool();
        assertTrue(hook.isSeeded(address(fund)));

        // Once the pool is open, buying USDG is not a rebalance any more.
        _refreshFeeds();
        usdg.mint(address(router), 300e6);
        p.sellAmount = 1e9;
        p.minBuyAmount = 300e6;
        p.data = abi.encodeCall(MockSwapRouter.swap, (address(net), 1e9, address(usdg), 300e6));
        vm.prank(keeper);
        vm.expectRevert(IFund.InvalidBasket.selector);
        fund.rebalance(p);
    }

    function test_launchRebalance_ignoresVolumeCap_thenCapApplies() public {
        _finalizeTwoDepositors();
        tsla.mint(address(router), 1000e18);
        vm.startPrank(keeper);
        // $24k of NET for TSLA in one swap: about twice the 10% daily cap on ~$125k.
        fund.rebalance(_netForTsla(80e9, 59.2e18));
        assertEq(fund.rebalanceVolume(), 0);
        launch.seedPool();
        vm.stopPrank();

        _refreshFeeds();
        vm.prank(keeper);
        vm.expectRevert(IFund.RebalanceVolumeExceeded.selector);
        fund.rebalance(_netForTsla(40e9, 29.6e18));
    }

    function test_seedPool_atNavWithoutPremium() public {
        LaunchConfig memory lc = factory.launchConfig();
        lc.launchPremiumBps = 0;
        vm.prank(admin);
        factory.setLaunchConfig(lc);
        _createFund();
        _finalizeTwoDepositors();
        uint256 nav = fund.navPerShare();
        vm.prank(keeper);
        launch.seedPool();
        assertApproxEqRel(_poolPrice(), nav, 1e14);
        assertApproxEqRel(fund.navPerShare(), nav, 1e14);
    }

    function test_seedPool_afterRedemptions_scalesPoolDown() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        vm.prank(alice);
        fund.redeem(shares / 2, alice, new uint256[](0), 0);
        uint256 supply = fund.totalSupply();
        uint256 expectedUsdg = Math.mulDiv(launch.poolUsdg(), supply, launch.depositorSupply());
        uint256 nav = fund.navPerShare();

        vm.prank(keeper);
        launch.seedPool();
        assertApproxEqAbs(usdg.balanceOf(address(poolManager)), expectedUsdg, 1);
        assertApproxEqRel(_poolPrice(), nav * 13 / 10, 1e14);
    }

    function test_beforeSeed_mintBlocked_redeemOpen() public {
        _finalizeTwoDepositors();
        vm.prank(bob);
        vm.expectRevert(IFund.NoMarketPrice.selector);
        fund.mint(1e18, 0, 0, bob);

        vm.prank(alice);
        uint256 shares = launch.claim(false);
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        fund.redeem(shares, alice, new uint256[](0), 0);
        assertGt(usdg.balanceOf(alice), usdgBefore);
        assertGt(net.balanceOf(alice), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  markFailed / refund
    // ──────────────────────────────────────────────────────────

    function test_markFailed_beforeDeadline_reverts() public {
        vm.warp(launch.endTime());
        vm.expectRevert(IFundLaunch.FinalizeDeadlineNotPassed.selector);
        launch.markFailed();
    }

    function test_refund_afterFailure_returnsEverything() public {
        _deposit(alice, address(net), 10e9);
        _deposit(alice, address(usdg), 500e6);
        vm.warp(launch.finalizeDeadline() + 1);
        launch.markFailed();

        vm.prank(alice);
        launch.refund();
        assertEq(net.balanceOf(alice), 10e9);
        assertEq(usdg.balanceOf(alice), 500e6);
        assertTrue(launch.settled(alice));

        vm.prank(alice);
        vm.expectRevert(IFundLaunch.NothingToClaim.selector);
        launch.refund();
    }

    function test_refund_whileOpen_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.WrongStatus.selector);
        launch.refund();
    }

    function test_refund_nothingDeposited_reverts() public {
        vm.warp(launch.finalizeDeadline() + 1);
        launch.markFailed();
        vm.prank(bob);
        vm.expectRevert(IFundLaunch.NothingToClaim.selector);
        launch.refund();
    }

    // ──────────────────────────────────────────────────────────
    //  claim and the depositor lock
    // ──────────────────────────────────────────────────────────

    function test_claim_transfersAllocationLocked() public {
        _finalizeTwoDepositors();
        uint256 expected = launch.claimable(alice);
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        assertEq(shares, expected);
        assertEq(fund.balanceOf(alice), shares);
        assertEq(fund.launchLocked(alice), shares);

        vm.prank(alice);
        vm.expectRevert(IFundLaunch.NothingToClaim.selector);
        launch.claim(false);
    }

    function test_distribute_pushesStakedLockedShares() public {
        _finalizeTwoDepositors();
        uint256 aliceShares = launch.claimable(alice);
        uint256 bobShares = launch.claimable(bob);
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = attacker; // nothing to claim: skipped
        vm.prank(attacker);
        launch.distribute(accounts);

        assertEq(staking.balanceOf(alice), aliceShares);
        assertEq(staking.balanceOf(bob), bobShares);
        assertEq(staking.lockedShares(alice), aliceShares);
        assertEq(staking.lockedShares(bob), bobShares);
        assertTrue(launch.settled(alice));
        assertEq(staking.balanceOf(attacker), 0);

        // Running it again is a no-op, and a pushed depositor has nothing left to claim.
        launch.distribute(accounts);
        assertEq(staking.balanceOf(alice), aliceShares);
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.NothingToClaim.selector);
        launch.claim(true);
    }

    function test_distribute_beforeSuccess_reverts() public {
        vm.expectRevert(IFundLaunch.WrongStatus.selector);
        launch.distribute(new address[](0));
    }

    function test_autoStake_earnsYieldBeforeDepositorsAct() public {
        _finalizeTwoDepositors();
        vm.prank(keeper);
        launch.seedPool();
        _setFeed(address(fund), _navPrice() * 13 / 10);

        uint256 aliceShares = launch.claimable(alice);
        uint256 valueAtClose = staking.convertToAssets(aliceShares);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        staking.accrue();

        // Alice did nothing, yet her allocation grew; the push hands over the grown shares.
        assertGt(staking.convertToAssets(aliceShares), valueAtClose);
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        launch.distribute(accounts);
        assertEq(staking.balanceOf(alice), aliceShares);
    }

    function test_autoStake_launchHoldsWholeStakeUntilPushed() public {
        _finalizeTwoDepositors();
        // Nobody has claimed: the launch holds the whole stake and casts no votes, so in the weekly
        // vote it counts as silent stake, which follows the curators.
        assertEq(staking.totalSupply(), launch.stakedShares());
        assertEq(governor.escrowOf(address(launch), address(staking)), 0);
    }

    function test_claim_lockedTokensCannotMoveForSevenDays() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        uint256 shares = launch.claim(false);

        vm.prank(alice);
        vm.expectRevert(IFund.LaunchTokensLocked.selector);
        fund.transfer(bob, 1);

        vm.warp(fund.depositorUnlockAt() - 1);
        vm.prank(alice);
        vm.expectRevert(IFund.LaunchTokensLocked.selector);
        fund.transfer(bob, 1);

        vm.warp(fund.depositorUnlockAt());
        vm.prank(alice);
        fund.transfer(bob, shares);
        assertEq(fund.balanceOf(bob), shares);
    }

    function test_claim_lockedTokensStillRedeemable() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        vm.prank(alice);
        fund.redeem(shares / 2, alice, new uint256[](0), 0);
        assertEq(fund.balanceOf(alice), shares - shares / 2);
        assertEq(fund.launchLocked(alice), shares - shares / 2);
        assertGt(net.balanceOf(alice), 0);
    }

    function test_claim_lockOnlyCoversLaunchTokens() public {
        _finalizeTwoDepositors();
        vm.prank(keeper);
        launch.seedPool();
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        // Tokens bought later move freely; the launch tokens stay put.
        _poolSwap(alice, true, -int256(1000e6));
        uint256 bought = fund.balanceOf(alice) - shares;
        assertGt(bought, 0);
        vm.prank(alice);
        fund.transfer(bob, bought);
        vm.prank(alice);
        vm.expectRevert(IFund.LaunchTokensLocked.selector);
        fund.transfer(bob, 1);
    }

    function test_claim_withStake_locksStakedShares() public {
        _finalizeTwoDepositors();
        uint256 expected = launch.claimable(bob);
        vm.prank(bob);
        uint256 shares = launch.claim(true);
        assertEq(shares, expected);
        assertEq(staking.balanceOf(bob), shares);
        assertEq(staking.lockedShares(bob), shares);

        vm.prank(bob);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.transfer(alice, 1);
    }

    function test_claim_stakedThenUnstaked_staysLockedUntilUnlock() public {
        _finalizeTwoDepositors();
        vm.prank(bob);
        uint256 shares = launch.claim(true);
        vm.prank(bob);
        uint256 assets = staking.unstake(shares, bob);
        assertEq(fund.launchLocked(bob), assets);
        vm.prank(bob);
        vm.expectRevert(IFund.LaunchTokensLocked.selector);
        fund.transfer(alice, 1);

        _passDepositorLock();
        vm.prank(bob);
        fund.transfer(alice, assets);
    }

    function test_claim_lockedSharesUnstakeOnlyToSelf() public {
        _finalizeTwoDepositors();
        vm.prank(bob);
        uint256 shares = launch.claim(true);
        vm.prank(bob);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.unstake(1, alice);

        _passDepositorLock();
        vm.prank(bob);
        uint256 assets = staking.unstake(shares, alice);
        assertEq(fund.launchLocked(alice), 0);
        assertEq(fund.balanceOf(alice), assets);
    }

    function test_claim_lockedTokensCanBeStaked() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        vm.startPrank(alice);
        fund.approve(address(staking), shares);
        staking.stake(shares, alice);
        vm.stopPrank();
        assertEq(fund.launchLocked(alice), 0);
        assertEq(staking.lockedShares(alice), staking.balanceOf(alice));
    }

    function test_claim_beforeSuccess_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.WrongStatus.selector);
        launch.claim(false);
    }

    function test_claim_allClaimsWithinAllocation() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        launch.claim(false);
        vm.prank(bob);
        launch.claim(true);
        assertLe(fund.balanceOf(alice) + staking.totalAssets(), launch.depositorSupply());
        assertApproxEqAbs(staking.balanceOf(address(launch)), 0, 10);
    }

    function test_depositValues_reportsTargetsAndValues() public {
        _deposit(alice, address(net), 100e9);
        _deposit(bob, address(tsla), 10e18);
        _deposit(bob, address(usdg), 2000e6);
        (address[] memory assets, uint256[] memory values, uint16[] memory weights) = launch.depositValues();
        assertEq(assets.length, 4);
        assertEq(assets[0], address(net));
        assertEq(assets[3], address(usdg));
        assertEq(values[0], 30_000e18);
        assertEq(values[1], 0);
        assertEq(values[2], 4000e18);
        assertEq(values[3], 2000e18);
        // Basket weights take the 80% left after USDG's 20% pool share.
        assertEq(weights[0], 3200);
        assertEq(weights[2], 2400);
        assertEq(weights[3], 2000);
        assertEq(launch.raisedValue(), 36_000e18);
    }

    function _finalizeTwoDepositors() internal {
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(alice, address(net), 100e9);
        _deposit(alice, address(pons), 1_500_000e18);
        _deposit(alice, address(usdg), 15_000e6);
        _deposit(bob, address(net), 20e9);
        _deposit(bob, address(tsla), 85e18);
        _deposit(bob, address(usdg), 10_000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
    }

    function _createTargetFund(
        uint256 target
    ) internal {
        CreateFundParams memory p = _defaultParams();
        p.targetRaiseUsd = target;
        _createFund(p);
    }

    function _netForTsla(uint256 netIn, uint256 tslaOut) internal view returns (IFund.RebalanceParams memory) {
        return IFund.RebalanceParams({
            sellAsset: address(net),
            sellAmount: netIn,
            buyAsset: address(tsla),
            minBuyAmount: tslaOut,
            router: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (address(net), netIn, address(tsla), tslaOut))
        });
    }

    /// @dev Pool spot price in USD per fund token, 18 decimals.
    function _poolPrice() internal view returns (uint256) {
        PoolKey memory key = hook.poolKeyOf(address(fund));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return address(usdg) < address(fund)
            ? Math.mulDiv(1e30, 1 << 192, priceX192) // currency0 = USDG
            : Math.mulDiv(priceX192, 1e30, 1 << 192); // currency1 = USDG
    }
}
