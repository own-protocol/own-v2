// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Types — Shared types for the Own Protocol
/// @notice Enums, structs, and constants used across multiple protocol interfaces.

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

/// @notice Whether the user wants market execution (with slippage) or a limit price.
enum PriceType {
    Market,
    Limit
}

/// @notice Lifecycle status of an order in the escrow marketplace.
enum OrderStatus {
    Open,
    PartiallyClaimed,
    FullyClaimed,
    PartiallyConfirmed,
    Confirmed,
    Cancelled,
    Expired
}

/// @notice Lifecycle status of an async LP withdrawal request.
enum WithdrawalStatus {
    Pending,
    Fulfilled,
    Cancelled
}

/// @notice Operating state of a collateral vault.
enum VaultStatus {
    Active,
    Halted,
    WindingDown
}

// ──────────────────────────────────────────────────────────────
//  Structs
// ──────────────────────────────────────────────────────────────

/// @notice An order placed by a minter in the escrow marketplace.
/// @param orderId       Unique order identifier.
/// @param user          Minter who placed the order.
/// @param orderType     Mint or Redeem.
/// @param priceType     Market or Limit.
/// @param asset         Asset ticker (e.g. bytes32("TSLA")).
/// @param stablecoin    Payment / payout token address.
/// @param amount        Stablecoin amount (Mint) or eToken amount (Redeem).
/// @param slippage      Max oracle-price movement tolerance in BPS (Market orders only; 0 for Limit).
/// @param limitPrice    Exact execution price in 18-decimal (Limit orders only; 0 for Market).
/// @param deadline      Timestamp after which the order expires.
/// @param allowPartialFill  Whether partial fills are accepted.
/// @param preferredVM   Directed-order target (address(0) for open orders).
/// @param placementPrice Oracle price at order placement (18 decimals).
/// @param filledAmount  Amount claimed / confirmed so far.
/// @param status        Current order status.
/// @param createdAt     Timestamp when the order was placed.
struct Order {
    uint256 orderId;
    address user;
    OrderType orderType;
    PriceType priceType;
    bytes32 asset;
    address stablecoin;
    uint256 amount;
    uint256 slippage;
    uint256 limitPrice;
    uint256 deadline;
    bool allowPartialFill;
    address preferredVM;
    uint256 placementPrice;
    uint256 filledAmount;
    OrderStatus status;
    uint256 createdAt;
}

/// @notice A claim on an order made by a vault manager.
/// @param claimId        Unique claim identifier.
/// @param orderId        The order being claimed.
/// @param vm             Vault manager who claimed.
/// @param vault          Vault whose collateral backs this claim.
/// @param amount         Portion of the order claimed.
/// @param executionPrice Oracle price at confirmation (18 decimals; 0 until confirmed).
/// @param confirmed      Whether the VM has confirmed execution.
/// @param claimedAt      Timestamp of the claim.
struct ClaimInfo {
    uint256 claimId;
    uint256 orderId;
    address vm;
    address vault;
    uint256 amount;
    uint256 executionPrice;
    bool confirmed;
    uint256 claimedAt;
}

/// @notice An async LP withdrawal request in the FIFO queue.
/// @param requestId  Unique request identifier.
/// @param owner      LP who requested the withdrawal.
/// @param shares     Number of vault shares to redeem.
/// @param timestamp  When the request was submitted.
/// @param status     Current request status.
struct WithdrawalRequest {
    uint256 requestId;
    address owner;
    uint256 shares;
    uint256 timestamp;
    WithdrawalStatus status;
}

/// @notice Configuration for a whitelisted asset.
/// @param activeToken           Address of the current active eToken.
/// @param legacyTokens          Previous eToken addresses (post-split).
/// @param minCollateralRatio    Minimum collateral ratio in BPS (e.g. 11_000 = 110%).
/// @param liquidationThreshold  Ratio below which liquidation is triggered, in BPS.
/// @param liquidationReward     Liquidator discount in BPS.
/// @param active                Whether the asset is active for new orders.
/// @dev Oracle config (staleness, deviation) lives in IOracleVerifier as the single source of truth.
struct AssetConfig {
    address activeToken;
    address[] legacyTokens;
    uint256 minCollateralRatio;
    uint256 liquidationThreshold;
    uint256 liquidationReward;
    bool active;
}

/// @notice Onchain state for a registered vault manager.
/// @param spread               VM's posted spread in BPS (>= minSpread).
/// @param maxExposure          Max USD notional the VM will hedge (18 decimals).
/// @param maxOffMarketExposure Max exposure during off-market hours (18 decimals).
/// @param currentExposure      Current outstanding notional (18 decimals).
/// @param registered           Whether the VM is registered.
/// @param active               Whether the VM is currently active.
struct VMConfig {
    uint256 spread;
    uint256 maxExposure;
    uint256 maxOffMarketExposure;
    uint256 currentExposure;
    bool registered;
    bool active;
}
