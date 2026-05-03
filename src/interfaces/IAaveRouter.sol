// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IAaveRouter — Multi-reserve periphery router for Aave V3 ↔ OwnVault
/// @notice Stateless deposit/withdraw helper for any registered Aave V3 reserve
///         (e.g. wstETH, WETH, wBTC). Supplies the underlying to Aave on the
///         router's own behalf, then deposits the resulting aToken into an
///         OwnVault via standard `IERC4626.deposit`.
///
///         The pool is set at construction. Reserves are added by an admin via
///         `registerReserve(underlying, aToken)`. Once registered, the
///         `(underlying, aToken)` pair is immutable — the admin can only flip
///         `enabled` to pause or resume routing through that reserve.
interface IAaveRouter {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Per-reserve metadata.
    /// @param aToken  Aave aToken paired with the underlying. Zero if unregistered.
    /// @param enabled Whether deposit/withdraw is currently allowed.
    struct ReserveInfo {
        address aToken;
        bool enabled;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when an admin registers a new reserve. One-shot per `underlying`.
    event ReserveRegistered(address indexed underlying, address indexed aToken);

    /// @notice Emitted when an admin enables or disables a registered reserve.
    event ReserveEnabledChanged(address indexed underlying, bool enabled);

    /// @notice Emitted when underlying is supplied to Aave and shares are minted.
    event Deposit(
        address indexed vault,
        address indexed sender,
        address indexed receiver,
        address underlying,
        uint256 underlyingAmount,
        uint256 shares
    );

    /// @notice Emitted when aToken is burned back to underlying via Aave withdrawal.
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed underlying,
        uint256 aTokenAmount,
        uint256 underlyingAmount
    );

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice A zero address was provided.
    error ZeroAddress();

    /// @notice Caller is not the protocol admin.
    error OnlyAdmin();

    /// @notice The reserve is not registered.
    error ReserveNotRegistered(address underlying);

    /// @notice The reserve is already registered (mapping is append-only).
    error ReserveAlreadyRegistered(address underlying);

    /// @notice The reserve exists but is currently disabled.
    error ReserveDisabled(address underlying);

    /// @notice Slippage check failed.
    error MinSharesError(uint256 shares, uint256 minSharesOut);

    /// @notice The vault's underlying asset does not match the reserve's aToken.
    error VaultAssetMismatch(address expected, address actual);

    // ──────────────────────────────────────────────────────────
    //  Reserve management (admin)
    // ──────────────────────────────────────────────────────────

    /// @notice Register a new reserve. One-shot per `underlying` — reverts if
    ///         the underlying is already registered. Sets `enabled = true` and
    ///         pre-approves the pool to pull the underlying.
    /// @param underlying Reserve underlying asset (e.g. wstETH).
    /// @param aToken     Aave aToken paired with the underlying.
    function registerReserve(address underlying, address aToken) external;

    /// @notice Enable or disable an already-registered reserve.
    function setReserveEnabled(address underlying, bool enabled) external;

    /// @notice Return the reserve metadata for an underlying (zero aToken if unregistered).
    function reserves(
        address underlying
    ) external view returns (address aToken, bool enabled);

    // ──────────────────────────────────────────────────────────
    //  Deposit / withdraw
    // ──────────────────────────────────────────────────────────

    /// @notice Supply `underlying` to Aave V3 and deposit the resulting aToken
    ///         into `vault`, minting shares to `receiver`.
    /// @dev    Pulls underlying from the caller, calls
    ///         `pool.supply(underlying, amount, onBehalfOf=address(this))` so
    ///         the aToken lands in the router, then approves and calls
    ///         `vault.deposit(aTokenAmount, receiver)`.
    /// @param underlying       Registered reserve underlying.
    /// @param vault            OwnVault whose underlying is the matching aToken.
    /// @param underlyingAmount Amount of underlying to supply.
    /// @param receiver         Address to receive vault shares.
    /// @param minSharesOut     Minimum acceptable shares (slippage protection).
    /// @return shares Vault shares minted to `receiver`.
    function deposit(
        address underlying,
        IERC4626 vault,
        uint256 underlyingAmount,
        address receiver,
        uint256 minSharesOut
    ) external returns (uint256 shares);

    /// @notice Withdraw `underlying` from Aave V3 by burning aToken the caller holds.
    /// @param underlying    Registered reserve underlying.
    /// @param aTokenAmount  Amount of aToken to redeem (or `type(uint256).max`).
    /// @param receiver      Address to receive the underlying.
    /// @return underlyingAmount Amount of underlying returned by Aave.
    function withdraw(
        address underlying,
        uint256 aTokenAmount,
        address receiver
    ) external returns (uint256 underlyingAmount);

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Aave V3 Pool used by this router.
    function pool() external view returns (address);
}
