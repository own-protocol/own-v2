// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IssuanceConfig, IssuanceStep, PremiumConfig} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {FullRangeLiquidity} from "./libraries/FullRangeLiquidity.sol";
import {PoolIssuance} from "./libraries/PoolIssuance.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title FundHook — Uniswap v4 hook and liquidity locker for fund pools
/// @notice See {IFundHook}.
/// @dev Runs behind an ERC-1967 proxy (UUPS) upgraded by the registry ADMIN; storage is
///      append-only across upgrades. The proxy must be deployed at an address whose low bits
///      encode exactly {getHookPermissions} (mined with CREATE2); the pool manager calls only
///      those callbacks, so only they are implemented. Every pool is the fund token against USDG
///      with this hook, a dynamic fee and {TICK_SPACING}, so a fund's pool key is derived rather
///      than stored. Swap fees are taken in
///      USDG whichever side the trader specifies:
///      - USDG is the specified side (exact USDG in, or exact USDG out): {beforeSwap} returns a
///        specified delta, so the pool swaps the amount net of (or grossed up by) the fee;
///      - USDG is the unspecified side: {afterSwap} returns an unspecified delta on the USDG leg.
///      Either way the fee is taken from the pool manager straight to the recipients inside the
///      same callback, and the returned delta makes the trader pay it.
///
///      TWAP: before each swap moves the price, the tick that has held since the last update is
///      added to a per-pool accumulator (as in Uniswap v3). Checkpoints are copied into a ring at
///      most every {OBSERVATION_INTERVAL}, and the ring spans longer than {MAX_TWAP_WINDOW}, so
///      a checkpoint old enough for any allowed window is always kept.
///
///      The fund's position is this hook's full-range position (salt 0) in the fund's pool. It is
///      valued at the pool TWAP: price manipulation inside a block never moves it, because the
///      accumulator only adds a tick once it has held across a block boundary.
///
///      Issuance (how much of a buy the hook fills) is computed by the {PoolIssuance} library.
contract FundHook is IFundHook, IUnlockCallback, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    /// @notice Tick spacing of every fund pool.
    int24 public constant TICK_SPACING = 60;

    /// @notice Hard cap on a pool's LP fee (10%, in hundredths of a basis point).
    uint24 public constant MAX_LP_FEE = 100_000;

    /// @notice Minimum spacing between ring checkpoints.
    uint32 public constant OBSERVATION_INTERVAL = 5 minutes;

    /// @notice Ring size; 48 checkpoints at least 5 minutes apart span at least 235 minutes.
    uint256 public constant OBSERVATION_SLOTS = 48;

    /// @notice Longest window {consult} serves.
    uint32 public constant MAX_TWAP_WINDOW = 3 hours;

    /// @notice Window over which the fund's position is valued.
    uint32 public constant POSITION_TWAP_WINDOW = 30 minutes;

    enum Action {
        Seed,
        Collect,
        Remove
    }

    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    /// @dev The first slot holds the pool's flags and the latest accumulator checkpoint, so a swap
    ///      reads both with one storage load. The second caches the fund's curators module and when
    ///      the newest ring checkpoint was taken; both are zero for a pool seeded before they existed
    ///      and are filled on first use.
    struct Pool {
        bool registered;
        bool seeded;
        uint24 lpFee;
        uint128 liquidity;
        uint32 observedAt;
        int56 tickCumulative;
        uint8 index;
        // The tick at the start of the latest observed block, for a zero-length TWAP period.
        int24 blockTick;
        address curators;
        uint32 ringAt;
        Observation[OBSERVATION_SLOTS] ring;
        uint16 issuanceStartBps;
        uint16 potShareBps;
        // USDG paid for issued tokens, held as pool manager claims until the next collect or redeem.
        uint128 pendingUsdg;
        IssuanceStep[] steps;
    }

    /// @notice The Uniswap v4 pool manager.
    IPoolManager public immutable override poolManager;

    /// @notice The fund factory (its owner is this hook's admin).
    IFundFactory public immutable factory;

    address private immutable _usdg;
    uint256 private immutable _usdgUnit;
    int24 private immutable _tickLower = TickMath.minUsableTick(TICK_SPACING);
    int24 private immutable _tickUpper = TickMath.maxUsableTick(TICK_SPACING);
    uint160 private immutable _sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING));
    uint160 private immutable _sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING));

    mapping(address fund => Pool) private _pools;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, IFundFactory factory_) {
        poolManager = poolManager_;
        factory = factory_;
        _usdg = factory_.usdg();
        _usdgUnit = 10 ** IERC20Metadata(_usdg).decimals();
        _disableInitializers();
    }

    /// @inheritdoc IFundHook
    function initialize() external override initializer {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @inheritdoc IFundHook
    function registerFund(
        address fund
    ) external override {
        if (msg.sender != address(factory)) revert NotFactory();
        Pool storage pool = _pools[fund];
        if (pool.registered) revert AlreadyRegistered();
        pool.registered = true;
        emit FundRegistered(fund, PoolId.unwrap(_key(fund).toId()));
        PremiumConfig memory c = factory.premiumConfig();
        _setIssuance(fund, pool, c.issuanceStartBps, c.potShareBps, factory.defaultIssuanceSteps());
    }

    /// @inheritdoc IFundHook
    function seedPool(address fund, uint256 usdgAmount, uint256 shareAmount) external override {
        Pool storage pool = _pools[fund];
        if (!pool.registered) revert NotRegistered();
        if (msg.sender != IFund(fund).launch()) revert NotLaunch();
        if (pool.seeded) revert AlreadySeeded();
        if (usdgAmount == 0 || shareAmount == 0) revert InvalidSeed();
        pool.seeded = true;

        bool usdgIs0 = _usdg < fund;
        (uint256 amount0, uint256 amount1) = usdgIs0 ? (usdgAmount, shareAmount) : (shareAmount, usdgAmount);
        uint160 sqrtPrice = _sqrtPriceX96(amount0, amount1);

        PoolKey memory key = _key(fund);
        pool.blockTick = poolManager.initialize(key, sqrtPrice);
        pool.observedAt = uint32(block.timestamp);
        pool.ring[0] = Observation({timestamp: uint32(block.timestamp), tickCumulative: 0});
        pool.ringAt = uint32(block.timestamp);
        pool.curators = IFund(fund).curators();
        if (pool.lpFee != 0) poolManager.updateDynamicLPFee(key, pool.lpFee);

        uint128 liquidity = FullRangeLiquidity.liquidityForAmounts(sqrtPrice, _sqrtLower, _sqrtUpper, amount0, amount1);
        if (liquidity == 0) revert InvalidSeed();
        pool.liquidity = liquidity;

        (uint256 used0, uint256 used1) =
            abi.decode(poolManager.unlock(abi.encode(Action.Seed, fund, liquidity)), (uint256, uint256));
        _sweepSeedDust(fund);

        if (usdgIs0) emit PoolSeeded(fund, liquidity, used0, used1);
        else emit PoolSeeded(fund, liquidity, used1, used0);
    }

    /// @inheritdoc IFundHook
    function poke(
        address fund
    ) external override {
        Pool storage pool = _pools[fund];
        if (!pool.seeded) revert NotRegistered();
        _observe(pool, _key(fund).toId());
    }

    /// @inheritdoc IFundHook
    function collectLpFees(
        address fund
    ) external override returns (uint256 usdgAmount, uint256 burned) {
        Pool storage pool = _seeded(fund);
        if (pool.liquidity == 0 && pool.pendingUsdg == 0) return (0, 0);
        (, usdgAmount, burned) =
            abi.decode(poolManager.unlock(abi.encode(Action.Collect, fund)), (uint256, uint256, uint256));
        if (burned != 0) IFund(fund).burn(burned);
        emit LpFeesCollected(fund, usdgAmount, burned);
    }

    /// @inheritdoc IFundHook
    function redeemPosition(
        uint256 numerator,
        uint256 denominator,
        address receiver
    ) external override returns (uint256 usdgPaid) {
        address fund = msg.sender;
        Pool storage pool = _pools[fund];
        if (!pool.registered) revert NotFund();
        if (!pool.seeded || numerator == 0) return 0;
        // Rounds down: a redeemer never removes more than their share of the position or of the
        // pending issuance USDG.
        uint128 liquidity = SafeCast.toUint128(Math.mulDiv(pool.liquidity, numerator, denominator));
        uint256 pending = Math.mulDiv(pool.pendingUsdg, numerator, denominator);
        if (liquidity == 0 && pending == 0) return 0;
        pool.pendingUsdg -= uint128(pending);
        (uint256 usdgCap,) = _amountsAt(fund, _positionTick(pool, fund), liquidity);
        usdgPaid = _reduce(fund, pool, liquidity, receiver, usdgCap, pending);
    }

    /// @inheritdoc IFundHook
    function withdrawPosition(address fund, uint128 liquidity) external override {
        if (!factory.isAdmin(msg.sender)) revert NotAdmin();
        Pool storage pool = _seeded(fund);
        if (liquidity == 0 || liquidity > pool.liquidity) revert InsufficientLiquidity();
        _reduce(fund, pool, liquidity, fund, 0, 0);
    }

    /// @inheritdoc IFundHook
    function setLpFee(address fund, uint24 lpFee) external override {
        if (!factory.isAdmin(msg.sender)) revert NotAdmin();
        if (lpFee > MAX_LP_FEE) revert LpFeeTooHigh();
        Pool storage pool = _pools[fund];
        if (!pool.registered) revert NotRegistered();
        pool.lpFee = lpFee;
        if (pool.seeded) poolManager.updateDynamicLPFee(_key(fund), lpFee);
        emit LpFeeSet(fund, lpFee);
    }

    /// @inheritdoc IFundHook
    function setIssuance(address fund, IssuanceConfig calldata config) external override {
        if (!factory.isAdmin(msg.sender)) revert NotAdmin();
        Pool storage pool = _pools[fund];
        if (!pool.registered) revert NotRegistered();
        _setIssuance(fund, pool, config.startBps, config.potShareBps, config.steps);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(
        bytes calldata data
    ) external override onlyPoolManager returns (bytes memory) {
        (Action action, address fund) = abi.decode(data, (Action, address));
        PoolKey memory key = _key(fund);
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            liquidityDelta: 0,
            salt: bytes32(0)
        });

        if (action == Action.Seed) {
            (,, uint128 liquidity) = abi.decode(data, (Action, address, uint128));
            params.liquidityDelta = SafeCast.toInt256(uint256(liquidity));
            (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
            return abi.encode(_settle(key.currency0, delta.amount0()), _settle(key.currency1, delta.amount1()));
        }

        uint256 paid;
        uint256 toFund;
        uint256 burned;
        if (action == Action.Collect) {
            Pool storage pool = _pools[fund];
            if (pool.liquidity != 0) {
                (BalanceDelta fees,) = poolManager.modifyLiquidity(key, params, "");
                (, toFund, burned) = _payOut(fees, fees, fund, fund, type(uint256).max);
            }
            uint256 pending = pool.pendingUsdg;
            pool.pendingUsdg = 0;
            return abi.encode(0, toFund + _payPending(fund, pending), burned);
        }

        (,, uint128 removed, address receiver, uint256 usdgCap, uint256 share) =
            abi.decode(data, (Action, address, uint128, address, uint256, uint256));
        if (removed != 0) {
            params.liquidityDelta = -SafeCast.toInt256(uint256(removed));
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, "");
            (paid, toFund, burned) = _payOut(callerDelta, callerDelta - feesAccrued, receiver, fund, usdgCap);
        }
        return abi.encode(paid + _payPending(receiver, share), toFund, burned);
    }

    /// @notice Pool manager callback; any call is someone else trying to create a pool on this hook.
    /// @dev The pool manager skips this callback when the hook itself initialises.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert InitializeNotAllowed();
    }

    /// @notice Pool manager callback: records the TWAP accumulator, takes the swap fees when USDG
    ///         is the specified side, and fills part of a buy above NAV with newly issued fund tokens.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        (address fund, bool usdgIs0) = _fundOf(key);
        Pool storage pool = _pools[fund];
        PoolId id = key.toId();
        _observe(pool, id);
        bool exactIn = params.amountSpecified < 0;
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        Currency usdg = usdgIs0 ? key.currency0 : key.currency1;
        bool buy = params.zeroForOne == usdgIs0;
        if ((exactIn == params.zeroForOne) == usdgIs0) {
            // USDG is the specified side: a buy with exact USDG in, or a sell for exact USDG out.
            uint256 taken = _takeFees(fund, pool, usdg, amount);
            uint256 tokensOut;
            if (buy) {
                uint256 usdgIn;
                (usdgIn, tokensOut) = _issue(fund, pool, id, usdgIs0, amount - taken, true);
                taken += usdgIn;
            }
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_int128(taken), -_int128(tokensOut)), 0);
        }
        if (!buy) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        // A buy of exact fund tokens out: the hook hands over part of them and charges their USDG plus the fee.
        (uint256 cost, uint256 issued) = _issue(fund, pool, id, usdgIs0, amount, false);
        if (issued == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        cost += _takeFees(fund, pool, usdg, cost);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(-_int128(issued), _int128(cost)), 0);
    }

    /// @notice Pool manager callback: takes the swap fees when USDG is the unspecified side.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        (address fund, bool usdgIs0) = _fundOf(key);
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIs0 == usdgIs0) return (IHooks.afterSwap.selector, 0);
        int128 usdgDelta = usdgIs0 ? delta.amount0() : delta.amount1();
        uint256 amount = usdgDelta < 0 ? uint256(-int256(usdgDelta)) : uint256(int256(usdgDelta));
        uint256 fee = _takeFees(fund, _pools[fund], usdgIs0 ? key.currency0 : key.currency1, amount);
        return (IHooks.afterSwap.selector, SafeCast.toInt128(SafeCast.toInt256(fee)));
    }

    /// @inheritdoc IFundHook
    function consult(
        address fund,
        uint32 window
    ) external view override returns (bool ok, int24 meanTick, uint32 period) {
        Pool storage pool = _pools[fund];
        if (!pool.seeded || window == 0 || window > MAX_TWAP_WINDOW || block.timestamp <= window) {
            return (false, 0, 0);
        }
        (ok, meanTick, period) = _twap(pool, fund, uint32(block.timestamp) - window);
        if (!ok) return (false, 0, 0);
    }

    /// @inheritdoc IFundHook
    function maxTwapWindow() external pure override returns (uint32) {
        return MAX_TWAP_WINDOW;
    }

    /// @inheritdoc IFundHook
    function poolKeyOf(
        address fund
    ) external view override returns (PoolKey memory key) {
        if (_pools[fund].registered) key = _key(fund);
    }

    /// @inheritdoc IFundHook
    function isSeeded(
        address fund
    ) external view override returns (bool) {
        return _pools[fund].seeded;
    }

    /// @inheritdoc IFundHook
    function positionLiquidity(
        address fund
    ) external view override returns (uint128) {
        return _pools[fund].liquidity;
    }

    /// @inheritdoc IFundHook
    function positionAmounts(
        address fund
    ) external view override returns (uint256 usdgAmount, uint256 fundTokens) {
        Pool storage pool = _pools[fund];
        (usdgAmount, fundTokens) = liquidityAmounts(fund, pool.liquidity);
        usdgAmount += pool.pendingUsdg;
    }

    /// @inheritdoc IFundHook
    function liquidityAmounts(
        address fund,
        uint128 liquidity
    ) public view override returns (uint256 usdgAmount, uint256 fundTokens) {
        Pool storage pool = _pools[fund];
        if (!pool.seeded || liquidity == 0) return (0, 0);
        return _amountsAt(fund, _positionTick(pool, fund), liquidity);
    }

    /// @inheritdoc IFundHook
    function spotPrice(
        address fund
    ) external view override returns (uint256) {
        if (!_pools[fund].seeded) return 0;
        PoolKey memory key = _key(fund);
        return PoolIssuance.priceOf(_sqrtUsdgPerToken(key.toId(), Currency.unwrap(key.currency0) == _usdg), _usdgUnit);
    }

    /// @inheritdoc IFundHook
    function issuanceOf(
        address fund
    ) external view override returns (IssuanceConfig memory) {
        Pool storage pool = _pools[fund];
        return IssuanceConfig({startBps: pool.issuanceStartBps, potShareBps: pool.potShareBps, steps: pool.steps});
    }

    /// @notice Callbacks this hook enables; its deployed address must encode exactly these.
    /// @return The permissions.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _observe(Pool storage pool, PoolId id) private {
        uint32 nowTs = uint32(block.timestamp);
        uint32 last = pool.observedAt;
        if (nowTs == last) return;
        (, int24 tick,,) = poolManager.getSlot0(id);
        int56 cumulative = pool.tickCumulative + int56(tick) * int56(uint56(nowTs - last));
        pool.observedAt = nowTs;
        pool.tickCumulative = cumulative;
        pool.blockTick = tick;
        uint256 index = pool.index;
        uint32 ringAt = pool.ringAt;
        if (ringAt == 0) ringAt = pool.ring[index].timestamp;
        if (nowTs - ringAt >= OBSERVATION_INTERVAL) {
            index = (index + 1) % OBSERVATION_SLOTS;
            pool.index = uint8(index);
            pool.ringAt = nowTs;
            pool.ring[index] = Observation({timestamp: nowTs, tickCumulative: cumulative});
        }
    }

    function _reduce(
        address fund,
        Pool storage pool,
        uint128 liquidity,
        address receiver,
        uint256 usdgCap,
        uint256 pending
    ) private returns (uint256 paid) {
        pool.liquidity -= liquidity;
        uint256 toFund;
        uint256 burned;
        (paid, toFund, burned) = abi.decode(
            poolManager.unlock(abi.encode(Action.Remove, fund, liquidity, receiver, usdgCap, pending)),
            (uint256, uint256, uint256)
        );
        if (burned != 0) IFund(fund).burn(burned);
        emit PositionReduced(fund, liquidity, paid, toFund, burned);
    }

    /// @dev Takes a removal's tokens from the pool manager: the principal USDG up to `usdgCap` to
    ///      `receiver`, the rest of the USDG to the fund, and every fund token to this hook (to be
    ///      burned). Returns (USDG to receiver, USDG to fund, fund tokens taken).
    function _payOut(
        BalanceDelta total,
        BalanceDelta principal,
        address receiver,
        address fund,
        uint256 usdgCap
    ) private returns (uint256, uint256, uint256) {
        bool usdgIs0 = _usdg < fund;
        uint256 all = _positive(usdgIs0 ? total.amount0() : total.amount1());
        uint256 paid = Math.min(_positive(usdgIs0 ? principal.amount0() : principal.amount1()), usdgCap);
        if (receiver == fund) paid = 0;
        if (paid != 0) poolManager.take(Currency.wrap(_usdg), receiver, paid);
        if (all > paid) poolManager.take(Currency.wrap(_usdg), fund, all - paid);
        uint256 burned = _take(Currency.wrap(fund), usdgIs0 ? total.amount1() : total.amount0(), address(this));
        return (paid, all - paid, burned);
    }

    function _positive(
        int128 x
    ) private pure returns (uint256) {
        return x > 0 ? uint256(int256(x)) : 0;
    }

    /// @dev Turns `amount` of the hook's USDG claims into USDG for `to`.
    function _payPending(address to, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        poolManager.burn(address(this), uint256(uint160(_usdg)), amount);
        poolManager.take(Currency.wrap(_usdg), to, amount);
        return amount;
    }

    /// @dev Fills part of a buy with new fund tokens when the pool price is above the issuance start
    ///      (see {PoolIssuance-issue}): for exact input `amount` is the USDG left after the fee, for
    ///      exact output the fund tokens bought. Returns the USDG the buyer pays for the issued tokens
    ///      and the tokens issued; the USDG is held as claims for the fund until the next collect or
    ///      redeem, and counted in its position meanwhile.
    function _issue(
        address fund,
        Pool storage pool,
        PoolId id,
        bool usdgIs0,
        uint256 amount,
        bool exactIn
    ) private returns (uint256 usdgIn, uint256 tokensOut) {
        if (amount == 0 || pool.steps.length == 0) return (0, 0);
        (usdgIn, tokensOut) = PoolIssuance.issue(
            pool.steps,
            PoolIssuance.Buy({
                fund: fund,
                usdg: _usdg,
                usdgUnit: _usdgUnit,
                id: id,
                usdgIs0: usdgIs0,
                startBps: pool.issuanceStartBps,
                potShareBps: pool.potShareBps,
                amount: amount,
                exactIn: exactIn
            })
        );
        pool.pendingUsdg += SafeCast.toUint128(usdgIn);
    }

    function _setIssuance(
        address fund,
        Pool storage pool,
        uint16 startBps,
        uint16 potShareBps,
        IssuanceStep[] memory steps
    ) private {
        if (potShareBps > BPS || !PoolIssuance.store(pool.steps, steps)) revert InvalidIssuance();
        pool.issuanceStartBps = startBps;
        pool.potShareBps = potShareBps;
        emit IssuanceSet(fund, IssuanceConfig({startBps: startBps, potShareBps: potShareBps, steps: steps}));
    }

    function _takeFees(address fund, Pool storage pool, Currency usdg, uint256 amount) private returns (uint256) {
        // Rounds down: the fee never exceeds the configured share of the USDG leg.
        uint256 fee = Math.mulDiv(amount, IFund(fund).feeBps(), BPS);
        if (fee == 0) return 0;
        address cur = pool.curators;
        if (cur == address(0)) {
            cur = IFund(fund).curators();
            pool.curators = cur;
        }
        poolManager.take(usdg, cur, fee);
        emit SwapFeesTaken(fund, fee);
        return fee;
    }

    // Sweeps the whole balance: the hook holds nothing between seeds, so anything else was donated.
    function _sweepSeedDust(
        address fund
    ) private {
        uint256 shareDust = IERC20(fund).balanceOf(address(this));
        if (shareDust != 0) IFund(fund).burn(shareDust);
        uint256 usdgDust = IERC20(_usdg).balanceOf(address(this));
        if (usdgDust != 0) IERC20(_usdg).safeTransfer(fund, usdgDust);
    }

    function _settle(Currency currency, int128 delta) private returns (uint256 amount) {
        if (delta >= 0) return 0;
        amount = uint256(-int256(delta));
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, int128 delta, address recipient) private returns (uint256 amount) {
        if (delta <= 0) return 0;
        amount = uint256(int256(delta));
        poolManager.take(currency, recipient, amount);
    }

    function _seeded(
        address fund
    ) private view returns (Pool storage pool) {
        pool = _pools[fund];
        if (!pool.seeded) revert NotRegistered();
    }

    /// @dev Mean tick over {POSITION_TWAP_WINDOW}, or over all history since seeding when there is
    ///      less, or the tick at the start of the block when the pool was seeded in this block.
    function _positionTick(Pool storage pool, address fund) private view returns (int24 meanTick) {
        uint32 nowTs = uint32(block.timestamp);
        (, meanTick,) = _twap(pool, fund, nowTs > POSITION_TWAP_WINDOW ? nowTs - POSITION_TWAP_WINDOW : 0);
    }

    /// @dev Mean tick since the newest checkpoint at or before `target` (`found`), or else since the
    ///      oldest checkpoint kept. Over a zero-length period it is the tick at the start of the block.
    function _twap(
        Pool storage pool,
        address fund,
        uint32 target
    ) private view returns (bool found, int24 meanTick, uint32 period) {
        Observation memory latest = Observation({timestamp: pool.observedAt, tickCumulative: pool.tickCumulative});
        Observation memory from = latest;
        found = from.timestamp <= target;
        if (!found) {
            uint256 index = pool.index;
            for (uint256 i; i < OBSERVATION_SLOTS; ++i) {
                Observation memory o = pool.ring[index];
                if (o.timestamp == 0) break;
                from = o;
                if (o.timestamp <= target) {
                    found = true;
                    break;
                }
                index = index == 0 ? OBSERVATION_SLOTS - 1 : index - 1;
            }
        }

        uint32 nowTs = uint32(block.timestamp);
        period = nowTs - from.timestamp;
        if (period == 0) return (found, pool.blockTick, 0);
        (, int24 tick,,) = poolManager.getSlot0(_key(fund).toId());
        int56 delta =
            latest.tickCumulative + int56(tick) * int56(uint56(nowTs - latest.timestamp)) - from.tickCumulative;
        int56 elapsed = int56(uint56(period));
        meanTick = int24(delta / elapsed);
        if (delta < 0 && delta % elapsed != 0) meanTick--;
    }

    /// @dev UUPS upgrade gate: the registry ADMIN.
    function _authorizeUpgrade(
        address
    ) internal view override {
        if (!factory.isAdmin(msg.sender)) revert NotAdmin();
    }

    function _amountsAt(
        address fund,
        int24 tick,
        uint128 liquidity
    ) private view returns (uint256 usdgAmount, uint256 fundTokens) {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtPrice < _sqrtLower) sqrtPrice = _sqrtLower;
        if (sqrtPrice > _sqrtUpper) sqrtPrice = _sqrtUpper;
        // Rounds down: the position is never overstated.
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(sqrtPrice, _sqrtUpper, liquidity, false);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(_sqrtLower, sqrtPrice, liquidity, false);
        (usdgAmount, fundTokens) = _usdg < fund ? (amount0, amount1) : (amount1, amount0);
    }

    function _key(
        address fund
    ) private view returns (PoolKey memory) {
        bool usdgIs0 = _usdg < fund;
        return PoolKey({
            currency0: Currency.wrap(usdgIs0 ? _usdg : fund),
            currency1: Currency.wrap(usdgIs0 ? fund : _usdg),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    /// @dev Only this hook initialises pools on itself, so every pool it sees is a fund against USDG.
    function _fundOf(
        PoolKey calldata key
    ) private view returns (address fund, bool usdgIs0) {
        usdgIs0 = Currency.unwrap(key.currency0) == _usdg;
        fund = Currency.unwrap(usdgIs0 ? key.currency1 : key.currency0);
    }

    /// @dev Square root of the pool price as USDG per fund token in raw units, Q96.
    function _sqrtUsdgPerToken(PoolId id, bool usdgIs0) private view returns (uint256) {
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(id);
        return usdgIs0 ? (1 << 192) / sqrtPrice : sqrtPrice;
    }

    function _int128(
        uint256 amount
    ) private pure returns (int128) {
        return SafeCast.toInt128(SafeCast.toInt256(amount));
    }

    function _sqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160) {
        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) revert InvalidSeed();
        return uint160(sqrtPrice);
    }
}
