// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../src/funds/Fund.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundHook} from "../../src/interfaces/IFundHook.sol";
import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {FundMetadata, LockOption, PlatformMetadata} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Stands in as the fund's governor and tries to change the basket when it is paid mid-swap.
contract BasketSwapper is ERC20 {
    Fund internal immutable fund;
    address internal immutable replacement;

    constructor(Fund fund_, address replacement_) ERC20("Hop", "HOP") {
        fund = fund_;
        replacement = replacement_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == address(fund)) {
            address[] memory a = fund.assets();
            a[2] = replacement;
            uint16[] memory w = new uint16[](3);
            w[0] = 4000;
            w[1] = 3000;
            w[2] = 3000;
            fund.setTargetWeights(a, w);
            // Refill the reused slot so the old per-slot balance check would pass.
            IERC20(replacement).transfer(address(fund), IERC20(replacement).balanceOf(address(this)));
        }
    }
}

contract FundTest is FundTestBase {
    MockSwapRouter internal router;
    uint256 internal aliceShares;
    uint256 internal bobShares;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        aliceShares = launch.claimable(alice);
        bobShares = launch.claimable(bob);
        vm.prank(alice);
        launch.claim(false);
        vm.prank(bob);
        launch.claim(false);

        router = new MockSwapRouter();
        vm.prank(admin);
        factory.setRouter(address(router), true);
    }

    // ──────────────────────────────────────────────────────────
    //  NAV, the pool position and premium
    // ──────────────────────────────────────────────────────────

    function test_nav_countsPoolUsdgAndExcludesPoolTokens() public view {
        (uint256 positionUsdg, uint256 positionTokens) = fund.positionAmounts();
        assertApproxEqRel(positionUsdg, 30_000e6, 1e15);
        assertApproxEqRel(positionTokens, 130_000e18 - launch.depositorSupply(), 1e15);
        assertApproxEqRel(fund.effectiveSupply(), launch.depositorSupply(), 1e15);
        assertApproxEqRel(fund.totalValue(), 130_000e18, 1e15);
        // Depositors get exactly what they brought, at NAV.
        assertApproxEqRel(fund.navPerShare(), uint256(130_000e18) * 1e18 / launch.depositorSupply(), 1e15);
        assertApproxEqAbs(fund.totalSupply(), 130_000e18, 1e6); // seeding dust is burned
    }

    function test_depositors_getWhatTheyBroughtAtNav() public view {
        uint256 nav = fund.navPerShare();
        // alice brought $60k of basket and $18k of USDG, and gains the $200 of credit bob's
        // overweight TSLA lost.
        assertApproxEqRel(aliceShares * nav / 1e18, uint256(78_000e18) * 100_000 / 99_800, 1e15);
        // bob brought $40k and $12k, less 5% of TSLA's $4k over target ($200 of basket credit).
        assertLt(bobShares * nav / 1e18, 52_000e18);
        assertGt(bobShares * nav / 1e18, 51_600e18);
    }

    function test_premium_thirtyPercentAtLaunch() public view {
        (bool ok, int256 premium) = fund.premiumBps();
        assertTrue(ok);
        assertApproxEqAbs(premium, 3000, 2);
    }

    function test_premium_staleMarketPrice_notOk() public {
        vm.warp(block.timestamp + STALENESS + 1);
        (bool ok,) = fund.premiumBps();
        assertFalse(ok);
    }

    function test_nav_premiumBuysRaiseIt() public {
        vm.warp(block.timestamp + 1 hours);
        _refreshFeeds();
        uint256 navBefore = fund.navPerShare();
        _poolSwap(makeAddr("buyer"), true, -int256(5000e6));
        vm.warp(block.timestamp + 1 hours);
        _refreshFeeds();
        assertGt(fund.navPerShare(), navBefore);
    }

    // ──────────────────────────────────────────────────────────
    //  mint
    // ──────────────────────────────────────────────────────────

    function test_mint_noLock_atMarketPrice() public {
        _mintAsset(alice, pons, 50_000e18); // $1,000
        uint256 navBefore = fund.navPerShare();
        uint256 market = uint256(feeds[address(fund)].answer()) * 1e10;

        vm.prank(alice);
        uint256 shares = fund.mint(address(pons), 50_000e18, 0, 0, alice);

        // $1,000 at the market price; 0.5% protocol and 1% curator fees.
        uint256 gross = uint256(1000e18) * 1e18 / market;
        assertEq(shares, gross - gross * 50 / 10_000 - gross * 100 / 10_000);
        assertEq(fund.balanceOf(alice), aliceShares + shares);
        assertEq(fund.balanceOf(protocolTreasury), gross * 50 / 10_000);
        assertEq(fund.balanceOf(address(curators)), gross * 100 / 10_000);
        assertGt(fund.navPerShare(), navBefore); // minting above NAV adds backing for everyone
    }

    function test_mint_withLock_discountedAndLocked() public {
        _mintAsset(alice, pons, 50_000e18);
        uint256 market = uint256(feeds[address(fund)].answer()) * 1e10;
        vm.prank(alice);
        uint256 shares = fund.mint(address(pons), 50_000e18, 1, 0, alice); // 7 days, 5% off

        uint256 gross = uint256(1000e18) * 1e18 / (market * 95 / 100);
        assertApproxEqAbs(shares, gross - gross * 50 / 10_000 - gross * 100 / 10_000, 1e6);
        assertEq(fund.balanceOf(alice), aliceShares);

        IFund.Lock[] memory locks = fund.locksOf(alice);
        assertEq(locks.length, 1);
        assertEq(locks[0].amount, shares);
        assertEq(locks[0].unlockAt, block.timestamp + 7 days);

        uint256[] memory ids = new uint256[](1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFund.LockNotClaimable.selector, 0));
        fund.claimLocks(ids);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(fund.claimLocks(ids), shares);
        assertEq(fund.balanceOf(alice), aliceShares + shares);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFund.LockNotClaimable.selector, 0));
        fund.claimLocks(ids);
    }

    function test_mint_marketBelowNav_pricedAtNav() public {
        _setFeed(address(fund), 0.5e8);
        uint256 nav = fund.navPerShare();
        _mintAsset(alice, pons, 50_000e18);
        (, uint256 mintPrice) = fund.previewMint(address(pons), 50_000e18, 0);
        assertApproxEqAbs(mintPrice, nav, 1);

        vm.prank(alice);
        fund.mint(address(pons), 50_000e18, 0, 0, alice);
        assertGe(fund.navPerShare(), nav); // never dilutive
    }

    function test_mint_matchesPreview() public {
        _mintAsset(alice, tsla, 3e18);
        (uint256 quoted,) = fund.previewMint(address(tsla), 3e18, 2);
        vm.prank(alice);
        assertEq(fund.mint(address(tsla), 3e18, 2, quoted, alice), quoted);
    }

    function test_mint_notLaunched_reverts() public {
        _createFund();
        _mintAsset(alice, pons, 1e18);
        vm.prank(alice);
        vm.expectRevert(IFund.NotLaunched.selector);
        fund.mint(address(pons), 1e18, 0, 0, alice);
    }

    function test_mint_paused_reverts() public {
        vm.prank(admin);
        fund.setMintPaused(true);
        vm.prank(alice);
        vm.expectRevert(IFund.MintPaused.selector);
        fund.mint(address(pons), 1e18, 0, 0, alice);
    }

    function test_mint_assetNotInBasket_reverts() public {
        _mintAsset(alice, spare, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFund.AssetNotMintable.selector, address(spare)));
        fund.mint(address(spare), 1e18, 0, 0, alice);
    }

    function test_mint_staleMarketPrice_reverts() public {
        vm.warp(block.timestamp + STALENESS + 1);
        _setFeed(address(pons), 0.02e8);
        _setFeed(address(net), 300e8);
        _setFeed(address(tsla), 400e8);
        _mintAsset(alice, pons, 1e18);
        vm.prank(alice);
        vm.expectRevert(IFund.NoMarketPrice.selector);
        fund.mint(address(pons), 1e18, 0, 0, alice);
    }

    function test_mint_slippage_reverts() public {
        _mintAsset(alice, pons, 50_000e18);
        (uint256 quoted,) = fund.previewMint(address(pons), 50_000e18, 0);
        vm.prank(alice);
        vm.expectRevert(IFund.Slippage.selector);
        fund.mint(address(pons), 50_000e18, 0, quoted + 1, alice);
    }

    function test_mint_invalidLockOption_reverts() public {
        _mintAsset(alice, pons, 1e18);
        vm.prank(alice);
        vm.expectRevert(IFund.InvalidLockOption.selector);
        fund.mint(address(pons), 1e18, 3, 0, alice);
    }

    function test_mint_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFund.ZeroAmount.selector);
        fund.mint(address(pons), 0, 0, 0, alice);
    }

    function test_mint_zeroReceiver_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IFund.ZeroAddress.selector);
        fund.mint(address(pons), 1e18, 0, 0, address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  redeem
    // ──────────────────────────────────────────────────────────

    function test_redeem_basketAndPoolSliceProRata() public {
        uint256 supply = fund.effectiveSupply();
        uint256 totalBefore = fund.totalSupply();
        uint256 navBefore = fund.navPerShare();
        uint256 netBal = net.balanceOf(address(fund));
        uint256 ponsBal = pons.balanceOf(address(fund));
        uint256 tslaBal = tsla.balanceOf(address(fund));
        uint128 liquidity = hook.positionLiquidity(address(fund));
        (uint256 positionUsdg, uint256 positionTokens) = fund.positionAmounts();

        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        (uint256[] memory out, uint256 usdgOut) = fund.redeem(10_000e18, alice, new uint256[](0), 0);

        uint256 net_ = 10_000e18 - 50e18 - 100e18;
        assertEq(out[0], netBal * net_ / supply);
        assertEq(out[1], ponsBal * net_ / supply);
        assertEq(out[2], tslaBal * net_ / supply);
        assertEq(net.balanceOf(alice), out[0]);
        assertEq(pons.balanceOf(alice), out[1]);
        assertEq(tsla.balanceOf(alice), out[2]);
        assertEq(usdg.balanceOf(alice) - usdgBefore, usdgOut);
        assertApproxEqRel(usdgOut, positionUsdg * net_ / supply, 1e15);
        assertEq(fund.balanceOf(protocolTreasury), 50e18);
        assertEq(fund.balanceOf(address(curators)), 100e18);
        assertApproxEqAbs(hook.positionLiquidity(address(fund)), liquidity - uint256(liquidity) * net_ / supply, 1);
        // The redeemer's net shares and the slice's pool tokens are both burned.
        assertApproxEqRel(totalBefore - fund.totalSupply(), net_ + positionTokens * net_ / supply, 1e15);
        assertGe(fund.navPerShare() * 10_001 / 10_000, navBefore);
    }

    function test_redeem_pumpedSpotCannotInflateUsdg() public {
        vm.warp(block.timestamp + 1 hours);
        _refreshFeeds();
        (, uint256 quoted) = fund.previewRedeem(10_000e18);
        uint256 idleBefore = fund.idleUsdg();

        // Pump the spot price in the same block, then redeem.
        _poolSwap(attacker, true, -int256(50_000e6));
        vm.prank(alice);
        (, uint256 usdgOut) = fund.redeem(10_000e18, alice, new uint256[](0), 0);

        assertLe(usdgOut, quoted + 1);
        assertGt(fund.idleUsdg(), idleBefore); // the excess stays with the fund
    }

    function test_redeem_worksWithStaleOracleAndMintPaused() public {
        vm.prank(admin);
        fund.setMintPaused(true);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        (uint256[] memory out, uint256 usdgOut) = fund.redeem(1000e18, alice, new uint256[](0), 0);
        assertGt(out[0], 0);
        assertGt(usdgOut, 0);
    }

    function test_redeem_matchesPreview() public {
        vm.warp(block.timestamp + 1 hours);
        _refreshFeeds();
        (uint256[] memory quoted, uint256 quotedUsdg) = fund.previewRedeem(5000e18);
        vm.prank(bob);
        (uint256[] memory out, uint256 usdgOut) = fund.redeem(5000e18, bob, quoted, quotedUsdg * 999 / 1000);
        for (uint256 i; i < out.length; ++i) {
            assertEq(out[i], quoted[i]);
        }
        assertApproxEqRel(usdgOut, quotedUsdg, 1e14);
    }

    function test_redeem_belowMinimum_reverts() public {
        (uint256[] memory mins,) = fund.previewRedeem(5000e18);
        mins[1] += 1;
        vm.prank(bob);
        vm.expectRevert(IFund.Slippage.selector);
        fund.redeem(5000e18, bob, mins, 0);
    }

    function test_redeem_belowMinUsdg_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFund.Slippage.selector);
        fund.redeem(5000e18, bob, new uint256[](0), 1e30);
    }

    function test_redeem_lengthMismatch_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFund.LengthMismatch.selector);
        fund.redeem(5000e18, bob, new uint256[](2), 0);
    }

    function test_redeem_zero_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFund.ZeroAmount.selector);
        fund.redeem(0, bob, new uint256[](0), 0);
    }

    function test_redeem_includesIdleUsdg() public {
        uint128 half = hook.positionLiquidity(address(fund)) / 2;
        vm.prank(admin);
        hook.withdrawPosition(address(fund), half);
        uint256 idle = fund.idleUsdg();
        uint256 supply = fund.effectiveSupply();
        (uint256 positionUsdg,) = fund.positionAmounts();

        vm.prank(alice);
        (, uint256 usdgOut) = fund.redeem(10_000e18, alice, new uint256[](0), 0);
        uint256 net_ = 10_000e18 * 9850 / 10_000;
        assertApproxEqRel(usdgOut, (idle + positionUsdg) * net_ / supply, 1e15);
    }

    function test_burn_raisesNav() public {
        uint256 navBefore = fund.navPerShare();
        vm.prank(alice);
        fund.burn(10_000e18);
        assertGt(fund.navPerShare(), navBefore);
    }

    // ──────────────────────────────────────────────────────────
    //  Pool position: admin withdrawal and LP fees
    // ──────────────────────────────────────────────────────────

    function test_withdrawPosition_returnsToFundAndKeepsNav() public {
        uint256 navBefore = fund.navPerShare();
        uint128 liquidity = hook.positionLiquidity(address(fund));
        vm.prank(admin);
        hook.withdrawPosition(address(fund), liquidity);

        assertEq(hook.positionLiquidity(address(fund)), 0);
        assertApproxEqRel(fund.idleUsdg(), 30_000e6, 1e15);
        assertApproxEqRel(fund.totalSupply(), launch.depositorSupply(), 1e15);
        assertApproxEqRel(fund.navPerShare(), navBefore, 1e15);
        assertEq(usdg.balanceOf(admin), 0);
    }

    function test_withdrawPosition_notAdmin_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(IFundHook.NotAdmin.selector);
        hook.withdrawPosition(address(fund), 1);
    }

    function test_withdrawPosition_tooMuch_reverts() public {
        uint128 liquidity = hook.positionLiquidity(address(fund));
        vm.prank(admin);
        vm.expectRevert(IFundHook.InsufficientLiquidity.selector);
        hook.withdrawPosition(address(fund), liquidity + 1);
    }

    function test_redeemPosition_onlyFunds() public {
        vm.prank(attacker);
        vm.expectRevert(IFundHook.NotFund.selector);
        hook.redeemPosition(1, 1, attacker);
    }

    function test_lpFees_goToFund() public {
        vm.prank(admin);
        hook.setLpFee(address(fund), 3000); // 0.3%
        _poolSwap(makeAddr("buyer"), true, -int256(10_000e6));
        _poolSwap(makeAddr("buyer"), false, -int256(1000e18));
        uint256 supplyBefore = fund.totalSupply();

        (uint256 usdgAmount, uint256 burned) = hook.collectLpFees(address(fund));
        assertGt(usdgAmount, 0);
        assertGt(burned, 0);
        assertEq(fund.idleUsdg(), usdgAmount);
        assertEq(fund.totalSupply(), supplyBefore - burned);
    }

    // ──────────────────────────────────────────────────────────
    //  rebalance
    // ──────────────────────────────────────────────────────────

    function test_rebalance_swapsWithinOracleBound() public {
        tsla.mint(address(router), 100e18);
        uint256 netBefore = net.balanceOf(address(fund));
        uint256 tslaBefore = tsla.balanceOf(address(fund));

        // Sell 10 NET ($3,000) for 7.4 TSLA ($2,960): 1.33% below oracle value, inside the 2% bound.
        vm.prank(keeper);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));

        assertEq(net.balanceOf(address(fund)), netBefore - 10e9);
        assertEq(tsla.balanceOf(address(fund)), tslaBefore + 7.4e18);
        assertEq(net.allowance(address(fund), address(router)), 0);
    }

    function test_rebalance_dailyVolumeCapped() public {
        tsla.mint(address(router), 100e18);
        // 3 x $3,000 = $9,000 fits under 10% of the ~$100k basket; a fourth does not.
        vm.startPrank(keeper);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.expectRevert(IFund.RebalanceVolumeExceeded.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        vm.prank(keeper);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
    }

    function test_rebalance_allowanceRefillsLinearly() public {
        tsla.mint(address(router), 100e18);
        vm.startPrank(keeper);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.stopPrank();

        // Half a day drains ~$5k of the ~$9k used: one more $3k sale fits, a second does not.
        vm.warp(block.timestamp + 12 hours);
        _refreshFeeds();
        vm.startPrank(keeper);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.expectRevert(IFund.RebalanceVolumeExceeded.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
        vm.stopPrank();
    }

    function test_rebalance_basketChangeMidSwap_reverts() public {
        BasketSwapper hop = new BasketSwapper(fund, address(spare));
        vm.prank(admin);
        fund.setGovernor(address(hop));
        hop.mint(address(router), 1);
        spare.mint(address(hop), tsla.balanceOf(address(fund))); // 85 SPARE ($85) for $34k of TSLA

        // Sells all TSLA; the payout swaps TSLA's slot for SPARE so the balance checks would skip it.
        uint256 tslaHeld = tsla.balanceOf(address(fund));
        IFund.RebalanceParams memory p = IFund.RebalanceParams({
            sellAsset: address(tsla),
            sellAmount: tslaHeld,
            buyAsset: address(pons),
            minBuyAmount: 0,
            router: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (address(tsla), tslaHeld, address(hop), 1))
        });
        vm.prank(keeper);
        vm.expectRevert(IFund.RebalanceCallFailed.selector);
        fund.rebalance(p);
    }

    function test_rebalance_tooMuchValueLost_reverts() public {
        tsla.mint(address(router), 100e18);
        // 7 TSLA = $2,800, 6.7% below the $3,000 sold.
        vm.prank(keeper);
        vm.expectRevert(IFund.RebalanceInvalid.selector);
        fund.rebalance(_swap(10e9, 7e18, 7e18));
    }

    function test_rebalance_belowMinBuy_reverts() public {
        tsla.mint(address(router), 100e18);
        vm.prank(keeper);
        vm.expectRevert(IFund.RebalanceInvalid.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.5e18));
    }

    function test_rebalance_routerNotAllowed_reverts() public {
        vm.prank(admin);
        factory.setRouter(address(router), false);
        vm.prank(keeper);
        vm.expectRevert(IFund.RouterNotAllowed.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
    }

    function test_rebalance_notManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotManager.selector);
        fund.rebalance(_swap(10e9, 7.4e18, 7.4e18));
    }

    function test_rebalance_routerCallFails_reverts() public {
        IFund.RebalanceParams memory p = _swap(10e9, 7.4e18, 7.4e18);
        p.data = abi.encodeCall(MockSwapRouter.alwaysReverts, ());
        vm.prank(keeper);
        vm.expectRevert(IFund.RebalanceCallFailed.selector);
        fund.rebalance(p);
    }

    function _swap(
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 minBuy
    ) internal view returns (IFund.RebalanceParams memory) {
        return IFund.RebalanceParams({
            sellAsset: address(net),
            sellAmount: sellAmount,
            buyAsset: address(tsla),
            minBuyAmount: minBuy,
            router: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (address(net), sellAmount, address(tsla), buyAmount))
        });
    }

    function test_rebalance_spendsIdleUsdg() public {
        uint128 tenth = hook.positionLiquidity(address(fund)) / 10;
        vm.prank(admin);
        hook.withdrawPosition(address(fund), tenth);
        uint256 idle = fund.idleUsdg();
        tsla.mint(address(router), 100e18);
        uint256 tslaBefore = tsla.balanceOf(address(fund));

        // $2,000 of USDG for 4.95 TSLA ($1,980): 1% under, inside the 2% bound.
        IFund.RebalanceParams memory p = IFund.RebalanceParams({
            sellAsset: address(usdg),
            sellAmount: 2000e6,
            buyAsset: address(tsla),
            minBuyAmount: 4.95e18,
            router: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (address(usdg), 2000e6, address(tsla), 4.95e18))
        });
        vm.prank(keeper);
        fund.rebalance(p);
        assertEq(fund.idleUsdg(), idle - 2000e6);
        assertEq(tsla.balanceOf(address(fund)), tslaBefore + 4.95e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Depositor lock
    // ──────────────────────────────────────────────────────────

    function test_lock_launchTokensCannotMove() public {
        assertEq(fund.launchLocked(alice), aliceShares);
        vm.prank(alice);
        vm.expectRevert(IFund.LaunchTokensLocked.selector);
        fund.transfer(bob, 1);
    }

    function test_lock_boughtTokensCanMove() public {
        address buyer = makeAddr("buyer");
        _poolSwap(buyer, true, -int256(1000e6));
        uint256 bought = fund.balanceOf(buyer);
        // alice buys on top of her locked tokens; only the extra moves.
        vm.prank(buyer);
        fund.transfer(alice, bought);
        vm.startPrank(alice);
        fund.transfer(bob, bought);
        vm.expectRevert(IFund.LaunchTokensLocked.selector);
        fund.transfer(bob, 1);
        vm.stopPrank();
    }

    function test_lock_endsAfterSevenDays() public {
        assertEq(fund.depositorUnlockAt(), launch.endTime() + 7 days);
        _passDepositorLock();
        vm.prank(alice);
        fund.transfer(bob, aliceShares);
        assertEq(fund.balanceOf(bob), bobShares + aliceShares);
    }

    function test_lock_redeemAllowedAndShrinksLock() public {
        vm.prank(alice);
        fund.redeem(10_000e18, alice, new uint256[](0), 0);
        assertEq(fund.launchLocked(alice), aliceShares - 10_000e18);
    }

    function test_lock_stakeMovesLockToShares() public {
        vm.startPrank(alice);
        fund.approve(address(staking), 10_000e18);
        uint256 shares = staking.stake(10_000e18, alice);
        vm.expectRevert(IFundStaking.SharesLocked.selector);
        staking.transfer(bob, 1);
        vm.stopPrank();
        assertEq(staking.lockedShares(alice), shares);
        assertEq(fund.launchLocked(alice), aliceShares - 10_000e18);

        // Unstaking hands the lock back to the fund tokens.
        vm.prank(alice);
        uint256 assets = staking.unstake(shares, alice);
        assertEq(staking.lockedShares(alice), 0);
        assertEq(fund.launchLocked(alice), aliceShares - 10_000e18 + assets);
        vm.prank(alice);
        vm.expectRevert(IFund.LaunchTokensLocked.selector);
        fund.transfer(bob, 1);
    }

    function test_lock_stakedSharesCanEnterGovernor() public {
        vm.startPrank(alice);
        fund.approve(address(staking), 10_000e18);
        uint256 shares = staking.stake(10_000e18, alice);
        staking.approve(address(governor), shares);
        governor.deposit(address(staking), shares);
        vm.stopPrank();
        assertEq(governor.escrowOf(alice, address(staking)), shares);
    }

    function test_lock_onlyModulesCanLock() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotModule.selector);
        fund.addLaunchLock(bob, 1);
        vm.prank(attacker);
        vm.expectRevert(IFund.NotStaking.selector);
        fund.releaseLaunchLock(alice, 1);
    }

    // ──────────────────────────────────────────────────────────
    //  basket and admin settings
    // ──────────────────────────────────────────────────────────

    function test_setTargetWeights_addsAsset() public {
        address[] memory a = new address[](4);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        a[3] = address(spare);
        uint16[] memory w = new uint16[](4);
        w[0] = 4000;
        w[1] = 2000;
        w[2] = 3000;
        w[3] = 1000;
        vm.prank(address(governor));
        fund.setTargetWeights(a, w);
        assertTrue(fund.isAsset(address(spare)));
        assertEq(fund.targetWeightBps(address(pons)), 2000);
        assertEq(fund.assets().length, 4);
    }

    function test_setTargetWeights_dropHeldAsset_reverts() public {
        address[] memory a = new address[](2);
        a[0] = address(net);
        a[1] = address(tsla);
        uint16[] memory w = new uint16[](2);
        w[0] = 5000;
        w[1] = 5000;
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(IFund.AssetHasBalance.selector, address(pons)));
        fund.setTargetWeights(a, w);
    }

    function test_setTargetWeights_dustDoesNotBlockDrop() public {
        (address[] memory withSpare, uint16[] memory w4) = _basketWithSpare();
        vm.prank(address(governor));
        fund.setTargetWeights(withSpare, w4);

        spare.mint(address(fund), 1); // a griefer's 1 wei
        address[] memory a = new address[](3);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 3000;
        vm.prank(address(governor));
        fund.setTargetWeights(a, w);
        assertFalse(fund.isAsset(address(spare)));
    }

    function test_setTargetWeights_moreThanDust_reverts() public {
        (address[] memory withSpare, uint16[] memory w4) = _basketWithSpare();
        vm.prank(address(governor));
        fund.setTargetWeights(withSpare, w4);

        spare.mint(address(fund), 101e18); // $101, over 0.1% of the ~$100k basket
        address[] memory a = new address[](3);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 3000;
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(IFund.AssetHasBalance.selector, address(spare)));
        fund.setTargetWeights(a, w);
    }

    function _basketWithSpare() internal view returns (address[] memory a, uint16[] memory w) {
        a = new address[](4);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        a[3] = address(spare);
        w = new uint16[](4);
        w[0] = 4000;
        w[1] = 2000;
        w[2] = 3000;
        w[3] = 1000;
    }

    function test_setTargetWeights_badSum_reverts() public {
        address[] memory a = fund.assets();
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 2000;
        vm.prank(address(governor));
        vm.expectRevert(IFund.InvalidBasket.selector);
        fund.setTargetWeights(a, w);
    }

    function test_setTargetWeights_notGovernor_reverts() public {
        address[] memory a = fund.assets();
        uint16[] memory w = new uint16[](3);
        vm.prank(keeper);
        vm.expectRevert(IFund.NotGovernor.selector);
        fund.setTargetWeights(a, w);
    }

    function test_setTargetWeights_usdgNotAllowed() public {
        address[] memory a = new address[](4);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        a[3] = address(usdg);
        uint16[] memory w = new uint16[](4);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 3000;
        vm.prank(address(governor));
        vm.expectRevert(IFund.InvalidBasket.selector);
        fund.setTargetWeights(a, w);
    }

    function test_isDust() public {
        assertTrue(fund.isDust(address(spare)));
        assertFalse(fund.isDust(address(pons)));
        spare.mint(address(fund), 50e18); // $50, under 0.1% of the ~$100k basket
        assertTrue(fund.isDust(address(spare)));
        spare.mint(address(fund), 51e18);
        assertFalse(fund.isDust(address(spare)));
    }

    function test_setCuratorFee_adminOnlyAndCapped() public {
        vm.prank(curatorA);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.setCuratorFee(1000);
        vm.startPrank(admin);
        fund.setCuratorFee(1000);
        assertEq(fund.curatorFeeBps(), 1000);
        vm.expectRevert(IFund.FeeTooHigh.selector);
        fund.setCuratorFee(1001);
        vm.stopPrank();
    }

    function test_setLockOptions_invalid_reverts() public {
        LockOption[] memory opts = new LockOption[](1);
        opts[0] = LockOption({duration: 1 days, discountBps: 5001});
        vm.prank(admin);
        vm.expectRevert(IFund.InvalidLockOptions.selector);
        fund.setLockOptions(opts);
    }

    function test_setManager_adminOnly() public {
        vm.prank(keeper);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.setManager(attacker);
        vm.prank(admin);
        fund.setManager(bob);
        assertEq(fund.manager(), bob);
    }

    function test_moduleMint_notModule_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotModule.selector);
        fund.moduleMint(attacker, 1e18);
    }

    function test_markLaunched_notLaunch_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotLaunch.selector);
        fund.markLaunched(0);
    }

    function test_setModules_twice_reverts() public {
        vm.prank(address(factory));
        vm.expectRevert(IFund.ModulesAlreadySet.selector);
        fund.setModules(alice, bob, bob, bob);
    }

    function test_implementation_cannotBeInitialized() public {
        Fund impl = new Fund();
        vm.expectRevert();
        impl.initialize(_defaultParams());
    }

    function test_metadata() public view {
        assertEq(fund.name(), "Own Curated Fund 1");
        assertEq(fund.symbol(), "OCF1");
        assertEq(fund.decimals(), 18);
        assertEq(staking.symbol(), "sOCF1");
        assertEq(fund.curators(), address(curators));
        assertEq(fund.manager(), keeper);
    }

    function test_metadata_fundFieldsPlusPlatform() public {
        vm.prank(admin);
        factory.setPlatformMetadata(
            PlatformMetadata({
                name: "Own Curated Funds",
                description: "Basket-backed funds on Own.",
                url: "https://own.money"
            })
        );
        FundMetadata memory m = fund.metadata();
        assertEq(m.name, "Own Curated Fund 1");
        assertEq(m.symbol, "OCF1");
        assertEq(m.logoURI, "ipfs://ocf1-logo");
        assertEq(m.description, "Robinhood Chain ecosystem tokens and stocks.");
        assertEq(m.platform.name, "Own Curated Funds");
        assertEq(m.platform.url, "https://own.money");
    }

    function test_setMetadata_adminOnly() public {
        vm.prank(admin);
        fund.setMetadata("Robin Fund", "ROBIN", "ipfs://robin", "New description");
        assertEq(fund.name(), "Robin Fund");
        assertEq(fund.symbol(), "ROBIN");
        assertEq(fund.logoURI(), "ipfs://robin");
        assertEq(fund.description(), "New description");

        vm.prank(keeper);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.setMetadata("X", "X", "", "");
        vm.prank(curatorA);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.setMetadata("X", "X", "", "");
    }

    function test_setMetadata_emptyName_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IFund.InvalidMetadata.selector);
        fund.setMetadata("", "OCF1", "", "");
    }

    function test_setMetadata_longSymbol_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IFund.InvalidMetadata.selector);
        fund.setMetadata("OCF1", "SEVENTEEN_CHARSXX", "", "");
    }

    function test_setGovernor_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IFund.ZeroAddress.selector);
        fund.setGovernor(address(0));
    }
}
