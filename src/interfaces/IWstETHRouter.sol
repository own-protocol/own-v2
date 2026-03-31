// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IWstETHRouter — Periphery router for stETH ↔ wstETH ERC-4626 vaults
/// @notice Wraps stETH to wstETH on deposit and unwraps wstETH to stETH on redeem,
///         routing through any ERC-4626 vault that uses wstETH as its underlying asset.
///         Follows the ERC4626-Alliance router pattern with slippage protection.
///         Supports ERC-2612 permit for single-tx stETH deposits.
interface IWstETHRouter {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when stETH is deposited, wrapped to wstETH, and routed into vault shares.
    /// @param vault       The ERC-4626 vault.
    /// @param sender      The caller who provided stETH.
    /// @param receiver    The address that received vault shares.
    /// @param stETHAmount Amount of stETH wrapped.
    /// @param shares      Amount of vault shares minted.
    event DepositStETH(
        address indexed vault, address indexed sender, address indexed receiver, uint256 stETHAmount, uint256 shares
    );

    /// @notice Emitted when wstETH is unwrapped to stETH.
    /// @param sender       The caller who provided wstETH.
    /// @param receiver     The address that received stETH.
    /// @param wstETHAmount Amount of wstETH unwrapped.
    /// @param stETHAmount  Amount of stETH received.
    event UnwrappedWstETH(address indexed sender, address indexed receiver, uint256 wstETHAmount, uint256 stETHAmount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Slippage check failed: received fewer shares than minimum.
    error MinSharesError(uint256 shares, uint256 minSharesOut);

    /// @notice Slippage check failed: received fewer assets than minimum.
    error MinAmountError(uint256 amount, uint256 minAmountOut);

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice A zero address was provided.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Functions
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit stETH into an ERC-4626 wstETH vault.
    /// @dev Pulls stETH from caller, wraps to wstETH, deposits into vault.
    ///      Caller must have approved this router to spend their stETH.
    /// @param vault        The ERC-4626 vault (must use wstETH as underlying).
    /// @param stETHAmount  Amount of stETH to deposit.
    /// @param receiver     Address to receive vault shares.
    /// @param minSharesOut Minimum acceptable shares (slippage protection).
    /// @return shares Amount of vault shares minted.
    function depositStETH(
        IERC4626 vault,
        uint256 stETHAmount,
        address receiver,
        uint256 minSharesOut
    ) external returns (uint256 shares);

    /// @notice Deposit stETH into an ERC-4626 wstETH vault using ERC-2612 permit.
    /// @dev Single-transaction flow: permit → pull stETH → wrap → deposit.
    /// @param vault        The ERC-4626 vault (must use wstETH as underlying).
    /// @param stETHAmount  Amount of stETH to deposit.
    /// @param receiver     Address to receive vault shares.
    /// @param minSharesOut Minimum acceptable shares (slippage protection).
    /// @param deadline     Permit deadline.
    /// @param v            Permit signature v.
    /// @param r            Permit signature r.
    /// @param s            Permit signature s.
    /// @return shares Amount of vault shares minted.
    function depositStETHWithPermit(
        IERC4626 vault,
        uint256 stETHAmount,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares);

    /// @notice Unwrap wstETH to stETH and send to receiver.
    /// @dev Pulls wstETH from caller, unwraps to stETH, and sends. Caller must have
    ///      approved this router to spend their wstETH.
    /// @param amount   Amount of wstETH to unwrap.
    /// @param receiver Address to receive stETH.
    /// @return stETHAmount Amount of stETH sent.
    function unwrapWstETH(uint256 amount, address receiver) external returns (uint256 stETHAmount);
}
