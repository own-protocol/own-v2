// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @title MockV3Pool — Uniswap v3-style exact-input swap at a fixed price
/// @notice Fills `fillBps` of the input at `price1Per0` (token1 per token0, 1e18 fixed point, raw
///         units), sends the output first, then calls back and checks it was paid.
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint256 public price1Per0 = 1e18;
    uint256 public fillBps = 10_000;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setPrice(
        uint256 p
    ) external {
        price1Per0 = p;
    }

    function setFillBps(
        uint256 f
    ) external {
        fillBps = f;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = uint256(amountSpecified) * fillBps / 10_000;
        require(amountIn > 0, "AS");
        uint256 amountOut = zeroForOne ? amountIn * price1Per0 / 1e18 : amountIn * 1e18 / price1Per0;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        IERC20(tokenOut).transfer(recipient, amountOut);
        (amount0, amount1) =
            zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }

    /// @dev Calls a contract's swap callback as this pool, outside any trade.
    function callback(address target, int256 a0, int256 a1, bytes calldata data) external {
        IV3SwapCallback(target).uniswapV3SwapCallback(a0, a1, data);
    }
}
