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

/// @notice Lifecycle status of an order.
enum OrderStatus {
    Open,
    Claimed,
    Confirmed,
    Cancelled,
    Expired,
    Closed,
    ForceExecuted
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

/// @notice An order placed by a user in the escrow marketplace.
/// @param orderId   Unique order identifier.
/// @param user      Address that placed the order.
/// @param orderType Mint or Redeem.
/// @param asset     Asset ticker (e.g. bytes32("TSLA")).
/// @param amount    Stablecoin amount (Mint) or eToken amount (Redeem).
/// @param price     Max price per eToken (Mint) or min price per eToken (Redeem). 18 decimals.
/// @param expiry    Timestamp after which the order can be expired.
/// @param status    Current order status.
/// @param createdAt Timestamp when the order was placed.
/// @param vm        VM that claimed the order (address(0) if unclaimed).
/// @param vault     Vault backing the claim (address(0) if unclaimed).
/// @param claimedAt Timestamp of the claim (0 if unclaimed).
struct Order {
    uint256 orderId;
    address user;
    OrderType orderType;
    bytes32 asset;
    uint256 amount;
    uint256 price;
    uint256 expiry;
    OrderStatus status;
    uint256 createdAt;
    address vm;
    address vault;
    uint256 claimedAt;
}

/// @notice An async LP withdrawal request in the FIFO queue.
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
/// @param assets     Amount of collateral deposited.
/// @param timestamp  When the request was submitted.
/// @param status     Current request status.
struct DepositRequest {
    uint256 requestId;
    address depositor;
    address receiver;
    uint256 assets;
    uint256 timestamp;
    DepositStatus status;
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
