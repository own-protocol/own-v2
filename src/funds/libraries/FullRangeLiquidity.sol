// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// @title FullRangeLiquidity — liquidity and amounts of a position while the price is inside its range
/// @notice The subset of Uniswap's LiquidityAmounts and SqrtPriceMath a full-range position needs,
///         on OpenZeppelin's mulDiv (the same floor of the exact product) so the hook carries one
///         mulDiv rather than two.
library FullRangeLiquidity {
    /// @notice Largest liquidity both amounts can fund at `sqrtPrice`, given
    ///         `sqrtLower < sqrtPrice < sqrtUpper`. Rounds down.
    /// @param sqrtPrice Current sqrt price, Q64.96.
    /// @param sqrtLower Lower bound sqrt price, Q64.96.
    /// @param sqrtUpper Upper bound sqrt price, Q64.96.
    /// @param amount0   Currency0 available.
    /// @param amount1   Currency1 available.
    /// @return The liquidity.
    function liquidityForAmounts(
        uint160 sqrtPrice,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        uint256 intermediate = Math.mulDiv(sqrtPrice, sqrtUpper, FixedPoint96.Q96);
        uint256 liquidity0 = Math.mulDiv(amount0, intermediate, sqrtUpper - sqrtPrice);
        uint256 liquidity1 = Math.mulDiv(amount1, FixedPoint96.Q96, sqrtPrice - sqrtLower);
        return SafeCast.toUint128(liquidity0 < liquidity1 ? liquidity0 : liquidity1);
    }

    /// @notice Amounts `liquidity` holds at `sqrtPrice`, given
    ///         `0 < sqrtLower <= sqrtPrice <= sqrtUpper`. Rounds down, so a position is never
    ///         overstated.
    /// @param sqrtPrice Current sqrt price, Q64.96.
    /// @param sqrtLower Lower bound sqrt price, Q64.96.
    /// @param sqrtUpper Upper bound sqrt price, Q64.96.
    /// @param liquidity The liquidity.
    /// @return amount0 Currency0 held.
    /// @return amount1 Currency1 held.
    function amountsForLiquidity(
        uint160 sqrtPrice,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        amount0 =
            Math.mulDiv(uint256(liquidity) << FixedPoint96.RESOLUTION, sqrtUpper - sqrtPrice, sqrtUpper) / sqrtPrice;
        amount1 = Math.mulDiv(liquidity, sqrtPrice - sqrtLower, FixedPoint96.Q96);
    }
}
