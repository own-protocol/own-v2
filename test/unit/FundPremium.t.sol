// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {IFundHook} from "../../src/interfaces/IFundHook.sol";
import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {
    CreateFundParams,
    IssuanceConfig,
    IssuanceStep,
    PremiumConfig,
    YieldPoint
} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @dev Pool issuance, the Premium Boost, the Premium Pot and the locked mint. The pool opens at
///      1.3x NAV, so issuance runs at the first density step. Tier yield is switched off so each
///      test sees the premium flows alone.
contract FundPremiumTest is FundTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // 2 / ln 2, 18 decimals.
    uint256 internal constant K = 2_885_390_081_777_926_815;

    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        launch.claim(false);
        vm.prank(bob);
        launch.claim(true);
        _passDepositorLock();
        vm.startPrank(admin);
        factory.setMaxYieldRate(0);
        staking.setCuratorYield(0, 0);
        vm.stopPrank();
        staking.accrue();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _nav() internal view returns (uint256 nav, uint256 supply) {
        bool ok;
        (ok, nav, supply) = fund.tryNav();
        assertTrue(ok);
    }

    /// @dev NAV as the mint prices it: rounded up.
    function _mintNav() internal view returns (uint256) {
        return Math.mulDiv(fund.totalValue(), 1e18, fund.effectiveSupply(), Math.Rounding.Ceil);
    }

    /// @dev Fund tokens the staking module holds for payouts (boosts and the pot), beyond the stakes.
    function _held() internal view returns (uint256) {
        return fund.balanceOf(address(staking)) - staking.totalAssets();
    }

    /// @dev Square root of the pool price, USDG per fund token in raw units, Q96.
    function _q() internal view returns (uint256) {
        PoolKey memory key = hook.poolKeyOf(address(fund));
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(key.toId());
        return Currency.unwrap(key.currency0) == address(usdg) ? (uint256(1) << 192) / sqrtPrice : sqrtPrice;
    }

    /// @dev Pool swap returning the hook's issuance for it (zeros when nothing was issued).
    function _swapIssued(
        address who,
        bool buy,
        int256 amountSpecified
    ) internal returns (uint256 usdgIn, uint256 issued, uint256 pot) {
        vm.recordLogs();
        _poolSwap(who, buy, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == IFundHook.Issued.selector) {
                (usdgIn, issued, pot) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    function _buy(
        int256 amountSpecified
    ) internal returns (uint256 usdgIn, uint256 issued, uint256 pot) {
        return _swapIssued(carol, true, amountSpecified);
    }

    function _steps(uint32 secondAt, uint16 first, uint16 second) internal pure returns (IssuanceStep[] memory s) {
        s = new IssuanceStep[](2);
        s[0] = IssuanceStep({premiumBps: 0, densityBps: first});
        s[1] = IssuanceStep({premiumBps: secondAt, densityBps: second});
    }

    function _warp(
        uint256 by
    ) internal {
        vm.warp(block.timestamp + by);
        _refreshFeeds();
    }

    // ──────────────────────────────────────────────────────────
    //  Pool issuance
    // ──────────────────────────────────────────────────────────

    function test_issuance_onePercentOfSupplyPerDoubling() public {
        (, uint256 supply) = _nav();
        uint256 q0 = _q();
        (, uint256 issued,) = _buy(-int256(50e6));
        uint256 q1 = _q();
        // `c * dq / q1` with c = 2 d S / ln 2: d of supply per doubling of price (dq / q = ln 2 / 2).
        uint256 expected = Math.mulDiv(supply * 100 / 10_000, K * (q1 - q0), 1e18 * q1);
        // The pool's LP fee moves its price a hair less than the split assumes.
        assertApproxEqRel(issued, expected, 0.005e18);
    }

    function test_issuance_densityFollowsSteps() public {
        vm.prank(admin);
        hook.setIssuance(
            address(fund), IssuanceConfig({startBps: 100, potShareBps: 7500, steps: _steps(2000, 100, 300)})
        );
        (, uint256 supply) = _nav();
        uint256 q0 = _q();
        (, uint256 issued,) = _buy(-int256(50e6));
        uint256 q1 = _q();
        // At a 30% premium the second step (from 20%) sets 3% per doubling.
        uint256 expected = Math.mulDiv(supply * 300 / 10_000, K * (q1 - q0), 1e18 * q1);
        assertApproxEqRel(issued, expected, 0.005e18);
    }

    function test_issuance_fillShareMatchesDensity() public {
        uint256 before = fund.balanceOf(carol);
        (uint256 usdgIn, uint256 issued,) = _buy(-int256(1000e6));
        uint256 got = fund.balanceOf(carol) - before;
        // The hook fills cq / (L + cq) of the buy after its 1% fee; the AMM fills the rest.
        PoolKey memory key = hook.poolKeyOf(address(fund));
        uint256 liquidity = poolManager.getLiquidity(key.toId());
        assertGt(issued, 0);
        assertLt(issued, got);
        uint256 afterFee = 1000e6 - 10e6;
        uint256 cq = Math.mulDiv(usdgIn, liquidity, afterFee - usdgIn);
        assertApproxEqRel(usdgIn * 1e18 / afterFee, cq * 1e18 / (liquidity + cq), 1e12);
    }

    function test_issuance_noneBelowStart() public {
        // Dump the pool to under NAV x 1.01.
        vm.prank(alice);
        fund.transfer(dave, 6000e18);
        _poolSwap(dave, false, -int256(6000e18));
        (uint256 nav,) = _nav();
        assertLt(hook.spotPrice(address(fund)) * 100, nav * 101);

        uint256 supply = fund.totalSupply();
        (, uint256 issued,) = _buy(-int256(100e6));
        assertEq(issued, 0);
        assertEq(fund.totalSupply(), supply);
        assertEq(staking.potLeft(), 0);
    }

    function test_issuance_startIsConfigurable() public {
        vm.prank(admin);
        hook.setIssuance(
            address(fund), IssuanceConfig({startBps: 5000, potShareBps: 7500, steps: _steps(10_000, 100, 200)})
        );
        (, uint256 issued,) = _buy(-int256(100e6)); // a 30% premium is under the 50% start
        assertEq(issued, 0);
    }

    function test_issuance_potGetsShareOfPremiumRestIsBacking() public {
        (uint256 nav0, uint256 s0) = _nav();
        (uint256 usdgIn, uint256 issued, uint256 pot) = _buy(-int256(2000e6));
        assertGt(issued, 0);
        uint256 premium = usdgIn * 1e12 - issued * nav0 / 1e18;
        // The pot's share of the premium, in fund tokens at NAV.
        assertEq(pot, Math.mulDiv(premium, 7500e18, 10_000 * nav0));
        assertEq(_held(), pot);
        assertEq(staking.potLeft(), pot);
        assertEq(staking.potEnd(), block.timestamp + 7 days);

        (uint256 nav1, uint256 s1) = _nav();
        assertEq(s1, s0 + issued + pot);
        // All the USDG for the issued tokens is in the fund; the pot tokens are claims on it.
        assertApproxEqAbs(nav1 * s1 / 1e18, nav0 * s0 / 1e18 + usdgIn * 1e12, 1e6);
        assertGt(nav1, nav0);
    }

    function test_issuance_sellsNeverIssue() public {
        vm.prank(alice);
        fund.transfer(dave, 2000e18);
        uint256 supply = fund.totalSupply();
        (, uint256 issued,) = _swapIssued(dave, false, -int256(1000e18));
        assertEq(issued, 0);
        (, issued,) = _swapIssued(dave, false, int256(100e6));
        assertEq(issued, 0);
        assertEq(fund.totalSupply(), supply);
        assertEq(staking.potLeft(), 0);
    }

    function test_issuance_exactOutBuy() public {
        uint256 before = fund.balanceOf(carol);
        (uint256 usdgIn, uint256 issued, uint256 pot) = _buy(int256(500e18));
        assertEq(fund.balanceOf(carol) - before, 500e18);
        assertGt(issued, 0);
        assertLt(issued, 500e18);
        assertGt(usdgIn, 0);
        assertEq(staking.potLeft(), pot);
    }

    function test_issuance_largeBuysSettle() public {
        (, uint256 issued,) = _buy(-int256(1_000_000e6));
        assertGt(issued, 0);
        // Now far above 5x NAV: the 3% step.
        (uint256 nav,) = _nav();
        assertGt(hook.spotPrice(address(fund)), nav * 5);
        uint256 before = fund.balanceOf(carol);
        (, issued,) = _buy(int256(5000e18));
        assertGt(issued, 0);
        assertEq(fund.balanceOf(carol) - before, 5000e18);
    }

    function test_issuance_usdgCountedInPositionUntilCollected() public {
        (uint256 positionUsdg0,) = fund.positionAmounts();
        uint256 idle0 = fund.idleUsdg();
        (uint256 usdgIn,,) = _buy(-int256(2000e6));
        (uint256 positionUsdg1,) = fund.positionAmounts();
        // Same block: the TWAP has not moved, so only the issuance USDG is new.
        assertEq(positionUsdg1, positionUsdg0 + usdgIn);

        (uint256 nav0,) = _nav();
        hook.collectLpFees(address(fund));
        assertGe(fund.idleUsdg() - idle0, usdgIn);
        (uint256 positionUsdg2,) = fund.positionAmounts();
        assertEq(positionUsdg2, positionUsdg0);
        (uint256 nav1,) = _nav();
        assertGe(nav1, nav0);
    }

    function test_issuance_poolBuysCreateNoBoost() public {
        _buy(-int256(5000e6));
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(staking.mintLockOf(carol, false).shares, 0);
        assertEq(staking.balanceOf(carol), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Premium Boost
    // ──────────────────────────────────────────────────────────

    function test_boost_isShareOfPremiumInTokens_fullProceedsInFund() public {
        uint256 navShares = 10_000e18;
        (, uint256 mintPrice,,,) = fund.previewMint(navShares, false);
        uint256 nav = _mintNav();
        uint256 v0 = fund.totalValue();
        uint256 supply0 = fund.totalSupply();
        _mintAs(carol, navShares);

        IFundStaking.Boost memory b = staking.boostOf(carol);
        uint256 gross = Math.mulDiv(navShares, nav, mintPrice);
        uint256 boost = (navShares - gross) * 7500 / 10_000;
        assertApproxEqAbs(b.left, boost, 1e6);
        assertEq(_held(), b.left);
        assertApproxEqRel(b.perSec, navShares * 7500 / (10_000 * 365 days), 1e9);
        assertEq(b.shares, staking.balanceOf(carol));
        assertEq(b.lastSettle, block.timestamp);
        // The whole payment lands in the fund; the boost tokens are minted with the mint.
        assertApproxEqRel(fund.totalValue() - v0, navShares * nav / 1e18, 1e9);
        assertApproxEqAbs(fund.totalSupply() - supply0, gross + boost, 1e6);
    }

    function test_boost_paysAtSpeed() public {
        (, uint256 mintPrice,,,) = fund.previewMint(10_000e18, false);
        uint256 nav = _mintNav();
        _mintAs(carol, 10_000e18);
        IFundStaking.Boost memory b = staking.boostOf(carol);
        uint256 duration = b.left / b.perSec;
        // 75% of the premium at 75% of the payment a year: the premium's share of the price, in years.
        assertApproxEqRel(duration, (1e18 - nav * 1e18 / mintPrice) * 365 days / 1e18, 1e12);

        _warp(duration / 2);
        staking.settleBoost(carol);
        assertApproxEqRel(b.left - staking.boostOf(carol).left, b.left / 2, 1e12);

        _warp(duration);
        staking.settleBoost(carol);
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(_held(), 0);
    }

    function test_boost_payoutLeavesNavAndSupplyUnchanged() public {
        _mintAs(carol, 10_000e18);
        _warp(20 days);
        staking.accrue();
        (uint256 nav0, uint256 s0) = _nav();
        uint256 owed = staking.pendingBoost(carol);
        uint256 held0 = _held();
        uint256 a0 = staking.convertToAssets(staking.balanceOf(carol));

        staking.settleBoost(carol);
        (uint256 nav1, uint256 s1) = _nav();
        assertEq(nav1, nav0);
        assertEq(s1, s0);
        assertEq(_held(), held0 - owed);
        assertApproxEqRel(staking.convertToAssets(staking.balanceOf(carol)) - a0, owed, 1e9);
    }

    /// @dev A6-M-12: the boost tokens share the fund's price moves, so a basket drop costs other
    ///      holders only its own share, with no fixed dollar claim levering it.
    function test_boost_sharesPriceMoves() public {
        _mintAs(carol, 20_000e18);
        uint256 left = staking.boostOf(carol).left;
        (uint256 nav0,) = _nav();
        uint256 v0 = fund.totalValue();

        _setFeed(address(tsla), feeds[address(tsla)].answer() / 2);
        (uint256 nav1,) = _nav();
        assertApproxEqRel(nav1 * 1e18 / nav0, fund.totalValue() * 1e18 / v0, 1e9);
        assertEq(staking.boostOf(carol).left, left);
    }

    /// @dev A6-L-07: a mint too small for any boost speed gets no boost; its boost tokens are burned.
    function test_boost_tinyMintSkipsBoost() public {
        uint256 supply0 = fund.totalSupply();
        (uint256 quoted, uint256 mintPrice,,,) = fund.previewMint(40_000, false);
        uint256 gross = Math.mulDiv(40_000, _mintNav(), mintPrice);
        assertGt(40_000 - gross, 0); // a boost would be owed
        assertEq(_mintAs(carol, 40_000), quoted);
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(_held(), 0);
        assertEq(fund.totalSupply() - supply0, gross);
    }

    function test_boost_forfeitBurnsUnpaidAndRaisesNav() public {
        _mintAs(carol, 10_000e18);
        _warp(15 days);
        staking.settleBoost(carol);
        IFundStaking.Boost memory b = staking.boostOf(carol);
        uint256 held0 = _held();
        (uint256 nav0, uint256 s0) = _nav();

        uint256 half = staking.balanceOf(carol) / 2;
        vm.prank(carol);
        staking.transfer(bob, half);

        uint256 held = staking.balanceOf(carol);
        IFundStaking.Boost memory a = staking.boostOf(carol);
        assertEq(a.left, Math.mulDiv(b.left, held, b.shares));
        assertEq(a.perSec, Math.mulDiv(b.perSec, held, b.shares));
        assertEq(a.shares, held);
        uint256 forfeited = held0 - _held();
        assertEq(forfeited, b.left - a.left);
        assertEq(staking.boostOf(bob).left, 0);

        (uint256 nav1, uint256 s1) = _nav();
        assertEq(s1, s0 - forfeited);
        assertApproxEqAbs(nav1, nav0 * s0 / s1, 2);
        assertGt(nav1, nav0);
    }

    function test_boost_partialUnstakeScales() public {
        _mintAs(carol, 10_000e18);
        _warp(15 days);
        staking.settleBoost(carol);
        IFundStaking.Boost memory b = staking.boostOf(carol);
        uint256 out = staking.balanceOf(carol) / 4;
        vm.prank(carol);
        staking.unstake(out, carol);
        uint256 held = staking.balanceOf(carol);
        IFundStaking.Boost memory a = staking.boostOf(carol);
        assertEq(a.left, Math.mulDiv(b.left, held, b.shares));
        assertEq(a.perSec, Math.mulDiv(b.perSec, held, b.shares));
        assertEq(_held(), a.left);
    }

    function test_boost_secondMintMergesAfterSettling() public {
        _mintAs(carol, 10_000e18);
        IFundStaking.Boost memory b1 = staking.boostOf(carol);
        _warp(10 days);
        uint256 owed = staking.pendingBoost(carol);
        uint256 held0 = _held();

        _fundSlice(carol, 5000e18);
        vm.expectEmit(true, false, false, false, address(staking));
        emit IFundStaking.BoostPaid(carol, owed, 0);
        vm.prank(carol);
        fund.mint(5000e18, 0, carol, false);

        IFundStaking.Boost memory b2 = staking.boostOf(carol);
        uint256 boost2 = _held() - (held0 - owed);
        assertGt(boost2, 0);
        assertEq(b2.left, b1.left - owed + boost2);
        assertApproxEqRel(b2.perSec - b1.perSec, uint256(5000e18) * 7500 / (10_000 * 365 days), 1e9);
        assertEq(b2.lastSettle, block.timestamp);
    }

    function test_boost_neverRevivedByRestaking() public {
        _mintAs(carol, 10_000e18);
        _warp(15 days);
        staking.settleBoost(carol);
        uint256 bal = staking.balanceOf(carol);
        vm.prank(carol);
        uint256 assets = staking.unstake(bal, carol);
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(_held(), 0);

        vm.startPrank(carol);
        fund.approve(address(staking), assets);
        staking.stake(assets, carol);
        vm.stopPrank();
        _warp(30 days);
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(staking.pendingBoost(carol), 0);
        uint256 shares = staking.balanceOf(carol);
        staking.settleBoost(carol);
        assertEq(staking.balanceOf(carol), shares);
    }

    function test_boost_redeemsLeaveBoostTokensInPlace() public {
        _mintAs(carol, 20_000e18);
        uint256 boost = staking.boostOf(carol).left;
        (uint256 nav0,) = _nav();

        // 80% of every other holder redeems.
        uint256 aliceBal = fund.balanceOf(alice);
        vm.prank(alice);
        fund.redeem(aliceBal * 8 / 10, alice, new uint256[](0), 0);
        uint256 bobBal = staking.balanceOf(bob);
        vm.prank(bob);
        staking.redeem(bobBal * 8 / 10, bob, new uint256[](0), 0);

        assertEq(_held(), boost);
        (uint256 nav1,) = _nav();
        // Redeems never lower NAV (rounding and the pool's TWAP cap leave dust with the fund).
        assertGe(nav1 + 1, nav0);
        assertApproxEqRel(nav1, nav0, 1e14);

        // The boost still pays out in full.
        uint256 a0 = staking.convertToAssets(staking.balanceOf(carol));
        _warp(2 * 365 days);
        staking.settleBoost(carol);
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(_held(), 0);
        assertApproxEqRel(staking.convertToAssets(staking.balanceOf(carol)) - a0, boost, 1e9);
    }

    /// @dev A6-M-12: a redeem reads no price, so a stale feed never blocks it while boosts are owed.
    function test_redeem_stalePriceWithBoostOwed() public {
        _mintAs(carol, 10_000e18);
        assertGt(_held(), 0);
        vm.warp(block.timestamp + 2 days); // feeds stale
        (bool ok,,) = fund.tryNav();
        assertFalse(ok);

        uint256 bal = fund.balanceOf(alice);
        vm.prank(alice);
        (, uint256 usdgOut) = fund.redeem(bal / 2, alice, new uint256[](0), 0);
        assertGt(usdgOut, 0);
        // The boost pays without a price too.
        uint256 shares = staking.balanceOf(carol);
        staking.settleBoost(carol);
        assertGt(staking.balanceOf(carol), shares);
        shares = staking.balanceOf(carol);
        vm.prank(carol);
        staking.redeem(shares, carol, new uint256[](0), 0);
        assertEq(staking.balanceOf(carol), 0);
    }

    function test_setPremiumConfig_adminOnlyBoundedAndApplied() public {
        vm.expectRevert(IFundStaking.NotAdmin.selector);
        staking.setPremiumConfig(5000, 10_000, 3 days);

        vm.startPrank(admin);
        vm.expectEmit(address(staking));
        emit IFundStaking.PremiumConfigSet(5000, 10_000, 3 days);
        staking.setPremiumConfig(5000, 10_000, 3 days);
        vm.expectRevert(IFundStaking.InvalidPremiumConfig.selector);
        staking.setPremiumConfig(10_001, 7500, 7 days);
        vm.expectRevert(IFundStaking.InvalidPremiumConfig.selector);
        staking.setPremiumConfig(7500, 0, 7 days);
        vm.expectRevert(IFundStaking.InvalidPremiumConfig.selector);
        staking.setPremiumConfig(7500, 7500, 1 hours - 1);
        vm.stopPrank();
        assertEq(staking.boostShareBps(), 5000);
        assertEq(staking.boostSpeedBpsPerYear(), 10_000);
        assertEq(staking.potDripPeriod(), 3 days);

        (, uint256 mintPrice,,,) = fund.previewMint(10_000e18, false);
        uint256 nav = _mintNav();
        _mintAs(carol, 10_000e18);
        IFundStaking.Boost memory b = staking.boostOf(carol);
        assertApproxEqRel(b.left, (10_000e18 - Math.mulDiv(10_000e18, nav, mintPrice)) / 2, 1e9);
        assertApproxEqRel(b.perSec, 10_000e18 / uint256(365 days), 1e9);

        (,, uint256 pot) = _buy(-int256(1000e6));
        assertEq(staking.potEnd(), block.timestamp + 3 days);
        assertGt(pot, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Premium Pot
    // ──────────────────────────────────────────────────────────

    function test_pot_dripsLinearlyAndKeepsNav() public {
        (,, uint256 pot) = _buy(-int256(5000e6));
        assertGt(pot, 0);

        _warp(1 days);
        (uint256 nav0, uint256 s0) = _nav();
        uint256 assets0 = staking.totalAssets();
        staking.accrue();
        assertEq(staking.potLeft(), pot - pot / 7);
        assertEq(_held(), pot - pot / 7);
        (uint256 nav1, uint256 s1) = _nav();
        assertEq(nav1, nav0);
        assertEq(s1, s0);
        assertEq(staking.totalAssets() - assets0, pot / 7);

        _warp(3 days);
        staking.accrue();
        assertApproxEqAbs(staking.potLeft(), pot - pot * 4 / 7, 2);

        _warp(3 days);
        staking.accrue();
        assertEq(staking.potLeft(), 0);
        assertEq(staking.potPending(), 0);
        assertEq(_held(), 0);
    }

    /// @dev A6-M-11, A6-M-12: the drip needs no price, so it keeps paying stakers while the feeds
    ///      are stale and nothing piles up.
    function test_pot_dripsWhileUnpriced() public {
        (,, uint256 pot) = _buy(-int256(5000e6));
        _warp(1 days);
        staking.accrue();
        uint256 left = staking.potLeft();
        uint256 assets0 = staking.totalAssets();

        vm.warp(block.timestamp + 2 days); // feeds stale
        (bool ok,,) = fund.tryNav();
        assertFalse(ok);
        staking.accrue();
        assertApproxEqAbs(staking.potLeft(), left - pot * 2 / 7, 2);
        assertEq(staking.potPending(), 0);
        assertApproxEqAbs(staking.totalAssets() - assets0, pot * 2 / 7, 2);
    }

    /// @dev A6-M-11: a stake made while NAV has no price takes nothing already dripped.
    function test_pot_stakeWhileUnpricedTakesNothing() public {
        _buy(-int256(5000e6));
        _warp(1 days);
        staking.accrue();

        vm.warp(block.timestamp + 2 days); // feeds stale
        vm.prank(alice);
        fund.transfer(dave, 10_000e18);
        vm.startPrank(dave);
        fund.approve(address(staking), type(uint256).max);
        uint256 shares = staking.stake(10_000e18, dave);
        vm.stopPrank();

        _refreshFeeds();
        staking.accrue();
        vm.prank(dave);
        assertLe(staking.unstake(shares, dave), 10_000e18);
    }

    function test_pot_topUpRespreadsOverFullPeriod() public {
        (,, uint256 pot1) = _buy(-int256(5000e6));
        _warp(3 days);
        (,, uint256 pot2) = _buy(-int256(5000e6));
        assertEq(staking.potEnd(), block.timestamp + 7 days);
        // What dripped waits for the next accrual; the rest and the top-up drip over the new period.
        assertEq(staking.potPending(), pot1 * 3 / 7);
        assertEq(staking.potLeft(), pot1 - pot1 * 3 / 7 + pot2);
    }

    function test_pot_stakingJustBeforeTopUpEarnsOnlyDrip() public {
        _buy(-int256(5000e6));
        _warp(3 days);
        staking.accrue();

        vm.prank(alice);
        fund.transfer(dave, 10_000e18);
        vm.startPrank(dave);
        fund.approve(address(staking), type(uint256).max);
        uint256 shares = staking.stake(10_000e18, dave);
        vm.stopPrank();
        _buy(-int256(5000e6));

        // Leaving in the same block takes nothing from the top-up.
        vm.prank(dave);
        uint256 back = staking.unstake(shares, dave);
        assertLe(back, 10_000e18);

        // Staying a day earns the share of what dripped that day.
        vm.prank(dave);
        shares = staking.stake(back, dave);
        uint256 total = staking.totalSupply();
        uint256 value0 = staking.convertToAssets(shares);
        _warp(1 days);
        vm.recordLogs();
        staking.accrue();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 released;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(staking) && logs[i].topics[0] == IFundStaking.PotReleased.selector) {
                (released,) = abi.decode(logs[i].data, (uint256, bool));
            }
        }
        assertGt(released, 0);
        assertApproxEqRel(staking.convertToAssets(shares) - value0, released * shares / total, 1e9);
    }

    function test_pot_dustStakeDoesNotCaptureIt() public {
        // Everyone leaves but the launch's wei of dust: the pot is burned into backing instead of
        // inflating the share price.
        uint256 bobBal = staking.balanceOf(bob);
        vm.prank(bob);
        staking.unstake(bobBal, bob);
        assertLt(staking.totalSupply(), 1e18);

        (,, uint256 pot) = _buy(-int256(5000e6));
        _warp(7 days);
        (uint256 nav0, uint256 s0) = _nav();
        uint256 assets0 = staking.totalAssets();
        staking.accrue();
        assertEq(staking.totalAssets(), assets0);
        assertEq(_held(), 0);
        (uint256 nav1, uint256 s1) = _nav();
        assertEq(s1, s0 - pot);
        assertApproxEqAbs(nav1, nav0 * s0 / s1, 2);

        // New stakes still get their full share.
        vm.prank(alice);
        fund.transfer(dave, 1000e18);
        vm.startPrank(dave);
        fund.approve(address(staking), 1000e18);
        uint256 shares = staking.stake(1000e18, dave);
        vm.stopPrank();
        assertApproxEqAbs(staking.convertToAssets(shares), 1000e18, 1);
    }

    // ──────────────────────────────────────────────────────────
    //  Locked mint
    // ──────────────────────────────────────────────────────────

    function test_lock_blocksTransferAndUnstakeButNotRedeem() public {
        _mintAs(carol, 1000e18);
        uint256 bal = staking.balanceOf(carol);
        vm.startPrank(carol);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.transfer(bob, 1);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.unstake(1, carol);
        (, uint256 usdgOut) = staking.redeem(bal, carol, new uint256[](0), 0);
        vm.stopPrank();
        assertGt(usdgOut, 0);
        assertEq(staking.balanceOf(carol), 0);
        assertEq(staking.mintLockOf(carol, false).shares, 0);
        // Redeeming at NAV gives up the unpaid boost.
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(_held(), 0);
    }

    function test_lock_freeAfterConfiguredLength() public {
        vm.prank(admin);
        fund.setMintConfig(3 days, 0, 0);
        _mintAs(carol, 1000e18);
        assertEq(staking.mintLockOf(carol, false).unlockAt, block.timestamp + 3 days);
        _warp(3 days);
        uint256 half = staking.balanceOf(carol) / 2;
        vm.prank(carol);
        staking.unstake(half, carol);
    }

    /// @dev A6-M-10: a locked or boosted mint goes only to the caller, so nobody can put a lock or
    ///      a boost on someone else.
    function test_mint_lockedForOthers_reverts() public {
        _fundSlice(dave, 1e18);
        vm.startPrank(dave);
        vm.expectRevert(IFund.NotReceiver.selector);
        fund.mint(1e18, 0, carol, false);
        vm.expectRevert(IFund.NotReceiver.selector);
        fund.mint(1e18, 0, carol, true);
        vm.stopPrank();
    }

    function test_mint_cappedForOthers_allowed() public {
        _setCap(1000); // unlocked, no boost
        _fundSlice(dave, 1000e18);
        vm.prank(dave);
        uint256 shares = fund.mint(1000e18, 0, carol, false);
        assertEq(fund.balanceOf(carol), shares);
        assertEq(staking.mintLockOf(carol, false).shares, 0);
        assertEq(staking.boostOf(carol).left, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Premium cap
    // ──────────────────────────────────────────────────────────

    function _setCap(
        uint32 capBps
    ) internal {
        vm.prank(admin);
        fund.setMintConfig(15 days, 0, capBps);
    }

    function test_cap_noneByDefault() public view {
        assertEq(fund.maxPremiumBps(), 0);
        (,,,, bool locked) = fund.previewMint(1000e18, false);
        assertTrue(locked);
    }

    function test_cap_pricesAtCapUnlockedWithoutBoost() public {
        _setCap(1000); // 10%, under the pool's 30%
        uint256 nav = _mintNav();
        (uint256 quoted, uint256 mintPrice,,, bool locked) = fund.previewMint(10_000e18, false);
        assertEq(mintPrice, Math.mulDiv(nav, 11_000, 10_000, Math.Rounding.Ceil));
        assertFalse(locked);

        (uint256 nav0,) = _nav();
        uint256 shares = _mintAs(carol, 10_000e18);
        assertEq(shares, quoted);
        assertEq(fund.balanceOf(carol), shares);
        assertEq(staking.balanceOf(carol), 0);
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(_held(), 0);
        // The whole premium is backing.
        (uint256 nav1,) = _nav();
        assertGt(nav1, nav0);

        // Free to sell into the pool at once: the arbitrage that holds the price near the cap.
        vm.prank(carol);
        fund.transfer(dave, shares);
        uint256 usdgBefore = usdg.balanceOf(dave);
        _poolSwap(dave, false, -int256(shares));
        assertGt(usdg.balanceOf(dave) - usdgBefore, 0);
    }

    function test_cap_aboveMarketLeavesTheLockedMint() public {
        _setCap(5000); // 50%, over the pool's 30%
        (,,,, bool locked) = fund.previewMint(1000e18, false);
        assertTrue(locked);
        _mintAs(carol, 1000e18);
        assertGt(staking.boostOf(carol).left, 0);
        assertEq(fund.balanceOf(carol), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Mint at NAV
    // ──────────────────────────────────────────────────────────

    function _mintAtNav(address who, uint256 navShares) internal returns (uint256 shares) {
        uint256 usdgAmount;
        uint256[] memory amounts;
        (,, amounts, usdgAmount,) = fund.previewMint(navShares, true);
        address[] memory a = fund.assets();
        for (uint256 i; i < a.length; ++i) {
            _mintAsset(who, MockERC20(a[i]), amounts[i]);
        }
        _mintAsset(who, usdg, usdgAmount);
        vm.prank(who);
        shares = fund.mint(navShares, 0, who, true);
    }

    function test_navMint_atNavLockedForGoodNoBoost() public {
        uint256 nav = _mintNav();
        (uint256 quoted, uint256 mintPrice,,, bool locked) = fund.previewMint(10_000e18, true);
        assertEq(mintPrice, nav);
        assertTrue(locked);
        assertEq(quoted, 10_000e18 - 10_000e18 * 100 / 10_000);

        (uint256 nav0,) = _nav();
        _mintAtNav(carol, 10_000e18);
        IFundStaking.MintLock memory lock = staking.mintLockOf(carol, true);
        assertEq(lock.shares, staking.balanceOf(carol));
        assertEq(lock.unlockAt, type(uint64).max);
        assertEq(staking.mintLockOf(carol, false).shares, 0);
        assertEq(staking.boostOf(carol).left, 0);
        assertEq(_held(), 0);
        (uint256 nav1,) = _nav();
        assertGe(nav1 + 1, nav0); // never dilutive (the fee even adds a little)
    }

    function test_navMint_onlyEverExitsAtNav() public {
        _mintAtNav(carol, 10_000e18);
        uint256 bal = staking.balanceOf(carol);
        _warp(3650 days);
        vm.startPrank(carol);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.transfer(dave, 1);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.unstake(1, carol);
        staking.redeem(bal / 2, carol, new uint256[](0), 0);
        assertEq(staking.mintLockOf(carol, true).shares, bal - bal / 2);
        staking.redeem(staking.balanceOf(carol), carol, new uint256[](0), 0);
        vm.stopPrank();
        assertEq(staking.mintLockOf(carol, true).shares, 0);
        assertEq(fund.balanceOf(carol), 0);
    }

    function test_navMint_yieldStaysLocked() public {
        vm.prank(admin);
        factory.setMaxYieldRate(109_500);
        _warp(1 hours);
        staking.accrue(); // the first reading at the new cap
        _mintAtNav(carol, 10_000e18);
        uint256 shares = staking.balanceOf(carol);
        uint256 before = staking.convertToAssets(shares);
        _warp(365 days);
        staking.accrue();
        assertGt(staking.convertToAssets(shares), before); // the yield lands on the locked shares
        assertEq(staking.balanceOf(carol), shares);
        assertEq(staking.mintLockOf(carol, true).shares, shares);
        vm.prank(carol);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.unstake(1, carol);
    }

    function test_navMint_governorEscrowKeepsTheLock() public {
        _mintAtNav(carol, 10_000e18);
        uint256 shares = staking.balanceOf(carol);
        vm.startPrank(carol);
        staking.approve(address(governor), shares);
        governor.deposit(address(staking), shares);
        governor.requestWithdrawal(address(staking), shares);
        vm.stopPrank();
        _warp(governor.unlockAt(carol) - block.timestamp);
        vm.startPrank(carol);
        governor.withdraw(address(staking));
        assertEq(staking.balanceOf(carol), shares);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.transfer(dave, 1);
        vm.stopPrank();
    }

    function test_navMint_keepsItsOwnLockBesideDirectMints() public {
        _mintAtNav(carol, 10_000e18);
        uint256 navLocked = staking.mintLockOf(carol, true).shares;
        // A big direct mint with its short lock cannot pull the NAV lock's end in.
        _mintAs(carol, 50_000e18);
        assertEq(staking.mintLockOf(carol, true).unlockAt, type(uint64).max);
        assertEq(staking.mintLockOf(carol, false).unlockAt, block.timestamp + 15 days);

        _warp(15 days);
        staking.settleBoost(carol);
        uint256 free = staking.balanceOf(carol) - navLocked;
        vm.startPrank(carol);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.unstake(free + 1, carol);
        staking.unstake(free, carol);
        vm.stopPrank();
    }

    function test_navMint_laterMintsJoinTheLockForGood() public {
        _mintAtNav(carol, 1000e18);
        uint256 first = staking.balanceOf(carol);
        _warp(30 days);
        _mintAtNav(carol, 2000e18);
        IFundStaking.MintLock memory lock = staking.mintLockOf(carol, true);
        assertEq(lock.shares, staking.balanceOf(carol));
        assertGt(lock.shares, first);
        assertEq(lock.unlockAt, type(uint64).max);
    }

    function test_navMint_closedWithTheMintDoor() public {
        vm.prank(admin);
        fund.setMintPaused(true);
        vm.expectRevert(IFund.MintPaused.selector);
        fund.mint(1000e18, 0, carol, true);
    }

    // ──────────────────────────────────────────────────────────
    //  Fund pool position
    // ──────────────────────────────────────────────────────────

    function test_increasePosition_addsIdleUsdgWithoutMovingNav() public {
        usdg.mint(address(fund), 10_000e6);
        (uint256 nav0, uint256 s0) = _nav();
        uint128 liq0 = hook.positionLiquidity(address(fund));
        (uint256 posUsdg0,) = fund.positionAmounts();
        uint256 idle0 = fund.idleUsdg();
        uint256 supply0 = fund.totalSupply();

        vm.prank(admin);
        uint128 added = fund.increasePosition(5000e6);

        assertGt(added, 0);
        assertEq(hook.positionLiquidity(address(fund)), liq0 + added);
        assertApproxEqAbs(idle0 - fund.idleUsdg(), 5000e6, 1);
        (uint256 posUsdg1,) = fund.positionAmounts();
        assertApproxEqRel(posUsdg1 - posUsdg0, 5000e6, 1e15);
        assertGt(fund.totalSupply(), supply0); // tokens minted into the position
        (uint256 nav1, uint256 s1) = _nav();
        assertApproxEqRel(s1, s0, 1e15); // outside supply
        assertApproxEqRel(nav1, nav0, 1e15);
        assertEq(IERC20(address(fund)).balanceOf(address(hook)), 0);
        assertEq(usdg.balanceOf(address(hook)), 0);
    }

    function test_increasePosition_thenWithdraw() public {
        usdg.mint(address(fund), 10_000e6);
        vm.prank(admin);
        uint128 added = fund.increasePosition(5000e6);
        uint256 idle = fund.idleUsdg();
        vm.prank(admin);
        hook.withdrawPosition(address(fund), added);
        assertApproxEqRel(fund.idleUsdg() - idle, 5000e6, 1e15);
    }

    function test_increasePosition_adminOnly() public {
        usdg.mint(address(fund), 10_000e6);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.increasePosition(1000e6);
        vm.expectRevert(IFundHook.NotRegistered.selector);
        hook.increasePosition(1000e6);
    }

    function test_increasePosition_spotOffTwap_reverts() public {
        usdg.mint(address(fund), 10_000e6);
        _poolSwap(dave, true, -int256(5000e6)); // spot jumps, the TWAP has not moved
        vm.prank(admin);
        vm.expectRevert(IFundHook.PriceOffTwap.selector);
        fund.increasePosition(1000e6);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin settings and defaults
    // ──────────────────────────────────────────────────────────

    function test_defaultsMatchSpec() public view {
        PremiumConfig memory c = factory.premiumConfig();
        assertEq(c.mintLock, 15 days);
        assertEq(c.mintAdjustmentBps, 0);
        assertEq(c.maxPremiumBps, 0);
        assertEq(c.boostShareBps, 7500);
        assertEq(c.boostSpeedBpsPerYear, 7500);
        assertEq(c.potDripPeriod, 7 days);
        assertEq(c.issuanceStartBps, 100);
        assertEq(c.potShareBps, 7500);

        IssuanceStep[] memory s = factory.defaultIssuanceSteps();
        assertEq(s.length, 3);
        assertEq(s[0].premiumBps, 0);
        assertEq(s[0].densityBps, 100);
        assertEq(s[1].premiumBps, 10_000);
        assertEq(s[1].densityBps, 200);
        assertEq(s[2].premiumBps, 40_000);
        assertEq(s[2].densityBps, 300);

        YieldPoint[] memory y = factory.defaultYieldCurve();
        assertEq(y.length, 3);
        assertEq(y[0].premiumBps, 0);
        assertEq(y[0].rateBpsPerYear, 1200);
        assertEq(y[1].premiumBps, 2500);
        assertEq(y[1].rateBpsPerYear, 2400);
        assertEq(y[2].premiumBps, 10_000);
        assertEq(y[2].rateBpsPerYear, 4800);

        IssuanceConfig memory i = hook.issuanceOf(address(fund));
        assertEq(i.startBps, 100);
        assertEq(i.potShareBps, 7500);
        assertEq(i.steps.length, 3);
        assertEq(staking.boostShareBps(), 7500);
        assertEq(staking.boostSpeedBpsPerYear(), 7500);
        assertEq(staking.potDripPeriod(), 7 days);
    }

    function test_factoryDefaults_adminOnlyBoundedAndUsedByNewFunds() public {
        PremiumConfig memory c = PremiumConfig({
            mintLock: 30 days,
            mintAdjustmentBps: 200,
            maxPremiumBps: 5000,
            boostShareBps: 5000,
            boostSpeedBpsPerYear: 10_000,
            potDripPeriod: 3 days,
            issuanceStartBps: 500,
            potShareBps: 6000
        });
        IssuanceStep[] memory steps = _steps(20_000, 50, 400);
        YieldPoint[] memory curve = new YieldPoint[](2);
        curve[0] = YieldPoint({premiumBps: 0, rateBpsPerYear: 0});
        curve[1] = YieldPoint({premiumBps: 5000, rateBpsPerYear: 3600});

        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setPremiumConfig(c);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setDefaultIssuanceSteps(steps);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setDefaultYieldCurve(curve);

        vm.startPrank(admin);
        c.boostSpeedBpsPerYear = 0;
        vm.expectRevert(IFundFactory.InvalidPremiumConfig.selector);
        factory.setPremiumConfig(c);
        c.boostSpeedBpsPerYear = 10_000;
        c.potDripPeriod = 30 minutes;
        vm.expectRevert(IFundFactory.InvalidPremiumConfig.selector);
        factory.setPremiumConfig(c);
        c.potDripPeriod = 3 days;
        c.mintAdjustmentBps = -5001;
        vm.expectRevert(IFundFactory.InvalidPremiumConfig.selector);
        factory.setPremiumConfig(c);
        c.mintAdjustmentBps = 200;
        steps[1].densityBps = 5001;
        vm.expectRevert(IFundFactory.InvalidPremiumConfig.selector);
        factory.setDefaultIssuanceSteps(steps);
        steps[1].densityBps = 400;

        factory.setPremiumConfig(c);
        factory.setDefaultIssuanceSteps(steps);
        factory.setDefaultYieldCurve(curve);
        vm.stopPrank();

        vm.prank(admin);
        factory.setMaxYieldRate(4800);
        CreateFundParams memory p = _defaultParams();
        p.name = "Own Curated Fund 2";
        p.symbol = "OCF2";
        p.yieldCurve = new YieldPoint[](0);
        _createFund(p);

        assertEq(fund.mintLock(), 30 days);
        assertEq(fund.mintAdjustmentBps(), 200);
        assertEq(fund.maxPremiumBps(), 5000);
        assertEq(staking.boostShareBps(), 5000);
        assertEq(staking.boostSpeedBpsPerYear(), 10_000);
        assertEq(staking.potDripPeriod(), 3 days);
        IssuanceConfig memory i = hook.issuanceOf(address(fund));
        assertEq(i.startBps, 500);
        assertEq(i.potShareBps, 6000);
        assertEq(i.steps.length, 2);
        assertEq(i.steps[1].densityBps, 400);
        YieldPoint[] memory y = staking.yieldCurve();
        assertEq(y.length, 2);
        assertEq(y[1].rateBpsPerYear, 3600);
    }

    function test_setIssuance_adminOnlyAndBounded() public {
        IssuanceConfig memory c = IssuanceConfig({startBps: 300, potShareBps: 5000, steps: _steps(20_000, 50, 500)});
        vm.expectRevert(IFundHook.NotAdmin.selector);
        hook.setIssuance(address(fund), c);

        vm.startPrank(admin);
        vm.expectRevert(IFundHook.NotRegistered.selector);
        hook.setIssuance(dave, c);
        hook.setIssuance(address(fund), c);
        IssuanceConfig memory got = hook.issuanceOf(address(fund));
        assertEq(got.startBps, 300);
        assertEq(got.potShareBps, 5000);
        assertEq(got.steps.length, 2);
        assertEq(got.steps[1].premiumBps, 20_000);
        assertEq(got.steps[1].densityBps, 500);

        c.potShareBps = 10_001;
        vm.expectRevert(IFundHook.InvalidIssuance.selector);
        hook.setIssuance(address(fund), c);
        c.potShareBps = 7500;
        c.steps = _steps(0, 50, 500); // not ascending
        vm.expectRevert(IFundHook.InvalidIssuance.selector);
        hook.setIssuance(address(fund), c);
        c.steps = _steps(20_000, 50, 5001);
        vm.expectRevert(IFundHook.InvalidIssuance.selector);
        hook.setIssuance(address(fund), c);
        c.steps = new IssuanceStep[](9);
        for (uint256 j; j < 9; ++j) {
            c.steps[j] = IssuanceStep({premiumBps: uint32(j * 1000), densityBps: 100});
        }
        vm.expectRevert(IFundHook.InvalidIssuance.selector);
        hook.setIssuance(address(fund), c);
        vm.stopPrank();
    }
}
