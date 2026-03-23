// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultStatus, WithdrawalRequest} from "./types/Types.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IOwnVault — ERC-4626 collateral vault with async withdrawal and health tracking
/// @notice Each vault holds one LP collateral type (USDC, aUSDC, WETH, wstETH)
///         as trustless security for outstanding eToken exposure. Extends
///         ERC-4626 for LP share accounting and adds:
///         - Async withdrawal queue (ERC-7540 FIFO pattern).
///         - Health factor and utilization tracking.
///         - Halt / unhalt / wind-down mechanisms.
///         - AUM fee and reserve factor for protocol revenue.
///
/// @dev Standard ERC-4626 `deposit` works normally. `maxWithdraw` / `maxRedeem`
///      return 0 when utilization prevents instant withdrawal, signalling that
///      LPs must use `requestWithdrawal` for async exit. This is ERC-4626
///      compliant per the spec.
interface IOwnVault is IERC4626 {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when an LP submits an async withdrawal request.
    /// @param requestId Unique request identifier.
    /// @param owner     LP who submitted the request.
    /// @param shares    Number of vault shares to redeem.
    event WithdrawalRequested(uint256 indexed requestId, address indexed owner, uint256 shares);

    /// @notice Emitted when an LP cancels a pending withdrawal request.
    /// @param requestId Request identifier.
    /// @param owner     LP who cancelled.
    event WithdrawalCancelled(uint256 indexed requestId, address indexed owner);

