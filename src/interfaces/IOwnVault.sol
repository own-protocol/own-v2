// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DepositRequest, VaultStatus, WithdrawalRequest} from "./types/Types.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IOwnVault — ERC-4626 collateral vault with async deposit/withdrawal
/// @notice Single vault holding ETH (WETH) as collateral to back eToken exposure.
///         Bound 1:1 to a single VM. Accepts one payment token for fee accrual.
///         LPs deposit via async queue (VM approval) and withdraw via FIFO queue.
interface IOwnVault is IERC4626 {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event DepositRequested(uint256 indexed requestId, address indexed depositor, address receiver, uint256 assets);
    event DepositAccepted(uint256 indexed requestId, address indexed depositor, uint256 shares);
    event DepositRejected(uint256 indexed requestId, address indexed depositor);
    event DepositCancelled(uint256 indexed requestId, address indexed depositor);

    event WithdrawalRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    event WithdrawalCancelled(uint256 indexed requestId, address indexed owner);
    event WithdrawalFulfilled(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 shares);

    event VaultHalted(bytes32 indexed reason);
    event VaultUnhalted();
    event AssetHalted(bytes32 indexed asset, bytes32 indexed reason);
    event AssetUnhalted(bytes32 indexed asset);
    event WindDownInitiated();
    event UtilizationUpdated(uint256 newUtilization);

    event FeeDeposited(
        address indexed token, uint256 totalAmount, uint256 protocolAmount, uint256 vmAmount, uint256 lpAmount
    );
    event ProtocolFeesClaimed(address indexed token, uint256 amount);
    event VMFeesClaimed(address indexed token, uint256 amount);
    event LPRewardsClaimed(address indexed account, address indexed token, uint256 amount);

    event ProtocolShareUpdated(uint256 oldShareBps, uint256 newShareBps);
    event VMShareUpdated(uint256 oldShareBps, uint256 newShareBps);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error OnlyVM();
    error VaultIsHalted();
    error VaultIsWindingDown();
    error InsufficientCollateral();
    error MaxUtilizationExceeded(uint256 currentUtilization, uint256 maxUtilization);
    error WithdrawalRequestNotFound(uint256 requestId);
    error WithdrawalNotReady(uint256 requestId);
    error NotRequestOwner(uint256 requestId, address caller);
    error DepositRequestNotFound(uint256 requestId);
    error DepositRequestNotPending(uint256 requestId);
    error OnlyDepositor(uint256 requestId);
    error ZeroAmount();
    error ZeroAddress();
    error AssetIsHalted(bytes32 asset);
    error NoFeesToClaim();
    error ShareTooHigh(uint256 shareBps, uint256 maxBps);
    error OnlyAdmin();
    error OnlyMarket();
    error WithdrawalNotPending(uint256 requestId);
    error OutstandingFeesExist();
    error WrongFeeToken(address expected, address provided);
    error WithdrawalWaitPeriodNotElapsed(uint256 requestId, uint256 readyAt);

    // ──────────────────────────────────────────────────────────
    //  VM binding
    // ──────────────────────────────────────────────────────────

    /// @notice Return the address of the vault's bound VM.
    function vm() external view returns (address);

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    /// @notice Request an async deposit. Assets are escrowed until the VM
    ///         accepts/rejects or the depositor cancels.
    function requestDeposit(uint256 assets, address receiver) external returns (uint256 requestId);

    /// @notice Accept a pending deposit request. Only callable by the bound VM.
    function acceptDeposit(uint256 requestId) external;

    /// @notice Reject a pending deposit request. Returns escrowed assets to depositor.
    function rejectDeposit(uint256 requestId) external;

    /// @notice Cancel a pending deposit request. Only callable by the original depositor.
    function cancelDeposit(uint256 requestId) external;

    function getDepositRequest(uint256 requestId) external view returns (DepositRequest memory request);
    function getPendingDeposits() external view returns (uint256[] memory requestIds);

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    /// @notice Submit an async withdrawal request.
    function requestWithdrawal(uint256 shares) external returns (uint256 requestId);

    /// @notice Cancel a pending withdrawal request. Shares are returned to the LP.
    function cancelWithdrawal(uint256 requestId) external;

    /// @notice Fulfill a withdrawal request. Callable by anyone when utilization allows.
    function fulfillWithdrawal(uint256 requestId) external returns (uint256 assets);

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory request);
    function getPendingWithdrawals() external view returns (uint256[] memory requestIds);

    // ──────────────────────────────────────────────────────────
    //  Vault status and control
    // ──────────────────────────────────────────────────────────

    function vaultStatus() external view returns (VaultStatus);
    function halt(bytes32 reason) external;
    function unhalt() external;
    function haltAsset(bytes32 asset, bytes32 reason) external;
    function unhaltAsset(bytes32 asset) external;
    function isAssetHalted(bytes32 asset) external view returns (bool);
    function initiateWindDown() external;

    // ──────────────────────────────────────────────────────────
    //  Health and utilization
    // ──────────────────────────────────────────────────────────

    /// @notice Return the current vault health factor (1e18 = 1.0).
    function healthFactor() external view returns (uint256);

    /// @notice Return the current vault utilization in BPS.
    function utilization() external view returns (uint256);

    function maxUtilization() external view returns (uint256);
    function setMaxUtilization(uint256 maxUtilBps) external;

    /// @notice Return the withdrawal wait period in seconds.
    function withdrawalWaitPeriod() external view returns (uint256);

    /// @notice Set the withdrawal wait period. Only callable by admin.
    function setWithdrawalWaitPeriod(uint256 period) external;

    /// @notice Return the total outstanding eToken exposure backed by this vault (18 decimals).
    function totalExposure() external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Fee management
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit order fees into the vault. Called by OwnMarket on confirmation.
    ///         Splits three ways: protocol / VM / LP. Token must match the current payment token.
    function depositFees(address token, uint256 amount) external;

    function setProtocolShareBps(uint256 shareBps) external;
    function setVMShareBps(uint256 shareBps) external;
    function protocolShareBps() external view returns (uint256);
    function vmShareBps() external view returns (uint256);

    /// @notice Claim accrued protocol fees. Callable by anyone. Transfers to treasury.
    function claimProtocolFees() external;

    /// @notice Claim accrued VM fees. Only callable by the bound VM.
    function claimVMFees() external;

    /// @notice Claim accrued LP fee rewards for the caller.
    function claimLPRewards() external returns (uint256 amount);

    function accruedProtocolFees() external view returns (uint256);
    function accruedVMFees() external view returns (uint256);
    function claimableLPRewards(address account) external view returns (uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Collateral release (force execution)
    // ──────────────────────────────────────────────────────────

    /// @notice Release vault collateral (ETH/WETH) to a recipient.
    ///         Only callable by OwnMarket during force execution.
    /// @param to     Recipient address.
    /// @param amount Amount of collateral to release.
    function releaseCollateral(address to, uint256 amount) external;

    // ──────────────────────────────────────────────────────────
    //  Payment token
    // ──────────────────────────────────────────────────────────

    /// @notice Set the accepted payment token. Only callable by the bound VM.
    ///         All outstanding protocol and VM fees must be claimed first.
    function setPaymentToken(address token) external;

    /// @notice Return the accepted payment token address.
    function paymentToken() external view returns (address);
}
