// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LiquidityMath — concentrated-liquidity math for Uniswap v4-style pools
/// @notice Tick to sqrt-price conversion, token amounts for a liquidity at a price, liquidity for
///         token amounts, and conversions between oracle prices (18 decimals) and Q64.96 sqrt prices.
/// @dev `getSqrtPriceAtTick` is Uniswap v4-core `TickMath.getSqrtPriceAtTick` (MIT), vendored so
///      the repo takes no new dependency. The amount and liquidity formulas are the v4-periphery
///      `LiquidityAmounts` formulas on OpenZeppelin `Math.mulDiv`.
library LiquidityMath {
    /// @notice Lowest tick a Uniswap v4 pool supports.
    int24 internal constant MIN_TICK = -887_272;

    /// @notice Highest tick a Uniswap v4 pool supports.
    int24 internal constant MAX_TICK = 887_272;

    /// @dev 2^96, the Q64.96 fixed-point unit.
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @dev 2^192, the square of the Q64.96 unit.
    uint256 internal constant Q192 = Q96 * Q96;

    /// @notice Thrown when a tick is outside [MIN_TICK, MAX_TICK].
    /// @param tick The tick.
    error InvalidTick(int24 tick);

    /// @notice sqrt(1.0001^tick) as a Q64.96 number.
    /// @param tick The tick, within [MIN_TICK, MAX_TICK].
    /// @return sqrtPriceX96 The sqrt price (Q64.96).
    function getSqrtPriceAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                let mask := sar(255, tick)
                absTick := xor(mask, add(mask, tick))
            }
            if (absTick > uint256(int256(MAX_TICK))) revert InvalidTick(tick);

            uint256 price;
            assembly ("memory-safe") {
                price := xor(shl(128, 1), mul(xor(shl(128, 1), 0xfffcb933bd6fad37aa2d162d1a594001), and(absTick, 0x1)))
            }
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

            assembly ("memory-safe") {
                if sgt(tick, 0) { price := div(not(0), price) }
                // Q128.128 to Q64.96, rounding up; fits 160 bits for ticks within range.
                sqrtPriceX96 := shr(32, add(price, sub(shl(32, 1), 1)))
            }
        }
    }

    /// @notice Token amounts held by `liquidity` between two sqrt prices when the pool is at
    ///         `sqrtPriceX96`. Rounds down.
    /// @param sqrtPriceX96  Pool sqrt price (Q64.96).
    /// @param sqrtPriceAX96 One range bound (Q64.96).
    /// @param sqrtPriceBX96 The other range bound (Q64.96).
    /// @param liquidity     Liquidity.
    /// @return amount0 Currency0 amount (raw units).
    /// @return amount1 Currency1 amount (raw units).
    function getAmountsForLiquidity(
        uint256 sqrtPriceX96,
        uint256 sqrtPriceAX96,
        uint256 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = _amount0(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = _amount0(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = _amount1(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = _amount1(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }

    /// @notice Largest liquidity that `amount0` and `amount1` fund between two sqrt prices when the
    ///         pool is at `sqrtPriceX96`. Rounds down.
    /// @param sqrtPriceX96  Pool sqrt price (Q64.96).
    /// @param sqrtPriceAX96 One range bound (Q64.96).
    /// @param sqrtPriceBX96 The other range bound (Q64.96).
    /// @param amount0       Currency0 available (raw units).
    /// @param amount1       Currency1 available (raw units).
    /// @return liquidity The liquidity.
    function getLiquidityForAmounts(
        uint256 sqrtPriceX96,
        uint256 sqrtPriceAX96,
        uint256 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = _liquidity0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = _liquidity0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = _liquidity1(sqrtPriceAX96, sqrtPriceX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _liquidity1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    /// @notice Q64.96 sqrt pool price for an oracle price, given which side the priced asset is on.
    /// @dev Pool price is currency1 raw units per currency0 raw unit. The quote token (eUSD) has
    ///      18 decimals and is worth $1, so one raw asset unit is worth `price / 10^decimals` raw
    ///      eUSD units. Rounds down.
    /// @param price       Asset price in eUSD per whole asset (18 decimals).
    /// @param assetScale  10^assetDecimals.
    /// @param assetIsZero Whether the asset is currency0.
    /// @return The sqrt price (Q64.96).
    function sqrtPriceFromOracle(uint256 price, uint256 assetScale, bool assetIsZero) internal pure returns (uint256) {
        if (assetIsZero) return Math.sqrt(Math.mulDiv(price, Q192, assetScale));
        return Math.sqrt(Math.mulDiv(assetScale, Q192, price));
    }

    /// @notice Asset price in eUSD per whole asset (18 decimals) implied by a Q64.96 sqrt pool price.
    /// @dev Inverse of {sqrtPriceFromOracle}. Rounds down.
    /// @param sqrtPriceX96 Pool sqrt price (Q64.96).
    /// @param assetScale   10^assetDecimals.
    /// @param assetIsZero  Whether the asset is currency0.
    /// @return price Asset price (18 decimals).
    function priceFromSqrtPrice(
        uint256 sqrtPriceX96,
        uint256 assetScale,
        bool assetIsZero
    ) internal pure returns (uint256 price) {
        if (assetIsZero) {
            return Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96), assetScale, Q96);
        }
        return Math.mulDiv(Math.mulDiv(Q96, assetScale, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    /// @dev Currency0 held by `liquidity` between two ordered sqrt prices. Rounds down.
    /// @param sqrtPriceAX96 Lower sqrt price (Q64.96).
    /// @param sqrtPriceBX96 Upper sqrt price (Q64.96).
    /// @param liquidity     Liquidity.
    /// @return Currency0 amount (raw units).
    function _amount0(uint256 sqrtPriceAX96, uint256 sqrtPriceBX96, uint128 liquidity) private pure returns (uint256) {
        return Math.mulDiv(uint256(liquidity) << 96, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96) / sqrtPriceAX96;
    }

    /// @dev Currency1 held by `liquidity` between two ordered sqrt prices. Rounds down.
    /// @param sqrtPriceAX96 Lower sqrt price (Q64.96).
    /// @param sqrtPriceBX96 Upper sqrt price (Q64.96).
    /// @param liquidity     Liquidity.
    /// @return Currency1 amount (raw units).
    function _amount1(uint256 sqrtPriceAX96, uint256 sqrtPriceBX96, uint128 liquidity) private pure returns (uint256) {
        return Math.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, Q96);
    }

    /// @dev Liquidity funded by `amount0` between two ordered sqrt prices. Rounds down.
    /// @param sqrtPriceAX96 Lower sqrt price (Q64.96).
    /// @param sqrtPriceBX96 Upper sqrt price (Q64.96).
    /// @param amount0       Currency0 amount (raw units).
    /// @return Liquidity.
    function _liquidity0(
        uint256 sqrtPriceAX96,
        uint256 sqrtPriceBX96,
        uint256 amount0
    ) private pure returns (uint128) {
        uint256 intermediate = Math.mulDiv(sqrtPriceAX96, sqrtPriceBX96, Q96);
        return SafeCast.toUint128(Math.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @dev Liquidity funded by `amount1` between two ordered sqrt prices. Rounds down.
    /// @param sqrtPriceAX96 Lower sqrt price (Q64.96).
    /// @param sqrtPriceBX96 Upper sqrt price (Q64.96).
    /// @param amount1       Currency1 amount (raw units).
    /// @return Liquidity.
    function _liquidity1(
        uint256 sqrtPriceAX96,
        uint256 sqrtPriceBX96,
        uint256 amount1
    ) private pure returns (uint128) {
        return SafeCast.toUint128(Math.mulDiv(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }
}
