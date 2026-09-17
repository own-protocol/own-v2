// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWETH — Standard WETH9 interface
/// @notice Canonical wrapped-ETH interface (deposit ETH → WETH, withdraw WETH → ETH).
interface IWETH is IERC20 {
    /// @notice Wrap sent ETH into WETH.
    function deposit() external payable;

    /// @notice Unwrap WETH back to ETH.
    /// @param amount Amount of WETH to unwrap.
    function withdraw(
        uint256 amount
    ) external;
}
