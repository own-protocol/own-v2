// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWstETH — Lido wrapped staked ETH interface
/// @notice wstETH wraps rebasing stETH into a non-rebasing ERC-20. The exchange
///         rate (stETH per wstETH) increases over time as staking yield accrues.
interface IWstETH is IERC20 {
    /// @notice Wrap stETH into wstETH.
    /// @param stETHAmount Amount of stETH to wrap.
    /// @return wstETHAmount Amount of wstETH minted.
    function wrap(
        uint256 stETHAmount
    ) external returns (uint256 wstETHAmount);

    /// @notice Unwrap wstETH back to stETH.
    /// @param wstETHAmount Amount of wstETH to unwrap.
    /// @return stETHAmount Amount of stETH returned.
    function unwrap(
        uint256 wstETHAmount
    ) external returns (uint256 stETHAmount);

    /// @notice Get the amount of stETH for a given wstETH amount.
    /// @param wstETHAmount Amount of wstETH.
    /// @return Amount of stETH.
    function getStETHByWstETH(
        uint256 wstETHAmount
    ) external view returns (uint256);

    /// @notice Get the amount of wstETH for a given stETH amount.
    /// @param stETHAmount Amount of stETH.
    /// @return Amount of wstETH.
    function getWstETHByStETH(
        uint256 stETHAmount
    ) external view returns (uint256);
}
