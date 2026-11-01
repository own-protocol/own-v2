// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSD} from "../interfaces/IEUSD.sol";
import {IEUSDManager} from "../interfaces/IEUSDManager.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EUSDManager — CDP engine for the eUSD stablecoin
/// @notice Custodies collateral tokens (debtor collateral) and owns all CDP logic:
///         deposits/withdrawals, minting against a fresh oracle price, repay/close, keeper
///         liquidation at a fixed bonus, and riskiest-first redemption as the peg anchor. Resolves
///         the oracle, treasury and roles through the ProtocolRegistry.
/// @dev Positions with debt live in a per-collateral doubly-linked list sorted ascending by
///      nominal ratio (stored collateral / stored debt) — price-invariant within one collateral,
///      so ordering only changes when a position is touched. Insertions take an O(1) hint (the
///      prospective predecessor) and fall back to a head walk. Collateral tokens are 18-decimal ERC-20s
///      without transfer fees, each priced by the oracle ticker set at add time.
///      Runs behind an ERC-1967 proxy (UUPS) so the manager address — and the positions it
///      custodies — survive upgrades. Upgrades are ADMIN-gated ({_authorizeUpgrade});
///      ossification is a final upgrade to an implementation whose {_authorizeUpgrade} always
///      reverts.
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

    /// @notice ProtocolRegistry used to resolve the oracle, treasury and roles.
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
        if (amount == 0) revert ZeroAmount();

        Position storage p = _accrue(collateral, msg.sender);
        // Disabled = no new exposure. An existing debtor may still top up (defensive lever —
        // liquidation is never gated); minting stays blocked regardless.
        if (!cfg.enabled && p.debt == 0) revert CollateralDisabled(collateral);
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

        // Risk-increasing while debt exists: same gates as minting — pause, fresh price, MCR.
        if (p.debt > 0) {
            if (mintPaused) revert MintingPaused();
            uint256 ratio = _ratioBps(p.collateral, p.debt, _freshPrice(cfg.ticker));
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

        uint256 ratio = _ratioBps(p.collateral, newDebt, _freshPrice(cfg.ticker));
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
        if (p.feesAccrued > remaining) p.feesAccrued = remaining;
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
        _close(collateral, false);
    }

    /// @inheritdoc IEUSDManager
    /// @dev The entry accrual mints any pending fee to the treasury and folds it into
    ///      `feesAccrued`, so the treasury burn nets pending fees to zero and retires previously
    ///      minted ones from its balance.
    function closePositionPrincipalOnly(
        address collateral
    ) external override nonReentrant {
        _requireCollateral(collateral);
        _close(collateral, true);
    }

    /// @dev Shared close: retire the full debt, delete the position, pay out the collateral.
    ///      With `feesFromCollateral`, the tracked fee portion is settled in kind — collateral of
    ///      equal value (fresh oracle price, ceil rounding against the debtor) to the treasury, whose
    ///      eUSD is burned in the same amount — and the caller burns only the remainder. An
    ///      underwater position caps the settlement at its collateral value; the caller pays the
    ///      rest in eUSD.
    function _close(address collateral, bool feesFromCollateral) private {
        Position storage p = _accrue(collateral, msg.sender);
        uint256 debt = p.debt;
        uint256 coll = p.collateral;
        if (debt == 0 && coll == 0) revert EmptyPosition(collateral, msg.sender);

        uint256 fees;
        uint256 feeCollateral;
        if (feesFromCollateral && p.feesAccrued > 0) {
            fees = p.feesAccrued;
            uint256 price = _freshPrice(_collateralConfigs[collateral].ticker);
            feeCollateral = Math.mulDiv(fees, PRECISION, price, Math.Rounding.Ceil);
            if (feeCollateral > coll) {
                feeCollateral = coll;
                fees = Math.mulDiv(feeCollateral, price, PRECISION);
            }
        }

        if (_isListed(collateral, msg.sender)) _removeNode(collateral, msg.sender);
        totalDebt -= debt;
        totalCollateral[collateral] -= coll;
        delete _positions[collateral][msg.sender];

        if (debt > fees) _eusd.burn(msg.sender, debt - fees);
        if (coll > feeCollateral) IERC20(collateral).safeTransfer(msg.sender, coll - feeCollateral);
        emit PositionClosed(collateral, msg.sender, coll - feeCollateral, debt - fees);
        if (fees > 0) {
            _eusd.burn(registry.treasury(), fees);
            IERC20(collateral).safeTransfer(registry.treasury(), feeCollateral);
            emit PositionFeesSettledFromCollateral(collateral, msg.sender, fees, feeCollateral);
        }
    }

    /// @inheritdoc IEUSDManager
    function accrue(address collateral, address owner, address hint) external override nonReentrant {
        _requireCollateral(collateral);
        if (owner == address(0)) revert ZeroAddress();
        Position storage p = _accrue(collateral, owner);
        if (p.debt == 0) revert NoDebt(collateral, owner);
        _reindex(collateral, owner, hint);
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

        (uint256 price,) = _oracle().getPrice(ticker);
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
        (uint256 seized, uint256 refund) = _seizure(p.collateral, p.debt, repaid, price, remaining == 0);

        totalDebt -= repaid;
        totalCollateral[collateral] -= seized + refund;
        p.debt = remaining;
        if (p.feesAccrued > remaining) p.feesAccrued = remaining;
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

        uint256 price = _freshPrice(cfg.ticker);
        uint256 remaining = amount;
        uint256 touched;

        while (remaining > 0 && (maxPositions == 0 || touched < maxPositions)) {
            address owner = listHead[collateral];
            if (owner == address(0)) break;
            (uint256 repaid, uint256 seized) = _redeemFrom(collateral, owner, price, remaining, hint);
            // The head yields nothing when the minDebt clamp consumes the whole request; every
            // other outcome delists or shrinks it, so this is the only zero-progress case.
            if (repaid == 0 && seized == 0) break;
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

    // ──────────────────────────────────────────────────────────
    //  External — admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IEUSDManager
    function addCollateral(address collateral, bytes32 ticker) external override onlyAdmin {
        if (collateral == address(0)) revert ZeroAddress();
        if (_collateralConfigs[collateral].exists) revert CollateralAlreadySupported(collateral);
        uint8 dec = IERC20Metadata(collateral).decimals();
        if (dec != 18) revert InvalidCollateralDecimals(dec);
        // Reverts unless the ticker is priced.
        _oracle().getPrice(ticker);
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
    ///      keeping eUSD supply equal to total debt across managers. The mint is a call into the trusted
    ///      EUSD token (no transfer hooks); all callers hold the reentrancy guard.
    function _accrue(address collateral, address owner) private returns (Position storage p) {
        _settleFeeIndex();
        p = _positions[collateral][owner];
        if (p.debt > 0 && _feeIndex > p.feeIndexSnapshot) {
            // Charged on principal only, so the fee stays simple however often a position is touched.
            uint256 fee = Math.mulDiv(p.debt - p.feesAccrued, _feeIndex - p.feeIndexSnapshot, BPS * YEAR);
            if (fee > 0) {
                p.debt += fee;
                p.feesAccrued += fee;
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
    ///      A partial redemption may not leave dust: the remaining debt is either 0 or >= minDebt
    ///      (repaid is clamped to leave exactly minDebt, same rule as {repay}); a node where even
    ///      that clamp yields nothing redeemable returns zeros and the caller stops the walk.
    function _redeemFrom(
        address collateral,
        address owner,
        uint256 price,
        uint256 maxAmount,
        address hint
    ) private returns (uint256 repaid, uint256 seized) {
        Position storage p = _accrue(collateral, owner);
        repaid = maxAmount > p.debt ? p.debt : maxAmount;
        uint256 remainingDebt = p.debt - repaid;
        if (remainingDebt != 0 && remainingDebt < _riskParams.minDebt) {
            uint256 minDebt = _riskParams.minDebt;
            repaid = p.debt > minDebt ? p.debt - minDebt : 0;
            if (repaid == 0) {
                _reindex(collateral, owner, hint);
                return (0, 0);
            }
        }
        seized = Math.mulDiv(repaid, PRECISION, price);
        if (seized > p.collateral) {
            seized = p.collateral;
            repaid = Math.mulDiv(seized, price, PRECISION);
        }

        p.debt -= repaid;
        if (p.feesAccrued > p.debt) p.feesAccrued = p.debt;
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

    /// @dev The protocol's Chainlink-primary oracle verifier, resolved through the registry.
    function _oracle() private view returns (IOracleVerifier) {
        return IOracleVerifier(registry.oracle());
    }

    /// @dev Live price, no older than mintPriceMaxAge, for mint, withdraw against debt, redeem and
    ///      the fee leg of a principal-only close. Future-dated timestamps are treated as current.
    function _freshPrice(
        bytes32 ticker
    ) private view returns (uint256 price) {
        uint256 ts;
        (price, ts) = _oracle().getPrice(ticker);
        uint256 maxAge = _riskParams.mintPriceMaxAge;
        if (block.timestamp > ts + maxAge) revert StaleMintPrice(ts, maxAge);
    }

    /// @dev Liquidation seizure: collateral worth repaid × (1 + bonus), capped at `coll`. Floor
    ///      rounding favours the position owner. Surplus is refunded only on a full close; a
    ///      partial leaves it in the position. A partial is additionally capped at the pro-rata
    ///      share `coll × repaid / debt`, so the remainder's ratio never falls below the
    ///      pre-liquidation ratio and the bonus cannot be extracted from collateral the remaining
    ///      debt needs. The cap is inert while ratio >= 1 + bonus.
    function _seizure(
        uint256 coll,
        uint256 debt,
        uint256 repaid,
        uint256 price,
        bool fullClose
    ) private view returns (uint256 seized, uint256 refund) {
        seized = Math.mulDiv(repaid * (BPS + _riskParams.liquidationBonusBps), PRECISION, price * BPS);
        if (seized > coll) seized = coll;
        if (fullClose) {
            refund = coll - seized;
        } else {
            uint256 proRata = Math.mulDiv(coll, repaid, debt);
            if (seized > proRata) seized = proRata;
        }
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
        return p.debt + Math.mulDiv(p.debt - p.feesAccrued, globalFeeIndex() - p.feeIndexSnapshot, BPS * YEAR);
    }

    /// @inheritdoc IEUSDManager
    function collateralRatioBps(address collateral, address owner) public view override returns (uint256) {
        uint256 debt = currentDebt(collateral, owner);
        if (debt == 0) return type(uint256).max;
        (uint256 price,) = _oracle().getPrice(_collateralConfigs[collateral].ticker);
        return _ratioBps(_positions[collateral][owner].collateral, debt, price);
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
