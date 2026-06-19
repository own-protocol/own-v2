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

    /// @notice Emitted when the manager adds collateral yield to the vault, raising the share price for all LPs.
    event ShareYieldAdded(address indexed manager, uint256 amount);

    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event DepositApprovalUpdated(bool required);
    event LendingEnabled(address indexed borrowManager);
    event CreditDelegationGranted(address indexed creditToken, address indexed borrowManager);
    event CollateralReleasedForBadDebt(address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error OnlyManager();
    error DirectWithdrawalDisabled();
    error VaultIsPaused();
    error VaultIsHalted();
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
    error NoSharesToReward();
    error InsufficientSharesOut(uint256 sharesOut, uint256 minSharesOut);
    error OnlyAdmin();
    error OnlyOperator();
    error OnlyMarket();
    error OnlyManagerOrOperator();
    error WithdrawalNotPending(uint256 requestId);
    error DecimalsTooHigh(uint256 decimals);
    error WithdrawalWaitPeriodNotElapsed(uint256 requestId, uint256 readyAt);
    error DepositApprovalNotRequired();
    error DepositApprovalRequired();
    error LendingAlreadyEnabled();
    error LendingNotEnabled();
    error OnlyBorrowManager();
    error TreasuryNotSet();
    error AmountExceedsBackedCollateral();

    // ──────────────────────────────────────────────────────────
    //  Manager binding
    // ──────────────────────────────────────────────────────────

    /// @notice Return the address of the vault's bound manager (operator).
    function manager() external view returns (address);

    /// @notice Update the vault's manager (operator) address. Only callable by admin.
    /// @dev    The manager runs the vault: accepts/rejects LP deposits, distributes share yield,
    ///         and can pause the vault. Order settlement no longer flows through it — quotes are
    ///         authorised by the global signer registry on VaultManager and funds flow to/from
    ///         each signer's linked address.
    /// @param newManager New manager address.
    function setManager(
        address newManager
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

    /// @notice Pause the vault — temporary freeze of both LP deposits and withdrawals.
    ///         Callable by the vault's manager or the admin.
    function pause(
        bytes32 reason
    ) external;

    /// @notice Unpause the vault. Callable by the vault's manager or the admin.
    function unpause() external;

    /// @notice Halt the vault — emergency wind-down. Deposits stop; LP withdrawals become instant
    ///         (no wait period, no utilisation check). The vault's collateral is excluded from the
    ///         global risk pool while halted. Admin only.
    function haltVault() external;

    /// @notice Unhalt the vault, re-including its collateral in the global risk pool. Admin only.
    function unhalt() external;

    // ──────────────────────────────────────────────────────────
    //  Withdrawal queue config
    // ──────────────────────────────────────────────────────────

    /// @notice Return the withdrawal wait period in seconds.
    function withdrawalWaitPeriod() external view returns (uint256);
    function setWithdrawalWaitPeriod(
        uint256 period
    ) external;

    // ──────────────────────────────────────────────────────────
    //  Share yield (manager-distributed LP rewards)
    // ──────────────────────────────────────────────────────────

    /// @notice Add collateral yield to the vault, raising the share price for all LPs.
    /// @dev    The manager transfers `amount` of the vault's collateral (`asset()`) in. This is the
    ///         sole onchain channel for LP fee revenue — protocol/manager splits are handled offchain.
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

    /// @notice Release collateral (aToken) to cover bad debt the borrow manager could not recover
    ///         from a liquidated position. Only callable by the bound borrow manager, which must
    ///         have already repaid the matching Aave debt so the slice is unlocked. Shrinks
    ///         totalAssets, so the loss is socialized to LPs via a lower share price.
    /// @dev    The recipient is fixed to the protocol treasury (`ProtocolRegistry.treasury()`) — not
    ///         a caller-supplied address — so a malicious borrow manager can never exfiltrate
    ///         collateral to an external wallet; it can only move it into protocol-controlled hands.
    ///         Reverts (`TreasuryNotSet`) if the treasury is unconfigured.
    /// @param amount aToken amount to release to the treasury.
    function releaseCollateralForBadDebt(
        uint256 amount
    ) external;

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
    //  Lending opt-in (provider-neutral)
    // ──────────────────────────────────────────────────────────

    /// @notice Authorise the vault's borrow manager — the address allowed to call
    ///         `releaseCollateralForBadDebt`. One-shot per vault: reverts if lending is already
    ///         enabled. Provider-neutral: venue-specific authorization (credit delegation / on-behalf
    ///         authorization) is granted separately via the scoped helpers below.
    /// @param manager_ Borrow manager (implements IBorrowManager) bound to this vault.
    function setBorrowManager(
        address manager_
    ) external;

    /// @notice Grant the bound borrow manager unlimited borrow credit delegation on `creditToken`
    ///         (the Aave-style `approveDelegation` pattern). Admin-only; requires lending enabled.
    /// @dev    Safe by construction: the delegated party is always the bound borrow manager (never an
    ///         admin-chosen address), and a delegation grant moves no vault assets — even a malicious
    ///         `creditToken` cannot use it to pull the vault's collateral.
    /// @param creditToken The debt/credit token to delegate on (e.g. an Aave variable debt token).
    function grantCreditDelegation(
        address creditToken
    ) external;

    /// @notice Address of the borrow manager (zero if lending not enabled).
    function borrowManager() external view returns (address);
}
