// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DepositRequest, VaultStatus, WithdrawalRequest} from "./types/Types.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IOwnVault — ERC-4626 collateral vault with async deposit/withdrawal and health tracking
/// @notice Each vault is bound to a single VM and holds one LP collateral type
///         (USDC, aUSDC, WETH, wstETH) as trustless security for outstanding
///         eToken exposure. Extends ERC-4626 for LP share accounting and adds:
///         - Async deposit queue (VM approval pattern).
///         - Async withdrawal queue (ERC-7540 FIFO pattern).
///         - Health factor and utilization tracking.
///         - Halt / unhalt / wind-down mechanisms.
///         - AUM fee for protocol revenue.
///
/// @dev Standard ERC-4626 `deposit` / `mint` are restricted to the bound VM.
///      External LPs use `requestDeposit` for async entry.
///      `maxWithdraw` / `maxRedeem` return 0 when utilization prevents instant
///      withdrawal, signalling that LPs must use `requestWithdrawal` for async exit.
interface IOwnVault is IERC4626 {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when an LP requests an async deposit.
    /// @param requestId Unique request identifier.
    /// @param depositor Address that initiated the deposit.
    /// @param receiver  Address that will receive vault shares.
    /// @param assets    Amount of collateral deposited.
    event DepositRequested(uint256 indexed requestId, address indexed depositor, address receiver, uint256 assets);

    /// @notice Emitted when the VM accepts a deposit request.
    /// @param requestId Unique request identifier.
    /// @param depositor Address that initiated the deposit.
    /// @param shares    Number of vault shares minted.
    event DepositAccepted(uint256 indexed requestId, address indexed depositor, uint256 shares);

    /// @notice Emitted when the VM rejects a deposit request.
    /// @param requestId Unique request identifier.
    /// @param depositor Address that initiated the deposit.
    event DepositRejected(uint256 indexed requestId, address indexed depositor);

    /// @notice Emitted when a depositor cancels their pending deposit request.
    /// @param requestId Unique request identifier.
    /// @param depositor Address that initiated the deposit.
    event DepositCancelled(uint256 indexed requestId, address indexed depositor);

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

    /// @notice Emitted when a specific asset is halted on this vault.
    /// @param asset  Asset ticker.
    /// @param reason Short identifier for the halt reason.
    event AssetHalted(bytes32 indexed asset, bytes32 indexed reason);

    /// @notice Emitted when a specific asset is unhalted on this vault.
    /// @param asset Asset ticker.
    event AssetUnhalted(bytes32 indexed asset);

    /// @notice Emitted when the vault enters wind-down mode.
    event WindDownInitiated();

    /// @notice Emitted when the vault utilization changes.
    /// @param newUtilization Updated utilization in BPS.
    event UtilizationUpdated(uint256 newUtilization);

    /// @notice Emitted when the AUM fee is collected.
    /// @param amount   Fee amount in underlying asset.
    /// @param treasury Protocol treasury address.
    event AumFeeCollected(uint256 amount, address indexed treasury);

    /// @notice Emitted when order fees are deposited and split three ways.
    /// @param token          Fee token address (stablecoin).
    /// @param totalAmount    Total fee deposited.
    /// @param protocolAmount Protocol's share.
    /// @param vmAmount       VM's share.
    /// @param lpAmount       LP share (into rewards-per-share accumulator).
    event FeeDeposited(
        address indexed token, uint256 totalAmount, uint256 protocolAmount, uint256 vmAmount, uint256 lpAmount
    );

    /// @notice Emitted when protocol fees are claimed.
    /// @param token  Fee token claimed.
    /// @param amount Amount transferred to treasury.
    event ProtocolFeesClaimed(address indexed token, uint256 amount);

    /// @notice Emitted when VM fees are claimed.
    /// @param token  Fee token claimed.
    /// @param amount Amount transferred to VM.
    event VMFeesClaimed(address indexed token, uint256 amount);

