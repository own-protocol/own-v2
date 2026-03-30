// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {
    BPS,
    DepositRequest,
    DepositStatus,
    PRECISION,
    VaultStatus,
    WithdrawalRequest,
    WithdrawalStatus
} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnVault — ERC-4626 collateral vault with async deposit/withdrawal
/// @notice Single vault holding ETH (WETH) as collateral to back eToken exposure.
///         Bound 1:1 to a single VM. Accepts one payment token for fee accrual.
///         All fees must be flushed before the payment token can be changed.
contract OwnVault is ERC4626, IOwnVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;
    address public immutable vm;

    // ──────────────────────────────────────────────────────────
    //  Vault status
    // ──────────────────────────────────────────────────────────

    VaultStatus private _vaultStatus;
    mapping(bytes32 => bool) private _assetHalted;

    // ──────────────────────────────────────────────────────────
    //  Utilization & health
    // ──────────────────────────────────────────────────────────

    uint256 private _maxUtilization;
    uint256 private _totalExposure;
    uint256 private _withdrawalWaitPeriod;

    // ──────────────────────────────────────────────────────────
    //  Payment token (single, VM-controlled)
    // ──────────────────────────────────────────────────────────

    address private _paymentToken;

    // ──────────────────────────────────────────────────────────
    //  Order fee accrual (single-token, Uniswap-style)
    //  All fees are denominated in _paymentToken. Token must be
    //  flushed (protocol + VM claimed) before changing token.
    // ──────────────────────────────────────────────────────────

    uint256 private _protocolShareBps;
    uint256 private _vmShareBps;

    uint256 private _protocolFees;
    uint256 private _vmFees;

    /// @dev Cumulative LP rewards-per-share (scaled by PRECISION).
    uint256 private _lpRewardsPerShare;

    /// @dev Per-account checkpoint — last-seen rewardsPerShare.
    mapping(address => uint256) private _lpCheckpoint;

    /// @dev Per-account accrued unclaimed LP fee rewards.
    mapping(address => uint256) private _lpAccruedFees;

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    uint256 private _nextDepositRequestId = 1;
    mapping(uint256 => DepositRequest) private _depositRequests;
    uint256[] private _pendingDepositIds;

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    uint256 private _nextRequestId = 1;
    mapping(uint256 => WithdrawalRequest) private _withdrawalRequests;
    uint256[] private _pendingRequestIds;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != Ownable(address(registry)).owner()) revert OnlyAdmin();
        _;
    }

    modifier onlyVM() {
        if (msg.sender != vm) revert OnlyVM();
        _;
    }

    modifier onlyMarket() {
        if (msg.sender != registry.market()) revert OnlyMarket();
        _;
    }

    modifier whenActive() {
        if (_vaultStatus == VaultStatus.Halted) revert VaultIsHalted();
        if (_vaultStatus == VaultStatus.WindingDown) revert VaultIsWindingDown();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param asset_            Underlying collateral ERC-20 (WETH).
    /// @param name_             Vault share name.
    /// @param symbol_           Vault share symbol.
    /// @param registry_         ProtocolRegistry contract address.
    /// @param vm_               Vault manager address bound to this vault.
    /// @param maxUtilBps        Initial max utilization in BPS.
    /// @param protocolShareBps_ Initial protocol fee share in BPS.
    /// @param vmShareBps_       Initial VM fee share (of LP+VM remainder) in BPS.
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        address registry_,
        address vm_,
        uint256 maxUtilBps,
        uint256 protocolShareBps_,
        uint256 vmShareBps_
    ) ERC4626(IERC20(asset_)) ERC20(name_, symbol_) {
        if (protocolShareBps_ > BPS) revert ShareTooHigh(protocolShareBps_, BPS);
        if (vmShareBps_ > BPS) revert ShareTooHigh(vmShareBps_, BPS);
        registry = IProtocolRegistry(registry_);
        vm = vm_;
        _maxUtilization = maxUtilBps;
        _vaultStatus = VaultStatus.Active;
        _protocolShareBps = protocolShareBps_;
        _vmShareBps = vmShareBps_;
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626 overrides
    // ──────────────────────────────────────────────────────────

    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626, IERC4626) whenActive onlyVM nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626, IERC4626) whenActive onlyVM nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function maxWithdraw(
        address owner
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_vaultStatus == VaultStatus.Halted) return 0;
        return super.maxWithdraw(owner);
    }

    function maxRedeem(
        address owner
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_vaultStatus == VaultStatus.Halted) return 0;
        return super.maxRedeem(owner);
    }

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function requestDeposit(
        uint256 assets,
        address receiver
    ) external whenActive nonReentrant returns (uint256 requestId) {
        if (assets == 0) revert ZeroAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        requestId = _nextDepositRequestId++;
        _depositRequests[requestId] = DepositRequest({
            requestId: requestId,
            depositor: msg.sender,
            receiver: receiver,
            assets: assets,
            timestamp: block.timestamp,
            status: DepositStatus.Pending
        });
        _pendingDepositIds.push(requestId);

        emit DepositRequested(requestId, msg.sender, receiver, assets);
    }

    /// @inheritdoc IOwnVault
    function acceptDeposit(
        uint256 requestId
    ) external onlyVM nonReentrant {
        DepositRequest storage req = _depositRequests[requestId];
        if (req.depositor == address(0)) revert DepositRequestNotFound(requestId);
        if (req.status != DepositStatus.Pending) revert DepositRequestNotPending(requestId);

        uint256 shares = previewDeposit(req.assets);
        req.status = DepositStatus.Accepted;
        _removePendingDeposit(requestId);
        _mint(req.receiver, shares);

        emit DepositAccepted(requestId, req.depositor, shares);
    }

    /// @inheritdoc IOwnVault
    function rejectDeposit(
        uint256 requestId
    ) external onlyVM nonReentrant {
        DepositRequest storage req = _depositRequests[requestId];
        if (req.depositor == address(0)) revert DepositRequestNotFound(requestId);
        if (req.status != DepositStatus.Pending) revert DepositRequestNotPending(requestId);

        req.status = DepositStatus.Rejected;
        _removePendingDeposit(requestId);
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

        req.status = DepositStatus.Cancelled;
        _removePendingDeposit(requestId);
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
        return _pendingDepositIds;
    }

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function requestWithdrawal(
        uint256 shares
    ) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();

        _transfer(msg.sender, address(this), shares);

        requestId = _nextRequestId++;
        _withdrawalRequests[requestId] = WithdrawalRequest({
            requestId: requestId,
            owner: msg.sender,
            shares: shares,
            timestamp: block.timestamp,
            status: WithdrawalStatus.Pending
        });
        _pendingRequestIds.push(requestId);

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
        _transfer(address(this), msg.sender, req.shares);
        _removePendingRequest(requestId);

        emit WithdrawalCancelled(requestId, msg.sender);
    }

    /// @inheritdoc IOwnVault
    function fulfillWithdrawal(
        uint256 requestId
    ) external nonReentrant returns (uint256 assets) {
        WithdrawalRequest storage req = _withdrawalRequests[requestId];
        if (req.owner == address(0)) revert WithdrawalRequestNotFound(requestId);
        if (req.status != WithdrawalStatus.Pending) revert WithdrawalNotPending(requestId);

        // Enforce wait period
        uint256 readyAt = req.timestamp + _withdrawalWaitPeriod;
        if (block.timestamp < readyAt) {
            revert WithdrawalWaitPeriodNotElapsed(requestId, readyAt);
        }

        uint256 shares = req.shares;
        assets = convertToAssets(shares);

        // Check that withdrawal won't breach max utilization
        uint256 assetsAfter = totalAssets() - assets;
        if (assetsAfter > 0 && _totalExposure > 0) {
            uint256 utilizationAfter = _totalExposure.mulDiv(BPS, assetsAfter);
            if (utilizationAfter > _maxUtilization) {
                revert MaxUtilizationExceeded(utilizationAfter, _maxUtilization);
            }
        }

        req.status = WithdrawalStatus.Fulfilled;
        _removePendingRequest(requestId);

        // Auto-claim LP rewards before exit
        _claimLPRewardsFor(req.owner);

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
        return _pendingRequestIds;
    }

    // ──────────────────────────────────────────────────────────
    //  Vault status and control
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function vaultStatus() external view returns (VaultStatus) {
        return _vaultStatus;
    }

    /// @inheritdoc IOwnVault
    function halt(bytes32 reason) external onlyAdmin {
        _vaultStatus = VaultStatus.Halted;
        emit VaultHalted(reason);
    }

    /// @inheritdoc IOwnVault
    function unhalt() external onlyAdmin {
        _vaultStatus = VaultStatus.Active;
        emit VaultUnhalted();
    }

    /// @inheritdoc IOwnVault
    function haltAsset(bytes32 asset_, bytes32 reason) external onlyAdmin {
        _assetHalted[asset_] = true;
        emit AssetHalted(asset_, reason);
    }

    /// @inheritdoc IOwnVault
    function unhaltAsset(bytes32 asset_) external onlyAdmin {
        _assetHalted[asset_] = false;
        emit AssetUnhalted(asset_);
    }

    /// @inheritdoc IOwnVault
    function isAssetHalted(bytes32 asset_) external view returns (bool) {
        return _assetHalted[asset_];
    }

    /// @inheritdoc IOwnVault
    function initiateWindDown() external onlyAdmin {
        _vaultStatus = VaultStatus.WindingDown;
        emit WindDownInitiated();
    }

    // ──────────────────────────────────────────────────────────
    //  Health and utilization
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function healthFactor() external view returns (uint256) {
        if (_totalExposure == 0) return type(uint256).max;
        return totalAssets().mulDiv(PRECISION, _totalExposure);
    }

    /// @inheritdoc IOwnVault
    function utilization() external view returns (uint256) {
        uint256 assets_ = totalAssets();
        if (assets_ == 0) return 0;
        return _totalExposure.mulDiv(BPS, assets_);
    }

    /// @inheritdoc IOwnVault
    function maxUtilization() external view returns (uint256) {
        return _maxUtilization;
    }

    /// @inheritdoc IOwnVault
    function setMaxUtilization(uint256 maxUtilBps) external onlyAdmin {
        _maxUtilization = maxUtilBps;
    }

    /// @inheritdoc IOwnVault
    function totalExposure() external view returns (uint256) {
        return _totalExposure;
    }

    /// @inheritdoc IOwnVault
    function withdrawalWaitPeriod() external view returns (uint256) {
        return _withdrawalWaitPeriod;
    }

    /// @inheritdoc IOwnVault
    function setWithdrawalWaitPeriod(uint256 period) external onlyAdmin {
        _withdrawalWaitPeriod = period;
    }

    // ──────────────────────────────────────────────────────────
    //  Order fee accrual & claims
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function depositFees(address token, uint256 amount) external onlyMarket {
        if (amount == 0) return;
        if (token != _paymentToken) revert WrongFeeToken(_paymentToken, token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Protocol takes its cut first (round up — protocol-favorable)
        uint256 protocolAmount = amount.mulDiv(_protocolShareBps, BPS, Math.Rounding.Ceil);
        uint256 remainder = amount - protocolAmount;

        // VM takes its share of the remainder (round down — LP-favorable)
        uint256 vmAmount = remainder.mulDiv(_vmShareBps, BPS);
        uint256 lpAmount = remainder - vmAmount;

        _protocolFees += protocolAmount;
        _vmFees += vmAmount;

        // LP share → rewards-per-share accumulator
        uint256 supply = totalSupply();
        if (supply == 0) {
            _protocolFees += lpAmount;
        } else if (lpAmount > 0) {
            _lpRewardsPerShare += lpAmount.mulDiv(PRECISION, supply);
        }

        emit FeeDeposited(token, amount, protocolAmount, vmAmount, lpAmount);
    }

    /// @inheritdoc IOwnVault
    function setProtocolShareBps(uint256 shareBps) external onlyAdmin {
        if (shareBps > BPS) revert ShareTooHigh(shareBps, BPS);
        uint256 oldShare = _protocolShareBps;
        _protocolShareBps = shareBps;
        emit ProtocolShareUpdated(oldShare, shareBps);
    }

    /// @inheritdoc IOwnVault
    function setVMShareBps(uint256 shareBps) external onlyVM {
        if (shareBps > BPS) revert ShareTooHigh(shareBps, BPS);
        uint256 oldShare = _vmShareBps;
        _vmShareBps = shareBps;
        emit VMShareUpdated(oldShare, shareBps);
    }

    /// @inheritdoc IOwnVault
    function protocolShareBps() external view returns (uint256) {
        return _protocolShareBps;
    }

    /// @inheritdoc IOwnVault
    function vmShareBps() external view returns (uint256) {
        return _vmShareBps;
    }

    /// @inheritdoc IOwnVault
    function claimProtocolFees() external nonReentrant {
        uint256 amount = _protocolFees;
        if (amount == 0) revert NoFeesToClaim();

        _protocolFees = 0;
        IERC20(_paymentToken).safeTransfer(registry.treasury(), amount);

        emit ProtocolFeesClaimed(_paymentToken, amount);
    }

    /// @inheritdoc IOwnVault
    function claimVMFees() external onlyVM nonReentrant {
        uint256 amount = _vmFees;
        if (amount == 0) revert NoFeesToClaim();

        _vmFees = 0;
        IERC20(_paymentToken).safeTransfer(vm, amount);

        emit VMFeesClaimed(_paymentToken, amount);
    }

    /// @inheritdoc IOwnVault
    function claimLPRewards() external nonReentrant returns (uint256 amount) {
        _settleLPReward(msg.sender);

        amount = _lpAccruedFees[msg.sender];
        if (amount == 0) revert NoFeesToClaim();

        _lpAccruedFees[msg.sender] = 0;
        IERC20(_paymentToken).safeTransfer(msg.sender, amount);

        emit LPRewardsClaimed(msg.sender, _paymentToken, amount);
    }

    /// @inheritdoc IOwnVault
    function accruedProtocolFees() external view returns (uint256) {
        return _protocolFees;
    }

    /// @inheritdoc IOwnVault
    function accruedVMFees() external view returns (uint256) {
        return _vmFees;
    }

    /// @inheritdoc IOwnVault
    function claimableLPRewards(address account) external view returns (uint256 amount) {
        uint256 userPaid = _lpCheckpoint[account];
        amount = _lpAccruedFees[account] + balanceOf(account).mulDiv(_lpRewardsPerShare - userPaid, PRECISION);
    }

    // ──────────────────────────────────────────────────────────
    //  Payment token management
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function setPaymentToken(address token) external onlyVM {
        if (token == address(0)) revert ZeroAddress();
        if (_protocolFees != 0 || _vmFees != 0) revert OutstandingFeesExist();

        address oldToken = _paymentToken;
        _paymentToken = token;

        emit PaymentTokenUpdated(oldToken, token);
    }

    /// @inheritdoc IOwnVault
    function paymentToken() external view returns (address) {
        return _paymentToken;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — LP reward settlement
    // ──────────────────────────────────────────────────────────

    /// @dev Override _update to settle LP rewards before any share balance change.
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && from != address(this)) {
            _settleLPReward(from);
        }
        if (to != address(0) && to != address(this)) {
            _settleLPReward(to);
        }
        super._update(from, to, amount);
    }

    /// @dev Settle pending LP rewards for an account.
    function _settleLPReward(address account) private {
        uint256 currentRPS = _lpRewardsPerShare;
        uint256 userPaid = _lpCheckpoint[account];
        if (currentRPS > userPaid) {
            uint256 owed = balanceOf(account).mulDiv(currentRPS - userPaid, PRECISION);
            if (owed > 0) {
                _lpAccruedFees[account] += owed;
            }
            _lpCheckpoint[account] = currentRPS;
        }
    }

    /// @dev Settle and claim LP rewards for an account (used by fulfillWithdrawal).
    function _claimLPRewardsFor(address account) private {
        _settleLPReward(account);

        uint256 amount = _lpAccruedFees[account];
        if (amount > 0) {
            _lpAccruedFees[account] = 0;
            IERC20(_paymentToken).safeTransfer(account, amount);
            emit LPRewardsClaimed(account, _paymentToken, amount);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Remove a request ID from the pending withdrawal list (swap-and-pop).
    function _removePendingRequest(uint256 requestId) private {
        uint256 len = _pendingRequestIds.length;
        for (uint256 i; i < len;) {
            if (_pendingRequestIds[i] == requestId) {
                _pendingRequestIds[i] = _pendingRequestIds[len - 1];
                _pendingRequestIds.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Remove a request ID from the pending deposit list (swap-and-pop).
    function _removePendingDeposit(uint256 requestId) private {
        uint256 len = _pendingDepositIds.length;
        for (uint256 i; i < len;) {
            if (_pendingDepositIds[i] == requestId) {
                _pendingDepositIds[i] = _pendingDepositIds[len - 1];
                _pendingDepositIds.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Collateral release (force execution)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function releaseCollateral(address to, uint256 amount) external onlyMarket nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransfer(to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Required overrides for diamond inheritance
    // ──────────────────────────────────────────────────────────

    function withdraw(uint256 assets, address receiver, address own)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        return super.withdraw(assets, receiver, own);
    }

    function redeem(uint256 shares, address receiver, address own)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        return super.redeem(shares, receiver, own);
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return super.totalAssets();
    }

    function convertToShares(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.convertToShares(assets);
    }

    function convertToAssets(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.convertToAssets(shares);
    }

    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_vaultStatus != VaultStatus.Active) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_vaultStatus != VaultStatus.Active) return 0;
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewDeposit(assets);
    }

    function previewMint(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewMint(shares);
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewRedeem(shares);
    }

    function asset() public view override(ERC4626, IERC4626) returns (address) {
        return super.asset();
    }
}
