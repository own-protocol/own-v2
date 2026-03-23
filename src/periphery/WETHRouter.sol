// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWETHRouter} from "../interfaces/IWETHRouter.sol";
import {IWETH} from "../interfaces/external/IWETH.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WETHRouter — Periphery router for native ETH ↔ WETH ERC-4626 vaults
/// @notice Wraps native ETH to WETH on deposit and unwraps WETH to ETH on redeem.
///         Stateless: no tokens or ETH should remain in the router after any call.
///         Follows the ERC4626-Alliance PeripheryPayments pattern.
contract WETHRouter is IWETHRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The canonical WETH contract.
    IWETH public immutable weth;

    constructor(
        address weth_
    ) {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = IWETH(weth_);
    }

    /// @inheritdoc IWETHRouter
    function depositETH(
        IERC4626 vault,
        address receiver,
        uint256 minSharesOut
    ) external payable nonReentrant returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Wrap ETH → WETH
        weth.deposit{value: msg.value}();

        // Approve vault to pull WETH
        IERC20(address(weth)).forceApprove(address(vault), msg.value);

        // Deposit WETH into vault, shares go to receiver
        shares = vault.deposit(msg.value, receiver);

        // Slippage check
        if (shares < minSharesOut) revert MinSharesError(shares, minSharesOut);

        emit DepositETH(address(vault), msg.sender, receiver, msg.value, shares);
    }

    /// @inheritdoc IWETHRouter
    function redeemETH(
        IERC4626 vault,
        uint256 shares,
        address receiver,
        uint256 minAmountOut
    ) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Pull vault shares from caller and redeem for WETH (to this contract)
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);
        assets = vault.redeem(shares, address(this), address(this));

        // Slippage check
        if (assets < minAmountOut) revert MinAmountError(assets, minAmountOut);

        // Unwrap WETH → ETH
        weth.withdraw(assets);

        // Send ETH to receiver
        Address.sendValue(payable(receiver), assets);

        emit RedeemETH(address(vault), msg.sender, receiver, assets, shares);
    }

    /// @notice Accept ETH only from the WETH contract (during withdraw).
    receive() external payable {
        if (msg.sender != address(weth)) revert OnlyWETH();
    }
}
