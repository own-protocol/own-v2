// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Order, OrderStatus} from "./types/Types.sol";

/// @title IOwnMarket — Order escrow and execution marketplace
/// @notice Users place mint or redeem orders with a price and expiry. The VM
///         claims orders, executes off-chain hedges, and confirms execution.
///         Orders execute at the user's set price. Force execution provides
///         user recourse when the VM fails to confirm or close in time.
interface IOwnMarket {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a user places a new order.
    event OrderPlaced(
        uint256 indexed orderId, address indexed user, uint8 orderType, bytes32 indexed asset, uint256 amount
    );

    /// @notice Emitted when the VM claims an order.
    event OrderClaimed(uint256 indexed orderId, address indexed vm);

    /// @notice Emitted when the VM confirms execution of a claimed order.
    event OrderConfirmed(uint256 indexed orderId, address indexed vm, uint256 eTokenAmount);

    /// @notice Emitted when a user cancels their order (before claim).
    event OrderCancelled(uint256 indexed orderId, address indexed user);

    /// @notice Emitted when an unclaimed order expires past its deadline.
    event OrderExpired(uint256 indexed orderId);

    /// @notice Emitted when the VM closes an expired claimed order and returns funds.
    event OrderClosed(uint256 indexed orderId, address indexed vm);

    /// @notice Emitted when a user force-executes after the grace period.
    event OrderForceExecuted(uint256 indexed orderId, address indexed user, bool priceReachable);

    /// @notice Emitted when a protocol fee is collected during order confirmation.
    event FeeCollected(uint256 indexed orderId, address indexed token, uint256 feeAmount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The order does not exist.
    error OrderNotFound(uint256 orderId);

    /// @notice The order is not in the expected status.
    error InvalidOrderStatus(uint256 orderId, OrderStatus currentStatus);

    /// @notice The order has passed its expiry.
    error OrderExpiredError(uint256 orderId);

    /// @notice Only the order owner can perform this action.
    error OnlyOrderOwner(uint256 orderId);

    /// @notice The order expiry has not been reached yet.
    error ExpiryNotReached(uint256 orderId);

    /// @notice The grace period has not elapsed since claim.
    error GracePeriodNotElapsed(uint256 orderId);

    /// @notice The claim threshold has not elapsed since placement.
    error ClaimThresholdNotElapsed(uint256 orderId);

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice The expiry timestamp is invalid.
    error InvalidExpiry();

    /// @notice The price is invalid (zero).
    error InvalidPrice();

    /// @notice The asset is not active in the registry.
    error AssetNotActive(bytes32 asset);

    /// @notice Only the registered VM can perform this action.
    error OnlyVM();

    /// @notice The claim would breach the vault's max utilization.
    error UtilizationBreached(uint256 currentUtilization, uint256 maxUtilization);

    // ──────────────────────────────────────────────────────────
    //  Order placement
    // ──────────────────────────────────────────────────────────

    /// @notice Place a mint order. User deposits stablecoins into escrow.
    /// @param asset  Asset ticker (e.g. bytes32("TSLA")).
    /// @param amount Amount of stablecoins to deposit.
    /// @param price  Maximum price per eToken the user will pay (18 decimals).
    /// @param expiry Timestamp after which the order can be expired.
    /// @return orderId The unique order identifier.
    function placeMintOrder(bytes32 asset, uint256 amount, uint256 price, uint256 expiry)
        external
        returns (uint256 orderId);

    /// @notice Place a redeem order. User deposits eTokens into escrow.
    /// @param asset  Asset ticker.
    /// @param amount Amount of eTokens to deposit.
    /// @param price  Minimum price per eToken the user will accept (18 decimals).
    /// @param expiry Timestamp after which the order can be expired.
    /// @return orderId The unique order identifier.
    function placeRedeemOrder(bytes32 asset, uint256 amount, uint256 price, uint256 expiry)
        external
        returns (uint256 orderId);

    // ──────────────────────────────────────────────────────────
    //  VM operations
    // ──────────────────────────────────────────────────────────

    /// @notice Claim an open order. Full fill only.
    ///         Mint: stablecoins (minus escrowed fee) transferred to VM.
    ///         Redeem: eTokens remain in escrow.
    /// @param orderId Order to claim.
    function claimOrder(
        uint256 orderId
    ) external;

    /// @notice Confirm execution of a claimed order at the set price.
    ///         Mint: eTokens minted to user, escrowed fee deposited to vault.
    ///         Redeem: VM sends stablecoins to user, eTokens burned, fee deposited to vault.
    /// @param orderId Order to confirm.
    function confirmOrder(
        uint256 orderId
    ) external;

    /// @notice Close an expired claimed order and return funds to the user.
    ///         Mint: VM returns stablecoins to user in this transaction, escrowed fee returned.
    ///         Redeem: eTokens returned to user.
    /// @param orderId Order to close.
    function closeOrder(
        uint256 orderId
    ) external;

    // ──────────────────────────────────────────────────────────
    //  User operations
    // ──────────────────────────────────────────────────────────

    /// @notice Cancel an open (unclaimed) order. Returns escrowed funds to user.
    /// @param orderId Order to cancel.
    function cancelOrder(
        uint256 orderId
    ) external;

    /// @notice Force-execute an order after the grace period when the VM has
    ///         not confirmed or closed. For claimed orders (mint & redeem) and
    ///         unclaimed redeem orders past the claim threshold.
    /// @param orderId       Order to force-execute.
    /// @param ohlcProofData OHLC oracle proof showing whether the set price was reachable.
    function forceExecute(uint256 orderId, bytes calldata ohlcProofData) external;

    // ──────────────────────────────────────────────────────────
    //  Permissionless
    // ──────────────────────────────────────────────────────────

    /// @notice Expire an unclaimed order after its expiry. Callable by anyone.
    ///         Returns escrowed stablecoins (mint) or eTokens (redeem) to user.
    /// @param orderId Order to expire.
    function expireOrder(
        uint256 orderId
    ) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the full details of an order.
    function getOrder(
        uint256 orderId
    ) external view returns (Order memory order);

    /// @notice Return all open order IDs for an asset.
    function getOpenOrders(
        bytes32 asset
    ) external view returns (uint256[] memory orderIds);

    /// @notice Return all order IDs for a user.
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory orderIds);
}
