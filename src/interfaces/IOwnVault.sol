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

    /// @notice Emitted when the VM adds collateral yield to the vault, raising the share price for all LPs.
    event ShareYieldAdded(address indexed vm, uint256 amount);

    event VMUpdated(address indexed oldVM, address indexed newVM);
    event QuoteSignerAdded(address indexed signer);
    event QuoteSignerRemoved(address indexed signer);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);
    event DepositApprovalUpdated(bool required);
    event LendingEnabled(address indexed userBorrowManager, address indexed debtToken);
    event AaveCollateralEnabled(address indexed pool, address indexed underlying);
    event CollateralReleasedForBadDebt(address indexed to, uint256 amount);

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
    error MaxUtilizationExceeded();
    error WithdrawalRequestNotFound(uint256 requestId);
    error WithdrawalNotReady(uint256 requestId);
    error NotRequestOwner(uint256 requestId, address caller);
    error DepositRequestNotFound(uint256 requestId);
    error DepositRequestNotPending(uint256 requestId);
    error OnlyDepositor(uint256 requestId);
    error ZeroAmount();
    error ZeroAddress();
    error AssetIsHalted(bytes32 asset);
    error NoSharesToReward();
    error InsufficientSharesOut(uint256 sharesOut, uint256 minSharesOut);
    error OnlyAdmin();
    error OnlyMarket();
    error OnlyVMOrAdmin();
    error AlreadyQuoteSigner(address signer);
    error NotQuoteSigner(address signer);
    error WithdrawalNotPending(uint256 requestId);
    error PaymentTokenCannotBeCollateral();
    error DecimalsTooHigh(uint256 decimals);
    error WithdrawalWaitPeriodNotElapsed(uint256 requestId, uint256 readyAt);
    error DepositApprovalNotRequired();
    error DepositApprovalRequired();
    error LendingAlreadyEnabled();
    error OnlyBorrowManager();

    // ──────────────────────────────────────────────────────────
    //  VM binding
    // ──────────────────────────────────────────────────────────

    /// @notice Return the address of the vault's bound VM.
    function vm() external view returns (address);

    /// @notice Update the vault manager address. Only callable by admin.
    /// @dev    The VM is the operational / fund-custody address (it receives mint proceeds,
    ///         funds redeem payouts, and claims VM fees). It is independent of the quote-signer
    ///         set — changing the VM does not alter authorised quote signers.
    /// @param newVM New VM address.
    function setVM(
        address newVM
    ) external;

    /// @notice Whether an address is an authorised quote signer for this vault.
    /// @dev    The market verifies that order quotes are signed by an authorised signer.
    ///         Signers are decoupled from the operational `vm` address so a hot signing key
    ///         (e.g. an HSM/KMS key) need not custody funds. No signer is registered at
    ///         construction; signers must be added explicitly before quotes can be filled.
    function isQuoteSigner(
        address account
    ) external view returns (bool);

    /// @notice Authorise a new quote signer. Callable by the VM or the admin.
    function addQuoteSigner(
        address signer
    ) external;

    /// @notice Revoke a quote signer. Callable by the VM or the admin.
    function removeQuoteSigner(
        address signer
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    /// @notice Deposit with slippage protection. Reverts if minted shares < `minSharesOut`.
    /// @dev    Guards against share-price movement (e.g. a `shareYield` top-up) between
    ///         transaction submission and execution.
    function deposit(uint256 assets, address receiver, uint256 minSharesOut) external returns (uint256 shares);

    /// @notice Request an async deposit. Assets are escrowed until the VM
    ///         accepts/rejects or the depositor cancels.
    /// @param minSharesOut Minimum shares the depositor will accept at acceptance time.
    ///        `acceptDeposit` reverts if the previewed shares fall below this floor.
    function requestDeposit(
        uint256 assets,
        address receiver,
        uint256 minSharesOut
    ) external returns (uint256 requestId);

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
    //  Withdrawal queue config
    // ──────────────────────────────────────────────────────────

    /// @notice Return the withdrawal wait period in seconds.
    function withdrawalWaitPeriod() external view returns (uint256);
    function setWithdrawalWaitPeriod(
        uint256 period
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Order execution parameters (used by OwnMarket)
    // ──────────────────────────────────────────────────────────

    /// @notice Delay after a resting redeem order is placed before it can be force-executed.
    function claimThreshold() external view returns (uint256);

    /// @notice Set the claim threshold. Only callable by admin.
    function setClaimThreshold(
        uint256 threshold
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Share yield (VM-distributed LP rewards)
    // ──────────────────────────────────────────────────────────

    /// @notice Add collateral yield to the vault, raising the share price for all LPs.
    /// @dev    The VM transfers `amount` of the vault's collateral (`asset()`) in. This is the
    ///         sole onchain channel for LP fee revenue — protocol/VM splits are handled offchain.
    ///         Reverts when there are no shares to distribute to (`totalSupply() == 0`).
    /// @param amount Collateral amount (in `asset()` units) to distribute to LPs.
    function shareYield(
        uint256 amount
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Collateral release (force execution)
    // ──────────────────────────────────────────────────────────

    /// @notice Release vault collateral to a recipient.
    ///         Only callable by OwnMarket during force execution.
    /// @param to     Recipient address.
    /// @param amount Amount of collateral to release.
    function releaseCollateral(address to, uint256 amount) external;

    /// @notice Release collateral (aToken) to cover bad debt the borrow manager
    ///         could not recover from a liquidated position. Only callable by the
    ///         bound borrow manager, which must have already repaid the matching
    ///         Aave debt so the slice is unlocked. Shrinks totalAssets, so the
    ///         loss is socialized to LPs via a lower share price.
    /// @param to     Recipient (the caller that fronted the residual repayment).
    /// @param amount aToken amount to release.
    function releaseCollateralForBadDebt(address to, uint256 amount) external;

    // ──────────────────────────────────────────────────────────
    //  Payment token
    // ──────────────────────────────────────────────────────────

    /// @notice Set the accepted payment token (order settlement currency). Only callable by the bound VM.
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
    //  Withdrawal queue accessors
    // ──────────────────────────────────────────────────────────

    /// @notice Return total shares currently escrowed for pending withdrawals.
    function pendingWithdrawalShares() external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Lending opt-in
    // ──────────────────────────────────────────────────────────

    /// @notice Authorise the user-borrowing manager for this vault and approve
    ///         unlimited credit delegation on the matching Aave variable debt
    ///         token. The delegation is what lets the manager call
    ///         `IAaveV3Pool.borrow(..., onBehalfOf=vault)`. One-shot per vault:
    ///         reverts if lending is already enabled.
    /// @dev    Aave's LTV / collateral checks still bound the actual borrowable
    ///         amount regardless of the unlimited delegation.
    /// @param userBorrowManager Borrow manager for users borrowing against eTokens.
    /// @param debtToken         Aave variable debt token (must implement IAaveDebtToken).
    function enableLending(address userBorrowManager, address debtToken) external;

    /// @notice Mark `underlying` as Aave collateral for this vault. Required
    ///         once the vault holds aTokens for the reserve so its Aave
    ///         account-data reflects the collateral and the borrow manager
    ///         can borrow against it. Idempotent at the Aave level.
    /// @param pool       Aave V3 Pool.
    /// @param underlying Reserve underlying (e.g. wstETH).
    function enableAaveCollateral(address pool, address underlying) external;

    /// @notice Address of the user-borrowing manager (zero if lending not enabled).
    function borrowManager() external view returns (address);
}
