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
    /// @param maker The signer's linked settlement address (mint sink / redeem source).
    event OrderExecuted(
        uint256 indexed quoteId,
        address indexed user,
        address indexed maker,
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
        uint256 amount,
        uint256 limitPrice
    );

    /// @notice Emitted when a resting order is filled (fully or partially) against a signed quote.
    /// @param remaining Input amount still outstanding after this fill (0 = fully filled).
    event OrderFilled(
        uint256 indexed orderId,
        uint256 indexed quoteId,
        address indexed maker,
        uint256 fillAmount,
        uint256 amountOut,
        uint256 remaining
    );

    /// @notice Emitted when a user force-executes the remaining amount of a redeem order.
    event OrderForceExecuted(uint256 indexed orderId, address indexed user, uint256 fillAmount, uint256 collateralOut);

    /// @notice Emitted when a holder redeems a halted asset against the halt redeem address.
    event OrderRedeemedHalted(address indexed user, bytes32 indexed asset, uint256 eTokenAmount, uint256 payout);

    /// @notice Emitted when a holder converts a legacy token to the active token after a migration.
    event LegacyConverted(
        address indexed user, bytes32 indexed asset, address indexed legacyToken, uint256 amountIn, uint256 amountOut
    );

    /// @notice Emitted when a user cancels the remaining amount of a resting order.
    event OrderCancelled(uint256 indexed orderId, address indexed user);

    /// @notice Emitted when an expired resting order is closed and its escrow returned.
    event OrderExpired(uint256 indexed orderId);

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

    /// @notice The recovered quote signer is not an authorised protocol signer.
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

    /// @notice The asset price proof's timestamp is outside the order's live window [createdAt, now].
    error AssetPriceProofOutsideWindow();

    /// @notice The collateral price proof is stale; force execution requires a current collateral price.
    error StaleCollateralPrice();

    /// @notice The asset is not active in the registry.
    error AssetNotActive(bytes32 asset);

    /// @notice The collateral oracle is not configured.
    error CollateralOracleNotSet();

    /// @notice The vault is not registered in the factory.
    error VaultNotRegistered(address vault);

    /// @notice The named vault's collateral is excluded from the global pool (halted / winding down),
    ///         so it cannot be drawn on for force execution.
    error VaultExcludedFromPool(address vault);

    /// @notice The global payment token is not configured.
    error PaymentTokenNotSet();

    /// @notice Trading for the asset is paused (global or per-asset).
    error AssetPaused(bytes32 asset);

    /// @notice Mint operations are blocked because the asset is halted.
    error MintBlockedDuringHalt(bytes32 asset);

    /// @notice Normal trading is blocked because the asset is halted; use redeemHalted instead.
    error TradingHalted(bytes32 asset);

    /// @notice Force execution is disabled for a halted asset; use redeemHalted instead.
    error ForceDisabledDuringHalt(bytes32 asset);

    /// @notice The asset is not halted (redeemHalted is only valid for halted assets).
    error AssetNotHalted(bytes32 asset);

    /// @notice The halt redeem address is not configured.
    error HaltRedeemAddressNotSet();

    /// @notice The order's escrowed token was migrated to a legacy token; recover via cancel/expire.
    error OrderTokenMigrated(uint256 orderId);

    /// @notice The token is not a legacy token of the asset.
    error NotLegacyToken(address token);

    /// @notice No conversion ratio is configured for the legacy token.
    error RatioNotSet(address token);

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

    /// @notice Place a resting limit / redeem order, escrowing the input. Orders are vault-less;
    ///         the collateral source for a forced redeem is named at force-execution time.
    ///         Mint escrows stablecoins; redeem escrows eTokens. Returned on cancel / expire.
    /// @param asset      Asset ticker.
    /// @param orderType  Mint or Redeem.
    /// @param amount     Input amount: stablecoins (Mint) or eTokens (Redeem).
    /// @param limitPrice Max price per eToken (Mint) or min price per eToken (Redeem). 18 decimals.
    /// @param expiry     Good-til-date timestamp after which the order can be expired.
    /// @return orderId   The unique order identifier.
    function placeOrder(
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
    ///         once the global claim threshold has elapsed. User recourse against an
    ///         unresponsive maker. The caller names the registered `vault` to draw collateral
    ///         from; releases that vault's collateral to the user and burns the escrowed eTokens.
    ///         Disabled while trading is paused or the asset is halted.
    /// @dev    For Pyth oracle: caller must send ETH to cover verifyPrice fees; unused ETH is refunded.
    ///         For the in-house oracle, msg.value should be 0.
    /// @param orderId             Redeem order to force-execute.
    /// @param vault               Registered vault to release collateral from.
    /// @param assetPriceData      Signed oracle price proof for the asset (eToken → USD).
    /// @param collateralPriceData Signed oracle price proof for the collateral (USD → collateral).
    function forceExecuteOrder(
        uint256 orderId,
        address vault,
        bytes calldata assetPriceData,
        bytes calldata collateralPriceData
    ) external payable;

    /// @notice Redeem a permanently halted asset at its fixed halt price. The payout is the global
    ///         payment token, pulled from the halt redeem address configured on VaultManager.
    ///         Burns `eTokenAmount` from the caller and reduces global exposure. Reverts if the
    ///         asset is not halted, the halt redeem address is unset, or it lacks stables/allowance.
    /// @param asset        Asset ticker (must be halted).
    /// @param eTokenAmount eToken amount to redeem.
    /// @return payout      Payment-token amount paid to the caller.
    function redeemHalted(bytes32 asset, uint256 eTokenAmount) external returns (uint256 payout);

    /// @notice Convert a legacy token to the current active token at the asset's migration ratio.
    /// @dev Burns `amount` legacy and mints `amount * ratio / 1e18` active to the caller. Allowed
    ///      while trading is paused/halted so legacy holders can always reach the active token.
    /// @param asset       Asset ticker.
    /// @param legacyToken Legacy token to convert.
    /// @param amount      Legacy token amount to convert.
    /// @return newAmount  Active token amount minted.
    function convertLegacy(bytes32 asset, address legacyToken, uint256 amount) external returns (uint256 newAmount);

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
