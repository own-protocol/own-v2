// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundSwapAdapter — lets funds and zaps trade through Uniswap's Universal Router
/// @notice Funds and zaps trade by approving an allowed router for the amount they sell and calling
///         it (see {IFund-rebalance}). Uniswap's Universal Router never pulls tokens from an approval,
///         only through Permit2, so it can't be called that way. This adapter is the allowlisted router
///         instead: it pulls the approved amount from the caller straight into the Universal Router, runs
///         the caller's commands with the router paying from its own balance (`payerIsUser = false`), and
///         sends the caller the `tokenOut` and leftover `tokenIn` this swap produced, measured as the
///         balance gained during the call so a token donated or stranded in the adapter earlier is left
///         untouched rather than paid to the next caller.
///
///         Commands must send their output to this adapter (the router's `MSG_SENDER` recipient) and may
///         sweep unused `tokenIn` to it too. The caller still checks what it got back: a fund's rebalance
///         applies its oracle slippage bound and daily cap to the balance changes, whatever the commands do.
///
///         Holds nothing between transactions and has no owner. Not payable: routes through native ETH
///         must wrap and unwrap inside the router.
interface IFundSwapAdapter {
    /// @notice Emitted on a swap.
    /// @param caller    Fund or zap that sold.
    /// @param tokenIn   Token sold.
    /// @param amountIn  Amount pulled from the caller.
    /// @param tokenOut  Token bought.
    /// @param amountOut Amount sent back to the caller.
    /// @param refund    Unused `tokenIn` sent back to the caller.
    event Swapped(
        address indexed caller,
        address indexed tokenIn,
        uint256 amountIn,
        address indexed tokenOut,
        uint256 amountOut,
        uint256 refund
    );

    /// @notice Zero address passed where an address is required.
    error ZeroAddress();

    /// @notice Zero amount.
    error ZeroAmount();

    /// @notice `tokenIn` equals `tokenOut`.
    error SameToken();

    /// @notice The Universal Router this adapter calls.
    /// @return The router.
    function universalRouter() external view returns (address);

    /// @notice Sells `amountIn` of the caller's `tokenIn` through the Universal Router and returns the proceeds.
    /// @param tokenIn  Token to sell; the caller must have approved this adapter for `amountIn`.
    /// @param amountIn Amount to sell.
    /// @param tokenOut Token to buy.
    /// @param commands Universal Router commands.
    /// @param inputs   Universal Router inputs, one per command.
    /// @return amountOut `tokenOut` sent to the caller.
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        bytes calldata commands,
        bytes[] calldata inputs
    ) external returns (uint256 amountOut);
}
