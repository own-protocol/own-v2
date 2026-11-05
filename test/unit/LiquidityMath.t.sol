// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {Test} from "forge-std/Test.sol";

/// @dev External wrapper so reverts from the internal library can be asserted.
contract LiquidityMathHarness {
    function sqrtAt(
        int24 tick
    ) external pure returns (uint160) {
        return LiquidityMath.getSqrtPriceAtTick(tick);
    }
}

contract LiquidityMathTest is Test {
    LiquidityMathHarness internal harness = new LiquidityMathHarness();

    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    function test_getSqrtPriceAtTick_knownValues() public pure {
        assertEq(LiquidityMath.getSqrtPriceAtTick(0), 2 ** 96);
        assertEq(LiquidityMath.getSqrtPriceAtTick(LiquidityMath.MIN_TICK), MIN_SQRT_PRICE);
        assertEq(LiquidityMath.getSqrtPriceAtTick(LiquidityMath.MAX_TICK), MAX_SQRT_PRICE);
        // Uniswap v4 TickMath reference values.
        assertEq(LiquidityMath.getSqrtPriceAtTick(1), 79_232_123_823_359_799_118_286_999_568);
        assertEq(LiquidityMath.getSqrtPriceAtTick(-1), 79_224_201_403_219_477_170_569_942_574);
    }

    function test_getSqrtPriceAtTick_outOfRange_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(LiquidityMath.InvalidTick.selector, LiquidityMath.MAX_TICK + 1));
        harness.sqrtAt(LiquidityMath.MAX_TICK + 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidityMath.InvalidTick.selector, LiquidityMath.MIN_TICK - 1));
        harness.sqrtAt(LiquidityMath.MIN_TICK - 1);
    }

    function testFuzz_getSqrtPriceAtTick_monotonic(
        int24 tick
    ) public pure {
        tick = int24(bound(tick, LiquidityMath.MIN_TICK, LiquidityMath.MAX_TICK - 1));
        assertLt(LiquidityMath.getSqrtPriceAtTick(tick), LiquidityMath.getSqrtPriceAtTick(tick + 1));
    }

    function testFuzz_liquidityRoundTrip(uint128 liquidity, int24 lower, int24 width, int24 priceTick) public pure {
        liquidity = uint128(bound(liquidity, 1e6, 1e30));
        lower = int24(bound(lower, -400_000, 400_000));
        width = int24(bound(width, 1, 100_000));
        int24 upper = lower + width;
        priceTick = int24(bound(priceTick, lower - 1000, upper + 1000));
        uint256 sqrtA = LiquidityMath.getSqrtPriceAtTick(lower);
        uint256 sqrtB = LiquidityMath.getSqrtPriceAtTick(upper);
        uint256 sqrtP = LiquidityMath.getSqrtPriceAtTick(priceTick);

        (uint256 a0, uint256 a1) = LiquidityMath.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        uint128 back = LiquidityMath.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, a0, a1);
        // Rounding is always down: the amounts never fund more than the liquidity they came from.
        assertLe(back, liquidity);
    }

    function testFuzz_amountsGrowWithLiquidity(uint128 liquidity, int24 priceTick) public pure {
        liquidity = uint128(bound(liquidity, 1, 1e30));
        priceTick = int24(bound(priceTick, -1000, 1000));
        uint256 sqrtA = LiquidityMath.getSqrtPriceAtTick(-600);
        uint256 sqrtB = LiquidityMath.getSqrtPriceAtTick(600);
        uint256 sqrtP = LiquidityMath.getSqrtPriceAtTick(priceTick);
        (uint256 a0, uint256 a1) = LiquidityMath.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        (uint256 b0, uint256 b1) = LiquidityMath.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity * 2);
        assertGe(b0, a0);
        assertGe(b1, a1);
    }

    function test_getAmountsForLiquidity_sidesOutsideRange() public pure {
        uint256 sqrtA = LiquidityMath.getSqrtPriceAtTick(-600);
        uint256 sqrtB = LiquidityMath.getSqrtPriceAtTick(600);
        (uint256 a0, uint256 a1) =
            LiquidityMath.getAmountsForLiquidity(LiquidityMath.getSqrtPriceAtTick(-700), sqrtA, sqrtB, 1e18);
        assertGt(a0, 0);
        assertEq(a1, 0);
        (a0, a1) = LiquidityMath.getAmountsForLiquidity(LiquidityMath.getSqrtPriceAtTick(700), sqrtB, sqrtA, 1e18);
        assertEq(a0, 0);
        assertGt(a1, 0);
    }

    function testFuzz_oraclePriceRoundTrip(uint256 price, bool assetIsZero, bool sixDecimals) public pure {
        price = bound(price, 1e15, 1e24);
        uint256 scale = sixDecimals ? 1e6 : 1e18;
        uint256 sqrtP = LiquidityMath.sqrtPriceFromOracle(price, scale, assetIsZero);
        uint256 back = LiquidityMath.priceFromSqrtPrice(sqrtP, scale, assetIsZero);
        assertApproxEqRel(back, price, 1e9);
    }

    function test_sqrtPriceFromOracle_orientation() public pure {
        // 700 eUSD per 18-decimal asset: price 700 when the asset is currency0, 1/700 otherwise.
        uint256 sqrt0 = LiquidityMath.sqrtPriceFromOracle(700e18, 1e18, true);
        uint256 sqrt1 = LiquidityMath.sqrtPriceFromOracle(700e18, 1e18, false);
        assertApproxEqRel(sqrt0 * sqrt1, uint256(2 ** 192), 1e9);
        // $1 for a 6-decimal currency1 asset: 1e6 raw asset per 1e18 raw eUSD, sqrt 1e-6.
        uint256 sqrtUsd = LiquidityMath.sqrtPriceFromOracle(1e18, 1e6, false);
        assertApproxEqRel(sqrtUsd, uint256(2 ** 96) / 1e6, 1e9);
    }
}
