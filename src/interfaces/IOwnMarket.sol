// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClaimInfo, Order, OrderStatus, PriceType} from "./types/Types.sol";

/// @title IOwnMarket — Order escrow and claim marketplace
/// @notice The core execution mechanism for the protocol. Minters place orders
///         (mint or redeem) that sit in escrow. Vault managers claim orders,
///         execute offchain hedges, and confirm with signed oracle prices.
///         Supports market orders (with slippage), limit orders, directed orders
///         (specific VM), open orders (any VM), partial fills, and cross-vault
///         VM competition.
interface IOwnMarket {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a minter places a new order.
    /// @param orderId   Unique order identifier.
    /// @param user      Minter address.
    /// @param orderType 0 = Mint, 1 = Redeem.
    /// @param asset     Asset ticker.
    /// @param amount    Stablecoin amount (Mint) or eToken amount (Redeem).
    event OrderPlaced(
        uint256 indexed orderId, address indexed user, uint8 orderType, bytes32 indexed asset, uint256 amount
    );

    /// @notice Emitted when a VM claims a portion (or all) of an order.
    /// @param orderId Claimed order.
    /// @param claimId Unique claim identifier.
    /// @param vm      Vault manager who claimed.
    /// @param amount  Amount claimed.
    event OrderClaimed(uint256 indexed orderId, uint256 indexed claimId, address indexed vm, uint256 amount);

    /// @notice Emitted when a VM confirms execution of their claim.
    /// @param orderId       Order being confirmed.
    /// @param claimId       Claim being confirmed.
    /// @param vm            Confirming vault manager.
    /// @param executionPrice Oracle price at execution (18 decimals).
    /// @param eTokenAmount  eTokens minted (Mint) or burned (Redeem).
    event OrderConfirmed(
        uint256 indexed orderId,
        uint256 indexed claimId,
        address indexed vm,
        uint256 executionPrice,
        uint256 eTokenAmount
    );

    /// @notice Emitted when a user cancels their order.
    /// @param orderId Cancelled order.
    /// @param user    Minter who cancelled.
    event OrderCancelled(uint256 indexed orderId, address indexed user);

    /// @notice Emitted when an order expires past its deadline.
    /// @param orderId Expired order.
    event OrderExpired(uint256 indexed orderId);

