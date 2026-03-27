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

/// @title OwnVault — ERC-4626 collateral vault with async deposit/withdrawal and health tracking
/// @notice Each vault is bound to a single VM and holds one LP collateral type
///         as trustless security for outstanding eToken exposure. Extends ERC-4626
///         with async deposit approval, FIFO withdrawal queue, health/utilization
///         tracking, and fee management.
contract OwnVault is ERC4626, IOwnVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol registry for resolving all contract addresses.
    IProtocolRegistry public immutable registry;

    /// @notice The vault manager (VM) bound to this vault.
    address public immutable vm;

    // ──────────────────────────────────────────────────────────
    //  Vault status
    // ──────────────────────────────────────────────────────────

    VaultStatus private _vaultStatus;

    /// @dev Per-asset halt status.
    mapping(bytes32 => bool) private _assetHalted;

    // ──────────────────────────────────────────────────────────
    //  Utilization & health
    // ──────────────────────────────────────────────────────────

    uint256 private _maxUtilization;
    uint256 private _totalExposure;

    // ──────────────────────────────────────────────────────────
    //  Fees
    // ──────────────────────────────────────────────────────────

    uint256 private _aumFee;
    uint256 private _lastAumFeeAccrual;

    // ──────────────────────────────────────────────────────────
    //  Order fee accrual (Uniswap-style per-vault)
    // ──────────────────────────────────────────────────────────

    /// @dev Protocol's share of all order fees in BPS.
    uint256 private _protocolShareBps;

    /// @dev VM's share of the LP+VM remainder in BPS.
    uint256 private _vmShareBps;

    /// @dev Accrued unclaimed protocol fees per fee token.
    mapping(address => uint256) private _protocolFees;

    /// @dev Accrued unclaimed VM fees per fee token.
    mapping(address => uint256) private _vmFees;

    /// @dev Per fee-token cumulative LP rewards-per-share (scaled by PRECISION).
    mapping(address => uint256) private _lpRewardsPerShare;

    /// @dev Per (account, token) checkpoint — last-seen rewardsPerShare.
    mapping(address => mapping(address => uint256)) private _lpCheckpoint;

    /// @dev Per (account, token) accrued unclaimed LP fee rewards.
    mapping(address => mapping(address => uint256)) private _lpAccruedFees;

    /// @dev Registered fee tokens for this vault (max ~3 for MVP).
    address[] private _rewardTokens;

    /// @dev O(1) lookup: is this token in _rewardTokens?
    mapping(address => bool) private _isRewardToken;

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
        require(msg.sender == Ownable(address(registry)).owner(), "OwnVault: not admin");
        _;
    }

    modifier onlyVM() {
        if (msg.sender != vm) revert OnlyVM();
        _;
    }

    modifier onlyMarket() {
        require(msg.sender == registry.market(), "OwnVault: not market");
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

    /// @param asset_            Underlying collateral ERC-20.
    /// @param name_             Vault share name.
    /// @param symbol_           Vault share symbol.
    /// @param registry_         ProtocolRegistry contract address.
    /// @param vm_               Vault manager address bound to this vault.
    /// @param maxUtilBps        Initial max utilization in BPS.
    /// @param aumFeeBps         Initial AUM fee in BPS.
    /// @param protocolShareBps_ Initial protocol fee share in BPS.
    /// @param vmShareBps_       Initial VM fee share (of LP+VM remainder) in BPS.
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        address registry_,
        address vm_,
        uint256 maxUtilBps,
        uint256 aumFeeBps,
        uint256 protocolShareBps_,
        uint256 vmShareBps_
    ) ERC4626(IERC20(asset_)) ERC20(name_, symbol_) {
        if (protocolShareBps_ > BPS) revert ShareTooHigh(protocolShareBps_, BPS);
        if (vmShareBps_ > BPS) revert ShareTooHigh(vmShareBps_, BPS);
        registry = IProtocolRegistry(registry_);
        vm = vm_;
        _maxUtilization = maxUtilBps;
        _aumFee = aumFeeBps;
        _lastAumFeeAccrual = block.timestamp;
        _vaultStatus = VaultStatus.Active;
        _protocolShareBps = protocolShareBps_;
        _vmShareBps = vmShareBps_;
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626 overrides (gate deposits on vault status + VM)
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

    /// @dev Standard ERC-4626 withdraw/redeem return 0 max when utilization is high,
    ///      signalling LPs to use the async queue.
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

        // Transfer assets from depositor to vault (escrow)
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

        // Calculate shares using ERC-4626 preview
        uint256 shares = previewDeposit(req.assets);

        // Update status
        req.status = DepositStatus.Accepted;

        // Remove from pending list
        _removePendingDeposit(requestId);

        // Mint shares to receiver (assets are already in the vault)
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

        // Update status
        req.status = DepositStatus.Rejected;

        // Remove from pending list
        _removePendingDeposit(requestId);

        // Return escrowed assets to depositor
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

        // Update status
        req.status = DepositStatus.Cancelled;

        // Remove from pending list
        _removePendingDeposit(requestId);

        // Return escrowed assets to depositor
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
    function getPendingDeposits() external view returns (uint256[] memory requestIds) {
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

        // Transfer shares from LP to vault (escrow)
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
        require(req.status == WithdrawalStatus.Pending, "OwnVault: not pending");

        req.status = WithdrawalStatus.Cancelled;

        // Return escrowed shares
        _transfer(address(this), msg.sender, req.shares);

        // Remove from pending list
        _removePendingRequest(requestId);

        emit WithdrawalCancelled(requestId, msg.sender);
    }

    /// @inheritdoc IOwnVault
    function fulfillWithdrawal(
        uint256 requestId
    ) external nonReentrant returns (uint256 assets) {
        WithdrawalRequest storage req = _withdrawalRequests[requestId];
        if (req.owner == address(0)) revert WithdrawalRequestNotFound(requestId);
        require(req.status == WithdrawalStatus.Pending, "OwnVault: not pending");

        uint256 shares = req.shares;
        assets = convertToAssets(shares);

        req.status = WithdrawalStatus.Fulfilled;

        // Remove from pending list
        _removePendingRequest(requestId);

        // Auto-claim any accrued LP fee rewards before exit
        _claimAllLPRewardsFor(req.owner);

        // Burn escrowed shares and transfer assets to owner
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
    function getPendingWithdrawals() external view returns (uint256[] memory requestIds) {
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
    function halt(
        bytes32 reason
    ) external onlyAdmin {
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
    function unhaltAsset(
        bytes32 asset_
    ) external onlyAdmin {
        _assetHalted[asset_] = false;
        emit AssetUnhalted(asset_);
    }

    /// @inheritdoc IOwnVault
    function isAssetHalted(
        bytes32 asset_
    ) external view returns (bool) {
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
        uint256 assets = totalAssets();
        if (assets == 0) return 0;
        return _totalExposure.mulDiv(BPS, assets);
    }

    /// @inheritdoc IOwnVault
    function maxUtilization() external view returns (uint256) {
        return _maxUtilization;
    }

    /// @inheritdoc IOwnVault
    function setMaxUtilization(
        uint256 maxUtilBps
    ) external onlyAdmin {
        _maxUtilization = maxUtilBps;
    }

    /// @inheritdoc IOwnVault
    function totalExposure() external view returns (uint256) {
        return _totalExposure;
    }

    // ──────────────────────────────────────────────────────────
    //  Fee management
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function aumFee() external view returns (uint256) {
        return _aumFee;
    }

    /// @inheritdoc IOwnVault
    function setAumFee(
        uint256 feeBps
    ) external onlyAdmin {
        _aumFee = feeBps;
    }

    /// @inheritdoc IOwnVault
    function accrueAumFee() external {
        _accrueAumFee();
    }

    // ──────────────────────────────────────────────────────────
    //  Order fee accrual & claims
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function depositFees(address token, uint256 amount) external onlyMarket {
        if (amount == 0) return;

        // Pull fee tokens from OwnMarket
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Protocol takes its cut first (round up — protocol-favorable)
        uint256 protocolAmount = amount.mulDiv(_protocolShareBps, BPS, Math.Rounding.Ceil);
        uint256 remainder = amount - protocolAmount;

        // VM takes its share of the remainder (round down — LP-favorable)
        uint256 vmAmount = remainder.mulDiv(_vmShareBps, BPS);
        uint256 lpAmount = remainder - vmAmount;

        // Accrue protocol and VM balances
        _protocolFees[token] += protocolAmount;
        _vmFees[token] += vmAmount;

        // LP share → rewards-per-share accumulator
        uint256 supply = totalSupply();
        if (supply == 0) {
            // No LPs — redirect LP portion to protocol
            _protocolFees[token] += lpAmount;
        } else if (lpAmount > 0) {
            // Rounding: floor — any dust stays for the next deposit
            _lpRewardsPerShare[token] += lpAmount.mulDiv(PRECISION, supply);
        }

        // Register reward token if first time
        if (!_isRewardToken[token]) {
            _isRewardToken[token] = true;
            _rewardTokens.push(token);
        }

        emit FeeDeposited(token, amount, protocolAmount, vmAmount, lpAmount);
    }

    /// @inheritdoc IOwnVault
    function setProtocolShareBps(
        uint256 shareBps
    ) external onlyAdmin {
        if (shareBps > BPS) revert ShareTooHigh(shareBps, BPS);
        uint256 oldShare = _protocolShareBps;
        _protocolShareBps = shareBps;
        emit ProtocolShareUpdated(oldShare, shareBps);
    }

    /// @inheritdoc IOwnVault
    function setVMShareBps(
        uint256 shareBps
    ) external onlyVM {
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
    function claimProtocolFees(
        address token
    ) external nonReentrant {
        uint256 amount = _protocolFees[token];
        if (amount == 0) revert NoFeesToClaim();

        _protocolFees[token] = 0;
        IERC20(token).safeTransfer(registry.treasury(), amount);

        emit ProtocolFeesClaimed(token, amount);
    }

    /// @inheritdoc IOwnVault
    function claimVMFees(
        address token
    ) external onlyVM nonReentrant {
        uint256 amount = _vmFees[token];
        if (amount == 0) revert NoFeesToClaim();

        _vmFees[token] = 0;
        IERC20(token).safeTransfer(vm, amount);

        emit VMFeesClaimed(token, amount);
    }

    /// @inheritdoc IOwnVault
    function claimLPRewards(
        address token
    ) external nonReentrant returns (uint256 amount) {
        _settleLPReward(msg.sender, token);

        amount = _lpAccruedFees[msg.sender][token];
        if (amount == 0) revert NoFeesToClaim();

        _lpAccruedFees[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit LPRewardsClaimed(msg.sender, token, amount);
    }

    /// @inheritdoc IOwnVault
    function claimAllLPRewards() external nonReentrant {
        _claimAllLPRewardsFor(msg.sender);
    }

    /// @inheritdoc IOwnVault
    function accruedProtocolFees(
        address token
    ) external view returns (uint256) {
        return _protocolFees[token];
    }

    /// @inheritdoc IOwnVault
    function accruedVMFees(
        address token
    ) external view returns (uint256) {
        return _vmFees[token];
    }

    /// @inheritdoc IOwnVault
    function claimableLPRewards(address token, address account) external view returns (uint256 amount) {
        uint256 currentRPS = _lpRewardsPerShare[token];
        uint256 userPaid = _lpCheckpoint[account][token];
        // Rounding: floor — protocol keeps dust
        amount = _lpAccruedFees[account][token] + balanceOf(account).mulDiv(currentRPS - userPaid, PRECISION);
    }

    /// @inheritdoc IOwnVault
    function getRewardTokens() external view returns (address[] memory tokens) {
        return _rewardTokens;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — LP reward settlement
    // ──────────────────────────────────────────────────────────

    /// @dev Override _update to settle LP rewards for both sender and receiver
    ///      before any share balance change. Mirrors the EToken dividend pattern.
    function _update(address from, address to, uint256 amount) internal override {
        // Settle BEFORE balance change (pre-transfer balances)
        // Skip address(0) (mint/burn) and address(this) (vault-escrowed shares)
        if (from != address(0) && from != address(this)) {
            _settleLPRewards(from);
        }
        if (to != address(0) && to != address(this)) {
            _settleLPRewards(to);
        }
        super._update(from, to, amount);
    }

    /// @dev Settle pending LP rewards for an account across all registered fee tokens.
    function _settleLPRewards(
        address account
    ) private {
        uint256 len = _rewardTokens.length;
        for (uint256 i; i < len;) {
            _settleLPReward(account, _rewardTokens[i]);
            unchecked {
                ++i;
            } // SAFETY: i < len
        }
    }

    /// @dev Settle pending LP rewards for an account for a single fee token.
    function _settleLPReward(address account, address token) private {
        uint256 currentRPS = _lpRewardsPerShare[token];
        uint256 userPaid = _lpCheckpoint[account][token];
        if (currentRPS > userPaid) {
            // Rounding: floor — protocol keeps dust
            uint256 owed = balanceOf(account).mulDiv(currentRPS - userPaid, PRECISION);
            if (owed > 0) {
                _lpAccruedFees[account][token] += owed;
                emit LPRewardsSettled(account, token, owed);
            }
            _lpCheckpoint[account][token] = currentRPS;
        }
    }

    /// @dev Settle and claim all LP fee rewards for an account. Used by
    ///      fulfillWithdrawal for auto-claim on LP exit.
    function _claimAllLPRewardsFor(
        address account
    ) private {
        uint256 len = _rewardTokens.length;
        for (uint256 i; i < len;) {
            address token = _rewardTokens[i];
            _settleLPReward(account, token);

            uint256 amount = _lpAccruedFees[account][token];
            if (amount > 0) {
                _lpAccruedFees[account][token] = 0;
                IERC20(token).safeTransfer(account, amount);
                emit LPRewardsClaimed(account, token, amount);
            }
            unchecked {
                ++i;
            } // SAFETY: i < len
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — AUM fee
    // ──────────────────────────────────────────────────────────

    function _accrueAumFee() private {
        if (_aumFee == 0) return;

        uint256 elapsed = block.timestamp - _lastAumFeeAccrual;
        if (elapsed == 0) return;

        _lastAumFeeAccrual = block.timestamp;

        uint256 assets = totalAssets();
        if (assets == 0) return;

        // Annual fee prorated: fee = assets * aumFee / BPS * elapsed / 365 days
        uint256 feeAmount = assets.mulDiv(_aumFee * elapsed, BPS * 365 days);
        if (feeAmount == 0) return;

        address _treasury = registry.treasury();
        IERC20(asset()).safeTransfer(_treasury, feeAmount);
        emit AumFeeCollected(feeAmount, _treasury);
    }

    /// @dev Remove a request ID from the pending withdrawal list (swap-and-pop).
    function _removePendingRequest(
        uint256 requestId
    ) private {
        uint256 len = _pendingRequestIds.length;
        for (uint256 i; i < len;) {
            if (_pendingRequestIds[i] == requestId) {
                _pendingRequestIds[i] = _pendingRequestIds[len - 1];
                _pendingRequestIds.pop();
                return;
            }
            unchecked {
                ++i;
            } // SAFETY: i < len
        }
    }

    /// @dev Remove a request ID from the pending deposit list (swap-and-pop).
    function _removePendingDeposit(
        uint256 requestId
    ) private {
        uint256 len = _pendingDepositIds.length;
        for (uint256 i; i < len;) {
            if (_pendingDepositIds[i] == requestId) {
                _pendingDepositIds[i] = _pendingDepositIds[len - 1];
                _pendingDepositIds.pop();
                return;
            }
            unchecked {
                ++i;
            } // SAFETY: i < len
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Required overrides for diamond inheritance
    //  (IOwnVault extends IERC4626 → functions exist in both
    //   ERC4626 and IERC4626, so Solidity requires explicit overrides)
    // ──────────────────────────────────────────────────────────

    function withdraw(
        uint256 assets,
        address receiver,
        address own
    ) public override(ERC4626, IERC4626) returns (uint256) {
        return super.withdraw(assets, receiver, own);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address own
    ) public override(ERC4626, IERC4626) returns (uint256) {
        return super.redeem(shares, receiver, own);
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return super.totalAssets();
    }

    function convertToShares(
        uint256 assets
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.convertToShares(assets);
    }

    function convertToAssets(
        uint256 shares
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.convertToAssets(shares);
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

    function previewDeposit(
        uint256 assets
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewDeposit(assets);
    }

    function previewMint(
        uint256 shares
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewMint(shares);
    }

    function previewWithdraw(
        uint256 assets
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewWithdraw(assets);
    }

    function previewRedeem(
        uint256 shares
    ) public view override(ERC4626, IERC4626) returns (uint256) {
        return super.previewRedeem(shares);
    }

    function asset() public view override(ERC4626, IERC4626) returns (address) {
        return super.asset();
    }
}
