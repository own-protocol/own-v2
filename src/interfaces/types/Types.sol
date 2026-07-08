// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Types — Shared types for the Own Protocol

// ──────────────────────────────────────────────────────────────
//  Constants
// ──────────────────────────────────────────────────────────────

/// @dev Basis-point denominator (10 000 = 100%).
uint256 constant BPS = 10_000;

/// @dev Fixed-point precision for prices and per-share accumulators.
uint256 constant PRECISION = 1e18;

// ──────────────────────────────────────────────────────────────
//  Enums
// ──────────────────────────────────────────────────────────────

/// @notice Whether an order is a mint (buy eTokens) or redeem (sell eTokens).
enum OrderType {
    Mint,
    Redeem
}

/// @notice Lifecycle status of a resting (limit / redeem) order.
/// @dev Market orders execute atomically and are never persisted, so they have no status.
///      A partially filled order stays `Open` until its remaining amount reaches zero,
///      at which point it becomes `Filled`.
enum OrderStatus {
    Open,
    Filled,
    ForceExecuted,
    Cancelled,
    Expired
}

/// @notice Lifecycle status of an async LP withdrawal request.
enum WithdrawalStatus {
    Pending,
    Fulfilled,
    Cancelled
}

/// @notice Lifecycle status of an async LP deposit request.
enum DepositStatus {
    Pending,
    Accepted,
    Rejected,
    Cancelled
}

/// @notice Operating state of a collateral vault.
enum VaultStatus {
    Active,
    Paused,
    Halted
}

// ──────────────────────────────────────────────────────────────
//  Structs
// ──────────────────────────────────────────────────────────────

/// @notice A resting (limit / redeem) order escrowed by a user in the marketplace.
/// @dev Market orders execute atomically via a signed Quote and are never stored as Orders.
///      The VM (or a relayer) fills a resting order — possibly in several partial chunks —
///      by submitting VM-signed Quotes whose price satisfies `limitPrice`. Redeem orders
///      additionally support user force execution at the oracle price after the vault's
///      claim threshold elapses.
/// @param orderId      Unique order identifier.
/// @param user         Address that placed the order.
/// @param asset        Asset ticker (e.g. bytes32("TSLA")).
/// @param orderType    Mint or Redeem.
/// @param amount       Original input amount: stablecoins (Mint) or eTokens (Redeem).
/// @param filledAmount Cumulative input amount filled so far (≤ amount).
/// @param limitPrice   Max price per eToken (Mint) or min price per eToken (Redeem). 18 decimals.
/// @param createdAt    Timestamp when the order was placed.
/// @param expiry       Timestamp after which the order can be expired (good-til-date).
/// @param status       Current order status.
/// @param escrowToken  Token escrowed at placement (payment token for Mint, eToken for Redeem).
///                     Snapshotted so a later token migration cannot strand the escrow.
struct Order {
    uint256 orderId;
    address user;
    bytes32 asset;
    OrderType orderType;
    uint256 amount;
    uint256 filledAmount;
    uint256 limitPrice;
    uint256 createdAt;
    uint256 expiry;
    OrderStatus status;
    address escrowToken;
}

/// @notice A firm price quote signed off-chain by a protocol-authorised signer.
/// @dev For a market order `orderId` is 0 and the Quote carries the full order terms;
///      the taker (`user`) submits it and it executes atomically. For a resting-order
///      fill `orderId` references the stored Order and `amount` is the chunk to fill
///      (≤ the order's remaining amount). The signature is verified against the global
///      signer registry in VaultManager; mint proceeds flow to the signer's linked
///      address and redeem payouts come from it. Binds chainId + market address for
///      replay safety. Quotes are vault-less — the protocol pools risk globally and
///      uses one global payment token.
/// @param orderId   Target resting order (0 = market / atomic).
/// @param user      Taker bound to the quote (must be msg.sender for market orders).
/// @param asset     Asset ticker.
/// @param orderType Mint or Redeem.
/// @param amount    Input amount this quote fills: stablecoins (Mint) or eTokens (Redeem).
/// @param price     Execution price per eToken (18 decimals).
/// @param quoteId   Unique nonce, enforcing single use per quote.
/// @param expiry    Timestamp after which the quote is no longer valid.
struct Quote {
    uint256 orderId;
    address user;
    bytes32 asset;
    OrderType orderType;
    uint256 amount;
    uint256 price;
    uint256 quoteId;
    uint256 expiry;
}

/// @notice An async LP withdrawal request in the withdrawal queue.
/// @param requestId Unique request identifier.
/// @param owner     LP who requested the withdrawal.
/// @param shares    Number of vault shares to redeem.
/// @param timestamp When the request was submitted.
/// @param status    Current request status.
struct WithdrawalRequest {
    uint256 requestId;
    address owner;
    uint256 shares;
    uint256 timestamp;
    WithdrawalStatus status;
}

/// @notice Configuration for a whitelisted asset.
/// @param activeToken     Address of the current active eToken.
/// @param legacyTokens    Previous eToken addresses (post-split).
/// @param active          Whether the asset is active for new orders.
/// @param volatilityLevel Volatility tier for fee lookup (1=low, 2=medium, 3=high).
/// @param oracleType      Oracle backend (0 = Pyth, 1 = in-house).
struct AssetConfig {
    address activeToken;
    address[] legacyTokens;
    bool active;
    uint8 volatilityLevel;
    uint8 oracleType;
}

/// @notice An async LP deposit request.
/// @param requestId  Unique request identifier.
/// @param depositor  Address that initiated the deposit.
/// @param receiver   Address that will receive vault shares.
/// @param assets       Amount of collateral deposited.
/// @param minSharesOut Minimum shares the depositor will accept at acceptance time (slippage floor).
/// @param timestamp    When the request was submitted.
/// @param status       Current request status.
struct DepositRequest {
    uint256 requestId;
    address depositor;
    address receiver;
    uint256 assets;
    uint256 minSharesOut;
    uint256 timestamp;
    DepositStatus status;
}

/// @notice PSM configuration for one (asset, wrapper token) pair.
/// @param reserveVault  ReserveVault holding this wrapper as 1:1 backing (0 = not configured).
/// @param lastUsedRatio Conversion ratio (eTokens per wrapper unit, 1e18) at the last PSM
///                      operation; 0 = guard unarmed.
/// @param paused        Per-wrapper PSM pause (blocks psmMint / psmRedeem).
struct PsmConfig {
    address reserveVault;
    uint256 lastUsedRatio;
    bool paused;
}

/// @notice Onchain state for a registered vault manager.
/// @param maxExposure     Max USD notional the VM will hedge (18 decimals).
/// @param currentExposure Current outstanding notional (18 decimals).
/// @param registered      Whether the VM is registered.
/// @param active          Whether the VM is currently active.
struct VMConfig {
    uint256 maxExposure;
    uint256 currentExposure;
    bool registered;
    bool active;
}
