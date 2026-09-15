// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockPsmMarket — Minimal OwnMarket PSM surface for zap unit tests
/// @notice Implements only {psmMint}: pulls the wrapper and mints eTokens at a configurable
///         ratio (1:1 by default), mirroring the real PSM's pull-then-mint shape.
contract MockPsmMarket {
    using SafeERC20 for IERC20;

    MockERC20 public immutable eToken;

    /// @dev eTokens minted per wrapper unit, 1e18 scale.
    uint256 public ratio = 1e18;

    constructor(
        MockERC20 eToken_
    ) {
        eToken = eToken_;
    }

    function setRatio(
        uint256 ratio_
    ) external {
        ratio = ratio_;
    }

    function psmMint(
        bytes32,
        address wrapper,
        uint256 wrapperAmount
    ) external returns (uint256 eTokenAmount) {
        IERC20(wrapper).safeTransferFrom(msg.sender, address(this), wrapperAmount);
        eTokenAmount = wrapperAmount * ratio / 1e18;
        eToken.mint(msg.sender, eTokenAmount);
    }
}
