// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

import {IEToken} from "../interfaces/IEToken.sol";
import {IEUSD} from "../interfaces/IEUSD.sol";
import {IEUSDManager} from "../interfaces/IEUSDManager.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EUSDManager — CDP engine for the eUSD stablecoin
/// @notice Custodies eToken collateral (debtor collateral, never LP equity — see
///         docs/psm-design.md §2) and owns all CDP logic: deposits/withdrawals, minting against a
///         fresh oracle price, repay/close, keeper liquidation at a fixed bonus, and
///         riskiest-first redemption as the peg anchor. Standalone module: touches no existing
///         protocol contract, resolves the oracle and roles through the ProtocolRegistry.
/// @dev Positions with debt live in a per-collateral doubly-linked list sorted ascending by
///      nominal ratio (stored collateral / stored debt) — price-invariant within one collateral,
///      so ordering only changes when a position is touched. Insertions take an O(1) hint (the
///      prospective predecessor) and fall back to a head walk. Collateral tokens are protocol
///      eTokens (18 decimals, no transfer fees), validated against the AssetRegistry at add time.
///      Runs behind an ERC-1967 proxy (UUPS) so the manager address — and the positions it
///      custodies — survive upgrades (e.g. the planned per-collateral risk params). Upgrades are
///      ADMIN-gated ({_authorizeUpgrade}); ossification is a final upgrade to an implementation
///      whose {_authorizeUpgrade} always reverts.
contract EUSDManager is IEUSDManager, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @dev Sorted-list node. prev points toward the head (riskier), next toward the tail (safer).
    struct ListNode {
        address prev;
        address next;
    }

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev Stability-fee year basis (simple interest).
    uint256 private constant YEAR = 365 days;

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve the oracle, AssetRegistry, treasury and roles.
    /// @dev Initializer-set, fixed thereafter (storage, not immutable, so an upgraded
    ///      implementation can never silently rebind it).
    IProtocolRegistry public registry;

    /// @dev The eUSD token minted and burned by this manager. Initializer-set, fixed thereafter.
    IEUSD private _eusd;

    RiskParams private _riskParams;

    /// @inheritdoc IEUSDManager
    bool public override mintPaused;

    /// @inheritdoc IEUSDManager
    uint256 public override totalDebt;

    /// @inheritdoc IEUSDManager
    mapping(address => uint256) public override totalCollateral;

    mapping(address => CollateralConfig) private _collateralConfigs;
    mapping(address => mapping(address => Position)) private _positions;

    mapping(address => mapping(address => ListNode)) private _nodes;

    /// @inheritdoc IEUSDManager
    mapping(address => address) public override listHead;

    /// @inheritdoc IEUSDManager
    mapping(address => address) public override listTail;

    /// @inheritdoc IEUSDManager
    mapping(address => uint256) public override listSize;

    /// @dev Global stability-fee index: cumulative stabilityFeeBps × elapsed seconds.
    uint256 private _feeIndex;
    uint256 private _feeIndexUpdated;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev The implementation is only ever used behind an ERC-1967 proxy; lock its own
    ///      initializers so the bare implementation can never be initialized or taken over.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the manager proxy (runs once, in the proxy's constructor call).
    /// @param registry_ ProtocolRegistry contract address.
    /// @param eusd_     EUSD token address (this manager must hold its MINTER_ROLE).
    /// @param params    Initial risk parameters (validated as in the setters).
    function initialize(address registry_, address eusd_, RiskParams calldata params) external initializer {
        if (registry_ == address(0) || eusd_ == address(0)) revert ZeroAddress();
        _validateRatios(params.mcrBps, params.liquidationThresholdBps, params.liquidationBonusBps);
        if (params.stabilityFeeBps > BPS || params.mintPriceMaxAge == 0) revert InvalidRiskParams();
        registry = IProtocolRegistry(registry_);
        _eusd = IEUSD(eusd_);
        _riskParams = params;
        _feeIndexUpdated = block.timestamp;
    }

    /// @dev UUPS upgrade gate: only the protocol ADMIN role may upgrade this proxy's
    ///      implementation.
    function _authorizeUpgrade(
        address
    ) internal view override onlyAdmin {}

    // ──────────────────────────────────────────────────────────
    //  External — position management
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDManager
    function deposit(address collateral, uint256 amount, address hint) external override nonReentrant {
        CollateralConfig storage cfg = _requireCollateral(collateral);
        if (!cfg.enabled) revert CollateralDisabled(collateral);
        if (amount == 0) revert ZeroAmount();

        Position storage p = _accrue(collateral, msg.sender);
        p.collateral += amount;
        totalCollateral[collateral] += amount;
        _reindex(collateral, msg.sender, hint);

        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(collateral, msg.sender, amount);
    }

    /// @inheritdoc IEUSDManager
    function withdrawCollateral(address collateral, uint256 amount, address hint) external override nonReentrant {
        CollateralConfig storage cfg = _requireCollateral(collateral);
        if (amount == 0) revert ZeroAmount();

        Position storage p = _accrue(collateral, msg.sender);
        if (amount > p.collateral) revert InsufficientCollateral(amount, p.collateral);
        p.collateral -= amount;
        totalCollateral[collateral] -= amount;

        // Risk-increasing while debt exists: fresh in-session price + MCR, same gate as minting.
        if (p.debt > 0) {
            uint256 ratio = _ratioBps(p.collateral, p.debt, _freshPrice(collateral, cfg.ticker));
            if (ratio < _riskParams.mcrBps) revert CollateralRatioTooLow(ratio, _riskParams.mcrBps);
        }
        _reindex(collateral, msg.sender, hint);

        IERC20(collateral).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(collateral, msg.sender, amount);
    }

    /// @inheritdoc IEUSDManager
    function mint(address collateral, uint256 amount, address hint) external override nonReentrant {
        CollateralConfig storage cfg = _requireCollateral(collateral);
        if (!cfg.enabled) revert CollateralDisabled(collateral);
        if (mintPaused) revert MintingPaused();
        if (amount == 0) revert ZeroAmount();

        Position storage p = _accrue(collateral, msg.sender);

        uint256 newDebt = p.debt + amount;
        if (newDebt < _riskParams.minDebt) revert BelowMinimumDebt(newDebt, _riskParams.minDebt);
        uint256 newTotal = totalDebt + amount;
        if (newTotal > _riskParams.debtCeiling) revert DebtCeilingExceeded(newTotal, _riskParams.debtCeiling);

        uint256 ratio = _ratioBps(p.collateral, newDebt, _freshPrice(collateral, cfg.ticker));
        if (ratio < _riskParams.mcrBps) revert CollateralRatioTooLow(ratio, _riskParams.mcrBps);

        p.debt = newDebt;
        totalDebt = newTotal;
        _reindex(collateral, msg.sender, hint);

        _eusd.mint(msg.sender, amount);
        emit EUSDMinted(collateral, msg.sender, amount, newDebt);
    }

    /// @inheritdoc IEUSDManager
    function repay(address collateral, address owner, uint256 amount, address hint) external override nonReentrant {
        _requireCollateral(collateral);
        if (owner == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Position storage p = _accrue(collateral, owner);
        if (p.debt == 0) revert NoDebt(collateral, owner);

        uint256 repaid = amount > p.debt ? p.debt : amount;
        uint256 remaining = p.debt - repaid;
        if (remaining != 0 && remaining < _riskParams.minDebt) {
            revert BelowMinimumDebt(remaining, _riskParams.minDebt);
        }

        p.debt = remaining;
        totalDebt -= repaid;
        _reindex(collateral, owner, hint);

        _eusd.burn(msg.sender, repaid);
        emit EUSDRepaid(collateral, owner, msg.sender, repaid, remaining);
    }

    /// @inheritdoc IEUSDManager
    function closePosition(
        address collateral
    ) external override nonReentrant {
        _requireCollateral(collateral);
        Position storage p = _accrue(collateral, msg.sender);
        uint256 debt = p.debt;
        uint256 coll = p.collateral;
        if (debt == 0 && coll == 0) revert EmptyPosition(collateral, msg.sender);

        if (_isListed(collateral, msg.sender)) _removeNode(collateral, msg.sender);
        totalDebt -= debt;
        totalCollateral[collateral] -= coll;
        delete _positions[collateral][msg.sender];

        if (debt > 0) _eusd.burn(msg.sender, debt);
        if (coll > 0) IERC20(collateral).safeTransfer(msg.sender, coll);
        emit PositionClosed(collateral, msg.sender, coll, debt);
    }

    // ──────────────────────────────────────────────────────────
    //  External — liquidation & redemption
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDManager
    function liquidate(
        address collateral,
        address owner,
        uint256 amount,
        address hint
    ) external override nonReentrant {
        bytes32 ticker = _requireCollateral(collateral).ticker;
        if (amount == 0) revert ZeroAmount();
        Position storage p = _accrue(collateral, owner);
        if (p.debt == 0) revert NoDebt(collateral, owner);

        uint256 price = _anchorPrice(collateral, ticker);
        {
            uint256 ratio = _ratioBps(p.collateral, p.debt, price);
            uint16 threshold = _riskParams.liquidationThresholdBps;
            if (ratio >= threshold) revert PositionNotLiquidatable(ratio, threshold);
        }

        uint256 repaid = amount > p.debt ? p.debt : amount;
        uint256 remaining = p.debt - repaid;
        if (remaining != 0 && remaining < _riskParams.minDebt) {
            revert BelowMinimumDebt(remaining, _riskParams.minDebt);
        }
        (uint256 seized, uint256 refund) = _seizure(p.collateral, repaid, price, remaining == 0);

        totalDebt -= repaid;
        totalCollateral[collateral] -= seized + refund;
        p.debt = remaining;
        p.collateral -= seized + refund;
        _reindex(collateral, owner, hint);
        if (remaining == 0) delete _positions[collateral][owner];

        _eusd.burn(msg.sender, repaid);
        IERC20(collateral).safeTransfer(msg.sender, seized);
        if (refund > 0) IERC20(collateral).safeTransfer(owner, refund);
        emit PositionLiquidated(collateral, owner, msg.sender, repaid, seized, refund);
    }

    /// @inheritdoc IEUSDManager
    function redeem(
        address collateral,
        uint256 amount,
        uint256 minCollateralOut,
        uint256 maxPositions,
        address hint
    ) external override nonReentrant returns (uint256 collateralOut, uint256 debtRepaid) {
        CollateralConfig storage cfg = _requireCollateral(collateral);
        if (amount == 0) revert ZeroAmount();

        uint256 price = _anchorPrice(collateral, cfg.ticker);
        uint256 remaining = amount;
        uint256 touched;

        while (remaining > 0 && (maxPositions == 0 || touched < maxPositions)) {
            address owner = listHead[collateral];
            if (owner == address(0)) break;
            (uint256 repaid, uint256 seized) = _redeemFrom(collateral, owner, price, remaining, hint);
            remaining -= repaid;
            collateralOut += seized;
            touched++;
        }

        debtRepaid = amount - remaining;
        if (debtRepaid == 0) revert NothingToRedeem(collateral);
        if (collateralOut < minCollateralOut) revert SlippageExceeded(collateralOut, minCollateralOut);

        _eusd.burn(msg.sender, debtRepaid);
        IERC20(collateral).safeTransfer(msg.sender, collateralOut);
        emit Redeemed(collateral, msg.sender, debtRepaid, collateralOut);
    }

    /// @inheritdoc IEUSDManager
    function sweepCollateralRewards(
        address collateral
    ) external override nonReentrant returns (uint256 amount) {
        _requireCollateral(collateral);
        amount = IEToken(collateral).claimableRewards(address(this));
        if (amount == 0) revert NoRewardsToSweep(collateral);
        IEToken(collateral).claimRewards();
        address rewardToken = IEToken(collateral).rewardToken();
        IERC20(rewardToken).safeTransfer(registry.treasury(), amount);
        emit CollateralRewardsSwept(collateral, rewardToken, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  External — admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDManager
    function addCollateral(address collateral, bytes32 ticker) external override onlyAdmin {
        if (collateral == address(0)) revert ZeroAddress();
        if (_collateralConfigs[collateral].exists) revert CollateralAlreadySupported(collateral);
        uint8 dec = IERC20Metadata(collateral).decimals();
        if (dec != 18) revert InvalidCollateralDecimals(dec);
        IAssetRegistry assetRegistry = IAssetRegistry(registry.assetRegistry());
        if (!assetRegistry.isValidToken(ticker, collateral)) revert TickerTokenMismatch(ticker, collateral);
        if (assetRegistry.legacyRatioToActive(collateral) != 0) revert LegacyCollateral(collateral);
        _collateralConfigs[collateral] = CollateralConfig({ticker: ticker, enabled: true, exists: true});
        emit CollateralAdded(collateral, ticker);
    }

    /// @inheritdoc IEUSDManager
    function setCollateralEnabled(address collateral, bool enabled) external override onlyAdmin {
        CollateralConfig storage cfg = _requireCollateral(collateral);
        cfg.enabled = enabled;
        emit CollateralEnabledSet(collateral, enabled);
    }

    /// @inheritdoc IEUSDManager
    function setRiskParams(
        uint16 mcrBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps
    ) external override onlyAdmin {
        _validateRatios(mcrBps, liquidationThresholdBps, liquidationBonusBps);
        _riskParams.mcrBps = mcrBps;
        _riskParams.liquidationThresholdBps = liquidationThresholdBps;
        _riskParams.liquidationBonusBps = liquidationBonusBps;
        emit RiskParamsSet(mcrBps, liquidationThresholdBps, liquidationBonusBps);
    }

    /// @inheritdoc IEUSDManager
    function setStabilityFee(
        uint16 stabilityFeeBps
    ) external override onlyAdmin {
        if (stabilityFeeBps > BPS) revert InvalidRiskParams();
        // Settle the index at the old rate so the new rate applies only prospectively.
        _settleFeeIndex();
        _riskParams.stabilityFeeBps = stabilityFeeBps;
        emit StabilityFeeSet(stabilityFeeBps);
    }

    /// @inheritdoc IEUSDManager
    function setDebtCeiling(
        uint256 debtCeiling
    ) external override onlyAdmin {
        _riskParams.debtCeiling = debtCeiling;
        emit DebtCeilingSet(debtCeiling);
    }

    /// @inheritdoc IEUSDManager
    function setMinDebt(
        uint256 minDebt
    ) external override onlyAdmin {
        _riskParams.minDebt = minDebt;
        emit MinDebtSet(minDebt);
    }

    /// @inheritdoc IEUSDManager
    function setMintPriceMaxAge(
        uint256 mintPriceMaxAge
    ) external override onlyAdmin {
        if (mintPriceMaxAge == 0) revert InvalidRiskParams();
        _riskParams.mintPriceMaxAge = mintPriceMaxAge;
        emit MintPriceMaxAgeSet(mintPriceMaxAge);
    }

    /// @inheritdoc IEUSDManager
    /// @dev Instant OPERATOR lever. Only gates {mint}; every exit path stays open.
    function setMintPaused(
        bool paused
    ) external override onlyOperator {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Revert unless the collateral has been added. Does not check `enabled` — exits are
    ///      never gated on it.
    function _requireCollateral(
        address collateral
    ) private view returns (CollateralConfig storage cfg) {
        cfg = _collateralConfigs[collateral];
        if (!cfg.exists) revert CollateralNotSupported(collateral);
    }

    /// @dev Settle the global fee index up to now at the current rate.
    function _settleFeeIndex() private {
        uint256 elapsed = block.timestamp - _feeIndexUpdated;
        if (elapsed > 0) {
            _feeIndex += uint256(_riskParams.stabilityFeeBps) * elapsed;
            _feeIndexUpdated = block.timestamp;
        }
    }

    /// @dev Fold a position's pending stability fee into its debt and mint it to the treasury,
    ///      keeping eusd.totalSupply() == totalDebt exact. The mint is a call into the trusted
    ///      EUSD token (no transfer hooks); all callers hold the reentrancy guard.
    function _accrue(address collateral, address owner) private returns (Position storage p) {
        _settleFeeIndex();
        p = _positions[collateral][owner];
        if (p.debt > 0 && _feeIndex > p.feeIndexSnapshot) {
            uint256 fee = Math.mulDiv(p.debt, _feeIndex - p.feeIndexSnapshot, BPS * YEAR);
            if (fee > 0) {
                p.debt += fee;
                totalDebt += fee;
                _eusd.mint(registry.treasury(), fee);
                emit StabilityFeeAccrued(collateral, owner, fee);
            }
        }
        p.feeIndexSnapshot = _feeIndex;
    }

    /// @dev Redeem up to `maxAmount` of debt from `owner`'s position at `price`. Floor rounding:
    ///      the redeemer receives at most $1 of collateral per eUSD burned. An underwater position
    ///      only redeems its collateral-backed portion; the unbacked residual stays on the books
    ///      off-list (clearable by repay/close/liquidation) so it never pins the head at ratio 0.
    function _redeemFrom(
        address collateral,
        address owner,
        uint256 price,
        uint256 maxAmount,
        address hint
    ) private returns (uint256 repaid, uint256 seized) {
        Position storage p = _accrue(collateral, owner);
        repaid = maxAmount > p.debt ? p.debt : maxAmount;
        seized = Math.mulDiv(repaid, PRECISION, price);
        if (seized > p.collateral) {
            seized = p.collateral;
            repaid = Math.mulDiv(seized, price, PRECISION);
        }

        p.debt -= repaid;
        p.collateral -= seized;
        totalDebt -= repaid;
        totalCollateral[collateral] -= seized;

        // Partial redemption improves the ratio — re-sort with the caller's hint. An exhausted
        // node (no debt, or no collateral) leaves the list; an empty position is deleted.
        _reindex(collateral, owner, hint);
        if (p.debt == 0 && p.collateral == 0) delete _positions[collateral][owner];
        emit RedeemedFromPosition(collateral, owner, repaid, seized);
    }

    /// @dev Re-sort a position after any collateral/debt change. Listed ⇔ debt > 0 and
    ///      collateral > 0: a debt-only residual (underwater redemption) stays off-list.
    function _reindex(address collateral, address owner, address hint) private {
        if (_isListed(collateral, owner)) _removeNode(collateral, owner);
        Position storage p = _positions[collateral][owner];
        if (p.debt > 0 && p.collateral > 0) _insertNode(collateral, owner, hint);
    }

    /// @dev List membership from the links themselves (head, or has a predecessor) — never
    ///      inferred from position state.
    function _isListed(address collateral, address owner) private view returns (bool) {
        return listHead[collateral] == owner || _nodes[collateral][owner].prev != address(0);
    }

    /// @dev Insert `owner` keeping ascending nominal-ratio order (head = riskiest). Equal ratios
    ///      insert after existing nodes. `hint` is the prospective predecessor; an unusable hint
    ///      falls back to a walk from the head.
    function _insertNode(address collateral, address owner, address hint) private {
        Position storage p = _positions[collateral][owner];
        uint256 ratio = Math.mulDiv(p.collateral, PRECISION, p.debt);

        address prev;
        if (hint != address(0) && hint != owner && _isListed(collateral, hint)) {
            if (
                Math.mulDiv(_positions[collateral][hint].collateral, PRECISION, _positions[collateral][hint].debt)
                    <= ratio
            ) {
                prev = hint;
            }
        }
        address next = prev == address(0) ? listHead[collateral] : _nodes[collateral][prev].next;
        while (next != address(0)) {
            Position storage np = _positions[collateral][next];
            if (Math.mulDiv(np.collateral, PRECISION, np.debt) > ratio) break;
            prev = next;
            next = _nodes[collateral][next].next;
        }

        _nodes[collateral][owner] = ListNode({prev: prev, next: next});
        if (prev == address(0)) listHead[collateral] = owner;
        else _nodes[collateral][prev].next = owner;
        if (next == address(0)) listTail[collateral] = owner;
        else _nodes[collateral][next].prev = owner;
        listSize[collateral]++;
    }

    /// @dev Unlink `owner` from the sorted list. Callers guarantee membership.
    function _removeNode(address collateral, address owner) private {
        ListNode memory node = _nodes[collateral][owner];
        if (node.prev == address(0)) listHead[collateral] = node.next;
        else _nodes[collateral][node.prev].next = node.next;
        if (node.next == address(0)) listTail[collateral] = node.prev;
        else _nodes[collateral][node.next].prev = node.prev;
        delete _nodes[collateral][owner];
        listSize[collateral]--;
    }

    // ──────────────────────────────────────────────────────────
    //  Views & pricing
    // ──────────────────────────────────────────────────────────

    /// @dev Resolve the oracle for a ticker via the AssetRegistry, as OwnMarket does.
    function _oracle(
        bytes32 ticker
    ) private view returns (IOracleVerifier) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(ticker);
        return IOracleVerifier(oracleType == 0 ? registry.pythOracle() : registry.inhouseOracle());
    }

    /// @dev Live price for risk-increasing actions: must be in-session, no older than
    ///      mintPriceMaxAge. Future-dated timestamps are treated as current. Leverage pauses with
    ///      trading (as in BorrowManager): a halted asset has no live value to lever against and a
    ///      paused one cannot be turned into cash — both are wind-down only (repay / close /
    ///      liquidate / redeem stay open).
    function _freshPrice(address collateral, bytes32 ticker) private view returns (uint256 price) {
        IVaultManager vm = _vaultManager();
        if (vm.isAssetHalted(ticker)) revert CollateralHalted(ticker);
        if (vm.isTradingPaused(ticker)) revert CollateralPaused(ticker);
        uint256 ts;
        (price, ts) = _oracle(ticker).getPrice(ticker);
        if (price == 0) revert ZeroOraclePrice(ticker);
        uint256 maxAge = _riskParams.mintPriceMaxAge;
        if (block.timestamp > ts + maxAge) revert StaleMintPrice(ts, maxAge);
        price = _effectivePrice(collateral, price);
    }

    /// @dev Last oracle anchor for exits (repay-side paths, liquidation, redemption): no age
    ///      bound, so closed markets never block an exit. The oracle itself rejects prices beyond
    ///      its own hard usability window. A halted asset is worth exactly its fixed halt price
    ///      (its only redeemable value, via OwnMarket.redeemHalted) — the feed is not consulted, so
    ///      exits keep working after the feed dies.
    function _anchorPrice(address collateral, bytes32 ticker) private view returns (uint256 price) {
        IVaultManager vm = _vaultManager();
        if (vm.isAssetHalted(ticker)) return _effectivePrice(collateral, vm.assetHaltPrice(ticker));
        (price,) = _oracle(ticker).getPrice(ticker);
        if (price == 0) revert ZeroOraclePrice(ticker);
        price = _effectivePrice(collateral, price);
    }

    function _vaultManager() private view returns (IVaultManager) {
        return IVaultManager(registry.vaultManager());
    }

    /// @dev Ticker prices are per ACTIVE eToken unit. A legacy (post-split) collateral is worth
    ///      `legacyRatioToActive` active units, so its price is scaled by that ratio (same rule as
    ///      BorrowManager). Active tokens have ratio 0 → identity. Floor rounding errs against
    ///      the debtor.
    function _effectivePrice(address collateral, uint256 price) private view returns (uint256) {
        uint256 ratio = IAssetRegistry(registry.assetRegistry()).legacyRatioToActive(collateral);
        return ratio == 0 ? price : Math.mulDiv(price, ratio, PRECISION);
    }

    /// @dev Liquidation seizure: collateral worth repaid × (1 + bonus), capped at `coll`. Floor
    ///      rounding favours the position owner. Surplus is refunded only on a full close; a
    ///      partial leaves it in the position.
    function _seizure(
        uint256 coll,
        uint256 repaid,
        uint256 price,
        bool fullClose
    ) private view returns (uint256 seized, uint256 refund) {
        seized = Math.mulDiv(repaid * (BPS + _riskParams.liquidationBonusBps), PRECISION, price * BPS);
        if (seized > coll) seized = coll;
        if (fullClose) refund = coll - seized;
    }

    /// @dev Collateral ratio in BPS. Floor rounding: measured ratios err against the debtor.
    function _ratioBps(uint256 coll, uint256 debt, uint256 price) private pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(Math.mulDiv(coll, price, PRECISION), BPS, debt);
    }

    /// @dev Shared ratio-parameter validation: a fresh mint can never be instantly liquidatable
    ///      (mcr ≥ threshold) and a threshold liquidation is always solvent (threshold ≥ 1+bonus).
    function _validateRatios(uint16 mcrBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps) private pure {
        if (mcrBps < liquidationThresholdBps || uint256(liquidationThresholdBps) < BPS + liquidationBonusBps) {
            revert InvalidRiskParams();
        }
    }

    /// @inheritdoc IEUSDManager
    function eusd() external view override returns (address) {
        return address(_eusd);
    }

    /// @inheritdoc IEUSDManager
    function riskParams() external view override returns (RiskParams memory) {
        return _riskParams;
    }

    /// @inheritdoc IEUSDManager
    function collateralConfig(
        address collateral
    ) external view override returns (CollateralConfig memory) {
        return _collateralConfigs[collateral];
    }

    /// @inheritdoc IEUSDManager
    function getPosition(address collateral, address owner) external view override returns (Position memory) {
        return _positions[collateral][owner];
    }

    /// @inheritdoc IEUSDManager
    function currentDebt(address collateral, address owner) public view override returns (uint256) {
        Position storage p = _positions[collateral][owner];
        if (p.debt == 0) return 0;
        return p.debt + Math.mulDiv(p.debt, globalFeeIndex() - p.feeIndexSnapshot, BPS * YEAR);
    }

    /// @inheritdoc IEUSDManager
    function collateralRatioBps(address collateral, address owner) public view override returns (uint256) {
        uint256 debt = currentDebt(collateral, owner);
        if (debt == 0) return type(uint256).max;
        return _ratioBps(
            _positions[collateral][owner].collateral,
            debt,
            _anchorPrice(collateral, _collateralConfigs[collateral].ticker)
        );
    }

    /// @inheritdoc IEUSDManager
    function isLiquidatable(address collateral, address owner) external view override returns (bool) {
        return collateralRatioBps(collateral, owner) < _riskParams.liquidationThresholdBps;
    }

    /// @inheritdoc IEUSDManager
    function nominalRatio(address collateral, address owner) external view override returns (uint256) {
        Position storage p = _positions[collateral][owner];
        if (p.debt == 0) revert NoDebt(collateral, owner);
        return Math.mulDiv(p.collateral, PRECISION, p.debt);
    }

    /// @inheritdoc IEUSDManager
    function listNext(address collateral, address owner) external view override returns (address) {
        return _nodes[collateral][owner].next;
    }

    /// @inheritdoc IEUSDManager
    function listPrev(address collateral, address owner) external view override returns (address) {
        return _nodes[collateral][owner].prev;
    }

    /// @inheritdoc IEUSDManager
    function findInsertHint(address collateral, uint256 ratio) external view override returns (address) {
        address prev;
        address node = listHead[collateral];
        while (node != address(0)) {
            Position storage p = _positions[collateral][node];
            if (Math.mulDiv(p.collateral, PRECISION, p.debt) > ratio) break;
            prev = node;
            node = _nodes[collateral][node].next;
        }
        return prev;
    }

    /// @inheritdoc IEUSDManager
    function globalFeeIndex() public view override returns (uint256) {
        return _feeIndex + uint256(_riskParams.stabilityFeeBps) * (block.timestamp - _feeIndexUpdated);
    }
}
