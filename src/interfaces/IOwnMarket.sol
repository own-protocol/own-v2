// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Order, OrderType, Quote} from "./types/Types.sol";

/// @title IOwnMarket — RFQ order execution marketplace
/// @notice Users execute mint/redeem orders against firm, VM-signed quotes.
///         - Market orders: the user submits a VM-signed Quote and it settles atomically (one tx).
///         - Limit orders: the user places a resting order (escrowing the input); the VM — or a
///           relayer carrying a VM-signed Quote — fills it, possibly in several partial chunks,
///           at any price satisfying the order's limit.
///         - Redeem orders are resting orders that additionally let the user force execution at
///           the oracle price once the vault's claim threshold elapses, as recourse against an
///           unresponsive VM. Mint orders have no force path (cancel / expire only).
interface IOwnMarket {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a market order settles atomically against a signed quote.
    event OrderExecuted(
        uint256 indexed quoteId,
        address indexed user,
        address indexed vm,
        bytes32 asset,
        uint8 orderType,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when a user places a resting (limit / redeem) order.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed user,
        uint8 orderType,
        bytes32 indexed asset,
        address vault,
        uint256 amount,
        uint256 limitPrice
    );

    /// @notice Emitted when a resting order is filled (fully or partially) against a signed quote.
    /// @param remaining Input amount still outstanding after this fill (0 = fully filled).
    event OrderFilled(
        uint256 indexed orderId,
        uint256 indexed quoteId,
        address indexed vm,
        uint256 fillAmount,
        uint256 amountOut,
        uint256 remaining
    );

    /// @notice Emitted when a user force-executes the remaining amount of a redeem order.
    event OrderForceExecuted(uint256 indexed orderId, address indexed user, uint256 fillAmount, uint256 collateralOut);

    /// @notice Emitted when a user cancels the remaining amount of a resting order.
    event OrderCancelled(uint256 indexed orderId, address indexed user);

    /// @notice Emitted when an expired resting order is closed and its escrow returned.
    event OrderExpired(uint256 indexed orderId);

