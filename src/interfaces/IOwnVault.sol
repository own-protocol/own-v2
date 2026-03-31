// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DepositRequest, VaultStatus, WithdrawalRequest} from "./types/Types.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IOwnVault — ERC-4626 collateral vault with async deposit/withdrawal
/// @notice Single vault holding collateral to back eToken exposure.
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

    event VaultPaused(bytes32 indexed reason);
    event VaultUnpaused();
    event VaultHalted();
    event VaultUnhalted();
    event AssetPaused(bytes32 indexed asset, bytes32 indexed reason);
    event AssetUnpaused(bytes32 indexed asset);
    event AssetHalted(bytes32 indexed asset);
    event AssetUnhalted(bytes32 indexed asset);
    event AssetHaltPriceSet(bytes32 indexed asset, uint256 haltPrice);
    event UtilizationUpdated(uint256 newUtilization);

    event FeeDeposited(
        address indexed token, uint256 totalAmount, uint256 protocolAmount, uint256 vmAmount, uint256 lpAmount
    );
    event ProtocolFeesClaimed(address indexed token, uint256 amount);
    event VMFeesClaimed(address indexed token, uint256 amount);
    event LPRewardsClaimed(address indexed account, address indexed token, uint256 amount);

    event VMShareUpdated(uint256 oldShareBps, uint256 newShareBps);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);
    event AssetEnabled(bytes32 indexed asset);
    event AssetDisabled(bytes32 indexed asset);
    event DepositApprovalUpdated(bool required);
    event AssetValuationUpdated(bytes32 indexed asset, uint256 exposureUnits, uint256 exposureUSD, uint256 price);
    event CollateralValuationUpdated(uint256 collateralValueUSD, uint256 price);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error OnlyVM();
    error DirectWithdrawalDisabled();
    error VaultIsPaused();
    error VaultIsHalted();
    error InvalidHaltPrice();
    error InvalidStatusTransition();
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
    error PaymentTokenCannotBeCollateral();
    error CollateralValueNotInitialized();
    error DecimalsTooHigh(uint256 decimals);
    error WithdrawalWaitPeriodNotElapsed(uint256 requestId, uint256 readyAt);
    error PriceNotAvailable(bytes32 asset);
    error DepositApprovalNotRequired();
    error DepositApprovalRequired();

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
    function acceptDeposit(
        uint256 requestId
    ) external;

    /// @notice Reject a pending deposit request. Returns escrowed assets to depositor.
    function rejectDeposit(
        uint256 requestId
    ) external;

    /// @notice Cancel a pending deposit request. Only callable by the original depositor.
    function cancelDeposit(
        uint256 requestId
    ) external;

    function getDepositRequest(
        uint256 requestId
    ) external view returns (DepositRequest memory request);
    function getPendingDeposits() external view returns (uint256[] memory requestIds);

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    /// @notice Submit an async withdrawal request.
    function requestWithdrawal(
        uint256 shares
    ) external returns (uint256 requestId);

    /// @notice Cancel a pending withdrawal request. Shares are returned to the LP.
    function cancelWithdrawal(
        uint256 requestId
    ) external;

    /// @notice Fulfill a withdrawal request. Callable by anyone when utilization allows.
    function fulfillWithdrawal(
        uint256 requestId
    ) external returns (uint256 assets);

    function getWithdrawalRequest(
        uint256 requestId
    ) external view returns (WithdrawalRequest memory request);
    function getPendingWithdrawals() external view returns (uint256[] memory requestIds);

    // ──────────────────────────────────────────────────────────
    //  Vault status and control
    // ──────────────────────────────────────────────────────────

    function vaultStatus() external view returns (VaultStatus);

    /// @notice Pause the vault. Blocks new orders, claims, and LP deposits.
    function pause(
        bytes32 reason
    ) external;

    /// @notice Unpause the vault. Resumes normal operation.
    function unpause() external;

    /// @notice Pause a specific asset. Blocks new orders and claims for this asset.
    function pauseAsset(bytes32 asset, bytes32 reason) external;

    /// @notice Unpause a specific asset.
    function unpauseAsset(
        bytes32 asset
    ) external;

    /// @notice Check if a specific asset is paused.
    function isAssetPaused(
        bytes32 asset
    ) external view returns (bool);

    /// @notice Halt the vault. Set per-asset halt prices via haltAsset before or after.
    ///         Assets without a halt price use the latest oracle price for redemptions.
    function haltVault() external;

    /// @notice Unhalt the vault. Does NOT clear per-asset halt prices.
    function unhalt() external;

    /// @notice Halt a specific asset with a settlement price.
    function haltAsset(bytes32 asset, uint256 haltPrice) external;

    /// @notice Unhalt a specific asset. Clears the halt price.
    function unhaltAsset(
        bytes32 asset
    ) external;

    /// @notice Check if a specific asset is halted.
    function isAssetHalted(
        bytes32 asset
    ) external view returns (bool);

    /// @notice Return the halt settlement price for an asset (0 if not halted).
    function getAssetHaltPrice(
        bytes32 asset
    ) external view returns (uint256);

    /// @notice Check if an asset is effectively paused (vault paused OR asset paused).
    function isEffectivelyPaused(
        bytes32 asset
    ) external view returns (bool);

    /// @notice Check if an asset is effectively halted (vault halted OR asset halted).
    function isEffectivelyHalted(
        bytes32 asset
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Health and utilization
    // ──────────────────────────────────────────────────────────

    /// @notice Return the current vault health factor (1e18 = 1.0).
    ///         healthFactor = collateralValueUSD / totalExposureUSD.
    function healthFactor() external view returns (uint256);

    /// @notice Return the current vault utilization in BPS.
    ///         utilization = totalExposureUSD * BPS / collateralValueUSD.
    function utilization() external view returns (uint256);

    function maxUtilization() external view returns (uint256);
    function setMaxUtilization(
        uint256 maxUtilBps
    ) external;

    /// @notice Return the withdrawal wait period in seconds.
    function withdrawalWaitPeriod() external view returns (uint256);
    function setWithdrawalWaitPeriod(
        uint256 period
    ) external;

    /// @notice Return the total exposure in USD across all assets (18 decimals).
    function totalExposureUSD() external view returns (uint256);

    /// @notice Return the collateral value in USD (18 decimals).
    function collateralValueUSD() external view returns (uint256);

    /// @notice Return per-asset exposure in raw units (18 decimals).
    function assetExposure(
        bytes32 asset
    ) external view returns (uint256);

    /// @notice Return per-asset exposure in USD (18 decimals).
    function assetExposureUSD(
        bytes32 asset
    ) external view returns (uint256);

    /// @notice Return the timestamp of the last valuation update for an asset.
    function assetLastUpdated(
        bytes32 asset
    ) external view returns (uint256);

    /// @notice Update raw exposure units for an asset. Only callable by OwnMarket.
    ///         Adjusts per-asset units and per-asset USD value using last known price.
    /// @param asset Asset ticker.
    /// @param delta Signed change in raw exposure units.
    function updateExposure(bytes32 asset, int256 delta) external;

    /// @notice Refresh the USD valuation of an asset using its oracle price.
    ///         Callable by anyone (keeper pattern). Reads price from the asset's primary oracle.
    /// @param asset Asset ticker to revalue.
    function updateAssetValuation(
        bytes32 asset
    ) external;

    /// @notice Refresh the USD valuation of vault collateral using the collateral oracle.
    ///         Callable by anyone (keeper pattern).
    function updateCollateralValuation() external;

    // ──────────────────────────────────────────────────────────
    //  Order execution parameters (used by OwnMarket)
    // ──────────────────────────────────────────────────────────

    /// @notice Time after claim before force execution is allowed.
    function gracePeriod() external view returns (uint256);

    /// @notice Set the grace period. Only callable by admin.
    function setGracePeriod(
        uint256 period
    ) external;

    /// @notice Time after placement before unclaimed redeem force execution is allowed.
    function claimThreshold() external view returns (uint256);

    /// @notice Set the claim threshold. Only callable by admin.
    function setClaimThreshold(
        uint256 threshold
    ) external;

    /// @notice Asset ticker used to look up the collateral price for force execution conversions.
    function collateralOracleAsset() external view returns (bytes32);

    /// @notice Set the collateral oracle asset. Only callable by admin.
    function setCollateralOracleAsset(
        bytes32 asset
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Fee management
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit order fees into the vault. Called by OwnMarket on confirmation.
    ///         Splits three ways: protocol / VM / LP. Token must match the current payment token.
    function depositFees(address token, uint256 amount) external;

    function setVMShareBps(
        uint256 shareBps
    ) external;
    function vmShareBps() external view returns (uint256);

    /// @notice Claim accrued protocol fees. Callable by anyone. Transfers to treasury.
    function claimProtocolFees() external;

    /// @notice Claim accrued VM fees. Only callable by the bound VM.
    function claimVMFees() external;

    /// @notice Claim accrued LP fee rewards for the caller.
    function claimLPRewards() external returns (uint256 amount);

    function accruedProtocolFees() external view returns (uint256);
    function accruedVMFees() external view returns (uint256);
    function claimableLPRewards(
        address account
    ) external view returns (uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Collateral release (force execution)
    // ──────────────────────────────────────────────────────────

    /// @notice Release vault collateral to a recipient.
    ///         Only callable by OwnMarket during force execution.
    /// @param to     Recipient address.
    /// @param amount Amount of collateral to release.
    function releaseCollateral(address to, uint256 amount) external;

    // ──────────────────────────────────────────────────────────
    //  Supported assets (VM-controlled)
    // ──────────────────────────────────────────────────────────

    /// @notice Enable an asset for this vault. Only callable by the bound VM.
    ///         The asset must exist in the global AssetRegistry.
    function enableAsset(
        bytes32 asset
    ) external;

    /// @notice Disable an asset for this vault. Only callable by the bound VM.
    function disableAsset(
        bytes32 asset
    ) external;

    /// @notice Check if this vault supports a given asset.
    function isAssetSupported(
        bytes32 asset
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Payment token
    // ──────────────────────────────────────────────────────────

    /// @notice Set the accepted payment token. Only callable by the bound VM.
    ///         All outstanding protocol and VM fees must be claimed first.
    function setPaymentToken(
        address token
    ) external;

    /// @notice Return the accepted payment token address.
    function paymentToken() external view returns (address);

    // ──────────────────────────────────────────────────────────
    //  Deposit approval
    // ──────────────────────────────────────────────────────────

    /// @notice Toggle whether LP deposits require VM approval.
    ///         When false (default), LPs call deposit() directly.
    ///         When true, LPs must use requestDeposit() and wait for VM acceptance.
    function setRequireDepositApproval(
        bool required
    ) external;

    /// @notice Return whether deposit approval is currently required.
    function requireDepositApproval() external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Projected utilization
    // ──────────────────────────────────────────────────────────

    /// @notice Return projected utilization in BPS, excluding collateral tied up
    ///         in pending withdrawal requests. For off-chain monitoring.
    function projectedUtilization() external view returns (uint256);

    /// @notice Return total shares currently escrowed for pending withdrawals.
    function pendingWithdrawalShares() external view returns (uint256);
}
