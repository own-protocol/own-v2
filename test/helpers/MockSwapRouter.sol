// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockSwapRouter — Test double for an allow-listed buy-&-burn swap target
/// @notice Swaps at whatever terms the test encodes: pulls `amountIn` of `tokenIn` (or takes the
///         attached native value) and pays out `amountOut` of `tokenOut` from its own inventory.
///         A dishonest fill is simulated simply by encoding a lower `amountOut`.
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external payable {
        if (tokenIn == address(0)) {
            require(msg.value == amountIn, "bad msg.value");
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @notice Pulls the input then pays nothing — a total-loss fill.
    function swapAndKeep(address tokenIn, uint256 amountIn) external payable {
        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
    }

    bytes public lastCallError;

    /// @notice Runs `target` mid-swap, as a route through a hooked pool or an executor would, then
    ///         pulls to `to` whatever `tokenIn` the call paid the caller. A failed call is recorded
    ///         and nothing is pulled.
    function callThenPull(address target, bytes calldata data, address tokenIn, address to) external {
        uint256 before = IERC20(tokenIn).balanceOf(msg.sender);
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) {
            lastCallError = err;
            return;
        }
        IERC20(tokenIn).safeTransferFrom(msg.sender, to, IERC20(tokenIn).balanceOf(msg.sender) - before);
    }

    function alwaysReverts() external payable {
        revert("router revert");
    }

    receive() external payable {}
}