    /// @notice Emitted when a protocol fee is collected during settlement.
    event FeeCollected(uint256 indexed orderId, address indexed token, uint256 feeAmount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The order does not exist.
    error OrderNotFound(uint256 orderId);

    /// @notice The order is not in the expected status.
    error InvalidOrderStatus(uint256 orderId);

    /// @notice Only the order owner can perform this action.
    error OnlyOrderOwner(uint256 orderId);

    /// @notice The order's expiry has not been reached yet.
    error ExpiryNotReached(uint256 orderId);

    /// @notice The resting order's good-til-date expiry has passed.
    error OrderExpiredError(uint256 orderId);

    /// @notice The redeem force window (claim threshold) has not elapsed.
    error ForceWindowNotElapsed(uint256 orderId);

    /// @notice Force execution is not available for mint orders.
    error ForceMintNotAllowed(uint256 orderId);

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice The price (or limit price) is invalid (zero).
    error InvalidPrice();

    /// @notice The expiry timestamp is invalid.
    error InvalidExpiry();

    /// @notice The quote has passed its expiry.
    error QuoteExpired();

    /// @notice The recovered quote signer is not the vault's VM.
    error InvalidQuoteSigner();

    /// @notice The quote has already been used (replay protection).
    error QuoteAlreadyUsed();

    /// @notice The caller is not the taker the quote was issued to.
    error NotQuoteUser();

    /// @notice A market quote must carry orderId 0; a fill quote must carry a non-zero orderId.
    error QuoteOrderMismatch();

    /// @notice The quote's terms do not match the target resting order.
    error QuoteTermsMismatch();

    /// @notice The quote price does not satisfy the order's limit price.
    error LimitNotSatisfied();

    /// @notice The fill amount exceeds the order's remaining amount.
    error FillExceedsRemaining(uint256 orderId);

    /// @notice The oracle price is below the order's minimum (limit) price at force time.
    error PriceBelowMinimum();

    /// @notice The asset is not active in the registry.
    error AssetNotActive(bytes32 asset);

    /// @notice The claim/fill would breach the vault's max utilization.
    error UtilizationBreached(uint256 currentUtilization, uint256 maxUtilization);

    /// @notice The collateral oracle is not configured.
    error CollateralOracleNotSet();

    /// @notice The vault is not registered in the factory.
    error VaultNotRegistered(address vault);

    /// @notice The vault does not support the requested asset.
    error VaultAssetNotSupported(address vault, bytes32 asset);

    /// @notice The vault's payment token is not configured.
    error PaymentTokenNotSet(address vault);

    /// @notice The asset is paused (vault-wide or per-asset).
    error AssetPaused(bytes32 asset);

    /// @notice Mint operations are blocked because the asset is halted.
    error MintBlockedDuringHalt(bytes32 asset);

    /// @notice Normal trading is blocked because the asset is halted; use force execution (redeem).
    error TradingHalted(bytes32 asset);

    /// @notice No oracle is configured for the asset.
    error AssetOracleNotSet(bytes32 asset);

    /// @notice The halt price is not set or is invalid.
    error InvalidHaltPrice();

    /// @notice ETH refund to caller failed at end of force execution.
    error ETHRefundFailed();

    // ──────────────────────────────────────────────────────────
    //  Market orders (atomic)
    // ──────────────────────────────────────────────────────────

    /// @notice Execute a market order atomically against a VM-signed quote.
    ///         Mint: pulls the taker's stablecoins (net to VM, fee to vault) and mints eTokens.
    ///         Redeem: pulls the VM's stablecoins (net to taker, fee to vault) and burns the taker's eTokens.
    /// @dev    `quote.orderId` must be 0 and `quote.user` must equal msg.sender.
    /// @param quote     The VM-signed quote carrying the full order terms and execution price.
    /// @param signature The VM's ECDSA signature over the quote digest.
    function executeOrder(Quote calldata quote, bytes calldata signature) external;

    // ──────────────────────────────────────────────────────────
    //  Resting orders (limit / redeem)
    // ──────────────────────────────────────────────────────────

    /// @notice Place a resting limit / redeem order, escrowing the input.
    ///         Mint escrows stablecoins; redeem escrows eTokens. Returned on cancel / expire.
    /// @param vault      Vault to trade against (must be registered and support the asset).
    /// @param asset      Asset ticker.
    /// @param orderType  Mint or Redeem.
    /// @param amount     Input amount: stablecoins (Mint) or eTokens (Redeem).
    /// @param limitPrice Max price per eToken (Mint) or min price per eToken (Redeem). 18 decimals.
    /// @param expiry     Good-til-date timestamp after which the order can be expired.
    /// @return orderId   The unique order identifier.
    function placeOrder(
        address vault,
        bytes32 asset,
        OrderType orderType,
        uint256 amount,
        uint256 limitPrice,
        uint256 expiry
    ) external returns (uint256 orderId);

    /// @notice Fill a resting order (fully or partially) against a VM-signed quote.
    ///         Callable by anyone carrying a valid VM-signed quote (VM or its relayer).
    /// @dev    `quote.orderId` must reference the order; `quote.amount` is the chunk to fill
    ///         (≤ remaining) and `quote.price` must satisfy the order's limit price.
    /// @param quote     The VM-signed quote.
    /// @param signature The VM's ECDSA signature over the quote digest.
    function fillOrder(Quote calldata quote, bytes calldata signature) external;

    /// @notice Force-execute the remaining amount of a redeem order at the oracle price,
    ///         once the vault's claim threshold has elapsed. User recourse against an
    ///         unresponsive VM. Releases vault collateral to the user and burns the escrowed eTokens.
    /// @dev    For Pyth oracle: caller must send ETH to cover verifyPrice fees; unused ETH is refunded.
    ///         For the in-house oracle, msg.value should be 0.
    /// @param orderId             Redeem order to force-execute.
    /// @param assetPriceData      Signed oracle price proof for the asset (eToken → USD).
    /// @param collateralPriceData Signed oracle price proof for the collateral (USD → collateral).
    function forceExecuteOrder(
        uint256 orderId,
        bytes calldata assetPriceData,
        bytes calldata collateralPriceData
    ) external payable;

    /// @notice Cancel the remaining amount of a resting order and return its escrow.
    /// @param orderId Order to cancel.
    function cancelOrder(
        uint256 orderId
    ) external;

    /// @notice Expire a resting order after its good-til-date and return its escrow. Callable by anyone.
    /// @param orderId Order to expire.
    function expireOrder(
        uint256 orderId
    ) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the full details of a resting order.
    function getOrder(
        uint256 orderId
    ) external view returns (Order memory order);

    /// @notice Return all resting order IDs placed by a user.
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory orderIds);

    /// @notice Whether a quote (by its digest) has already been used.
    function isQuoteUsed(
        bytes32 quoteDigest
    ) external view returns (bool);

    /// @notice Compute the EIP-191 digest a VM signs for a given quote.
    function quoteDigest(
        Quote calldata quote
    ) external view returns (bytes32);
}