    /// @notice Emitted when an LP claims accrued fee rewards.
    /// @param account LP address.
    /// @param token   Fee token claimed.
    /// @param amount  Amount transferred to LP.
    event LPRewardsClaimed(address indexed account, address indexed token, uint256 amount);

    /// @notice Emitted when LP rewards are settled (checkpoint updated).
    /// @param account LP address.
    /// @param token   Fee token settled.
    /// @param amount  Amount accrued in this settlement.
    event LPRewardsSettled(address indexed account, address indexed token, uint256 amount);

    /// @notice Emitted when the protocol fee share is updated.
    /// @param oldShareBps Previous share in BPS.
    /// @param newShareBps New share in BPS.
    event ProtocolShareUpdated(uint256 oldShareBps, uint256 newShareBps);

    /// @notice Emitted when the VM fee share is updated.
    /// @param oldShareBps Previous share in BPS.
    /// @param newShareBps New share in BPS.
    event VMShareUpdated(uint256 oldShareBps, uint256 newShareBps);

    /// @notice Emitted when a payment token is added to this vault.
    /// @param token The accepted payment token address.
    event PaymentTokenAdded(address indexed token);

    /// @notice Emitted when a payment token is removed from this vault.
    /// @param token The removed payment token address.
    event PaymentTokenRemoved(address indexed token);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The caller is not the bound VM.
    error OnlyVM();

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

    /// @notice The deposit request does not exist.
    error DepositRequestNotFound(uint256 requestId);

    /// @notice The deposit request is not in Pending status.
    error DepositRequestNotPending(uint256 requestId);

    /// @notice The caller is not the depositor of the deposit request.
    error OnlyDepositor(uint256 requestId);

    /// @notice A zero amount was provided.
    error ZeroAmount();

    /// @notice A zero address was provided.
    error ZeroAddress();

    /// @notice The asset is halted on this vault.
    error AssetIsHalted(bytes32 asset);

    /// @notice No fees available to claim.
    error NoFeesToClaim();

    /// @notice The share exceeds maximum allowed BPS.
    error ShareTooHigh(uint256 shareBps, uint256 maxBps);

    /// @notice Maximum payment tokens (3) reached for this vault.
    error MaxPaymentTokensReached();

    /// @notice The payment token is already accepted by this vault.
    error PaymentTokenAlreadyAdded(address token);

    /// @notice The payment token is not accepted by this vault.
    error PaymentTokenNotAccepted(address token);

    // ──────────────────────────────────────────────────────────
    //  VM binding
    // ──────────────────────────────────────────────────────────

    /// @notice Return the address of the vault's bound VM.
    /// @return The VM address.
    function vm() external view returns (address);

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    /// @notice Request an async deposit. Assets are escrowed in the vault until
    ///         the VM accepts or rejects, or the depositor cancels.
    /// @param assets   Amount of underlying asset to deposit.
    /// @param receiver Address that will receive vault shares on acceptance.
    /// @return requestId The unique request identifier.
    function requestDeposit(uint256 assets, address receiver) external returns (uint256 requestId);

    /// @notice Accept a pending deposit request. Only callable by the bound VM.
    /// @param requestId Request identifier.
    function acceptDeposit(
        uint256 requestId
    ) external;

    /// @notice Reject a pending deposit request. Only callable by the bound VM.
    ///         Returns escrowed assets to the depositor.
    /// @param requestId Request identifier.
    function rejectDeposit(
        uint256 requestId
    ) external;

    /// @notice Cancel a pending deposit request. Only callable by the original depositor.
    ///         Returns escrowed assets to the depositor.
    /// @param requestId Request identifier.
    function cancelDeposit(
        uint256 requestId
    ) external;

    /// @notice Return the details of a deposit request.
    /// @param requestId Request identifier.
    /// @return request The deposit request data.
    function getDepositRequest(
        uint256 requestId
    ) external view returns (DepositRequest memory request);

    /// @notice Return all pending deposit request IDs.
    /// @return requestIds Array of pending request IDs.
    function getPendingDeposits() external view returns (uint256[] memory requestIds);

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

