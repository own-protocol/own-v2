// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundLaunch} from "../../src/interfaces/IFundLaunch.sol";
import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract FundLaunchTest is FundTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    // Basket $100k, USDG $30k, supply 130k: M = 30k * 130k / (1.3 * 130k + 30k).
    uint256 internal constant POOL_SHARES = uint256(30_000e18) * 130_000e18 / 199_000e18;
    uint256 internal constant DEPOSITOR_SHARES = 130_000e18 - POOL_SHARES;

    function setUp() public override {
        super.setUp();
        _createFund();
    }

    // ──────────────────────────────────────────────────────────
    //  deposit
    // ──────────────────────────────────────────────────────────

    function test_deposit_pullsThirtyPercentUsdg() public {
        uint256 paid = _deposit(alice, address(net), 10e9); // 10 NET at $300 = $3,000
        assertEq(paid, 900e6);
        IFundLaunch.Deposit memory d = launch.depositOf(alice, address(net));
        assertEq(d.amount, 10e9);
        assertEq(d.usdg, 900e6);
        assertEq(d.timeWeight, 10e9 * 7 days);
        assertEq(launch.totalDeposited(address(net)), 10e9);
        assertEq(launch.totalUsdg(), 900e6);
        assertEq(usdg.balanceOf(address(launch)), 900e6);
    }

    function test_deposit_roundsUsdgUp() public {
        uint256 paid = _deposit(alice, address(pons), 1e10); // $0.0000002 of PONS
        assertEq(paid, 1);
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

    function test_deposit_usdg_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundLaunch.AssetNotAccepted.selector, address(usdg)));
        launch.deposit(address(usdg), 1e6);
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

    function test_setDepositsPaused_notAdmin_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(IFundLaunch.NotAdmin.selector);
        launch.setDepositsPaused(true);
    }

    function test_deposit_stalePrice_reverts() public {
        vm.warp(block.timestamp + STALENESS + 1);
        net.mint(alice, 1e9);
        vm.prank(alice);
        vm.expectRevert();
        launch.deposit(address(net), 1e9);
    }

    // ──────────────────────────────────────────────────────────
    //  withdraw
    // ──────────────────────────────────────────────────────────

    function test_withdraw_returnsAssetAndUsdgAndForfeitsEarlyYield() public {
        _deposit(alice, address(net), 10e9);
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        uint256 back = launch.withdraw(address(net), 4e9);

        assertEq(back, 360e6);
        assertEq(net.balanceOf(alice), 4e9);
        assertEq(usdg.balanceOf(alice), usdgBefore + 360e6);
        IFundLaunch.Deposit memory d = launch.depositOf(alice, address(net));
        assertEq(d.amount, 6e9);
        assertEq(d.usdg, 540e6);
        // The time weight left belongs to the tokens that stayed, from when they came in.
        assertEq(d.timeWeight, 6e9 * 7 days);
        assertEq(launch.totalDeposited(address(net)), 6e9);
        assertEq(launch.totalUsdg(), 540e6);
        assertEq(launch.totalTimeWeight(address(net)), 6e9 * 7 days);
    }

    function test_withdraw_inLastDay_reverts() public {
        _deposit(alice, address(net), 10e9);
        vm.warp(launch.withdrawDeadline());
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.WithdrawalsClosed.selector);
        launch.withdraw(address(net), 1e9);
        assertEq(launch.withdrawDeadline(), launch.endTime() - 1 days);
    }

    function test_withdraw_moreThanDeposited_reverts() public {
        _deposit(alice, address(net), 10e9);
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.InsufficientDeposit.selector);
        launch.withdraw(address(net), 10e9 + 1);
    }

    function test_withdraw_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.ZeroAmount.selector);
        launch.withdraw(address(net), 0);
    }

    function test_withdraw_afterFinalize_reverts() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        vm.expectRevert(IFundLaunch.WrongStatus.selector);
        launch.withdraw(address(net), 1e9);
    }

    // ──────────────────────────────────────────────────────────
    //  finalize
    // ──────────────────────────────────────────────────────────

    function test_finalize_windowOpen_reverts() public {
        vm.expectRevert(IFundLaunch.WindowOpen.selector);
        launch.finalize();
    }

    function test_finalize_success_sizesPoolAtPremium() public {
        _finalizeTwoDepositors();

        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
        assertTrue(fund.launched());
        assertEq(fund.depositorUnlockAt(), block.timestamp + 7 days);

        assertApproxEqAbs(launch.depositorSupply(), DEPOSITOR_SHARES, 1e6);
        assertEq(fund.balanceOf(address(launch)), launch.depositorSupply());
        // Full-range liquidity rounding leaves a few wei of fund tokens, which the hook burns.
        assertApproxEqAbs(fund.totalSupply(), 130_000e18, 1e7);
        assertApproxEqAbs(fund.balanceOf(address(poolManager)), POOL_SHARES, 1e7);
        assertApproxEqAbs(usdg.balanceOf(address(poolManager)), 30_000e6, 1);
        assertEq(fund.balanceOf(address(hook)), 0);
        assertEq(usdg.balanceOf(address(hook)), 0);
        assertTrue(hook.isSeeded(address(fund)));

        // Basket moved into the fund.
        assertEq(net.balanceOf(address(fund)), 120e9);
        assertEq(pons.balanceOf(address(fund)), 1_500_000e18);
        assertEq(tsla.balanceOf(address(fund)), 85e18);

        // The pool position counts: NAV = $130k over the depositors' tokens only.
        // The position is valued at the TWAP tick, a fraction of a basis point off the seed price.
        assertApproxEqRel(fund.effectiveSupply(), launch.depositorSupply(), 1e14);
        assertApproxEqRel(fund.totalValue(), 130_000e18, 1e14);
        uint256 nav = fund.navPerShare();
        assertApproxEqRel(nav, uint256(130_000e18) * 1e18 / DEPOSITOR_SHARES, 1e14);

        // Pool opens at 1.3x NAV.
        assertApproxEqRel(_poolPrice(), nav * 13 / 10, 1e14);
    }

    function test_finalize_depositorsGetNavEqualToWhatTheyBrought() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        // Alice brought $60k of assets and $18k of USDG; bob's $200 haircut adds a sliver.
        uint256 aliceValue = Math.mulDiv(shares, fund.navPerShare(), 1e18);
        assertApproxEqRel(aliceValue, uint256(78_000e18) * 130_000 / 129_800, 1e14);
    }

    function test_finalize_overweightHaircutGoesToOthers() public {
        _finalizeTwoDepositors();
        // TSLA is $34k against a $30k target: bob's TSLA credit loses 5% of the $4k over.
        assertEq(launch.rawValue(address(tsla)), 34_000e18);
        assertEq(launch.creditedValue(address(tsla)), 33_800e18);
        assertEq(launch.creditedValue(address(net)), 36_000e18);

        uint256 aliceShares = launch.claimable(alice);
        uint256 bobShares = launch.claimable(bob);
        // Points are credited value plus USDG paid: alice 60k + 18k, bob 39.8k + 12k.
        assertApproxEqRel(aliceShares, launch.depositorSupply() * 78_000 / 129_800, 1e12);
        assertApproxEqRel(bobShares, launch.depositorSupply() * 51_800 / 129_800, 1e12);
    }

    function test_finalize_earlyDepositEarnsExtraTokens() public {
        // Same basket from both, alice at the open and bob at the close.
        _deposit(alice, address(net), 50e9);
        _deposit(alice, address(pons), 750_000e18);
        _deposit(alice, address(tsla), 37.5e18);
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(bob, address(net), 50e9);
        _deposit(bob, address(pons), 750_000e18);
        _deposit(bob, address(tsla), 37.5e18);
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

    function test_finalize_pointsCountUsdgPaid_notDepositTimePrice() public {
        // Bob deposits the same basket while TSLA is 20% down, so he pays less USDG for it.
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        uint256 usdgA = _deposit(alice, address(net), 50e9);
        usdgA += _deposit(alice, address(pons), 750_000e18);
        usdgA += _deposit(alice, address(tsla), 37.5e18);
        int256 tslaPrice = feeds[address(tsla)].answer();
        _setFeed(address(tsla), tslaPrice * 8 / 10);
        uint256 usdgB = _deposit(bob, address(net), 50e9);
        usdgB += _deposit(bob, address(pons), 750_000e18);
        usdgB += _deposit(bob, address(tsla), 37.5e18);
        assertLt(usdgB, usdgA);
        _setFeed(address(tsla), tslaPrice);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();

        uint256 half = (
            launch.creditedValue(address(net)) + launch.creditedValue(address(pons))
                + launch.creditedValue(address(tsla))
        ) / 2;
        uint256 a = launch.claimable(alice);
        uint256 b = launch.claimable(bob);
        assertApproxEqRel(a * 1e18 / b, (half + usdgA * 1e12) * 1e18 / (half + usdgB * 1e12), 1e12);
    }

    function test_finalize_usdgDonatedToHook_goesToFund() public {
        _deposit(alice, address(net), 100e9);
        _deposit(alice, address(pons), 1_500_000e18);
        _deposit(bob, address(net), 20e9);
        _deposit(bob, address(tsla), 85e18);
        usdg.mint(address(hook), 1000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();

        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
        assertEq(usdg.balanceOf(address(hook)), 0);
        assertApproxEqAbs(fund.idleUsdg(), 1000e6, 1);
    }

    function test_finalize_belowMinimum_fails() public {
        _deposit(alice, address(net), 10e9); // $3k < $10k minimum
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Failed));
        assertFalse(fund.launched());
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
        _deposit(alice, address(net), 100e9); // $30k at deposit, $9k USDG
        vm.warp(launch.endTime());
        _refreshFeeds();
        _setFeed(address(net), 150e8); // halves by the close
        launch.finalize();
        assertEq(launch.closePrice(address(net)), 150e18);
        assertEq(launch.rawValue(address(net)), 15_000e18);
        // NAV is still what went in: $15k of NET plus the $9k USDG.
        assertApproxEqRel(fund.totalValue(), 24_000e18, 1e14);
        assertEq(launch.claimable(alice), launch.depositorSupply());
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
        uint256 paid = _deposit(alice, address(net), 10e9);
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.warp(launch.finalizeDeadline() + 1);
        launch.markFailed();

        vm.prank(alice);
        launch.refund();
        assertEq(net.balanceOf(alice), 10e9);
        assertEq(usdg.balanceOf(alice), usdgBefore + paid);
        assertTrue(launch.settled(alice));

        vm.prank(alice);
        vm.expectRevert(IFundLaunch.NothingToClaim.selector);
        launch.refund();
    }

    function test_refund_afterPartialWithdraw_returnsTheRest() public {
        _deposit(alice, address(net), 10e9);
        vm.prank(alice);
        launch.withdraw(address(net), 4e9);
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize(); // $1.8k < minimum
        vm.prank(alice);
        launch.refund();
        assertEq(net.balanceOf(alice), 10e9);
        assertEq(usdg.balanceOf(alice), usdgBefore + 540e6);
        assertEq(usdg.balanceOf(address(launch)), 0);
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
        assertEq(fund.balanceOf(address(staking)), shares);

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
        assertApproxEqAbs(fund.balanceOf(address(launch)), 0, 10);
    }

    function test_depositValues_reportsTargetsAndValues() public {
        _deposit(alice, address(net), 100e9);
        _deposit(bob, address(tsla), 10e18);
        (address[] memory assets, uint256[] memory values, uint16[] memory weights) = launch.depositValues();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(net));
        assertEq(values[0], 30_000e18);
        assertEq(values[1], 0);
        assertEq(values[2], 4000e18);
        assertEq(weights[0], 4000);
        assertEq(weights[2], 3000);
    }

    function _finalizeTwoDepositors() internal {
        vm.warp(launch.endTime() - 1);
        _refreshFeeds();
        _deposit(alice, address(net), 100e9);
        _deposit(alice, address(pons), 1_500_000e18);
        _deposit(bob, address(net), 20e9);
        _deposit(bob, address(tsla), 85e18);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
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
