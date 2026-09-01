// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IERC7802 — Crosschain token interface (ERC-7802)
/// @notice Minimal, bridge-agnostic mint/burn surface for crosschain token transfers. A token
///         implementing this can plug into any transport (CCIP token pool, OFT adapter, Hyperlane
///         warp route, native interop) by authorizing that transport to call these two functions.
interface IERC7802 is IERC165 {
    /// @notice Emitted when a crosschain transfer mints tokens.
    /// @param to     Address of the account tokens are being minted for.
    /// @param amount Amount of tokens minted.
    /// @param sender Address of the caller (msg.sender) who invoked crosschainMint.
    event CrosschainMint(address indexed to, uint256 amount, address indexed sender);

    /// @notice Emitted when a crosschain transfer burns tokens.
    /// @param from   Address of the account tokens are being burned from.
    /// @param amount Amount of tokens burned.
    /// @param sender Address of the caller (msg.sender) who invoked crosschainBurn.
    event CrosschainBurn(address indexed from, uint256 amount, address indexed sender);

    /// @notice Mint tokens through a crosschain transfer.
    /// @param to     Address to mint tokens to.
    /// @param amount Amount of tokens to mint.
    function crosschainMint(address to, uint256 amount) external;

    /// @notice Burn tokens through a crosschain transfer.
    /// @param from   Address to burn tokens from.
    /// @param amount Amount of tokens to burn.
    function crosschainBurn(address from, uint256 amount) external;
}
