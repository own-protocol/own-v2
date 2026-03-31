// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWstETHRouter} from "../interfaces/IWstETHRouter.sol";
import {IWstETH} from "../interfaces/external/IWstETH.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WstETHRouter — Periphery router for stETH ↔ wstETH ERC-4626 vaults
/// @notice Wraps stETH to wstETH on deposit and unwraps wstETH to stETH on redeem.
///         Stateless: no tokens should remain in the router after any call.
///         Supports ERC-2612 permit for single-tx stETH deposits.
///         Follows the ERC4626-Alliance PeripheryPayments pattern.
contract WstETHRouter is IWstETHRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The canonical wstETH contract.
    IWstETH public immutable wstETH;

    /// @notice The canonical stETH contract.
    IERC20 public immutable stETH;

    constructor(address wstETH_, address stETH_) {
        if (wstETH_ == address(0)) revert ZeroAddress();
        if (stETH_ == address(0)) revert ZeroAddress();
        wstETH = IWstETH(wstETH_);
        stETH = IERC20(stETH_);

        // Max-approve wstETH to pull stETH (same pattern as Morpho's StEthBundler)
        stETH.forceApprove(wstETH_, type(uint256).max);
    }

    /// @inheritdoc IWstETHRouter
    function depositStETH(
        IERC4626 vault,
        uint256 stETHAmount,
        address receiver,
        uint256 minSharesOut
    ) external nonReentrant returns (uint256 shares) {
        if (stETHAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        shares = _depositStETHInternal(vault, stETHAmount, receiver, minSharesOut);
    }

    /// @inheritdoc IWstETHRouter
    function depositStETHWithPermit(
        IERC4626 vault,
        uint256 stETHAmount,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 shares) {
        if (stETHAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Execute permit (stETH supports ERC-2612)
        IERC20Permit(address(stETH)).permit(msg.sender, address(this), stETHAmount, deadline, v, r, s);

        shares = _depositStETHInternal(vault, stETHAmount, receiver, minSharesOut);
    }

    /// @inheritdoc IWstETHRouter
    function unwrapWstETH(uint256 amount, address receiver) external nonReentrant returns (uint256 stETHAmount) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Pull wstETH from caller
        IERC20(address(wstETH)).safeTransferFrom(msg.sender, address(this), amount);

        // Unwrap wstETH → stETH
        IERC20(address(wstETH)).forceApprove(address(wstETH), amount);
        stETHAmount = wstETH.unwrap(amount);

        // Send stETH to receiver
        stETH.safeTransfer(receiver, stETHAmount);

        emit UnwrappedWstETH(msg.sender, receiver, amount, stETHAmount);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Shared deposit logic for depositStETH and depositStETHWithPermit.
    function _depositStETHInternal(
        IERC4626 vault,
        uint256 stETHAmount,
        address receiver,
        uint256 minSharesOut
    ) internal returns (uint256 shares) {
        // Pull stETH from caller
        stETH.safeTransferFrom(msg.sender, address(this), stETHAmount);

        // Wrap stETH → wstETH (stETH already approved to wstETH in constructor)
        uint256 wstETHAmount = wstETH.wrap(stETHAmount);

        // Approve vault to pull wstETH
        IERC20(address(wstETH)).forceApprove(address(vault), wstETHAmount);

        // Deposit wstETH into vault, shares go to receiver
        shares = vault.deposit(wstETHAmount, receiver);

        // Slippage check
        if (shares < minSharesOut) revert MinSharesError(shares, minSharesOut);

        emit DepositStETH(address(vault), msg.sender, receiver, stETHAmount, shares);
    }
}
