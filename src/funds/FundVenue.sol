// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {IFundVenue} from "../interfaces/IFundVenue.sol";
import {HookrTypes, IHookrDirectionalTax, IHookrLauncher, IHookrTaxQueue} from "../interfaces/external/IHookr.sol";
import {IssuanceConfig, IssuanceStep, PoolSettings} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {FullRangeLiquidity} from "./libraries/FullRangeLiquidity.sol";
import {PoolIssuance} from "./libraries/PoolIssuance.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title FundVenue — where one fund trades: its pool on Hookr, its position and its issuance
/// @notice See {IFundVenue}.
/// @dev Deployed as a beacon proxy per fund by {FundFactory}; storage is append-only across
///      upgrades, and an upgrade is how the venue learns a new kind of pool (our own hook). The
///      Hookr contracts are immutables of the implementation. The fund's position is the family's
///      only member (index 0): a full-range position the launcher holds for this venue as family
///      owner, with no lock, so it can leave at any time. The swap tax is paid by Hookr's tax
///      queues straight to the fund's curators module. Between calls the venue holds no USDG and no
///      fund tokens: whatever is left after a call is swept, USDG to the fund and fund tokens
///      burned.
contract FundVenue is IFundVenue, IUnlockCallback, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 private constant DEFAULT_TICK_SPACING = 60;

    // Hookr's cap on each tax direction, and ours on the LP fee: 10%, in pips.
    uint24 private constant MAX_FEE_PIPS = 100_000;

    // Hookr's bounds on its share of the tax.
    uint16 private constant MIN_HOOKR_SHARE_BPS = 2000;
    uint16 private constant MAX_HOOKR_SHARE_BPS = 5000;

    // Furthest the spot square root price may be from the oracle's when moving the position
    // (about 1% in price).
    uint256 private constant MAX_SQRT_GAP_BPS = 50;

    // Pool caps: the tax module reserves its own admitted caps on top of the rules', so the quote
    // take cap is twice the largest tax.
    uint24 private constant CAP_LP_FEE_PIPS = 100_000;
    uint24 private constant CAP_QUOTE_TAKE_PIPS = 200_000;

    uint32 private constant RULES_GAS_LIMIT = 2_000_000;
    uint32 private constant ADVISORY_GAS_LIMIT = 1_000_000;

    // The tax advises before and after the swap.
    uint8 private constant ADVISORY_PHASES = 3;

    bytes32 private constant POLICY_ID = keccak256("own.curated-fund");

    /// @notice Hookr's launcher, which opens the pools and holds the fund's position.
    IHookrLauncher public immutable launcher;

    /// @notice Hookr's shared hook every fund pool opens on.
    address public immutable root;

    /// @notice Hookr's rules module.
    address public immutable rules;

    /// @notice Hookr's Directional Tax advisory.
    address public immutable taxAdvisory;

    /// @notice The Uniswap v4 pool manager.
    IPoolManager public immutable poolManager;

    address private immutable _usdg;
    uint256 private immutable _usdgUnit;

    /// @inheritdoc IFundVenue
    address public override fund;

    /// @inheritdoc IFundVenue
    bool public override isSeeded;

    IFundFactory private _factory;
    PoolSettings private _settings;
    PoolKey private _key;

    /// @inheritdoc IFundVenue
    bytes32 public override family;

    address private _buyQueue;
    address private _sellQueue;

    // The current pool's opening square root price: the reference until the oracle has a price.
    uint160 private _openSqrt;

    // `q` (see {PoolIssuance}) where the current issuance run starts: after the last issue that
    // reached its target, or where the price was last seen lower.
    uint256 private _anchor;

    // Fund tokens issued since the anchor by sales the hourly cap cut short.
    uint256 private _anchorIssued;

    uint16 private _issuanceStartBps;
    uint16 private _potShareBps;
    uint16 private _hourlyCapBps;

    // When {_issued} was last updated.
    uint64 private _issuedAt;

    // Fund tokens issued that still count against the hourly cap; drains at the full cap per hour.
    uint256 private _issued;

    IssuanceStep[] private _steps;

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    modifier onlyFund() {
        if (msg.sender != fund) revert NotFund();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier seeded() {
        if (!isSeeded) revert NotSeeded();
        _;
    }

    /// @param launcher_    Hookr's launcher.
    /// @param root_        Hookr's root.
    /// @param rules_       Hookr's rules module.
    /// @param taxAdvisory_ Hookr's Directional Tax advisory.
    /// @param usdg_        The factory's USDG, fixed for every fund of the platform.
    constructor(IHookrLauncher launcher_, address root_, address rules_, address taxAdvisory_, address usdg_) {
        launcher = launcher_;
        root = root_;
        rules = rules_;
        taxAdvisory = taxAdvisory_;
        poolManager = IPoolManager(launcher_.poolManager());
        _usdg = usdg_;
        _usdgUnit = 10 ** IERC20Metadata(usdg_).decimals();
        _disableInitializers();
    }

    /// @inheritdoc IFundVenue
    function initialize(address fund_, PoolSettings calldata settings) external override initializer {
        // The implementation is built for one USDG; only a factory using the same one may deploy it.
        if (IFundFactory(msg.sender).usdg() != _usdg) revert NotAdmin();
        _factory = IFundFactory(msg.sender);
        fund = fund_;
        _setSettings(settings);
        (_issuanceStartBps, _potShareBps, _hourlyCapBps) = PoolIssuance.configureDefaults(_steps, _factory);
    }

    /// @inheritdoc IFundVenue
    function seedPool(uint256 usdgAmount, uint256 shareAmount) external payable override nonReentrant {
        if (msg.sender != IFund(fund).launch()) revert NotLaunch();
        if (isSeeded) revert AlreadySeeded();
        if (usdgAmount == 0 || shareAmount == 0) revert InvalidSeed();
        isSeeded = true;
        (uint256 amount0, uint256 amount1) = _usdgIs0() ? (usdgAmount, shareAmount) : (shareAmount, usdgAmount);
        _open(PoolIssuance.seedSqrtPrice(amount0, amount1), amount0, amount1);
        _sweep();
    }

    /// @inheritdoc IFundVenue
    function issue() external override nonReentrant seeded returns (uint256 issued, uint256 usdgIn) {
        (bool ok, uint256 nav, uint256 supply) = IFund(fund).tryNav();
        if (!ok) return (0, 0);
        PoolId id = _key.toId();
        bool usdgIs0 = _usdgIs0();
        uint256 q1 = PoolIssuance.qAt(_spot(id), usdgIs0);
        uint256 q2 = PoolIssuance.target(
            _steps,
            _issuanceStartBps,
            nav,
            supply,
            PoolIssuance.Pool(_anchor, _anchorIssued, q1, poolManager.getLiquidity(id)),
            _usdgUnit
        );
        if (q2 == 0) {
            if (q1 < _anchor) (_anchor, _anchorIssued) = (q1, 0);
            return (0, 0);
        }
        (uint256 left, uint256 used) = _hourly(supply);
        if (left == 0) return (0, 0);
        uint256 pot;
        (issued, usdgIn, pot) = abi.decode(
            poolManager.unlock(abi.encode(left, usdgIs0 ? (1 << 192) / q2 : q2, nav)), (uint256, uint256, uint256)
        );
        (_issued, _issuedAt) = (used + issued, uint64(block.timestamp));
        // A sale the cap cut short leaves the rest due from the same anchor.
        if (issued == left) _anchorIssued += issued;
        else (_anchor, _anchorIssued) = (PoolIssuance.qAt(_spot(id), usdgIs0), 0);
        emit Issued(usdgIn, issued, pot);
    }

    /// @inheritdoc IFundVenue
    function collectLpFees() external override nonReentrant seeded returns (uint256 usdgAmount, uint256 burned) {
        return _collectFees();
    }

    /// @inheritdoc IFundVenue
    function collectTax() external override nonReentrant returns (uint256 paid) {
        address[2] memory queues = [_buyQueue, _sellQueue];
        for (uint256 i; i < 2; ++i) {
            if (queues[i] == address(0)) continue;
            // A queue with nothing due reverts; the other may still pay.
            try IHookrTaxQueue(queues[i]).payCreator() returns (uint256 amount) {
                paid += amount;
            } catch {}
        }
    }

    /// @inheritdoc IFundVenue
    function redeemPosition(
        uint256 numerator,
        uint256 denominator,
        address receiver
    ) external override onlyFund nonReentrant returns (uint256 usdgPaid) {
        if (!isSeeded || numerator == 0) return 0;
        // Rounds down: a redeemer never removes more than their share of the position.
        uint128 removed = SafeCast.toUint128(Math.mulDiv(positionLiquidity(), numerator, denominator));
        if (removed == 0) return 0;
        (uint160 lower, uint160 upper) = _range();
        (uint256 usdgCap,) = _amountsAt(_reference(), removed, lower, upper);
        _collect();
        launcher.withdraw(family, 0, removed, 0, 0, address(this), block.timestamp);
        usdgPaid = Math.min(IERC20(_usdg).balanceOf(address(this)), usdgCap);
        if (usdgPaid != 0) IERC20(_usdg).safeTransfer(receiver, usdgPaid);
        (uint256 toFund, uint256 burned) = _sweep();
        emit PositionReduced(removed, usdgPaid, toFund, burned);
    }

    /// @inheritdoc IFundVenue
    function increasePosition(
        uint256 usdgAmount
    ) external override onlyFund nonReentrant seeded returns (uint128 liquidity) {
        if (usdgAmount == 0) revert InvalidSeed();
        uint160 sqrtPrice = _checkedSpot();
        (uint256 amount0, uint256 amount1, uint256 shares) =
            PoolIssuance.matchUsdg(sqrtPrice, _usdgIs0(), _usdgUnit, usdgAmount);
        IFund(fund).venueIssue(address(this), shares, 0);
        liquidity = _liquidityFor(sqrtPrice, amount0, amount1);
        _approveLauncher(amount0, amount1);
        (uint256 used0, uint256 used1) = launcher.addLiquidity(
            family, 0, liquidity, SafeCast.toUint128(amount0), SafeCast.toUint128(amount1), block.timestamp
        );
        _sweep();
        (uint256 usdgUsed, uint256 sharesUsed) = _usdgIs0() ? (used0, used1) : (used1, used0);
        emit PositionIncreased(liquidity, usdgUsed, sharesUsed);
    }

    /// @inheritdoc IFundVenue
    function withdrawPosition(
        uint128 liquidity
    ) external override onlyAdmin nonReentrant seeded {
        if (liquidity == 0 || liquidity > positionLiquidity()) revert InsufficientLiquidity();
        launcher.withdraw(family, 0, liquidity, 0, 0, address(this), block.timestamp);
        (uint256 toFund, uint256 burned) = _sweep();
        emit PositionReduced(liquidity, 0, toFund, burned);
    }

    /// @inheritdoc IFundVenue
    function migrate(
        PoolSettings calldata settings
    ) external payable override onlyAdmin nonReentrant seeded {
        uint160 sqrtPrice = _checkedSpot();
        bytes32 from = PoolId.unwrap(_key.toId());
        uint128 liquidity = positionLiquidity();
        if (liquidity != 0) launcher.withdraw(family, 0, liquidity, 0, 0, address(this), block.timestamp);
        _setSettings(settings);
        uint256 usdgHeld = IERC20(_usdg).balanceOf(address(this));
        uint256 sharesHeld = IERC20(fund).balanceOf(address(this));
        (uint256 amount0, uint256 amount1) = _usdgIs0() ? (usdgHeld, sharesHeld) : (sharesHeld, usdgHeld);
        _open(sqrtPrice, amount0, amount1);
        _sweep();
        // Staked LP positions in the old pool stop earning from here.
        IFundStaking(IFund(fund).staking()).poolMoved();
        emit Migrated(from, PoolId.unwrap(_key.toId()));
    }

    /// @inheritdoc IFundVenue
    function setPoolSettings(
        PoolSettings calldata settings
    ) external override onlyAdmin {
        if (isSeeded) revert AlreadySeeded();
        _setSettings(settings);
    }

    /// @inheritdoc IFundVenue
    function setIssuance(
        IssuanceConfig calldata config
    ) external override onlyAdmin {
        (_issuanceStartBps, _potShareBps, _hourlyCapBps) = PoolIssuance.configure(_steps, config);
    }

    /// @notice Pool manager callback for {issue}: sells up to `left` newly issued fund tokens into
    ///         the pool down to the square root price `limit`, mints what the swap took straight to
    ///         the pool manager, and sends the USDG it raised to the fund.
    /// @param data `(left, limit, nav)`.
    /// @return `(issued, usdgIn, pot)`.
    function unlockCallback(
        bytes calldata data
    ) external override onlyPoolManager returns (bytes memory) {
        (uint256 left, uint160 limit, uint256 nav) = abi.decode(data, (uint256, uint160, uint256));
        bool usdgIs0 = _usdgIs0();
        BalanceDelta delta = poolManager.swap(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: !usdgIs0,
                amountSpecified: -SafeCast.toInt256(left),
                sqrtPriceLimitX96: limit
            }),
            ""
        );
        (int128 usdgDelta, int128 fundDelta) =
            usdgIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 issued = fundDelta < 0 ? uint256(-int256(fundDelta)) : 0;
        uint256 usdgIn = usdgDelta > 0 ? uint256(int256(usdgDelta)) : 0;
        uint256 pot;
        if (issued != 0) {
            uint256 paid = Math.mulDiv(usdgIn, PRECISION, _usdgUnit);
            uint256 atNav = Math.mulDiv(issued, nav, PRECISION);
            // Rounds down: the pot never gets more tokens than its share of the premium buys at NAV.
            if (paid > atNav) pot = Math.mulDiv(paid - atNav, _potShareBps * PRECISION, BPS * nav);
            poolManager.sync(Currency.wrap(fund));
            IFund(fund).venueIssue(address(poolManager), issued, pot);
            poolManager.settle();
        }
        if (usdgIn != 0) poolManager.take(Currency.wrap(_usdg), fund, usdgIn);
        return abi.encode(issued, usdgIn, pot);
    }

    /// @inheritdoc IFundVenue
    function poolKey() external view override returns (PoolKey memory) {
        return _key;
    }

    /// @inheritdoc IFundVenue
    function poolSettings() external view override returns (PoolSettings memory) {
        return _settings;
    }

    /// @inheritdoc IFundVenue
    function taxQueues() external view override returns (address buyQueue, address sellQueue) {
        return (_buyQueue, _sellQueue);
    }

    /// @inheritdoc IFundVenue
    function positionLiquidity() public view override returns (uint128) {
        if (!isSeeded) return 0;
        return launcher.position(family, 0).liquidity;
    }

    /// @inheritdoc IFundVenue
    function positionAmounts() external view override returns (uint256 usdgAmount, uint256 fundTokens) {
        return liquidityAmounts(positionLiquidity());
    }

    /// @inheritdoc IFundVenue
    function positionBounds(
        bool high
    ) external view override returns (uint256 usdgAmount, uint256 fundTokens) {
        uint128 liquidity = positionLiquidity();
        if (liquidity == 0) return (0, 0);
        (uint160 lower, uint160 upper) = _range();
        (usdgAmount, fundTokens) = _amountsAt(_reference(), liquidity, lower, upper);
        (uint256 spotUsdg, uint256 spotTokens) = _amountsAt(_spot(_key.toId()), liquidity, lower, upper);
        (usdgAmount, fundTokens) = high
            ? (Math.max(usdgAmount, spotUsdg), Math.max(fundTokens, spotTokens))
            : (Math.min(usdgAmount, spotUsdg), Math.min(fundTokens, spotTokens));
    }

    /// @inheritdoc IFundVenue
    function liquidityAmounts(
        uint128 liquidity
    ) public view override returns (uint256 usdgAmount, uint256 fundTokens) {
        if (!isSeeded || liquidity == 0) return (0, 0);
        (uint160 lower, uint160 upper) = _range();
        return _amountsAt(_reference(), liquidity, lower, upper);
    }

    /// @inheritdoc IFundVenue
    function spotPrice() external view override returns (uint256) {
        if (!isSeeded) return 0;
        return PoolIssuance.priceOf(PoolIssuance.qAt(_spot(_key.toId()), _usdgIs0()), _usdgUnit);
    }

    /// @inheritdoc IFundVenue
    function issuanceOf() external view override returns (IssuanceConfig memory) {
        return IssuanceConfig({
            startBps: _issuanceStartBps,
            potShareBps: _potShareBps,
            hourlyCapBps: _hourlyCapBps,
            steps: _steps
        });
    }

    /// @dev Opens a Hookr pool with the current settings at `sqrtPrice`, funded with what
    ///      `amount0` and `amount1` (held here) allow as a full-range position, and points the venue
    ///      at it. The launcher pulls the amounts and refunds what it does not use.
    function _open(uint160 sqrtPrice, uint256 amount0, uint256 amount1) internal {
        uint128 liquidity = _liquidityFor(sqrtPrice, amount0, amount1);
        uint256 usdgBefore = IERC20(_usdg).balanceOf(address(this));
        uint256 sharesBefore = IERC20(fund).balanceOf(address(this));
        _approveLauncher(amount0, amount1);
        bytes32 family_ = _launch(sqrtPrice, liquidity, amount0, amount1);
        PoolKey memory key = launcher.position(family_, 0).key;
        IHookrDirectionalTax.Terms memory t = IHookrDirectionalTax(taxAdvisory).terms(root, key.toId());
        (_key, family, _buyQueue, _sellQueue) = (key, family_, t.buyQueue, t.sellQueue);
        _openSqrt = sqrtPrice;
        (_anchor, _anchorIssued) = (PoolIssuance.qAt(sqrtPrice, _usdgIs0()), 0);
        emit PoolOpened(
            PoolId.unwrap(key.toId()),
            family_,
            liquidity,
            usdgBefore - IERC20(_usdg).balanceOf(address(this)),
            sharesBefore - IERC20(fund).balanceOf(address(this))
        );
    }

    /// @dev Launches the fund's Hookr family: one fund token / USDG pool on the root with the
    ///      Directional Tax paying the fund's curators, and the fund's full-range position in it.
    function _launch(
        uint160 sqrtPrice,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) internal returns (bytes32 family_) {
        PoolSettings memory s = _settings;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory m = members[0];
        m.quote = Currency.wrap(_usdg);
        m.tickSpacing = s.tickSpacing;
        m.sqrtPriceX96 = sqrtPrice;
        m.tickLower = TickMath.minUsableTick(s.tickSpacing);
        m.tickUpper = TickMath.maxUsableTick(s.tickSpacing);
        m.liquidity = liquidity;
        m.amount0Max = SafeCast.toUint128(amount0);
        m.amount1Max = SafeCast.toUint128(amount1);
        m.config.rules = rules;
        m.config.advisory = taxAdvisory;
        m.config.baseLpFeePips = s.lpFeePips;
        m.config.caps = HookrTypes.Caps(CAP_LP_FEE_PIPS, CAP_QUOTE_TAKE_PIPS, 0);
        m.config.rulesGasLimit = RULES_GAS_LIMIT;
        m.config.advisoryGasLimit = ADVISORY_GAS_LIMIT;
        m.config.advisoryPhases = ADVISORY_PHASES;
        m.config.policyId = POLICY_ID;
        m.rules.maxFeePips = s.lpFeePips;
        m.rules.protocolShareBps = s.hookrShareBps;
        address curators = IFund(fund).curators();
        bytes[] memory advisory = new bytes[](1);
        advisory[0] =
            abi.encode(IHookrDirectionalTax.Config(_leg(s.buyTaxPips, curators), _leg(s.sellTaxPips, curators)));
        (family_,) = launcher.launchAdvised{value: msg.value}(
            IHookrLauncher.Token(fund, "", "", 0, bytes32(0)), root, members, advisory, block.timestamp
        );
    }

    /// @dev Collects the LP fees on the fund's position: USDG to the fund, fund tokens burned.
    function _collectFees() internal returns (uint256 usdgAmount, uint256 burned) {
        if (positionLiquidity() == 0) return (0, 0);
        return _collect();
    }

    /// @dev As {_collectFees}, for a position known to hold liquidity.
    function _collect() internal returns (uint256 usdgAmount, uint256 burned) {
        launcher.withdraw(family, 0, 0, 0, 0, address(this), block.timestamp);
        (usdgAmount, burned) = _sweep();
        emit LpFeesCollected(usdgAmount, burned);
    }

    /// @dev Sends every USDG held here to the fund and burns every fund token held here.
    function _sweep() internal returns (uint256 usdgAmount, uint256 burned) {
        burned = IERC20(fund).balanceOf(address(this));
        if (burned != 0) IFund(fund).burn(burned);
        usdgAmount = IERC20(_usdg).balanceOf(address(this));
        if (usdgAmount != 0) IERC20(_usdg).safeTransfer(fund, usdgAmount);
    }

    function _approveLauncher(uint256 amount0, uint256 amount1) internal {
        (uint256 usdgAmount, uint256 shares) = _usdgIs0() ? (amount0, amount1) : (amount1, amount0);
        IERC20(_usdg).forceApprove(address(launcher), usdgAmount);
        IERC20(fund).forceApprove(address(launcher), shares);
    }

    function _setSettings(
        PoolSettings memory s
    ) internal {
        if (s.tickSpacing == 0) s.tickSpacing = DEFAULT_TICK_SPACING;
        if (
            s.buyTaxPips > MAX_FEE_PIPS || s.sellTaxPips > MAX_FEE_PIPS || s.lpFeePips > MAX_FEE_PIPS
                || s.hookrShareBps < MIN_HOOKR_SHARE_BPS || s.hookrShareBps > MAX_HOOKR_SHARE_BPS || s.tickSpacing < 1
                || s.tickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidSettings();
        _settings = s;
        emit PoolSettingsSet(s);
    }

    /// @dev Fund tokens the hourly cap still allows, and those that count against it now.
    function _hourly(
        uint256 supply
    ) internal view returns (uint256 left, uint256 used) {
        uint256 cap = Math.mulDiv(supply, _hourlyCapBps, BPS);
        uint256 drained = Math.mulDiv(cap, block.timestamp - _issuedAt, 1 hours);
        used = _issued > drained ? _issued - drained : 0;
        left = cap > used ? cap - used : 0;
    }

    /// @dev The spot square root price, checked within {MAX_SQRT_GAP_BPS} of the reference's.
    function _checkedSpot() internal view returns (uint160 sqrtPrice) {
        sqrtPrice = _spot(_key.toId());
        uint256 ref = _reference();
        if (sqrtPrice * BPS > ref * (BPS + MAX_SQRT_GAP_BPS) || sqrtPrice * (BPS + MAX_SQRT_GAP_BPS) < ref * BPS) {
            revert PriceOffReference();
        }
    }

    /// @dev The square root price the position is valued at: the fund token's latest oracle price
    ///      (a signed pool TWAP), however old, since no spot reading resists manipulation within a
    ///      block; the pool's opening price until the oracle has one.
    function _reference() internal view returns (uint160) {
        uint256 price = IFundOracle(_factory.oracle()).lastPrice(fund);
        if (price == 0) return _openSqrt;
        return PoolIssuance.sqrtPriceAt(price, _usdgIs0(), _usdgUnit);
    }

    function _spot(
        PoolId id
    ) internal view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = poolManager.getSlot0(id);
    }

    /// @dev The square root prices bounding the current pool's full-range position.
    function _range() internal view returns (uint160 lower, uint160 upper) {
        int24 spacing = _key.tickSpacing;
        lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(spacing));
        upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(spacing));
    }

    function _amountsAt(
        uint160 sqrtPrice,
        uint128 liquidity,
        uint160 lower,
        uint160 upper
    ) internal view returns (uint256 usdgAmount, uint256 tokens) {
        sqrtPrice = uint160(Math.min(Math.max(sqrtPrice, lower), upper));
        (uint256 amount0, uint256 amount1) = FullRangeLiquidity.amountsForLiquidity(sqrtPrice, lower, upper, liquidity);
        (usdgAmount, tokens) = _usdgIs0() ? (amount0, amount1) : (amount1, amount0);
    }

    function _liquidityFor(
        uint160 sqrtPrice,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128 liquidity) {
        int24 spacing = _settings.tickSpacing;
        liquidity = FullRangeLiquidity.liquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(spacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(spacing)),
            amount0,
            amount1
        );
        if (liquidity == 0) revert InvalidSeed();
    }

    function _checkAdmin() internal view {
        if (!_factory.isAdmin(msg.sender)) revert NotAdmin();
    }

    function _usdgIs0() internal view returns (bool) {
        return _usdg < fund;
    }

    /// @dev One direction of the tax: a disabled direction must be all zero.
    function _leg(uint24 taxPips, address recipient) internal pure returns (IHookrDirectionalTax.Leg memory leg) {
        if (taxPips != 0) (leg.taxPips, leg.assetRecipient) = (taxPips, recipient);
    }
}
