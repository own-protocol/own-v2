// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IWETHRouter — Periphery router for native ETH ↔ WETH ERC-4626 vaults
/// @notice Wraps native ETH to WETH on deposit and unwraps WETH to ETH on redeem,
///         routing through any ERC-4626 vault that uses WETH as its underlying asset.
///         Follows the ERC4626-Alliance router pattern with slippage protection.
interface IWETHRouter {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when native ETH is deposited and wrapped into vault shares.
    /// @param vault    The ERC-4626 vault.
    /// @param sender   The caller who sent ETH.
    /// @param receiver The address that received vault shares.
    /// @param assets   Amount of WETH deposited.
    /// @param shares   Amount of vault shares minted.
    event DepositETH(
        address indexed vault, address indexed sender, address indexed receiver, uint256 assets, uint256 shares
    );

    /// @notice Emitted when WETH is unwrapped to native ETH.
    /// @param sender   The caller who provided WETH.
    /// @param receiver The address that received native ETH.
    /// @param amount   Amount of WETH unwrapped.
    event UnwrappedWETH(address indexed sender, address indexed receiver, uint256 amount);

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

    /// @notice ETH was sent by an address other than WETH (reject accidental ETH).
    error OnlyWETH();

    // ──────────────────────────────────────────────────────────
    //  Functions
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit native ETH into an ERC-4626 WETH vault.
    /// @dev Wraps msg.value to WETH, deposits into vault, returns shares to receiver.
    /// @param vault        The ERC-4626 vault (must use WETH as underlying).
    /// @param receiver     Address to receive vault shares.
    /// @param minSharesOut Minimum acceptable shares (slippage protection).
    /// @return shares Amount of vault shares minted.
    function depositETH(
        IERC4626 vault,
        address receiver,
        uint256 minSharesOut
    ) external payable returns (uint256 shares);

    /// @notice Unwrap WETH to native ETH and send to receiver.
    /// @dev Pulls WETH from caller, unwraps, and sends ETH. Caller must have
    ///      approved this router to spend their WETH.
    /// @param amount   Amount of WETH to unwrap.
    /// @param receiver Address to receive native ETH.
    /// @return Amount of ETH sent.
    function unwrapWETH(uint256 amount, address receiver) external returns (uint256);
}
