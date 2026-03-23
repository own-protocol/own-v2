// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPaymentTokenRegistry — Payment token (stablecoin) whitelist
/// @notice Manages the set of ERC-20 tokens accepted as payment for minting
///         and as payout for redemptions. Only admin-whitelisted tokens can be
///         used in orders.
interface IPaymentTokenRegistry {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a payment token is added to the whitelist.
    /// @param token The whitelisted token address.
    event PaymentTokenAdded(address indexed token);

    /// @notice Emitted when a payment token is removed from the whitelist.
    /// @param token The removed token address.
    event PaymentTokenRemoved(address indexed token);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The token is already whitelisted.
    error AlreadyWhitelisted(address token);

    /// @notice The token is not whitelisted.
    error NotWhitelisted(address token);

    /// @notice A zero address was provided.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Admin functions
    // ──────────────────────────────────────────────────────────

    /// @notice Add a payment token to the whitelist.
    /// @param token ERC-20 token address to whitelist.
    function addPaymentToken(
        address token
    ) external;

    /// @notice Remove a payment token from the whitelist.
    /// @param token ERC-20 token address to remove.
    function removePaymentToken(
        address token
    ) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Check whether a token is whitelisted for payments.
    /// @param token The token address to check.
    /// @return True if the token is whitelisted.
    function isWhitelisted(
        address token
    ) external view returns (bool);

    /// @notice Return all currently whitelisted payment tokens.
    /// @return tokens Array of whitelisted token addresses.
    function getPaymentTokens() external view returns (address[] memory tokens);
}
