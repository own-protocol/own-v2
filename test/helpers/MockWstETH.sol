// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockWstETH — Mock wrapped staked ETH with configurable exchange rate
/// @notice Simulates Lido's wstETH. stETH is rebasing; wstETH wraps it into
///         a non-rebasing token. The exchange rate (stETH per wstETH) increases
///         over time as staking yield accrues.
contract MockWstETH is ERC20 {
    using SafeERC20 for ERC20;
    using Math for uint256;

    /// @notice The mock stETH token that this wraps.
    ERC20 public stETH;

    /// @notice wstETH per stETH rate scaled to 1e18. Starts at 1:1.
    /// @dev In production Lido, `getStETHByWstETH(1e18)` returns how much
    ///      stETH you get for 1 wstETH. We store the inverse for simpler math:
    ///      `tokensPerStEth` = how many wstETH you get per stETH.
    ///      Default 1e18 means 1 stETH = 1 wstETH.
    uint256 public tokensPerStEth = 1e18;

    constructor(
        address stETH_
    ) ERC20("Mock Wrapped stETH", "wstETH") {
        stETH = ERC20(stETH_);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Set the exchange rate. Only for testing.
    /// @param newRate wstETH per stETH, scaled to 1e18.
    ///        e.g. 0.9e18 means 1 stETH wraps into 0.9 wstETH (stETH appreciated).
    function setTokensPerStEth(
        uint256 newRate
    ) external {
        tokensPerStEth = newRate;
    }

    /// @notice Wrap stETH into wstETH.
    /// @param stETHAmount Amount of stETH to wrap.
    /// @return wstETHAmount Amount of wstETH minted.
    function wrap(
        uint256 stETHAmount
    ) external returns (uint256 wstETHAmount) {
        wstETHAmount = stETHAmount.mulDiv(tokensPerStEth, 1e18);
        stETH.safeTransferFrom(msg.sender, address(this), stETHAmount);
        _mint(msg.sender, wstETHAmount);
    }

    /// @notice Unwrap wstETH back to stETH.
    /// @param wstETHAmount Amount of wstETH to unwrap.
    /// @return stETHAmount Amount of stETH returned.
    function unwrap(
        uint256 wstETHAmount
    ) external returns (uint256 stETHAmount) {
        stETHAmount = wstETHAmount.mulDiv(1e18, tokensPerStEth);
        _burn(msg.sender, wstETHAmount);
        stETH.safeTransfer(msg.sender, stETHAmount);
    }

    /// @notice Get the amount of stETH for a given wstETH amount.
    function getStETHByWstETH(
        uint256 wstETHAmount
    ) external view returns (uint256) {
        return wstETHAmount.mulDiv(1e18, tokensPerStEth);
    }

    /// @notice Get the amount of wstETH for a given stETH amount.
    function getWstETHByStETH(
        uint256 stETHAmount
    ) external view returns (uint256) {
        return stETHAmount.mulDiv(tokensPerStEth, 1e18);
    }
}
