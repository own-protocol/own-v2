// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IAaveDebtToken} from "../interfaces/external/IAaveDebtToken.sol";
import {IAaveV3Pool} from "../interfaces/external/IAaveV3Pool.sol";
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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title OwnVault — ERC-4626 collateral vault with async deposit/withdrawal
/// @notice Single vault holding collateral to back eToken exposure.
contract OwnVault is ERC4626, IOwnVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;

    /// @dev Multiplier that scales a collateral-token amount up to 18 decimals: 10**(18 - decimals).
    uint256 private immutable _collateralScale;

    address public vm;

    /// @dev Addresses authorised to sign order quotes for this vault (decoupled from `vm`).
    mapping(address => bool) private _quoteSigners;

    // ──────────────────────────────────────────────────────────
    //  Vault status
    // ──────────────────────────────────────────────────────────

    VaultStatus private _vaultStatus;
    mapping(bytes32 => bool) private _assetPaused;
    mapping(bytes32 => bool) private _assetHalted;
    mapping(bytes32 => uint256) private _assetHaltPrice;

    // ──────────────────────────────────────────────────────────
    //  Utilization & health
    // ──────────────────────────────────────────────────────────

    uint256 private _maxUtilization;
    uint256 private _withdrawalWaitPeriod;

    /// @dev Per-asset raw exposure in units (18 decimals).
    mapping(bytes32 => uint256) private _assetExposure;

    /// @dev Per-asset exposure in USD (18 decimals), updated incrementally.
    mapping(bytes32 => uint256) private _assetExposureUSD;

    /// @dev Per-asset last valuation update timestamp.
    mapping(bytes32 => uint256) private _assetLastUpdated;

    /// @dev Running total of all per-asset USD exposures. Updated incrementally — never loops.
    uint256 private _totalExposureUSD;

    /// @dev Collateral value in USD (18 decimals). Updated by keeper or on exposure changes.
    uint256 private _collateralValueUSD;

    // ──────────────────────────────────────────────────────────
    //  Order execution parameters (read by OwnMarket)
    // ──────────────────────────────────────────────────────────

    uint256 private _claimThreshold;
    bytes32 private _collateralOracleAsset;

    // ──────────────────────────────────────────────────────────
    //  Supported assets (VM-controlled)
    // ──────────────────────────────────────────────────────────

    mapping(bytes32 => bool) private _supportedAssets;

    // ──────────────────────────────────────────────────────────
    //  Payment token (single, VM-controlled)
    // ──────────────────────────────────────────────────────────

    address private _paymentToken;

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
    ///      Used by projectedUtilization() to estimate effective collateral.
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

    modifier onlyVM() {
        if (msg.sender != vm) revert OnlyVM();
        _;
    }

    modifier onlyVMOrAdmin() {
        if (msg.sender != vm && msg.sender != Ownable(address(registry)).owner()) revert OnlyVMOrAdmin();
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
    /// @param vm_         Vault manager address bound to this vault.
    /// @param maxUtilBps  Initial max utilization in BPS.
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        address registry_,
        address vm_,
        uint256 maxUtilBps
    ) ERC4626(IERC20(asset_)) ERC20(name_, symbol_) {
        uint8 collatDecimals = IERC20Metadata(asset_).decimals();
        if (collatDecimals > 18) revert DecimalsTooHigh(collatDecimals);
        _collateralScale = 10 ** (18 - collatDecimals);
        registry = IProtocolRegistry(registry_);
        vm = vm_;
        _maxUtilization = maxUtilBps;
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
        if (_requireDepositApproval && msg.sender != vm) revert DepositApprovalRequired();
        shares = super.deposit(assets, receiver);
        if (shares < minSharesOut) revert InsufficientSharesOut(shares, minSharesOut);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626, IERC4626) whenDepositsAllowed onlyVM nonReentrant returns (uint256) {
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
    ) external onlyVM nonReentrant {
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
    ) external onlyVM nonReentrant {
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

        // Enforce wait period
        uint256 readyAt = req.timestamp + _withdrawalWaitPeriod;
        if (block.timestamp < readyAt) {
            revert WithdrawalWaitPeriodNotElapsed(requestId, readyAt);
        }

        uint256 shares = req.shares;
        assets = convertToAssets(shares);

        // Check that withdrawal won't breach max utilization (in USD terms)
        if (_totalExposureUSD > 0) {
            // Block withdrawals if collateral value is unknown while exposure exists
            if (_collateralValueUSD == 0) revert CollateralValueNotInitialized();

            // Estimate collateral value after withdrawal
            uint256 collateralAfter = _collateralValueUSD - _collateralValueUSD.mulDiv(assets, totalAssets());
            if (collateralAfter > 0) {
                uint256 utilizationAfter = _totalExposureUSD.mulDiv(BPS, collateralAfter);
                if (utilizationAfter > _maxUtilization) {
                    revert MaxUtilizationExceeded(utilizationAfter, _maxUtilization);
                }
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

    // ── Pause ────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function pause(
        bytes32 reason
    ) external onlyAdmin {
        if (_vaultStatus != VaultStatus.Active) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Paused;
        emit VaultPaused(reason);
    }

    /// @inheritdoc IOwnVault
    function unpause() external onlyAdmin {
        if (_vaultStatus != VaultStatus.Paused) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Active;
        emit VaultUnpaused();
    }

    /// @inheritdoc IOwnVault
    function pauseAsset(bytes32 asset_, bytes32 reason) external onlyAdmin {
        _assetPaused[asset_] = true;
        emit AssetPaused(asset_, reason);
    }

    /// @inheritdoc IOwnVault
    function unpauseAsset(
        bytes32 asset_
    ) external onlyAdmin {
        _assetPaused[asset_] = false;
        emit AssetUnpaused(asset_);
    }

    /// @inheritdoc IOwnVault
    function isAssetPaused(
        bytes32 asset_
    ) external view returns (bool) {
        return _assetPaused[asset_];
    }

    // ── Halt ─────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function haltVault() external onlyAdmin {
        if (_vaultStatus != VaultStatus.Active) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Halted;
        emit VaultHalted();
    }

    /// @inheritdoc IOwnVault
    function unhalt() external onlyAdmin {
        if (_vaultStatus != VaultStatus.Halted) revert InvalidStatusTransition();
        _vaultStatus = VaultStatus.Active;
        emit VaultUnhalted();
    }

    /// @inheritdoc IOwnVault
    function haltAsset(bytes32 asset_, uint256 haltPrice) external onlyAdmin {
        if (haltPrice == 0) revert InvalidHaltPrice();
        _assetHalted[asset_] = true;
        _assetHaltPrice[asset_] = haltPrice;
        emit AssetHalted(asset_);
        emit AssetHaltPriceSet(asset_, haltPrice);
    }

    /// @inheritdoc IOwnVault
    function unhaltAsset(
        bytes32 asset_
    ) external onlyAdmin {
        _assetHalted[asset_] = false;
        _assetHaltPrice[asset_] = 0;
        emit AssetUnhalted(asset_);
    }

    /// @inheritdoc IOwnVault
    function isAssetHalted(
        bytes32 asset_
    ) external view returns (bool) {
        return _assetHalted[asset_];
    }

    /// @inheritdoc IOwnVault
    function getAssetHaltPrice(
        bytes32 asset_
    ) external view returns (uint256) {
        return _assetHaltPrice[asset_];
    }

    // ── Combined query helpers ───────────────────────────────

    /// @inheritdoc IOwnVault
    function isEffectivelyPaused(
        bytes32 asset_
    ) external view returns (bool) {
        return _vaultStatus == VaultStatus.Paused || _assetPaused[asset_];
    }

    /// @inheritdoc IOwnVault
    function isEffectivelyHalted(
        bytes32 asset_
    ) external view returns (bool) {
        return _vaultStatus == VaultStatus.Halted || _assetHalted[asset_];
    }

    // ──────────────────────────────────────────────────────────
    //  Health and utilization
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function healthFactor() external view returns (uint256) {
        if (_totalExposureUSD == 0) return type(uint256).max;
        return _collateralValueUSD.mulDiv(PRECISION, _totalExposureUSD);
    }

    /// @inheritdoc IOwnVault
    function utilization() external view returns (uint256) {
        if (_collateralValueUSD == 0) return 0;
        return _totalExposureUSD.mulDiv(BPS, _collateralValueUSD);
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
    function projectedUtilization() external view returns (uint256) {
        if (_collateralValueUSD == 0) return 0;
        uint256 total = totalAssets();
        if (total == 0) return type(uint256).max;
        uint256 pendingAssets = convertToAssets(_pendingWithdrawalShares);
        uint256 pendingValueUSD = _collateralValueUSD.mulDiv(pendingAssets, total);
        uint256 effectiveCollateral = _collateralValueUSD - pendingValueUSD;
        if (effectiveCollateral == 0) return type(uint256).max;
        return _totalExposureUSD.mulDiv(BPS, effectiveCollateral);
    }

    /// @inheritdoc IOwnVault
    function projectedExposureUtilization(
        uint256 additionalExposureUSD
    ) external view returns (uint256) {
        if (_collateralValueUSD == 0) return 0;
        return (_totalExposureUSD + additionalExposureUSD).mulDiv(BPS, _collateralValueUSD);
    }

    /// @inheritdoc IOwnVault
    function pendingWithdrawalShares() external view returns (uint256) {
        return _pendingWithdrawalShares;
    }

    /// @inheritdoc IOwnVault
    function totalExposureUSD() external view returns (uint256) {
        return _totalExposureUSD;
    }

    /// @inheritdoc IOwnVault
    function collateralValueUSD() external view returns (uint256) {
        return _collateralValueUSD;
    }

    /// @inheritdoc IOwnVault
    function assetExposure(
        bytes32 asset_
    ) external view returns (uint256) {
        return _assetExposure[asset_];
    }

    /// @inheritdoc IOwnVault
    function assetExposureUSD(
        bytes32 asset_
    ) external view returns (uint256) {
        return _assetExposureUSD[asset_];
    }

    /// @inheritdoc IOwnVault
    function assetLastUpdated(
        bytes32 asset_
    ) external view returns (uint256) {
        return _assetLastUpdated[asset_];
    }

    /// @inheritdoc IOwnVault
    function updateExposure(bytes32 asset_, int256 delta, uint256 price) external onlyMarket {
        // Update raw units
        if (delta > 0) {
            _assetExposure[asset_] += uint256(delta);
        } else if (delta < 0) {
            _assetExposure[asset_] -= uint256(-delta);
        }

        // Update USD values using provided execution price
        uint256 oldUSD = _assetExposureUSD[asset_];
        uint256 newUSD = _assetExposure[asset_].mulDiv(price, PRECISION);
        _assetExposureUSD[asset_] = newUSD;
        _totalExposureUSD = _totalExposureUSD - oldUSD + newUSD;

        // Also refresh collateral value
        _refreshCollateralValue();
    }

    /// @inheritdoc IOwnVault
    function updateAssetValuation(
        bytes32 asset_
    ) external {
        address oracleAddr = _getOracleForAsset(asset_);
        if (oracleAddr == address(0)) revert PriceNotAvailable(asset_);

        (uint256 price,) = IOracleVerifier(oracleAddr).getPrice(asset_);
        if (price == 0) revert PriceNotAvailable(asset_);

        uint256 oldUSD = _assetExposureUSD[asset_];
        uint256 newUSD = _assetExposure[asset_].mulDiv(price, PRECISION);

        _assetExposureUSD[asset_] = newUSD;
        _totalExposureUSD = _totalExposureUSD - oldUSD + newUSD;
        _assetLastUpdated[asset_] = block.timestamp;

        emit AssetValuationUpdated(asset_, _assetExposure[asset_], newUSD, price);
    }

    /// @inheritdoc IOwnVault
    function updateCollateralValuation() external {
        _refreshCollateralValue();
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
    //  Order execution parameters
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function claimThreshold() external view returns (uint256) {
        return _claimThreshold;
    }

    /// @inheritdoc IOwnVault
    function setClaimThreshold(
        uint256 threshold
    ) external onlyAdmin {
        _claimThreshold = threshold;
    }

    /// @inheritdoc IOwnVault
    function collateralOracleAsset() external view returns (bytes32) {
        return _collateralOracleAsset;
    }

    /// @inheritdoc IOwnVault
    function setCollateralOracleAsset(
        bytes32 asset_
    ) external onlyAdmin {
        _collateralOracleAsset = asset_;
    }

    // ──────────────────────────────────────────────────────────
    //  Share yield (VM-distributed LP rewards)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function shareYield(
        uint256 amount
    ) external onlyVM nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Cannot distribute yield with no shares outstanding; the assets would otherwise
        // accrue to whoever deposits first.
        if (totalSupply() == 0) revert NoSharesToReward();

        // VM transfers collateral in → totalAssets() rises → share price rises for all LPs.
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        // Keep the cached collateral USD valuation in step with the larger balance.
        _refreshCollateralValue();

        emit ShareYieldAdded(msg.sender, amount);
    }

    /// @inheritdoc IOwnVault
    function setVM(
        address newVM
    ) external onlyAdmin {
        if (newVM == address(0)) revert ZeroAddress();
        address oldVM = vm;
        vm = newVM;
        emit VMUpdated(oldVM, newVM);
    }

    /// @inheritdoc IOwnVault
    function isQuoteSigner(
        address account
    ) external view returns (bool) {
        return _quoteSigners[account];
    }

    /// @inheritdoc IOwnVault
    function addQuoteSigner(
        address signer
    ) external onlyVMOrAdmin {
        if (signer == address(0)) revert ZeroAddress();
        if (_quoteSigners[signer]) revert AlreadyQuoteSigner(signer);
        _quoteSigners[signer] = true;
        emit QuoteSignerAdded(signer);
    }

    /// @inheritdoc IOwnVault
    function removeQuoteSigner(
        address signer
    ) external onlyVMOrAdmin {
        if (!_quoteSigners[signer]) revert NotQuoteSigner(signer);
        _quoteSigners[signer] = false;
        emit QuoteSignerRemoved(signer);
    }

    // ──────────────────────────────────────────────────────────
    //  Supported assets
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function enableAsset(
        bytes32 asset_
    ) external onlyVM {
        _supportedAssets[asset_] = true;
        emit AssetEnabled(asset_);
    }

    /// @inheritdoc IOwnVault
    function disableAsset(
        bytes32 asset_
    ) external onlyVM {
        _supportedAssets[asset_] = false;
        emit AssetDisabled(asset_);
    }

    /// @inheritdoc IOwnVault
    function isAssetSupported(
        bytes32 asset_
    ) external view returns (bool) {
        return _supportedAssets[asset_];
    }

    // ──────────────────────────────────────────────────────────
    //  Payment token management
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function setPaymentToken(
        address token
    ) external onlyVM {
        if (token == address(0)) revert ZeroAddress();
        if (token == asset()) revert PaymentTokenCannotBeCollateral();
        uint256 decimals = IERC20Metadata(token).decimals();
        if (decimals > 18) revert DecimalsTooHigh(decimals);

        address oldToken = _paymentToken;
        _paymentToken = token;

        emit PaymentTokenUpdated(oldToken, token);
    }

    /// @inheritdoc IOwnVault
    function paymentToken() external view returns (address) {
        return _paymentToken;
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
    //  Lending opt-in
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnVault
    function enableLending(address userBorrowManager, address debtToken) external onlyAdmin {
        if (userBorrowManager == address(0) || debtToken == address(0)) {
            revert ZeroAddress();
        }
        if (_borrowManager != address(0)) revert LendingAlreadyEnabled();

        _borrowManager = userBorrowManager;

        // Per-spender delegation — the manager can call pool.borrow(... onBehalfOf=vault).
        IAaveDebtToken(debtToken).approveDelegation(userBorrowManager, type(uint256).max);

        emit LendingEnabled(userBorrowManager, debtToken);
    }

    /// @inheritdoc IOwnVault
    function enableAaveCollateral(address pool, address underlying) external onlyAdmin {
        if (pool == address(0) || underlying == address(0)) revert ZeroAddress();
        IAaveV3Pool(pool).setUserUseReserveAsCollateral(underlying, true);
        emit AaveCollateralEnabled(pool, underlying);
    }

    /// @inheritdoc IOwnVault
    function borrowManager() external view returns (address) {
        return _borrowManager;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — valuation
    // ──────────────────────────────────────────────────────────

    /// @dev Refresh the collateral value in USD using the collateral oracle.
    function _refreshCollateralValue() private {
        bytes32 collatAsset = _collateralOracleAsset;
        if (collatAsset == bytes32(0)) return;

        address oracleAddr = _getOracleForAsset(collatAsset);
        if (oracleAddr == address(0)) return;

        (uint256 price,) = IOracleVerifier(oracleAddr).getPrice(collatAsset);
        if (price == 0) return;

        // Normalize the collateral balance to 18 decimals before pricing so the USD value
        // is on the same scale as exposure (e.g. 6-decimal aUSDC/USDC vs 18-decimal eTokens).
        _collateralValueUSD = (totalAssets() * _collateralScale).mulDiv(price, PRECISION);

        emit CollateralValuationUpdated(_collateralValueUSD, price);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Resolve the oracle address for an asset via ProtocolRegistry.
    function _getOracleForAsset(
        bytes32 ticker
    ) private view returns (address) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(ticker);
        if (oracleType == 0) return registry.pythOracle();
        return registry.inhouseOracle();
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

    /// @inheritdoc IOwnVault
    function releaseCollateralForBadDebt(address to, uint256 amount) external onlyBorrowManager nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // The borrow manager has already repaid the corresponding Aave debt, so
        // this aToken slice is unlocked. Releasing it shrinks totalAssets, which
        // socializes the bad-debt loss to LPs via a lower share price; refresh
        // the cached collateral value so the debt cap tracks the smaller base.
        IERC20(asset()).safeTransfer(to, amount);
        _refreshCollateralValue();
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
