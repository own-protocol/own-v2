// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IUniswapV3PoolSwap — the subset of a Uniswap v3-style pool used to swap
/// @notice Shared by Uniswap v3 and Aero Slipstream pools. The pool sends the output first, then
///         calls `uniswapV3SwapCallback` on the caller, which must pay what it owes before
///         returning.
interface IUniswapV3PoolSwap {
    /// @notice Lower-sorted token of the pair.
    function token0() external view returns (address);

    /// @notice Higher-sorted token of the pair.
    function token1() external view returns (address);

    /// @notice Swap token0 for token1 or back.
    /// @param recipient         Receives the output.
    /// @param zeroForOne        True to sell token0 for token1.
    /// @param amountSpecified   Positive for exact input, negative for exact output.
    /// @param sqrtPriceLimitX96 The swap stops at this price.
    /// @param data              Passed to the callback.
    /// @return amount0 Pool's token0 balance change (positive = paid in by the caller).
    /// @return amount1 Pool's token1 balance change (positive = paid in by the caller).
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
