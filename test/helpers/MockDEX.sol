// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockDEX — Mock Uniswap-style swap router for Tier 3 liquidation testing
/// @notice Simulates a DEX swap: takes tokenIn, returns tokenOut at a preset rate.
///         Supports configurable exchange rates and failure simulation.
contract MockDEX {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Exchange rate: how many tokenOut per tokenIn, scaled to 1e18.
    /// @dev Key: keccak256(abi.encodePacked(tokenIn, tokenOut)).
    mapping(bytes32 => uint256) private _rates;

    /// @notice When true, all swaps revert.
    bool public forceRevert;

    /// @notice When true, swaps return 0 tokens (simulate extreme slippage).
    bool public forceZeroOutput;

    // ──────────────────────────────────────────────────────────
    //  Test helpers
    // ──────────────────────────────────────────────────────────

    /// @notice Set the exchange rate between two tokens.
    /// @param tokenIn  Input token address.
    /// @param tokenOut Output token address.
    /// @param rate     Output per input, scaled to 1e18 (e.g. 2000e18 means 1 tokenIn = 2000 tokenOut).
    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        bytes32 key = keccak256(abi.encodePacked(tokenIn, tokenOut));
        _rates[key] = rate;
    }

    /// @notice Toggle forced revert on swaps.
    function setForceRevert(
        bool value
    ) external {
        forceRevert = value;
    }

    /// @notice Toggle zero-output mode.
    function setForceZeroOutput(
        bool value
    ) external {
        forceZeroOutput = value;
    }

    // ──────────────────────────────────────────────────────────
    //  Swap
    // ──────────────────────────────────────────────────────────

    /// @notice Execute a swap. Caller must have approved this contract for `amountIn`.
    /// @param tokenIn   Input token.
    /// @param tokenOut  Output token.
    /// @param amountIn  Amount of tokenIn to sell.
    /// @param minAmountOut Minimum acceptable output (reverts if below).
    /// @return amountOut Actual output amount.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        require(!forceRevert, "MockDEX: forced revert");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (forceZeroOutput) {
            amountOut = 0;
        } else {
            bytes32 key = keccak256(abi.encodePacked(tokenIn, tokenOut));
            uint256 rate = _rates[key];
            require(rate > 0, "MockDEX: rate not set");

            // Adjust for decimal differences between tokens
            // rate is in 1e18 precision, so: amountOut = amountIn * rate / 1e18
            amountOut = amountIn.mulDiv(rate, 1e18);
        }

        require(amountOut >= minAmountOut, "MockDEX: insufficient output");

        if (amountOut > 0) {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
    }

    /// @notice Get the expected output for a swap (read-only).
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(tokenIn, tokenOut));
        uint256 rate = _rates[key];
        if (rate == 0) return 0;
        return amountIn.mulDiv(rate, 1e18);
    }
}
