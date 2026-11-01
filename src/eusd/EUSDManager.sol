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
/// @notice See {IEUSDManager}. Resolves the oracle, treasury and roles through the
///         ProtocolRegistry.
/// @dev Listed positions form a per-collateral doubly linked list sorted ascending by nominal
///      ratio (stored collateral / stored debt), so ordering only changes when a position is
///      touched. Inserts take a hint (the expected predecessor) and fall back to a walk from the
///      head. Collateral tokens must be 18-decimal ERC-20s without transfer fees.
///      Runs behind an ERC-1967 proxy (UUPS); upgrades are ADMIN-gated.
contract EUSDManager is IEUSDManager, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @dev Sorted-list links of one position.
    /// @param prev Neighbor toward the head (riskier).
    /// @param next Neighbor toward the tail (safer).
    struct ListNode {
        address prev;
        address next;
    }

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev Stability-fee year basis (simple interest).
    uint256 private constant YEAR = 365 days;

    /// @dev ProtocolRegistry role for configuration and upgrades.
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @dev ProtocolRegistry role for the mint pause.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve the oracle, treasury and roles. Set once at
    ///         initialization.
    IProtocolRegistry public registry;

    /// @dev The eUSD token minted and burned by this manager. Set once at initialization.
    IEUSD private _eusd;

    /// @dev Current risk parameters (see {riskParams}).
    RiskParams private _riskParams;

    /// @inheritdoc IEUSDManager
    bool public override mintPaused;

    /// @inheritdoc IEUSDManager
    uint256 public override totalDebt;

    /// @inheritdoc IEUSDManager
    mapping(address => uint256) public override totalCollateral;

    /// @dev Collateral token => its configuration.
    mapping(address => CollateralConfig) private _collateralConfigs;

    /// @dev Collateral token => owner => position.
    mapping(address => mapping(address => Position)) private _positions;

    /// @dev Collateral token => owner => sorted-list links.
    mapping(address => mapping(address => ListNode)) private _nodes;

    /// @inheritdoc IEUSDManager
    mapping(address => address) public override listHead;

    /// @inheritdoc IEUSDManager
    mapping(address => address) public override listTail;

    /// @inheritdoc IEUSDManager
    mapping(address => uint256) public override listSize;

    /// @dev Stability fee index: cumulative `stabilityFeeBps` × elapsed seconds.
    uint256 private _feeIndex;

    /// @dev Timestamp `_feeIndex` was last settled.
    uint256 private _feeIndexUpdated;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    /// @dev Reverts unless the caller holds ADMIN in the registry.
    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @dev Reverts unless the caller holds OPERATOR in the registry.
    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev Locks the implementation's initializers; it is only used behind a proxy.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy (called once, in the proxy's constructor).
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

    /// @dev UUPS upgrade gate: ADMIN only.
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
        // A disabled collateral takes no new exposure, but an existing debtor may still top up.
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

        // With debt, a withdrawal increases risk: same gates as minting.
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
        p.feesAccrued -= Math.min(repaid, p.feesAccrued);
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
    /// @dev Accrual on entry mints pending fees to the treasury first, so the treasury burn covers
    ///      every fee the position owes.
    function closePositionPrincipalOnly(
        address collateral
    ) external override nonReentrant {
        _requireCollateral(collateral);
        _close(collateral, true);
    }

    /// @dev Retire the full debt, delete the position and pay out the collateral. With
    ///      `feesFromCollateral`, `feesAccrued` is settled with collateral of equal value at a fresh
    ///      price (rounded up, against the owner) sent to the treasury, whose eUSD is burned by the
    ///      same amount; the caller burns the rest. Settlement is capped at the collateral value.
    /// @param collateral         Collateral token of the caller's position.
    /// @param feesFromCollateral Whether to settle `feesAccrued` from collateral instead of eUSD.
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
        p.feesAccrued -= Math.min(repaid, p.feesAccrued);
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
            // Only a head where the minDebt clamp leaves nothing to redeem yields zero; stop there.
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
    /// @dev Gates {mint} and withdrawal against debt; every exit stays open.
    function setMintPaused(
        bool paused
    ) external override onlyOperator {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Revert unless the collateral has been added. Does not check `enabled`.
    /// @param collateral Collateral token.
    /// @return cfg The collateral's configuration.
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

    /// @dev Fold a position's pending stability fee into its debt and mint it to the treasury.
    ///      EUSD has no transfer hooks, and every caller holds the reentrancy guard.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @return p The position, with its debt brought up to date.
    function _accrue(address collateral, address owner) private returns (Position storage p) {
        _settleFeeIndex();
        p = _positions[collateral][owner];
        if (p.debt > 0 && _feeIndex > p.feeIndexSnapshot) {
            // Charged on principal only, so the fee is simple interest however often it accrues.
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

    /// @dev Redeem up to `maxAmount` of debt from `owner`'s position at `price`, rounding down so
    ///      the redeemer gets at most $1 of collateral per eUSD. An underwater position only
    ///      redeems its collateral value and its residual leaves the list. The remaining debt is
    ///      either 0 or ≥ minDebt; a position where that leaves nothing to redeem returns zeros.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @param price      Fresh collateral price (18 decimals).
    /// @param maxAmount  Max debt to retire (18 decimals).
    /// @param hint       Sorted-list insert hint for the re-sorted position.
    /// @return repaid Debt retired (18 decimals).
    /// @return seized Collateral taken (18 decimals).
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
        p.feesAccrued -= Math.min(repaid, p.feesAccrued);
        p.collateral -= seized;
        totalDebt -= repaid;
        totalCollateral[collateral] -= seized;

        // Re-sort with the caller's hint; an exhausted position leaves the list, an empty one is deleted.
        _reindex(collateral, owner, hint);
        if (p.debt == 0 && p.collateral == 0) delete _positions[collateral][owner];
        emit RedeemedFromPosition(collateral, owner, repaid, seized);
    }

    /// @dev Re-sort a position after a change. A position is listed iff it has debt and collateral.
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @param hint       Sorted-list insert hint.
    function _reindex(address collateral, address owner, address hint) private {
        if (_isListed(collateral, owner)) _removeNode(collateral, owner);
        Position storage p = _positions[collateral][owner];
        if (p.debt > 0 && p.collateral > 0) _insertNode(collateral, owner, hint);
    }

    /// @dev List membership, read from the links (the head, or has a predecessor).
    /// @param collateral Collateral token.
    /// @param owner      Position owner.
    /// @return Whether the position is in the sorted list.
    function _isListed(address collateral, address owner) private view returns (bool) {
        return listHead[collateral] == owner || _nodes[collateral][owner].prev != address(0);
    }

    /// @dev Insert `owner` keeping ascending nominal-ratio order (head = riskiest). Equal ratios
    ///      insert after existing nodes. `hint` is the prospective predecessor; an unusable hint
    ///      falls back to a walk from the head.
    /// @param collateral Collateral token.
    /// @param owner      Position owner to insert.
    /// @param hint       Expected predecessor (address(0) = walk from the head).
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
    /// @param collateral Collateral token.
    /// @param owner      Position owner to remove.
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

    /// @dev The oracle, resolved through the registry.
    /// @return The current oracle.
    function _oracle() private view returns (IOracleVerifier) {
        return IOracleVerifier(registry.oracle());
    }

    /// @dev Oracle price no older than `mintPriceMaxAge`. A future timestamp counts as current.
    /// @param ticker Oracle ticker.
    /// @return price Price (18 decimals).
    function _freshPrice(
        bytes32 ticker
    ) private view returns (uint256 price) {
        uint256 ts;
        (price, ts) = _oracle().getPrice(ticker);
        uint256 maxAge = _riskParams.mintPriceMaxAge;
        if (block.timestamp > ts + maxAge) revert StaleMintPrice(ts, maxAge);
    }

    /// @dev Collateral seized for repaying `repaid`: worth repaid × (1 + bonus), rounded down and
    ///      capped at `coll`. A partial liquidation is also capped at `coll × repaid / debt`, so the
    ///      remaining position's ratio never falls.
    /// @param coll      Position collateral (18 decimals).
    /// @param debt      Position debt (18 decimals).
    /// @param repaid    Debt being repaid (18 decimals).
    /// @param price     Collateral price (18 decimals).
    /// @param fullClose Whether the liquidation retires the whole debt.
    /// @return seized Collateral paid to the liquidator (18 decimals).
    /// @return refund Surplus collateral returned to the owner on a full close (18 decimals).
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
    /// @param coll  Collateral (18 decimals).
    /// @param debt  Debt (18 decimals).
    /// @param price Collateral price (18 decimals).
    /// @return Ratio in BPS (type(uint256).max when debt is 0).
    function _ratioBps(uint256 coll, uint256 debt, uint256 price) private pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(Math.mulDiv(coll, price, PRECISION), BPS, debt);
    }

    /// @dev Require mcr ≥ threshold (a fresh mint is never liquidatable) and threshold ≥ 1 + bonus
    ///      (a liquidation at the threshold is solvent).
    /// @param mcrBps                  Min collateral ratio (BPS).
    /// @param liquidationThresholdBps Liquidation threshold (BPS).
    /// @param liquidationBonusBps     Liquidation bonus (BPS).
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
