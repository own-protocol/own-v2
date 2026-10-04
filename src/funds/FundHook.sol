// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {FullRangeLiquidity} from "./libraries/FullRangeLiquidity.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
/// @dev Must be deployed at an address whose low bits encode exactly {getHookPermissions}
///      (mined with CREATE2); the pool manager calls only those callbacks, so only they are
///      implemented. Every pool is the fund token against USDG with this hook, a dynamic fee and
///      {TICK_SPACING}, so a fund's pool key is derived rather than stored. Swap fees are taken in
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
contract FundHook is IFundHook, IUnlockCallback {
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
    ///      reads both with one storage load.
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
        Observation[OBSERVATION_SLOTS] ring;
    }

    /// @notice The Uniswap v4 pool manager.
    IPoolManager public immutable override poolManager;

    /// @notice The fund factory (its owner is this hook's admin).
    IFundFactory public immutable factory;

    address private immutable _usdg;
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
        if (_seeded(fund).liquidity == 0) return (0, 0);
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
        if (!pool.seeded || pool.liquidity == 0 || numerator == 0) return 0;
        // Rounds down: a redeemer never removes more than their share of the position.
        uint128 liquidity = SafeCast.toUint128(Math.mulDiv(pool.liquidity, numerator, denominator));
        if (liquidity == 0) return 0;
        (uint256 usdgCap,) = _amountsAt(fund, _positionTick(pool, fund), liquidity);
        usdgPaid = _reduce(fund, pool, liquidity, receiver, usdgCap);
    }

    /// @inheritdoc IFundHook
    function withdrawPosition(address fund, uint128 liquidity) external override {
        if (msg.sender != factory.owner()) revert NotAdmin();
        Pool storage pool = _seeded(fund);
        if (liquidity == 0 || liquidity > pool.liquidity) revert InsufficientLiquidity();
        _reduce(fund, pool, liquidity, fund, 0);
    }

    /// @inheritdoc IFundHook
    function setLpFee(address fund, uint24 lpFee) external override {
        if (msg.sender != factory.owner()) revert NotAdmin();
        if (lpFee > MAX_LP_FEE) revert LpFeeTooHigh();
        Pool storage pool = _pools[fund];
        if (!pool.registered) revert NotRegistered();
        pool.lpFee = lpFee;
        if (pool.seeded) poolManager.updateDynamicLPFee(_key(fund), lpFee);
        emit LpFeeSet(fund, lpFee);
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

        if (action == Action.Collect) {
            (BalanceDelta fees,) = poolManager.modifyLiquidity(key, params, "");
            return _payOut(fees, fees, fund, fund, type(uint256).max);
        }

        (,, uint128 removed, address receiver, uint256 usdgCap) =
            abi.decode(data, (Action, address, uint128, address, uint256));
        params.liquidityDelta = -SafeCast.toInt256(uint256(removed));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, "");
        return _payOut(callerDelta, callerDelta - feesAccrued, receiver, fund, usdgCap);
    }

    /// @notice Pool manager callback; any call is someone else trying to create a pool on this hook.
    /// @dev The pool manager skips this callback when the hook itself initialises.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert InitializeNotAllowed();
    }

    /// @notice Pool manager callback: records the TWAP accumulator and, when USDG is the specified
    ///         side, takes the swap fees.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        (address fund, bool usdgIs0) = _fundOf(key);
        _observe(_pools[fund], key.toId());
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIs0 != usdgIs0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _takeFees(fund, usdgIs0 ? key.currency0 : key.currency1, amount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(SafeCast.toInt256(fee)), 0), 0);
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
        uint256 fee = _takeFees(fund, usdgIs0 ? key.currency0 : key.currency1, amount);
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
        if (!pool.seeded || pool.liquidity == 0) return (0, 0);
        return _amountsAt(fund, _positionTick(pool, fund), pool.liquidity);
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
        if (nowTs - pool.ring[index].timestamp >= OBSERVATION_INTERVAL) {
            index = (index + 1) % OBSERVATION_SLOTS;
            pool.index = uint8(index);
            pool.ring[index] = Observation({timestamp: nowTs, tickCumulative: cumulative});
        }
    }

    function _reduce(
        address fund,
        Pool storage pool,
        uint128 liquidity,
        address receiver,
        uint256 usdgCap
    ) private returns (uint256 paid) {
        pool.liquidity -= liquidity;
        uint256 toFund;
        uint256 burned;
        (paid, toFund, burned) = abi.decode(
            poolManager.unlock(abi.encode(Action.Remove, fund, liquidity, receiver, usdgCap)),
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
    ) private returns (bytes memory) {
        bool usdgIs0 = _usdg < fund;
        int128 usdgPrincipal = usdgIs0 ? principal.amount0() : principal.amount1();
        int128 usdgTotal = usdgIs0 ? total.amount0() : total.amount1();
        uint256 all = usdgTotal > 0 ? uint256(int256(usdgTotal)) : 0;
        uint256 paid = usdgPrincipal > 0 ? uint256(int256(usdgPrincipal)) : 0;
        if (paid > usdgCap) paid = usdgCap;
        if (receiver == fund) paid = 0;
        if (paid != 0) poolManager.take(Currency.wrap(_usdg), receiver, paid);
        if (all > paid) poolManager.take(Currency.wrap(_usdg), fund, all - paid);
        uint256 burned = _take(Currency.wrap(fund), usdgIs0 ? total.amount1() : total.amount0(), address(this));
        return abi.encode(paid, all - paid, burned);
    }

    function _takeFees(address fund, Currency usdg, uint256 amount) private returns (uint256) {
        // Rounds down: a fee never exceeds the configured share of the USDG leg.
        uint256 protocolFee = Math.mulDiv(amount, factory.protocolFeeBps(), BPS);
        uint256 curatorFee = Math.mulDiv(amount, IFund(fund).curatorFeeBps(), BPS);
        if (protocolFee != 0) poolManager.take(usdg, factory.protocolFeeRecipient(), protocolFee);
        if (curatorFee != 0) poolManager.take(usdg, IFund(fund).curators(), curatorFee);
        if (protocolFee != 0 || curatorFee != 0) emit SwapFeesTaken(fund, protocolFee, curatorFee);
        return protocolFee + curatorFee;
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

    function _sqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160) {
        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) revert InvalidSeed();
        return uint160(sqrtPrice);
    }
}