    /// @notice Emitted when a partial fill is settled and remaining funds returned.
    /// @param orderId         Order identifier.
    /// @param filledAmount    Total amount that was filled.
    /// @param remainingAmount Amount returned to the user.
    event PartialFillCompleted(uint256 indexed orderId, uint256 filledAmount, uint256 remainingAmount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The order does not exist.
    error OrderNotFound(uint256 orderId);

    /// @notice The order is not in the expected status.
    error OrderNotOpen(uint256 orderId, OrderStatus currentStatus);

    /// @notice The order has passed its deadline.
    error OrderExpiredError(uint256 orderId, uint256 deadline);

    /// @notice Invalid order type provided.
    error InvalidOrderType();

    /// @notice Invalid price type provided.
    error InvalidPriceType();

    /// @notice Execution price exceeds the user's slippage tolerance.
    error SlippageExceeded(uint256 orderId, uint256 executionPrice, uint256 placementPrice, uint256 slippage);

    /// @notice The oracle price does not meet the limit price.
    error LimitPriceNotMet(uint256 orderId, uint256 oraclePrice, uint256 limitPrice);

    /// @notice Partial fills are not allowed on this order.
    error PartialFillNotAllowed(uint256 orderId);

    /// @notice The claim amount exceeds the remaining unfilled amount.
    error AmountExceedsRemaining(uint256 orderId, uint256 requestedAmount, uint256 remainingAmount);

    /// @notice The VM is not eligible to claim this order.
    error VMNotEligible(address vm, uint256 orderId);

    /// @notice This is a directed order for a different VM.
    error DirectedOrderWrongVM(uint256 orderId, address expectedVM, address caller);

    /// @notice Only the order owner can perform this action.
    error OnlyOrderOwner(uint256 orderId, address caller);

    /// @notice The claim does not exist.
    error ClaimNotFound(uint256 claimId);

    /// @notice The claim has already been confirmed.
    error ClaimAlreadyConfirmed(uint256 claimId);

    /// @notice The order deadline has not been reached yet.
    error DeadlineNotReached(uint256 orderId, uint256 deadline);

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice The deadline is invalid (e.g. in the past).
    error InvalidDeadline();

    /// @notice The asset's market is halted.
    error MarketHalted(bytes32 asset);

    /// @notice The asset is not active in the registry.
    error AssetNotActive(bytes32 asset);

    /// @notice The payment token is not whitelisted.
    error PaymentTokenNotWhitelisted(address token);

    // ──────────────────────────────────────────────────────────
    //  Order placement
    // ──────────────────────────────────────────────────────────

    /// @notice Place a mint order. Minter deposits stablecoins into escrow.
    /// @param asset                Asset ticker (e.g. bytes32("TSLA")).
    /// @param stablecoin           Payment token address.
    /// @param stablecoinAmount     Amount of stablecoins to deposit.
    /// @param priceType            Market or Limit.
    /// @param slippageOrLimitPrice Slippage in BPS (Market) or limit price in 18 decimals (Limit).
    /// @param deadline             Order expiry timestamp.
    /// @param allowPartialFill     Whether partial fills are accepted.
    /// @param preferredVM          Target VM for directed orders (address(0) for open).
    /// @param priceData            Oracle price data for recording placement price.
    /// @return orderId The unique order identifier.
    function placeMintOrder(
        bytes32 asset,
        address stablecoin,
        uint256 stablecoinAmount,
        PriceType priceType,
        uint256 slippageOrLimitPrice,
        uint256 deadline,
        bool allowPartialFill,
        address preferredVM,
        bytes calldata priceData
    ) external returns (uint256 orderId);

    /// @notice Place a redeem order. Minter deposits eTokens into escrow.
    /// @param asset                Asset ticker.
    /// @param stablecoin           Desired payout token address.
    /// @param eTokenAmount         Amount of eTokens to deposit.
    /// @param priceType            Market or Limit.
    /// @param slippageOrLimitPrice Slippage in BPS (Market) or limit price in 18 decimals (Limit).
    /// @param deadline             Order expiry timestamp.
    /// @param allowPartialFill     Whether partial fills are accepted.
    /// @param preferredVM          Target VM for directed orders (address(0) for open).
    /// @param priceData            Oracle price data for recording placement price.
    /// @return orderId The unique order identifier.
    function placeRedeemOrder(
        bytes32 asset,
        address stablecoin,
        uint256 eTokenAmount,
        PriceType priceType,
        uint256 slippageOrLimitPrice,
        uint256 deadline,
        bool allowPartialFill,
        address preferredVM,
        bytes calldata priceData
    ) external returns (uint256 orderId);

    // ──────────────────────────────────────────────────────────
    //  VM operations
    // ──────────────────────────────────────────────────────────

    /// @notice Claim a portion (or all) of an open order.
    /// @dev For mints, stablecoins are released to the VM. For redeems, the VM
    ///      commits to sending stablecoins to the minter on confirmation.
    /// @param orderId Order to claim.
    /// @param amount  Amount to claim (stablecoin for Mint, eToken for Redeem).
    /// @return claimId The unique claim identifier.
    function claimOrder(uint256 orderId, uint256 amount) external returns (uint256 claimId);

    /// @notice Confirm execution of a claim with a signed oracle price.
    /// @dev For mints: eTokens are minted to the user. For redeems: the protocol
    ///      verifies the VM has sent stablecoins, then burns the escrowed eTokens.
    /// @param claimId   Claim to confirm.
    /// @param priceData Signed oracle price data.
    function confirmOrder(uint256 claimId, bytes calldata priceData) external;

    // ──────────────────────────────────────────────────────────
    //  User operations
    // ──────────────────────────────────────────────────────────

    /// @notice Cancel an order. Only the unclaimed portion can be cancelled.
    ///         Escrowed stablecoins (Mint) or eTokens (Redeem) are returned.
    /// @param orderId Order to cancel.
    function cancelOrder(
        uint256 orderId
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Deadline enforcement
    // ──────────────────────────────────────────────────────────

    /// @notice Expire an order after its deadline. Callable by anyone.
    /// @dev For uncompleted redeem orders, triggers Tier 3 liquidation.
    ///      For uncompleted mint orders, returns escrowed stablecoins.
    /// @param orderId Order to expire.
    function expireOrder(
        uint256 orderId
    ) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the full details of an order.
    /// @param orderId Order identifier.
    /// @return order The order data.
    function getOrder(
        uint256 orderId
    ) external view returns (Order memory order);

    /// @notice Return the full details of a claim.
    /// @param claimId Claim identifier.
    /// @return claim The claim data.
    function getClaim(
        uint256 claimId
    ) external view returns (ClaimInfo memory claim);

    /// @notice Return all claim IDs for an order.
    /// @param orderId Order identifier.
    /// @return claimIds Array of claim IDs.
    function getOrderClaims(
        uint256 orderId
    ) external view returns (uint256[] memory claimIds);

    /// @notice Return all open order IDs for an asset.
    /// @param asset Asset ticker.
    /// @return orderIds Array of open order IDs.
    function getOpenOrders(
        bytes32 asset
    ) external view returns (uint256[] memory orderIds);

    /// @notice Return all order IDs for a user.
    /// @param user Minter address.
    /// @return orderIds Array of the user's order IDs.
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory orderIds);
}