    /// @notice Halt a specific asset on this vault (e.g. due to oracle staleness).
    /// @dev Only the halted asset's orders are blocked; other assets continue.
    /// @param asset  Asset ticker.
    /// @param reason Short identifier for the halt reason.
    function haltAsset(bytes32 asset, bytes32 reason) external;

    /// @notice Unhalt a specific asset on this vault.
    /// @param asset Asset ticker.
    function unhaltAsset(
        bytes32 asset
    ) external;

    /// @notice Check whether a specific asset is halted on this vault.
    /// @param asset Asset ticker.
    /// @return True if the asset is halted.
    function isAssetHalted(
        bytes32 asset
    ) external view returns (bool);

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

    /// @notice Return the annual AUM fee.
    /// @return Fee in BPS.
    function aumFee() external view returns (uint256);

    /// @notice Set the annual AUM fee.
    /// @param feeBps Fee in BPS.
    function setAumFee(
        uint256 feeBps
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Order fee management (Uniswap-style per-vault accrual)
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit order fees into the vault. Called by OwnMarket on order
    ///         confirmation. Pulls `amount` of `token` from caller, splits three
    ///         ways (protocol/VM/LP), and accrues each share.
    /// @param token Fee token address (stablecoin).
    /// @param amount Total fee amount.
    function depositFees(address token, uint256 amount) external;

    /// @notice Set the protocol's share of order fees. Only callable by admin.
    /// @param shareBps Protocol share in basis points (e.g., 2000 = 20%).
    function setProtocolShareBps(
        uint256 shareBps
    ) external;

    /// @notice Set the VM's share of the LP+VM remainder. Only callable by the bound VM.
    /// @param shareBps VM share of remainder in basis points.
    function setVMShareBps(
        uint256 shareBps
    ) external;

    /// @notice Return the protocol share in BPS.
    function protocolShareBps() external view returns (uint256);

    /// @notice Return the VM share in BPS.
    function vmShareBps() external view returns (uint256);

    /// @notice Claim accrued protocol fees for a token. Transfers to treasury.
    ///         Callable by anyone.
    /// @param token Fee token address.
    function claimProtocolFees(
        address token
    ) external;

    /// @notice Claim accrued VM fees for a token. Only callable by the bound VM.
    /// @param token Fee token address.
    function claimVMFees(
        address token
    ) external;

    /// @notice Claim accrued LP fee rewards for a single token.
    /// @param token Fee token address.
    /// @return amount Amount transferred to caller.
    function claimLPRewards(
        address token
    ) external returns (uint256 amount);

    /// @notice Claim accrued LP fee rewards for all registered fee tokens.
    function claimAllLPRewards() external;

    /// @notice Return accrued unclaimed protocol fees for a token.
    /// @param token Fee token address.
    function accruedProtocolFees(
        address token
    ) external view returns (uint256);

    /// @notice Return accrued unclaimed VM fees for a token.
    /// @param token Fee token address.
    function accruedVMFees(
        address token
    ) external view returns (uint256);

    /// @notice Return the claimable LP fee rewards for an account (pending + accrued).
    /// @param token   Fee token address.
    /// @param account LP address.
    /// @return amount Claimable amount.
    function claimableLPRewards(address token, address account) external view returns (uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Payment token management (per-vault, VM-controlled, max 3)
    // ──────────────────────────────────────────────────────────

    /// @notice Add a payment token accepted by this vault. Only callable by the bound VM.
    /// @param token ERC-20 token address to accept.
    function addPaymentToken(
        address token
    ) external;

    /// @notice Remove a payment token from this vault. Only callable by the bound VM.
    /// @param token ERC-20 token address to remove.
    function removePaymentToken(
        address token
    ) external;

    /// @notice Check whether a payment token is accepted by this vault.
    /// @param token The token address to check.
    /// @return True if the token is accepted.
    function isPaymentTokenAccepted(
        address token
    ) external view returns (bool);

    /// @notice Return all accepted payment tokens for this vault.
    /// @return tokens Array of accepted token addresses (max 3).
    function getPaymentTokens() external view returns (address[] memory tokens);
}
