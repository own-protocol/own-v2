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

    /// @notice Emitted when an async deposit is requested and assets are escrowed.
    /// @param requestId Deposit request id.
    /// @param depositor Caller who escrowed the assets.
    /// @param receiver  Address credited the shares on acceptance.
    /// @param assets    Collateral escrowed (asset() units).
    event DepositRequested(uint256 indexed requestId, address indexed depositor, address receiver, uint256 assets);
    /// @notice Emitted when a pending deposit request is accepted and shares are minted.
    /// @param requestId Deposit request id.
    /// @param depositor Caller whose request was accepted.
    /// @param shares    Vault shares minted.
    event DepositAccepted(uint256 indexed requestId, address indexed depositor, uint256 shares);
    /// @notice Emitted when a pending deposit request is rejected; escrowed assets are returned to the depositor.
    /// @param requestId Deposit request id.
    /// @param depositor Caller refunded the escrowed assets.
    event DepositRejected(uint256 indexed requestId, address indexed depositor);
    /// @notice Emitted when a pending deposit request is cancelled by the depositor; escrowed assets are returned.
    /// @param requestId Deposit request id.
    /// @param depositor Caller refunded the escrowed assets.
    event DepositCancelled(uint256 indexed requestId, address indexed depositor);

    /// @notice Emitted when an async withdrawal is requested and shares are escrowed.
    /// @param requestId Withdrawal request id.
    /// @param owner     Share owner who escrowed the shares.
    /// @param shares    Vault shares escrowed.
    event WithdrawalRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    /// @notice Emitted when a pending withdrawal request is cancelled; escrowed shares are returned to the owner.
    /// @param requestId Withdrawal request id.
    /// @param owner     Share owner refunded the escrowed shares.
    event WithdrawalCancelled(uint256 indexed requestId, address indexed owner);
    /// @notice Emitted when a withdrawal request is fulfilled: shares are burned and collateral is paid out.
    /// @param requestId Withdrawal request id.
    /// @param owner     Share owner receiving the collateral.
    /// @param assets    Collateral paid out (asset() units).
    /// @param shares    Vault shares burned.
    event WithdrawalFulfilled(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted when the vault is paused; LP deposits and withdrawals are temporarily frozen.
    /// @param reason Caller-supplied pause reason tag.
    event VaultPaused(bytes32 indexed reason);
    /// @notice Emitted when the vault is unpaused; LP deposits and withdrawals resume.
    event VaultUnpaused();
    /// @notice Emitted when the vault is halted for emergency wind-down; collateral is excluded from the global risk pool.
    event VaultHalted();
    /// @notice Emitted when the vault is unhalted; collateral is re-included in the global risk pool.
    event VaultUnhalted();

    /// @notice Emitted when the manager adds collateral yield to the vault, raising the share price for all LPs.
    /// @param manager Manager that contributed the yield.
    /// @param amount  Collateral added (asset() units).
    event ShareYieldAdded(address indexed manager, uint256 amount);

    /// @notice Emitted when the vault's bound manager (operator) is changed.
    /// @param oldManager Previous manager address.
    /// @param newManager New manager address.
    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    /// @notice Emitted when the deposit-approval requirement is toggled.
    /// @param required True if LP deposits now require VM approval.
    event DepositApprovalUpdated(bool required);
    /// @notice Emitted when lending is enabled and the borrow manager is bound (one-shot).
    /// @param borrowManager Borrow manager bound to this vault.
    event LendingEnabled(address indexed borrowManager);
    /// @notice Emitted when borrow credit delegation is granted to the bound borrow manager.
    /// @param creditToken   Debt/credit token delegated on (e.g. Aave variable debt token).
    /// @param borrowManager Borrow manager granted the delegation.
    event CreditDelegationGranted(address indexed creditToken, address indexed borrowManager);
    /// @notice Emitted when the vault's aToken is enabled as Aave collateral.
    /// @param pool       Aave V3 pool the bit was flipped on.
    /// @param underlying Reserve underlying whose aToken is this vault's asset.
    event AaveCollateralEnabled(address indexed pool, address indexed underlying);
    /// @notice Emitted when collateral is released to the treasury to cover bad debt (loss socialized to LPs).
    /// @param to     Recipient (protocol treasury).
    /// @param amount aToken collateral released.
    event CollateralReleasedForBadDebt(address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Caller is not the vault's bound manager.
    error OnlyManager();
    /// @notice Direct (synchronous) withdrawal is disabled; use the async withdrawal queue.
    error DirectWithdrawalDisabled();
    /// @notice Operation blocked because the vault is paused.
    error VaultIsPaused();
    /// @notice Operation blocked because the vault is halted.
    error VaultIsHalted();
    /// @notice Requested vault status transition is not allowed from the current status.
    error InvalidStatusTransition();
    /// @notice Vault has insufficient collateral to satisfy the request.
    error InsufficientCollateral();
    /// @notice Withdrawal would push utilization past the allowed maximum.
    error MaxUtilizationExceeded();
    /// @notice No withdrawal request exists for this id.
    error WithdrawalRequestNotFound(uint256 requestId);
    /// @notice Caller is not the owner of this request.
    error NotRequestOwner(uint256 requestId, address caller);
    /// @notice No deposit request exists for this id.
    error DepositRequestNotFound(uint256 requestId);
    /// @notice Deposit request is not in the pending state.
    error DepositRequestNotPending(uint256 requestId);
    /// @notice Caller is not the original depositor of this request.
    error OnlyDepositor(uint256 requestId);
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice No shares exist to distribute yield to (totalSupply == 0).
    error NoSharesToReward();
    /// @notice Minted shares fell below the caller's slippage floor.
    /// @param sharesOut    Shares that would be minted.
    /// @param minSharesOut Caller's minimum acceptable shares.
    error InsufficientSharesOut(uint256 sharesOut, uint256 minSharesOut);
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();
    /// @notice Caller is not the registry's market contract.
    error OnlyMarket();
    /// @notice Caller is neither the vault's manager nor the operator.
    error OnlyManagerOrOperator();
    /// @notice Withdrawal request is not in the pending state.
    error WithdrawalNotPending(uint256 requestId);
    /// @notice Collateral token has more than 18 decimals (unsupported).
    /// @param decimals Collateral token decimals.
    error DecimalsTooHigh(uint256 decimals);
    /// @notice Withdrawal wait period has not yet elapsed.
    /// @param readyAt Timestamp the request becomes fulfillable.
    error WithdrawalWaitPeriodNotElapsed(uint256 requestId, uint256 readyAt);
    /// @notice Deposit approval is not required, so this approval-gated path is unavailable.
    error DepositApprovalNotRequired();
    /// @notice Deposit approval is required; use the async request flow.
    error DepositApprovalRequired();
    /// @notice Lending is already enabled (setBorrowManager is one-shot).
    error LendingAlreadyEnabled();
    /// @notice Lending is not enabled on this vault.
    error LendingNotEnabled();
    /// @notice The supplied reserve underlying does not match the vault's asset.
    error InvalidUnderlying();
    /// @notice Caller is not the bound borrow manager.
    error OnlyBorrowManager();
    /// @notice The protocol treasury address is not configured.
    error TreasuryNotSet();
    /// @notice Requested amount exceeds the vault's backed collateral (totalAssets).
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

    /// @notice Mark the vault's aToken as Aave collateral so the bound borrow manager can borrow against
    ///         it. Aave only auto-enables collateral on a holder's first `supply(onBehalfOf)`, never on
    ///         the aToken transfer the deposit path uses — so the vault must flip the bit itself. Call
    ///         once after the first deposit (Aave requires a non-zero aToken balance), and again to
    ///         re-arm after a full drain (Aave clears the bit when the balance reaches zero).
    /// @dev    Admin-only. `underlying` is validated against the vault's own asset, so a wrong reserve
    ///         cannot be enabled. The call cannot move assets or disable collateral.
    /// @param pool       The Aave V3 pool the bound borrow manager borrows from.
    /// @param underlying The reserve underlying (e.g. wstETH) whose aToken is this vault's asset.
    function enableAaveCollateral(address pool, address underlying) external;

    /// @notice Address of the borrow manager (zero if lending not enabled).
    function borrowManager() external view returns (address);
}
