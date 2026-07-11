// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAaveV3Pool} from "./external/IAaveV3Pool.sol";

/// @title IOwnLendingPool — Single-asset, zero-rate lending pool (Aave V3 pool subset)
/// @notice Protocol-owned replacement for an external Aave V3 deployment. Holds one
///         stablecoin reserve, issues a 1:1 aToken, and tracks principal-only debt
///         (no interest accrual at the pool level — all interest is charged by the
///         BorrowManager premium layer). Implements exactly the {IAaveV3Pool} subset
///         the protocol consumes (AaveRouter supply/withdraw, BorrowManager
///         delegated borrow/repay, OwnVault collateral wiring), so it is a drop-in
///         `aavePool` for those contracts.
///
///         Deliberate omissions vs Aave: no liquidation (with a zero rate, a
///         position's health factor only changes at gated `borrow`/`withdraw`/
///         aToken-transfer sites, so HF < 1 is unreachable), no flashloans, no
///         interest indexes (fixed at 1 RAY).
interface IOwnLendingPool is IAaveV3Pool {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when underlying is supplied and aTokens are minted 1:1.
    /// @param caller     Allowed supplier that provided the underlying.
    /// @param onBehalfOf Account credited with the newly minted aTokens.
    /// @param amount     Underlying supplied (== aTokens minted), in underlying units.
    event Supplied(address indexed caller, address indexed onBehalfOf, uint256 amount);

    /// @notice Emitted when aTokens are burned and underlying is withdrawn.
    /// @param caller Account whose aTokens were burned.
    /// @param to     Recipient of the underlying.
    /// @param amount Underlying withdrawn (== aTokens burned), in underlying units.
    event Withdrawn(address indexed caller, address indexed to, uint256 amount);

    /// @notice Emitted when debt is opened and underlying is disbursed to the caller.
    /// @param caller     Borrower or delegatee that received the underlying.
    /// @param onBehalfOf Account whose debt balance increased (== caller for self-borrows).
    /// @param amount     Underlying borrowed, in underlying units.
    event Borrowed(address indexed caller, address indexed onBehalfOf, uint256 amount);

    /// @notice Emitted when debt is repaid.
    /// @param caller     Account that paid the underlying.
    /// @param onBehalfOf Account whose debt balance decreased.
    /// @param amount     Debt actually repaid (may be less than the requested amount), in underlying units.
    event Repaid(address indexed caller, address indexed onBehalfOf, uint256 amount);

    /// @notice Emitted when a supplier's allowlist entry is set.
    /// @param supplier Address whose supply permission changed.
    /// @param allowed  New permission (true = may call {supply}).
    event SupplierAllowedUpdated(address indexed supplier, bool allowed);

    /// @notice Emitted on construction and whenever the LTV/LT configuration changes.
    /// @param ltvBps                  New borrow LTV (BPS).
    /// @param liquidationThresholdBps New liquidation threshold (BPS).
    event LtvConfigUpdated(uint256 ltvBps, uint256 liquidationThresholdBps);

    /// @notice Compatibility record mirroring an Aave `setUserUseReserveAsCollateral` call.
    /// @dev    Collateral is always counted by this pool regardless of the flag (see the
    ///         function NatSpec); the event exists only for interface parity and indexers.
    /// @param user    Caller that toggled the (no-op) collateral flag.
    /// @param enabled The requested flag value.
    event CollateralUseSet(address indexed user, bool enabled);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller does not hold the registry ADMIN role.
    error OnlyAdmin();

    /// @notice Zero address argument.
    error ZeroAddress();

    /// @notice Zero amount argument.
    error ZeroAmount();

    /// @notice `asset` is not this pool's single registered underlying.
    /// @param asset The unrecognized reserve asset passed by the caller.
    error UnknownReserve(address asset);

    /// @notice Caller is not on the supplier allowlist.
    /// @param caller The disallowed caller of {supply}.
    error SupplierNotAllowed(address caller);

