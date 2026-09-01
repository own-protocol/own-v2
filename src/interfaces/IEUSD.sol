// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IEUSD — CDP stablecoin token
/// @notice Minimal ERC-20 + ERC-2612 (Permit) stablecoin. Supply changes only through
///         holders of MINTER_ROLE — in production exactly one: the EUSDManager. Burns are
///         allowance-free and restricted to the same role, so the manager can retire debt
///         (repay / redeem / liquidate) directly from the payer's balance.
interface IEUSD is IERC20, IERC20Permit {
    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A required address was the zero address.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Role allowed to mint and burn. Held only by the EUSDManager.
    function MINTER_ROLE() external view returns (bytes32);

    // ──────────────────────────────────────────────────────────
    //  Supply (MINTER_ROLE)
    // ──────────────────────────────────────────────────────────

    /// @notice Mint `amount` eUSD to `to`. Gated by MINTER_ROLE.
    /// @param to     Recipient of the minted tokens.
    /// @param amount Amount to mint (18 decimals).
    function mint(address to, uint256 amount) external;

    /// @notice Burn `amount` eUSD from `from`, without an allowance. Gated by MINTER_ROLE.
    /// @param from   Account whose tokens are burned.
    /// @param amount Amount to burn (18 decimals).
    function burn(address from, uint256 amount) external;
}
