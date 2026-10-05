// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundHook} from "../../src/interfaces/IFundHook.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract FundHookTest is FundTestBase {
    PoolSwapTest internal swapRouter;
    PoolKey internal key;
    bool internal usdgIs0;
    address internal trader = makeAddr("trader");

    // 0.5% protocol + 1% curator
    uint256 internal constant FEE_BPS = 100;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        key = hook.poolKeyOf(address(fund));
        usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        swapRouter = new PoolSwapTest(poolManager);

        vm.prank(alice);
        launch.claim(false);
        _passDepositorLock();
        vm.prank(alice);
        fund.transfer(trader, 10_000e18);
        usdg.mint(trader, 100_000e6);
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), type(uint256).max);
        fund.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Swap fees, all four swap shapes
    // ──────────────────────────────────────────────────────────

    function test_buy_exactUsdgIn_feeOnInput() public {
        uint256 usdgBefore = usdg.balanceOf(trader);
        _swap(true, -int256(1000e6));

        assertEq(usdgBefore - usdg.balanceOf(trader), 1000e6); // pays exactly what was specified
        assertEq(usdg.balanceOf(address(curators)), 10e6);
        assertGt(fund.balanceOf(trader), 10_000e18);
    }

    function test_buy_exactSharesOut_feeAddedToInput() public {
        uint256 usdgBefore = usdg.balanceOf(trader);
        uint256 sharesBefore = fund.balanceOf(trader);
        BalanceDelta delta = _swap(true, int256(500e18));

        assertEq(fund.balanceOf(trader) - sharesBefore, 500e18);
        uint256 paid = usdgBefore - usdg.balanceOf(trader);
        uint256 poolIn = paid - usdg.balanceOf(address(curators));
        assertEq(usdg.balanceOf(address(curators)), poolIn * 100 / 10_000);
        assertEq(uint256(-int256(_usdgDelta(delta))), paid);
    }

    function test_sell_exactSharesIn_feeOnOutput() public {
        uint256 usdgBefore = usdg.balanceOf(trader);
        _swap(false, -int256(1000e18));

        uint256 received = usdg.balanceOf(trader) - usdgBefore;
        uint256 gross = received + usdg.balanceOf(address(curators));
        assertEq(usdg.balanceOf(address(curators)), gross * 100 / 10_000);
        assertEq(fund.balanceOf(trader), 9000e18);
    }

    function test_sell_exactUsdgOut_traderGetsExactAmount() public {
        uint256 usdgBefore = usdg.balanceOf(trader);
        _swap(false, int256(500e6));

        assertEq(usdg.balanceOf(trader) - usdgBefore, 500e6);
        assertEq(usdg.balanceOf(address(curators)), 500e6 * 100 / 10_000);
    }

    function test_fees_followAdminChanges() public {
        vm.prank(admin);
        fund.setFee(0);
        _swap(true, -int256(1000e6));
        assertEq(usdg.balanceOf(address(curators)), 0);

        vm.prank(admin);
        fund.setFee(250);
        _swap(true, -int256(1000e6));
        assertEq(usdg.balanceOf(address(curators)), 25e6);
    }

    function test_roundTrip_costsAboutTheFees() public {
        uint256 usdgBefore = usdg.balanceOf(trader);
        uint256 sharesBefore = fund.balanceOf(trader);
        _swap(true, -int256(1000e6));
        _swap(false, -int256(fund.balanceOf(trader) - sharesBefore));
        uint256 lost = usdgBefore - usdg.balanceOf(trader);
        // two 1% legs, plus a little price impact
        assertApproxEqRel(lost, 1000e6 * 2 * FEE_BPS / 10_000, 0.05e18);
    }

    // ──────────────────────────────────────────────────────────
    //  LP fee and locked liquidity
    // ──────────────────────────────────────────────────────────

    function test_lpFee_accruesToFundPositionAndGoesToFund() public {
        vm.prank(admin);
        hook.setLpFee(address(fund), 3000); // 0.3%

        _swap(true, -int256(10_000e6));
        (uint256 usdgFees,) = hook.collectLpFees(address(fund));
        // 0.3% of the USDG that reached the pool (the hook's 1% is taken first)
        assertApproxEqAbs(usdgFees, (10_000e6 - 100e6) * 3000 / 1e6, 2);
        assertEq(usdg.balanceOf(address(fund)), usdgFees);
        assertGt(hook.positionLiquidity(address(fund)), 0);
    }

    function test_setLpFee_notAdmin_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(IFundHook.NotAdmin.selector);
        hook.setLpFee(address(fund), 3000);
    }

    function test_setLpFee_aboveCap_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IFundHook.LpFeeTooHigh.selector);
        hook.setLpFee(address(fund), 100_001);
    }

    function test_setLpFee_beforeSeed_appliedAtSeed() public {
        _createFund();
        vm.prank(admin);
        hook.setLpFee(address(fund), 2500);
        _deposit(alice, address(net), 400e9);
        _deposit(alice, address(usdg), 30_000e6);
        vm.warp(launch.endTime());
        _refreshFeeds();
        launch.finalize();
        assertFalse(hook.isSeeded(address(fund)));
        vm.prank(keeper);
        launch.seedPool();
        assertTrue(hook.isSeeded(address(fund)));
    }

    function test_initialize_byAnyoneElse_reverts() public {
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        poolManager.initialize(other, TickMath.getSqrtPriceAtTick(0));
    }

    function test_seedPool_notLaunch_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFundHook.NotLaunch.selector);
        hook.seedPool(address(fund), 1, 1);
    }

    function test_seedPool_twice_reverts() public {
        vm.prank(address(launch));
        vm.expectRevert(IFundHook.AlreadySeeded.selector);
        hook.seedPool(address(fund), 1, 1);
    }

    function test_registerFund_notFactory_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFundHook.NotFactory.selector);
        hook.registerFund(attacker);
    }

    function test_hookCallbacks_onlyPoolManager() public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(attacker);
        vm.expectRevert(IFundHook.NotPoolManager.selector);
        hook.beforeSwap(attacker, key, params, "");
    }

    function test_poolKey_isDynamicFeeWithHook() public view {
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(address(key.hooks), address(hook));
        assertEq(key.tickSpacing, 60);
    }

    function test_thirdPartyLiquidity_isAllowedButSeparate() public {
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(poolManager);
        usdg.mint(bob, 10_000e6);
        vm.prank(bob);
        launch.claim(false);
        _passDepositorLock();
        vm.startPrank(bob);
        usdg.approve(address(lpRouter), type(uint256).max);
        fund.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e15,
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
        uint128 locked = hook.positionLiquidity(address(fund));
        _swap(true, -int256(1000e6));
        assertEq(hook.positionLiquidity(address(fund)), locked);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @param buy             True to swap USDG for fund tokens.
    /// @param amountSpecified Negative for exact input, positive for exact output (v4 convention).
    function _swap(bool buy, int256 amountSpecified) internal returns (BalanceDelta delta) {
        bool zeroForOne = buy == usdgIs0;
        vm.prank(trader);
        delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _usdgDelta(
        BalanceDelta delta
    ) internal view returns (int128) {
        return usdgIs0 ? delta.amount0() : delta.amount1();
    }
}
