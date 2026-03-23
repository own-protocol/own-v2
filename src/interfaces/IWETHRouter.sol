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

    /// @notice Emitted when vault shares are redeemed for native ETH.
    /// @param vault    The ERC-4626 vault.
    /// @param owner    The share owner.
    /// @param receiver The address that received ETH.
    /// @param assets   Amount of WETH withdrawn.
    /// @param shares   Amount of vault shares burned.
    event RedeemETH(
        address indexed vault, address indexed owner, address indexed receiver, uint256 assets, uint256 shares
    );

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

    /// @notice Redeem vault shares for native ETH.
    /// @dev Burns shares, receives WETH, unwraps to ETH, sends to receiver.
    ///      Caller must have approved this router to spend their vault shares.
    /// @param vault        The ERC-4626 vault (must use WETH as underlying).
    /// @param shares       Number of vault shares to redeem.
    /// @param receiver     Address to receive native ETH.
    /// @param minAmountOut Minimum acceptable ETH output (slippage protection).
    /// @return assets Amount of ETH sent to receiver.
    function redeemETH(
        IERC4626 vault,
        uint256 shares,
        address receiver,
        uint256 minAmountOut
    ) external returns (uint256 assets);
}