    /// @notice Borrow would push `user`'s debt above `ltvBps` of their aToken collateral.
    /// @dev Because `ltvBps <= liquidationThresholdBps <= BPS` and debt never accrues
    ///      interest, this gate also guarantees pool-level exit liquidity: aggregate
    ///      borrow headroom can never exceed available liquidity, so any aToken
    ///      holder can always withdraw their full balance (LP exits are queued by
    ///      protocol utilization limits, never stranded by the pool).
    /// @param user The account whose borrow was rejected for insufficient collateral.
    error InsufficientCollateral(address user);

    /// @notice Repay attempted with no outstanding debt (Aave V3 error '39' parity).
    error NoDebtOfSelectedType();

    /// @notice Withdraw or aToken transfer would leave `user`'s debt above the
    ///         liquidation threshold share of their remaining collateral (HF < 1).
    /// @param user The account whose remaining collateral fails the health check.
    error HealthCheckFailed(address user);

    /// @notice LTV/LT config rejected: require 0 < ltv <= lt <= BPS.
    /// @param ltvBps                  The rejected borrow LTV.
    /// @param liquidationThresholdBps The rejected liquidation threshold.
    error InvalidLtvConfig(uint256 ltvBps, uint256 liquidationThresholdBps);

    /// @notice The underlying moved fewer tokens than requested (fee-on-transfer
    ///         tokens are unsupported; asserted on every inbound transfer).
    error FeeOnTransferNotSupported();

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Allow or disallow `supplier` to call {supply}. Supply is
    ///         allowlist-gated (router-only by policy); every other entry point
    ///         is permissionless, mirroring Aave.
    /// @param supplier Caller to update.
    /// @param allowed  True to allow.
    function setSupplierAllowed(address supplier, bool allowed) external;

    /// @notice Update borrow LTV and liquidation threshold (both BPS).
    /// @dev Bounds: 0 < ltvBps_ <= liquidationThresholdBps_ <= BPS. Raising LT
    ///      never strands positions; lowering it can gate future withdrawals only
    ///      (there is no liquidation path to punish existing positions).
    /// @param ltvBps_                  Max debt as a share of aToken collateral at borrow time.
    /// @param liquidationThresholdBps_ Max debt share enforced on withdraw / aToken transfer.
    function setLtvConfig(uint256 ltvBps_, uint256 liquidationThresholdBps_) external;

    // ──────────────────────────────────────────────────────────
    //  aToken hook
    // ──────────────────────────────────────────────────────────

    /// @notice Post-transfer health validation, called by the pool's aToken on every
    ///         user-to-user transfer (mirrors Aave's `finalizeTransfer`). Reverts with
    ///         {HealthCheckFailed} if `from`'s remaining collateral no longer covers
    ///         their debt at the liquidation threshold.
    /// @param from Address whose balance decreased in the transfer being validated.
    function validateTransfer(
        address from
    ) external view;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice The pool's single underlying reserve asset (the lending stablecoin).
    /// @return The underlying token address.
    function underlying() external view returns (address);

    /// @notice The pool's 1:1 aToken (what OwnVault holds as its ERC-4626 asset).
    /// @return The aToken address.
    function aToken() external view returns (address);

    /// @notice The pool's non-transferable variable debt token (credit-delegation surface).
    /// @return The variable debt token address.
    function variableDebtToken() external view returns (address);

    /// @notice Borrow LTV in BPS (max debt share of collateral at borrow time).
    /// @return The borrow LTV in basis points.
    function ltvBps() external view returns (uint256);

    /// @notice Liquidation threshold in BPS (max debt share enforced on exits).
    /// @return The liquidation threshold in basis points.
    function liquidationThresholdBps() external view returns (uint256);

    /// @notice Whether `supplier` may call {supply}.
    /// @param supplier The address to query.
    /// @return True if `supplier` is on the allowlist.
    function supplierAllowed(
        address supplier
    ) external view returns (bool);

    /// @notice Principal debt of `user` (no interest accrues at the pool level).
    /// @param user The account to query.
    /// @return The account's outstanding debt, in underlying units.
    function debtOf(
        address user
    ) external view returns (uint256);

    /// @notice Sum of all outstanding principal debt.
    /// @return The total outstanding debt, in underlying units.
    function totalDebt() external view returns (uint256);

    /// @notice Underlying held by the pool and available for borrows/withdrawals.
    /// @return The pool's underlying balance, in underlying units.
    function availableLiquidity() external view returns (uint256);
}
