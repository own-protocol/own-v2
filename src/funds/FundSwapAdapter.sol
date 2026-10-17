// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundSwapAdapter} from "../interfaces/IFundSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @title FundSwapAdapter — Universal Router adapter for fund rebalances and zaps
/// @notice See {IFundSwapAdapter}.
contract FundSwapAdapter is IFundSwapAdapter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFundSwapAdapter
    address public immutable override universalRouter;

    /// @param universalRouter_ Uniswap's Universal Router on this chain.
    constructor(
        address universalRouter_
    ) {
        if (universalRouter_ == address(0)) revert ZeroAddress();
        universalRouter = universalRouter_;
    }

    /// @inheritdoc IFundSwapAdapter
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        bytes calldata commands,
        bytes[] calldata inputs
    ) external override nonReentrant returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut) revert SameToken();
        if (amountIn == 0) revert ZeroAmount();

        IERC20(tokenIn).safeTransferFrom(msg.sender, universalRouter, amountIn);
        IUniversalRouter(universalRouter).execute(commands, inputs, block.timestamp);

        amountOut = IERC20(tokenOut).balanceOf(address(this));
        if (amountOut != 0) IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        uint256 refund = IERC20(tokenIn).balanceOf(address(this));
        if (refund != 0) IERC20(tokenIn).safeTransfer(msg.sender, refund);

        emit Swapped(msg.sender, tokenIn, amountIn, tokenOut, amountOut, refund);
    }
}
