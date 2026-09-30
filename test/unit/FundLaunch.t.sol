// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundLaunch} from "../../src/interfaces/IFundLaunch.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract FundLaunchTest is FundTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

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
        assertEq(launch.depositOf(alice, address(net)), 10e9);
        assertEq(launch.usdgOf(alice), 900e6);
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
        vm.prank(creator);
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
    //  finalize
    // ──────────────────────────────────────────────────────────

    function test_finalize_windowOpen_reverts() public {
        vm.expectRevert(IFundLaunch.WindowOpen.selector);
        launch.finalize();
    }

    function test_finalize_success_sizesPoolAtPremium() public {
        _deposit(alice, address(net), 100e9); // $30k
        _deposit(alice, address(pons), 1_500_000e18); // $30k
        _deposit(bob, address(net), 20e9); // $6k
        _deposit(bob, address(tsla), 85e18); // $34k
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();

        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
        assertTrue(fund.launched());

        // Depositors: 100k MF1 for $100k of basket. Pool: 30k USDG + 30k MF1 (M = U*C / (1.3R - U)).
        assertEq(fund.balanceOf(address(launch)), 100_000e18);
        // Full-range liquidity rounding leaves a few wei of MF1, which the hook burns.
        assertApproxEqAbs(fund.totalSupply(), 130_000e18, 1e7);
        assertApproxEqAbs(fund.balanceOf(address(poolManager)), 30_000e18, 1e7);
        assertApproxEqAbs(usdg.balanceOf(address(poolManager)), 30_000e6, 1);
        assertEq(fund.balanceOf(address(hook)), 0);
        assertEq(usdg.balanceOf(address(hook)), 0);
        assertTrue(hook.isSeeded(address(fund)));

        // Basket moved into the fund.
        assertEq(net.balanceOf(address(fund)), 120e9);
        assertEq(pons.balanceOf(address(fund)), 1_500_000e18);
        assertEq(tsla.balanceOf(address(fund)), 85e18);

        // NAV counts every MF1, including the pool's: 100k / 130k.
        assertApproxEqRel(fund.navPerShare(), uint256(100_000e18) * 1e18 / 130_000e18, 1e9);

        // Pool opens at $1.00 per MF1, i.e. 30% over NAV.
        PoolKey memory key = hook.poolKeyOf(address(fund));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        // raw USDG per raw MF1 (or the inverse), converted to USD per MF1
        uint256 usdPerMf1 = address(usdg) < address(fund)
            ? Math.mulDiv(1e30, 1 << 192, priceX192)  // currency0 = USDG
            : Math.mulDiv(priceX192, 1e30, 1 << 192); // currency1 = USDG
        assertApproxEqRel(usdPerMf1, 1e18, 1e12);
    }

    function test_finalize_usdgDonatedToHook_stillSeeds() public {
        _deposit(alice, address(net), 100e9);
        _deposit(alice, address(pons), 1_500_000e18);
        _deposit(bob, address(net), 20e9);
        _deposit(bob, address(tsla), 85e18);
        usdg.mint(address(hook), 30_000e6 + 1); // more than the seed itself
        uint256 treasuryBefore = usdg.balanceOf(protocolTreasury);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();

        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Succeeded));
        assertEq(usdg.balanceOf(address(hook)), 0);
        assertApproxEqAbs(usdg.balanceOf(protocolTreasury) - treasuryBefore, 30_000e6 + 1, 1);
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
        _deposit(alice, address(net), 100e9); // $30k at deposit
        vm.warp(launch.endTime());
        _refreshFeeds();
        _setFeed(address(net), 150e8); // halves by the close
        launch.finalize();
        assertEq(launch.closePrice(address(net)), 150e18);
        assertEq(launch.claimable(alice), 15_000e18);
    }

    function test_finalize_crashBelowUsdg_fails() public {
        _deposit(alice, address(net), 1000e9); // $300k, $90k USDG
        vm.warp(launch.endTime());
        _refreshFeeds();
        _setFeed(address(net), 60e8); // basket now $60k, and $60k * 1.3 < $90k USDG
        launch.finalize();
        assertEq(uint8(launch.status()), uint8(IFundLaunch.Status.Failed));
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
    //  claim
    // ──────────────────────────────────────────────────────────

    function test_claim_transfersAllocation() public {
        _finalizeTwoDepositors();
        vm.prank(alice);
        uint256 shares = launch.claim(false);
        assertEq(shares, 60_000e18);
        assertEq(fund.balanceOf(alice), 60_000e18);

        vm.prank(alice);
        vm.expectRevert(IFundLaunch.NothingToClaim.selector);
        launch.claim(false);
    }

    function test_claim_withStake_mintsStakedShares() public {
        _finalizeTwoDepositors();
        vm.prank(bob);
        uint256 shares = launch.claim(true);
        assertEq(shares, 40_000e18);
        assertEq(staking.balanceOf(bob), 40_000e18);
        assertEq(fund.balanceOf(address(staking)), 40_000e18);
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
        launch.claim(false);
        assertLe(fund.balanceOf(alice) + fund.balanceOf(bob), 100_000e18);
    }

    function _finalizeTwoDepositors() internal {
        _deposit(alice, address(net), 100e9);
        _deposit(alice, address(pons), 1_500_000e18);
        _deposit(bob, address(net), 20e9);
        _deposit(bob, address(tsla), 85e18);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
    }
}
