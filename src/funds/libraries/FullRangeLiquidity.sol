// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title FullRangeLiquidity — liquidity for given amounts when the price is inside the range
/// @notice The subset of Uniswap's LiquidityAmounts needed to seed a full-range position.
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
        uint256 intermediate = FullMath.mulDiv(sqrtPrice, sqrtUpper, FixedPoint96.Q96);
        uint256 liquidity0 = FullMath.mulDiv(amount0, intermediate, sqrtUpper - sqrtPrice);
        uint256 liquidity1 = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPrice - sqrtLower);
        return SafeCast.toUint128(liquidity0 < liquidity1 ? liquidity0 : liquidity1);
    }
}
