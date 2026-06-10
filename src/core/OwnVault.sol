// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {ICreditDelegation} from "../interfaces/external/ILendingVenue.sol";
import {
    DepositRequest,
    DepositStatus,
    VaultStatus,
    WithdrawalRequest,
    WithdrawalStatus
} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title OwnVault — ERC-4626 collateral vault with async deposit/withdrawal
/// @notice Single vault holding collateral to back eToken exposure.
contract OwnVault is ERC4626, IOwnVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;

    /// @notice Operational / fund-custody manager bound to this vault.
    address public manager;

    // ──────────────────────────────────────────────────────────
    //  Vault status
    // ──────────────────────────────────────────────────────────

    VaultStatus private _vaultStatus;

    // ──────────────────────────────────────────────────────────
    //  Withdrawal queue config
    // ──────────────────────────────────────────────────────────

    uint256 private _withdrawalWaitPeriod;

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    uint256 private _nextDepositRequestId = 1;
    mapping(uint256 => DepositRequest) private _depositRequests;
    EnumerableSet.UintSet private _pendingDepositIds;

    /// @dev Total assets held for pending deposit requests. Excluded from
    ///      totalAssets() so that ERC-4626 share math is not polluted by
    ///      assets that have no corresponding shares yet.
    uint256 private _pendingDepositAssets;

    /// @dev When true, LP deposits require VM approval via requestDeposit/acceptDeposit.
    ///      When false (default), LPs call deposit() directly.
    bool private _requireDepositApproval;

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    uint256 private _nextRequestId = 1;
    mapping(uint256 => WithdrawalRequest) private _withdrawalRequests;
    EnumerableSet.UintSet private _pendingRequestIds;

    /// @dev Total shares escrowed for pending withdrawal requests.
    uint256 private _pendingWithdrawalShares;

    // ──────────────────────────────────────────────────────────
    //  Lending opt-in (Phase 1 scaffold)
    // ──────────────────────────────────────────────────────────

    /// @dev Authorised user-borrowing manager. Zero until enableLending is called.
    address private _borrowManager;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert OnlyAdmin();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    modifier onlyManagerOrAdmin() {
        if (msg.sender != manager && msg.sender != Ownable(address(registry)).owner()) revert OnlyManagerOrAdmin();
        _;
    }

    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

    modifier onlyBorrowManager() {
        if (msg.sender != _borrowManager) revert OnlyBorrowManager();
        _;
    }

    modifier whenDepositsAllowed() {
        if (_vaultStatus == VaultStatus.Paused) revert VaultIsPaused();
        if (_vaultStatus == VaultStatus.Halted) revert VaultIsHalted();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param asset_      Underlying collateral ERC-20 (e.g. WETH).
    /// @param name_       Vault share name.
    /// @param symbol_     Vault share symbol.
    /// @param registry_   ProtocolRegistry contract address.
    /// @param manager_    Vault manager (operator) address bound to this vault.
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        address registry_,
        address manager_
    ) ERC4626(IERC20(asset_)) ERC20(name_, symbol_) {
        uint8 collatDecimals = IERC20Metadata(asset_).decimals();
        if (collatDecimals > 18) revert DecimalsTooHigh(collatDecimals);
        registry = IProtocolRegistry(registry_);
        manager = manager_;
        _vaultStatus = VaultStatus.Active;
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626 overrides
    // ──────────────────────────────────────────────────────────

    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626, IERC4626) whenDepositsAllowed nonReentrant returns (uint256) {
        return _depositWithMin(assets, receiver, 0);
    }

    /// @inheritdoc IOwnVault
    function deposit(
        uint256 assets,
        address receiver,
        uint256 minSharesOut
    ) external whenDepositsAllowed nonReentrant returns (uint256) {
        return _depositWithMin(assets, receiver, minSharesOut);
    }

    /// @dev Shared deposit path. Enforces the optional approval gate and a `minSharesOut`
    ///      slippage floor against share-price movement before execution.
    function _depositWithMin(uint256 assets, address receiver, uint256 minSharesOut) private returns (uint256 shares) {
        if (_requireDepositApproval && msg.sender != manager) revert DepositApprovalRequired();
        shares = super.deposit(assets, receiver);
        if (shares < minSharesOut) revert InsufficientSharesOut(shares, minSharesOut);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626, IERC4626) whenDepositsAllowed onlyManager nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @dev Direct withdrawals are disabled. Use the async withdrawal queue
    ///      (requestWithdrawal → fulfillWithdrawal) instead.
    function maxWithdraw(
        address
    ) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    /// @dev Direct redemptions are disabled. Use the async withdrawal queue
    ///      (requestWithdrawal → fulfillWithdrawal) instead.
    function maxRedeem(
        address
    ) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function requestDeposit(
        uint256 assets,
        address receiver,
        uint256 minSharesOut
    ) external whenDepositsAllowed nonReentrant returns (uint256 requestId) {
        if (!_requireDepositApproval) revert DepositApprovalNotRequired();
        if (assets == 0) revert ZeroAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _pendingDepositAssets += assets;

        requestId = _nextDepositRequestId++;
        _depositRequests[requestId] = DepositRequest({
            requestId: requestId,
            depositor: msg.sender,
            receiver: receiver,
            assets: assets,
            minSharesOut: minSharesOut,
            timestamp: block.timestamp,
            status: DepositStatus.Pending
        });
        _pendingDepositIds.add(requestId);

        emit DepositRequested(requestId, msg.sender, receiver, assets);
    }

    /// @inheritdoc IOwnVault
    function acceptDeposit(
        uint256 requestId
    ) external onlyManager nonReentrant {
        DepositRequest storage req = _depositRequests[requestId];
        if (req.depositor == address(0)) revert DepositRequestNotFound(requestId);
        if (req.status != DepositStatus.Pending) revert DepositRequestNotPending(requestId);

        uint256 shares = previewDeposit(req.assets);
        if (shares < req.minSharesOut) revert InsufficientSharesOut(shares, req.minSharesOut);
        _pendingDepositAssets -= req.assets;
        req.status = DepositStatus.Accepted;
        _pendingDepositIds.remove(requestId);
        _mint(req.receiver, shares);

        emit DepositAccepted(requestId, req.depositor, shares);
    }

    /// @inheritdoc IOwnVault
    function rejectDeposit(
        uint256 requestId
    ) external onlyManager nonReentrant {
        DepositRequest storage req = _depositRequests[requestId];
        if (req.depositor == address(0)) revert DepositRequestNotFound(requestId);
        if (req.status != DepositStatus.Pending) revert DepositRequestNotPending(requestId);

        _pendingDepositAssets -= req.assets;
        req.status = DepositStatus.Rejected;
        _pendingDepositIds.remove(requestId);
        IERC20(asset()).safeTransfer(req.depositor, req.assets);

        emit DepositRejected(requestId, req.depositor);
    }

    /// @inheritdoc IOwnVault
    function cancelDeposit(
        uint256 requestId
    ) external nonReentrant {
        DepositRequest storage req = _depositRequests[requestId];
        if (req.depositor == address(0)) revert DepositRequestNotFound(requestId);
        if (req.status != DepositStatus.Pending) revert DepositRequestNotPending(requestId);
        if (msg.sender != req.depositor) revert OnlyDepositor(requestId);

        _pendingDepositAssets -= req.assets;
        req.status = DepositStatus.Cancelled;
        _pendingDepositIds.remove(requestId);
        IERC20(asset()).safeTransfer(req.depositor, req.assets);

        emit DepositCancelled(requestId, req.depositor);
    }

    /// @inheritdoc IOwnVault
    function getDepositRequest(
        uint256 requestId
    ) external view returns (DepositRequest memory request) {
        request = _depositRequests[requestId];
        if (request.depositor == address(0)) revert DepositRequestNotFound(requestId);
    }

    /// @inheritdoc IOwnVault
    function getPendingDeposits() external view returns (uint256[] memory) {
        return _pendingDepositIds.values();
    }

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function requestWithdrawal(
        uint256 shares
    ) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        // Pause freezes both deposits and withdrawals; halt still allows withdrawals.
        if (_vaultStatus == VaultStatus.Paused) revert VaultIsPaused();

        _transfer(msg.sender, address(this), shares);
        _pendingWithdrawalShares += shares;

        requestId = _nextRequestId++;
        _withdrawalRequests[requestId] = WithdrawalRequest({
            requestId: requestId,
            owner: msg.sender,
            shares: shares,
            timestamp: block.timestamp,
            status: WithdrawalStatus.Pending
        });
        _pendingRequestIds.add(requestId);

        emit WithdrawalRequested(requestId, msg.sender, shares);
    }

    /// @inheritdoc IOwnVault
    function cancelWithdrawal(
        uint256 requestId
    ) external nonReentrant {
        WithdrawalRequest storage req = _withdrawalRequests[requestId];
        if (req.owner == address(0)) revert WithdrawalRequestNotFound(requestId);
        if (req.owner != msg.sender) revert NotRequestOwner(requestId, msg.sender);
        if (req.status != WithdrawalStatus.Pending) revert WithdrawalNotPending(requestId);

        req.status = WithdrawalStatus.Cancelled;
        _pendingWithdrawalShares -= req.shares;
        _transfer(address(this), msg.sender, req.shares);
        _pendingRequestIds.remove(requestId);

        emit WithdrawalCancelled(requestId, msg.sender);
    }

    /// @inheritdoc IOwnVault
    function fulfillWithdrawal(
        uint256 requestId
    ) external nonReentrant returns (uint256 assets) {
        WithdrawalRequest storage req = _withdrawalRequests[requestId];
        if (req.owner == address(0)) revert WithdrawalRequestNotFound(requestId);
        if (req.status != WithdrawalStatus.Pending) revert WithdrawalNotPending(requestId);
        // Pause freezes withdrawals entirely.
        if (_vaultStatus == VaultStatus.Paused) revert VaultIsPaused();

        uint256 shares = req.shares;
        assets = convertToAssets(shares);

        // A halted vault is an emergency wind-down: its collateral is already excluded from the
        // global pool, so LP exits are immediate and unconditional (no wait period, no util check).
        // Active vaults enforce the wait period and the global utilisation cap.
        if (_vaultStatus != VaultStatus.Halted) {
            uint256 readyAt = req.timestamp + _withdrawalWaitPeriod;
            if (block.timestamp < readyAt) {
                revert WithdrawalWaitPeriodNotElapsed(requestId, readyAt);
            }
            if (IVaultManager(registry.vaultManager()).withdrawalBreachesUtil(address(this), assets)) {
                revert MaxUtilizationExceeded();
            }
        }

        req.status = WithdrawalStatus.Fulfilled;
        _pendingWithdrawalShares -= shares;
        _pendingRequestIds.remove(requestId);

        _burn(address(this), shares);
        IERC20(asset()).safeTransfer(req.owner, assets);

        emit WithdrawalFulfilled(requestId, req.owner, assets, shares);
    }

    /// @inheritdoc IOwnVault
    function getWithdrawalRequest(
        uint256 requestId
    ) external view returns (WithdrawalRequest memory request) {
        request = _withdrawalRequests[requestId];
        if (request.owner == address(0)) revert WithdrawalRequestNotFound(requestId);
    }

    /// @inheritdoc IOwnVault
    function getPendingWithdrawals() external view returns (uint256[] memory) {
        return _pendingRequestIds.values();
    }

    // ──────────────────────────────────────────────────────────
    //  Vault status and control
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function vaultStatus() external view returns (VaultStatus) {
        return _vaultStatus;
    }

    // ── Pause (temporary; blocks deposits AND withdrawals) ──

    /// @inheritdoc IOwnVault
    function pause(
        bytes32 reason
    ) external onlyManagerOrAdmin {
        if (_vaultStatus != VaultStatus.Active) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Paused;
        emit VaultPaused(reason);
    }

    /// @inheritdoc IOwnVault
    function unpause() external onlyManagerOrAdmin {
        if (_vaultStatus != VaultStatus.Paused) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Active;
        emit VaultUnpaused();
    }

    // ── Halt (emergency wind-down; deposits off, instant withdrawals) ──

    /// @inheritdoc IOwnVault
    function haltVault() external onlyAdmin {
        if (_vaultStatus != VaultStatus.Active) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Halted;
        // Drop this vault's collateral from the global risk pool.
        IVaultManager(registry.vaultManager()).onVaultHalted();
        emit VaultHalted();
    }

    /// @inheritdoc IOwnVault
    function unhalt() external onlyAdmin {
        if (_vaultStatus != VaultStatus.Halted) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Active;
        // Re-include this vault's collateral in the global risk pool.
        IVaultManager(registry.vaultManager()).onVaultUnhalted();
        emit VaultUnhalted();
    }

    // ──────────────────────────────────────────────────────────
    //  Withdrawal queue accessors
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function pendingWithdrawalShares() external view returns (uint256) {
        return _pendingWithdrawalShares;
    }

    /// @inheritdoc IOwnVault
    function withdrawalWaitPeriod() external view returns (uint256) {
        return _withdrawalWaitPeriod;
    }

    /// @inheritdoc IOwnVault
    function setWithdrawalWaitPeriod(
        uint256 period
    ) external onlyAdmin {
        _withdrawalWaitPeriod = period;
    }

    // ──────────────────────────────────────────────────────────
    //  Share yield (manager-distributed LP rewards)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function shareYield(
        uint256 amount
    ) external onlyManager nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Cannot distribute yield with no shares outstanding; the assets would otherwise
        // accrue to whoever deposits first.
        if (totalSupply() == 0) revert NoSharesToReward();

        // Manager transfers collateral in → totalAssets() rises → share price rises for all LPs.
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit ShareYieldAdded(msg.sender, amount);
    }

    /// @inheritdoc IOwnVault
    function setManager(
        address newManager
    ) external onlyAdmin {
        if (newManager == address(0)) revert ZeroAddress();
        address oldManager = manager;
        manager = newManager;
        emit ManagerUpdated(oldManager, newManager);
    }

    // ──────────────────────────────────────────────────────────
    //  Deposit approval
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function setRequireDepositApproval(
        bool required
    ) external onlyAdmin {
        _requireDepositApproval = required;
        emit DepositApprovalUpdated(required);
    }

    /// @inheritdoc IOwnVault
    function requireDepositApproval() external view returns (bool) {
        return _requireDepositApproval;
    }

    // ──────────────────────────────────────────────────────────
    //  Lending opt-in (provider-neutral)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function setBorrowManager(
        address manager_
    ) external onlyAdmin {
        if (manager_ == address(0)) revert ZeroAddress();
        if (_borrowManager != address(0)) revert LendingAlreadyEnabled();
        _borrowManager = manager_;
        emit LendingEnabled(manager_);
    }

    /// @inheritdoc IOwnVault
    function grantCreditDelegation(
        address creditToken
    ) external onlyAdmin {
        if (_borrowManager == address(0)) revert LendingNotEnabled();
        if (creditToken == address(0)) revert ZeroAddress();
        // Beneficiary is ALWAYS the bound borrow manager — never an admin-chosen address — and this
        // grants borrow delegation only; it cannot move the vault's collateral.
        ICreditDelegation(creditToken).approveDelegation(_borrowManager, type(uint256).max);
        emit CreditDelegationGranted(creditToken, _borrowManager);
    }

    /// @inheritdoc IOwnVault
    function borrowManager() external view returns (address) {
        return _borrowManager;
    }

    // ──────────────────────────────────────────────────────────
    //  Collateral release (force execution)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function releaseCollateral(address to, uint256 amount) external onlyMarket nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // Sync the cached mark before assets leave, so the withdrawal gate never reads stale-high.
        IVaultManager(registry.vaultManager()).onCollateralReleased(amount);
        IERC20(asset()).safeTransfer(to, amount);
    }

    /// @inheritdoc IOwnVault
    function releaseCollateralForBadDebt(
        uint256 amount
    ) external onlyBorrowManager nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Destination is the protocol treasury (from the registry) — NOT a caller-supplied address.
        // This bounds the blast radius if the borrow manager is ever malicious: collateral can only
        // ever be moved into protocol-controlled hands, never to an external wallet.
        address to = registry.treasury();
        if (to == address(0)) revert TreasuryNotSet();
        // Drop the cached collateral mark before moving assets, so the withdrawal gate never sees a
        // stale-high collateral total between this release and the next keeper price pull.
        IVaultManager(registry.vaultManager()).onCollateralReleased(amount);
        // The borrow manager has already repaid the corresponding Aave debt, so this aToken slice is
        // unlocked. Releasing it shrinks totalAssets, socializing the bad-debt loss to LPs.
        IERC20(asset()).safeTransfer(to, amount);
        emit CollateralReleasedForBadDebt(to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Required overrides for diamond inheritance
    // ──────────────────────────────────────────────────────────

    /// @dev Direct withdrawals are disabled. Use the async withdrawal queue
    ///      (requestWithdrawal → fulfillWithdrawal) instead.
    function withdraw(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert DirectWithdrawalDisabled();
    }

    /// @dev Direct redemptions are disabled. Use the async withdrawal queue
    ///      (requestWithdrawal → fulfillWithdrawal) instead.
    function redeem(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert DirectWithdrawalDisabled();
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return super.totalAssets() - _pendingDepositAssets;
    }

    /// @dev Virtual-shares offset to neutralise ERC-4626 inflation / first-depositor attacks.
    ///      An attacker must forfeit ~10^6× any value they could extract, making it irrational.
    ///      Share token decimals are `collateralDecimals + 6` as a result.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function maxDeposit(
        address
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_vaultStatus != VaultStatus.Active) return 0;
        return type(uint256).max;
    }

    function maxMint(
        address
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_vaultStatus != VaultStatus.Active) return 0;
        return type(uint256).max;
    }
}
