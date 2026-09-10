// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC7802} from "./external/IERC7802.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IEUSD — CDP stablecoin token
/// @notice Minimal ERC-20 + ERC-2612 (Permit) stablecoin. CDP supply changes go through
///         MINTER_ROLE — in production exactly one holder: the EUSDManager. Burns are
///         allowance-free and restricted to the same role, so the manager can retire debt
///         (repay / redeem / liquidate) directly from the payer's balance.
///
///         Crosschain transfers use the ERC-7802 surface ({crosschainMint}/{crosschainBurn}),
///         gated by per-bridge rolling rate limits rather than a role: a bridge's limits ARE its
///         authorization (zero limits = not a bridge), so a transport can never be authorized
///         without a bounded blast radius. Limits refill linearly over {LIMIT_DURATION} and are
///         set by the token admin; zeroing them instantly de-authorizes a compromised transport.
///
///         Accounting: with bridging, the per-chain CDP invariant becomes
///         `totalSupply() == EUSDManager.totalDebt + netBridgedIn()`; the strict
///         supply == debt equality holds only over the sum of all chains.
interface IEUSD is IERC20, IERC20Permit, IERC7802 {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Rolling rate-limit state for one bridge.
    /// @param mintMaxLimit  Max mintable per {LIMIT_DURATION} window (18 decimals). 0 = disabled.
    /// @param burnMaxLimit  Max burnable per {LIMIT_DURATION} window (18 decimals). 0 = disabled.
    /// @param mintRemaining Remaining mint capacity at `lastUpdate` (18 decimals).
    /// @param burnRemaining Remaining burn capacity at `lastUpdate` (18 decimals).
    /// @param lastUpdate    Timestamp the remaining values were last settled.
    struct BridgeConfig {
        uint256 mintMaxLimit;
        uint256 burnMaxLimit;
        uint256 mintRemaining;
        uint256 burnRemaining;
        uint256 lastUpdate;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a bridge's rate limits are set (0/0 de-authorizes it).
    /// @param bridge       Bridge / token-pool address.
    /// @param mintMaxLimit New per-window mint limit (18 decimals).
    /// @param burnMaxLimit New per-window burn limit (18 decimals).
    event BridgeLimitsSet(address indexed bridge, uint256 mintMaxLimit, uint256 burnMaxLimit);

    /// @notice Emitted when the global net-bridged-in ceiling changes.
    /// @param oldCap Previous ceiling (18 decimals).
    /// @param newCap New ceiling (18 decimals).
    event MaxNetBridgedInSet(uint256 oldCap, uint256 newCap);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice Zero-amount bridge calls are rejected (no spoofed bridge events).
    error ZeroAmount();

    /// @notice The caller's remaining bridge capacity cannot cover the request. Also raised for
    ///         callers with no limits configured (available == 0), i.e. non-bridges.
    /// @param requested Amount requested (18 decimals).
    /// @param available Caller's current available capacity (18 decimals).
    error BridgeLimitExceeded(uint256 requested, uint256 available);

    /// @notice A crosschain mint would push net-bridged-in above the global ceiling — the hard
    ///         cap on how much bridged eUSD this chain may hold beyond its own CDP backing.
    /// @param wouldBe Net-bridged-in the mint would produce (18 decimals, signed).
    /// @param cap     The ceiling (18 decimals).
    error GlobalBridgeCapExceeded(int256 wouldBe, uint256 cap);

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Role allowed to mint and burn. Held only by the EUSDManager.
    function MINTER_ROLE() external view returns (bytes32);

    /// @notice Rolling window over which bridge limits refill (seconds).
    function LIMIT_DURATION() external view returns (uint256);

    /// @notice A bridge's stored limit configuration (remaining values as of `lastUpdate`;
    ///         use {bridgeMintAvailable}/{bridgeBurnAvailable} for live values).
    /// @param bridge Bridge address.
    function bridgeConfig(
        address bridge
    ) external view returns (BridgeConfig memory);

    /// @notice A bridge's currently available mint capacity, including refill (18 decimals).
    /// @param bridge Bridge address.
    function bridgeMintAvailable(
        address bridge
    ) external view returns (uint256);

    /// @notice A bridge's currently available burn capacity, including refill (18 decimals).
    /// @param bridge Bridge address.
    function bridgeBurnAvailable(
        address bridge
    ) external view returns (uint256);

    /// @notice Net eUSD bridged onto this chain: Σ crosschainMint − Σ crosschainBurn. Negative on
    ///         a net-exporter chain. Monitoring invariant:
    ///         totalSupply() == EUSDManager.totalDebt + netBridgedIn().
    function netBridgedIn() external view returns (int256);

    /// @notice Hard ceiling on {netBridgedIn} — the maximum bridged eUSD this chain may hold above
    ///         its own CDP backing, enforced on every {crosschainMint} regardless of which bridge
    ///         or how slowly (the per-bridge rate limits bound velocity; this bounds the total).
    ///         Defaults to 0: a net-importer position is blocked until governance raises it, so the
    ///         home/CDP chain stays fully backed by construction while destination chains get an
    ///         explicit, capped allowance. Re-importing previously-exported eUSD is always allowed
    ///         (it only moves netBridgedIn back toward 0).
    function maxNetBridgedIn() external view returns (uint256);

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

    // ──────────────────────────────────────────────────────────
    //  Bridge administration (DEFAULT_ADMIN_ROLE)
    // ──────────────────────────────────────────────────────────

    /// @notice Set a bridge's per-window mint and burn limits. A fresh authorization (bridge
    ///         currently has zero limits) starts with a full window; updating a live bridge settles
    ///         its accrued capacity and clamps it to the new maxima (never a refill). Setting both
    ///         to zero de-authorizes it immediately (the emergency lever for a compromised
    ///         transport).
    /// @param bridge       Bridge / token-pool address.
    /// @param mintMaxLimit Max mint per {LIMIT_DURATION} window (18 decimals).
    /// @param burnMaxLimit Max burn per {LIMIT_DURATION} window (18 decimals).
    function setBridgeLimits(address bridge, uint256 mintMaxLimit, uint256 burnMaxLimit) external;

    /// @notice Set the global net-bridged-in ceiling. See {maxNetBridgedIn}. May be set below the
    ///         current {netBridgedIn}; that blocks further inbound bridging without disturbing
    ///         eUSD already on-chain (outbound bridging still relieves it).
    /// @param newCap New ceiling (18 decimals).
    function setMaxNetBridgedIn(
        uint256 newCap
    ) external;
}