    /// @notice Emitted when a withdrawal request is fulfilled from the FIFO queue.
    /// @param requestId Request identifier.
    /// @param owner     LP who receives assets.
    /// @param assets    Amount of underlying assets transferred.
    /// @param shares    Number of vault shares burned.
    event WithdrawalFulfilled(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted when the vault is halted.
    /// @param reason A short identifier for the halt reason.
    event VaultHalted(bytes32 indexed reason);

    /// @notice Emitted when the vault is unhalted.
    event VaultUnhalted();

    /// @notice Emitted when the vault enters wind-down mode.
    event WindDownInitiated();

    /// @notice Emitted when the vault utilization changes.
    /// @param newUtilization Updated utilization in BPS.
    event UtilizationUpdated(uint256 newUtilization);

    /// @notice Emitted when the AUM fee is collected.
    /// @param amount   Fee amount in underlying asset.
    /// @param treasury Protocol treasury address.
    event AumFeeCollected(uint256 amount, address indexed treasury);

    /// @notice Emitted when the reserve factor is deducted from LP spread earnings.
    /// @param amount   Protocol's portion of spread earnings.
    /// @param treasury Protocol treasury address.
    event ReserveFactorCollected(uint256 amount, address indexed treasury);

    /// @notice Emitted when spread revenue is distributed to the vault and protocol.
    /// @param lpPortion       Amount accruing to LPs (increases share price).
    /// @param protocolPortion Amount sent to protocol treasury.
    event SpreadRevenueAccrued(uint256 lpPortion, uint256 protocolPortion);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The operation is not allowed while the vault is halted.
    error VaultIsHalted();

    /// @notice The vault is winding down; no new deposits or orders.
    error VaultIsWindingDown();

    /// @notice Withdrawal would breach the minimum collateral ratio.
    error InsufficientCollateral();

    /// @notice The vault's utilization exceeds the max; VMs cannot claim new orders.
    error MaxUtilizationExceeded(uint256 currentUtilization, uint256 maxUtilization);

    /// @notice The withdrawal request does not exist.
    error WithdrawalRequestNotFound(uint256 requestId);

    /// @notice The withdrawal request cannot be fulfilled yet (utilization too high).
    error WithdrawalNotReady(uint256 requestId);

    /// @notice The caller is not the owner of the withdrawal request.
    error NotRequestOwner(uint256 requestId, address caller);

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice A zero address was provided.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    /// @notice Submit an async withdrawal request.
    /// @param shares Number of vault shares to withdraw.
    /// @return requestId The unique request identifier.
    function requestWithdrawal(
        uint256 shares
    ) external returns (uint256 requestId);

    /// @notice Cancel a pending withdrawal request. Shares are returned to the LP.
    /// @param requestId Request identifier.
    function cancelWithdrawal(
        uint256 requestId
    ) external;

    /// @notice Fulfill the next eligible withdrawal request in the FIFO queue.
    /// @dev Callable by anyone (keeper pattern) when utilization allows.
    /// @param requestId Request identifier to fulfill.
    /// @return assets Amount of underlying assets transferred.
    function fulfillWithdrawal(
        uint256 requestId
    ) external returns (uint256 assets);

    /// @notice Return the details of a withdrawal request.
    /// @param requestId Request identifier.
    /// @return request The withdrawal request data.
    function getWithdrawalRequest(
        uint256 requestId
    ) external view returns (WithdrawalRequest memory request);

    /// @notice Return all pending withdrawal request IDs in FIFO order.
    /// @return requestIds Array of pending request IDs.
    function getPendingWithdrawals() external view returns (uint256[] memory requestIds);

    // ──────────────────────────────────────────────────────────
    //  Vault status and control
    // ──────────────────────────────────────────────────────────

    /// @notice Return the current vault status.
    /// @return The vault's operating status.
    function vaultStatus() external view returns (VaultStatus);

    /// @notice Halt the vault. No new orders accepted; redemptions and
    ///         liquidations continue.
    /// @param reason Short identifier for the halt reason.
    function halt(
        bytes32 reason
    ) external;

    /// @notice Unhalt the vault and resume normal operations.
    function unhalt() external;

    /// @notice Initiate vault wind-down. No new deposits or orders; existing
    ///         positions must be unwound.
    function initiateWindDown() external;

    // ──────────────────────────────────────────────────────────
    //  Health and utilization
    // ──────────────────────────────────────────────────────────

    /// @notice Return the current vault health factor.
    /// @dev 1e18 = 1.0 (exactly at minimum). > 1e18 is healthy.
    /// @return The health factor (PRECISION-scaled).
    function healthFactor() external view returns (uint256);

    /// @notice Return the current vault utilization.
    /// @return Utilization in BPS.
    function utilization() external view returns (uint256);

    /// @notice Return the maximum allowed utilization.
    /// @return Max utilization in BPS.
    function maxUtilization() external view returns (uint256);

    /// @notice Set the maximum allowed utilization.
    /// @param maxUtilBps Max utilization in BPS.
    function setMaxUtilization(
        uint256 maxUtilBps
    ) external;

    /// @notice Return the total outstanding eToken exposure backed by this vault.
    /// @return Total exposure in 18 decimals (USD notional).
    function totalExposure() external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Fee management
    // ──────────────────────────────────────────────────────────

    /// @notice Trigger AUM fee accrual. Called automatically on vault interactions.
    function accrueAumFee() external;

    /// @notice Distribute spread revenue between LPs and the protocol.
    /// @dev Called by OwnMarket when a VM confirms an order. The reserve
    ///      factor is deducted and sent to treasury; the remainder increases
    ///      vault `totalAssets()`.
    /// @param totalRevenue Total spread revenue in underlying asset.
    function distributeSpreadRevenue(
        uint256 totalRevenue
    ) external;

    /// @notice Return the annual AUM fee.
    /// @return Fee in BPS.
    function aumFee() external view returns (uint256);

    /// @notice Return the reserve factor percentage.
    /// @return Factor in BPS.
    function reserveFactor() external view returns (uint256);

    /// @notice Set the annual AUM fee.
    /// @param feeBps Fee in BPS.
    function setAumFee(
        uint256 feeBps
    ) external;

    /// @notice Set the reserve factor percentage.
    /// @param factorBps Factor in BPS.
    function setReserveFactor(
        uint256 factorBps
    ) external;

    /// @notice Return the protocol treasury address.
    /// @return The treasury address.
    function treasury() external view returns (address);
}
