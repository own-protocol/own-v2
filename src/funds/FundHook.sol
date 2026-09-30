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
///      (mined with CREATE2). Swap fees are taken in USDG whichever side the trader specifies:
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
contract FundHook is IFundHook, IHooks, IUnlockCallback {
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

    enum Action {
        Seed,
        Collect
    }

    struct PoolConfig {
        address fund;
        bool usdgIsCurrency0;
        bool seeded;
        uint24 lpFee;
        uint128 liquidity;
    }

    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    struct Twap {
        Observation latest;
        uint8 index;
        Observation[OBSERVATION_SLOTS] ring;
    }

    /// @notice The Uniswap v4 pool manager.
    IPoolManager public immutable override poolManager;

    /// @notice The fund factory (its owner is this hook's admin).
    IFundFactory public immutable factory;

    mapping(address fund => PoolKey) private _keys;
    mapping(PoolId => PoolConfig) private _configs;
    mapping(PoolId => Twap) private _twaps;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        IFundFactory factory_
    ) {
        poolManager = poolManager_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @inheritdoc IFundHook
    function registerFund(
        address fund
    ) external override {
        if (msg.sender != address(factory)) revert NotFactory();
        if (address(_keys[fund].hooks) != address(0)) revert AlreadyRegistered();

        address usdg = factory.usdg();
        bool usdgIsCurrency0 = usdg < fund;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdgIsCurrency0 ? usdg : fund),
            currency1: Currency.wrap(usdgIsCurrency0 ? fund : usdg),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
        _keys[fund] = key;
        PoolId id = key.toId();
        _configs[id] = PoolConfig({fund: fund, usdgIsCurrency0: usdgIsCurrency0, seeded: false, lpFee: 0, liquidity: 0});
        emit FundRegistered(fund, PoolId.unwrap(id));
    }

    /// @inheritdoc IFundHook
    function seedPool(
        address fund,
        uint256 usdgAmount,
        uint256 shareAmount
    ) external override {
        PoolKey memory key = _keys[fund];
        if (address(key.hooks) == address(0)) revert NotRegistered();
        if (msg.sender != IFund(fund).launch()) revert NotLaunch();
        PoolConfig storage cfg = _configs[key.toId()];
        if (cfg.seeded) revert AlreadySeeded();
        if (usdgAmount == 0 || shareAmount == 0) revert InvalidSeed();
        cfg.seeded = true;

        (uint256 amount0, uint256 amount1) = cfg.usdgIsCurrency0 ? (usdgAmount, shareAmount) : (shareAmount, usdgAmount);
        uint160 sqrtPrice = _sqrtPriceX96(amount0, amount1);

        poolManager.initialize(key, sqrtPrice);
        Twap storage twap = _twaps[key.toId()];
        twap.latest = Observation({timestamp: uint32(block.timestamp), tickCumulative: 0});
        twap.ring[0] = twap.latest;
        if (cfg.lpFee != 0) poolManager.updateDynamicLPFee(key, cfg.lpFee);

        uint128 liquidity = FullRangeLiquidity.liquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING)),
            amount0,
            amount1
        );
        if (liquidity == 0) revert InvalidSeed();
        cfg.liquidity = liquidity;

        poolManager.unlock(abi.encode(Action.Seed, fund, liquidity));

        uint256 shareDust = IERC20(fund).balanceOf(address(this));
        if (shareDust != 0) IFund(fund).burn(shareDust);
        address usdg = factory.usdg();
        uint256 usdgDust = IERC20(usdg).balanceOf(address(this));
        if (usdgDust != 0) IERC20(usdg).safeTransfer(factory.protocolFeeRecipient(), usdgDust);

        emit PoolSeeded(fund, liquidity, usdgAmount - usdgDust, shareAmount - shareDust);
    }

    /// @inheritdoc IFundHook
    function poke(
        address fund
    ) external override {
        PoolId id = _keys[fund].toId();
        if (!_configs[id].seeded) revert NotRegistered();
        _observe(id);
    }

    /// @inheritdoc IFundHook
    function collectLpFees(
        address fund
    ) external override returns (uint256 amount0, uint256 amount1) {
        PoolKey memory key = _keys[fund];
        if (address(key.hooks) == address(0)) revert NotRegistered();
        if (!_configs[key.toId()].seeded) revert NotRegistered();
        address recipient = factory.lpFeeRecipient();
        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(Action.Collect, fund, recipient)), (uint256, uint256));
        emit LpFeesCollected(fund, recipient, amount0, amount1);
    }

    /// @inheritdoc IFundHook
    function setLpFee(
        address fund,
        uint24 lpFee
    ) external override {
        if (msg.sender != factory.owner()) revert NotAdmin();
        if (lpFee > MAX_LP_FEE) revert LpFeeTooHigh();
        PoolKey memory key = _keys[fund];
        if (address(key.hooks) == address(0)) revert NotRegistered();
        PoolConfig storage cfg = _configs[key.toId()];
        cfg.lpFee = lpFee;
        if (cfg.seeded) poolManager.updateDynamicLPFee(key, lpFee);
        emit LpFeeSet(fund, lpFee);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(
        bytes calldata data
    ) external override onlyPoolManager returns (bytes memory) {
        (Action action, address fund) = abi.decode(data, (Action, address));
        PoolKey memory key = _keys[fund];
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: 0,
            salt: bytes32(0)
        });

        if (action == Action.Seed) {
            (,, uint128 liquidity) = abi.decode(data, (Action, address, uint128));
            params.liquidityDelta = SafeCast.toInt256(uint256(liquidity));
            (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
            _settle(key.currency0, delta.amount0());
            _settle(key.currency1, delta.amount1());
            return "";
        }

        (,, address recipient) = abi.decode(data, (Action, address, address));
        (BalanceDelta fees,) = poolManager.modifyLiquidity(key, params, "");
        uint256 amount0 = _take(key.currency0, fees.amount0(), recipient);
        uint256 amount1 = _take(key.currency1, fees.amount1(), recipient);
        return abi.encode(amount0, amount1);
    }

    /// @inheritdoc IHooks
    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external pure override returns (bytes4) {
        // The pool manager skips this callback when the hook itself initialises, so any call here
        // is someone else trying to create a pool on this hook.
        revert InitializeNotAllowed();
    }

    /// @inheritdoc IHooks
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        _observe(id);
        PoolConfig memory cfg = _configs[id];
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIs0 != cfg.usdgIsCurrency0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _takeFees(key, cfg, amount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(SafeCast.toInt256(fee)), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolConfig memory cfg = _configs[key.toId()];
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIs0 == cfg.usdgIsCurrency0) return (IHooks.afterSwap.selector, 0);
        int128 usdgDelta = cfg.usdgIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 amount = usdgDelta < 0 ? uint256(-int256(usdgDelta)) : uint256(int256(usdgDelta));
        uint256 fee = _takeFees(key, cfg, amount);
        return (IHooks.afterSwap.selector, SafeCast.toInt128(SafeCast.toInt256(fee)));
    }

    /// @inheritdoc IHooks
    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IFundHook
    function consult(
        address fund,
        uint32 window
    ) external view override returns (bool ok, int24 meanTick, uint32 period) {
        PoolId id = _keys[fund].toId();
        if (!_configs[id].seeded || window == 0 || window > MAX_TWAP_WINDOW) return (false, 0, 0);
        uint32 nowTs = uint32(block.timestamp);
        if (nowTs <= window) return (false, 0, 0);
        uint32 target = nowTs - window;

        Twap storage twap = _twaps[id];
        Observation memory latest = twap.latest;
        (, int24 tick,,) = poolManager.getSlot0(id);
        int56 cumulativeNow = latest.tickCumulative + int56(tick) * int56(uint56(nowTs - latest.timestamp));

        Observation memory from = latest;
        if (from.timestamp > target) {
            uint256 index = twap.index;
            bool found;
            for (uint256 i; i < OBSERVATION_SLOTS; ++i) {
                from = twap.ring[index];
                if (from.timestamp == 0) break;
                if (from.timestamp <= target) {
                    found = true;
                    break;
                }
                index = index == 0 ? OBSERVATION_SLOTS - 1 : index - 1;
            }
            if (!found) return (false, 0, 0);
        }

        period = nowTs - from.timestamp;
        int56 delta = cumulativeNow - from.tickCumulative;
        int56 elapsed = int56(uint56(period));
        meanTick = int24(delta / elapsed);
        if (delta < 0 && delta % elapsed != 0) meanTick--;
        ok = true;
    }

    /// @inheritdoc IFundHook
    function maxTwapWindow() external pure override returns (uint32) {
        return MAX_TWAP_WINDOW;
    }

    /// @inheritdoc IFundHook
    function poolKeyOf(
        address fund
    ) external view override returns (PoolKey memory) {
        return _keys[fund];
    }

    /// @inheritdoc IFundHook
    function isSeeded(
        address fund
    ) external view override returns (bool) {
        return _configs[_keys[fund].toId()].seeded;
    }

    /// @inheritdoc IFundHook
    function lockedLiquidity(
        address fund
    ) external view override returns (uint128) {
        return _configs[_keys[fund].toId()].liquidity;
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

    function _observe(
        PoolId id
    ) private {
        Twap storage twap = _twaps[id];
        Observation memory latest = twap.latest;
        uint32 nowTs = uint32(block.timestamp);
        if (nowTs == latest.timestamp) return;
        (, int24 tick,,) = poolManager.getSlot0(id);
        latest = Observation({
            timestamp: nowTs,
            tickCumulative: latest.tickCumulative + int56(tick) * int56(uint56(nowTs - latest.timestamp))
        });
        twap.latest = latest;
        uint256 index = twap.index;
        if (nowTs - twap.ring[index].timestamp >= OBSERVATION_INTERVAL) {
            index = (index + 1) % OBSERVATION_SLOTS;
            twap.index = uint8(index);
            twap.ring[index] = latest;
        }
    }

    function _takeFees(
        PoolKey calldata key,
        PoolConfig memory cfg,
        uint256 amount
    ) private returns (uint256) {
        // Rounds down: a fee never exceeds the configured share of the USDG leg.
        uint256 protocolFee = Math.mulDiv(amount, factory.protocolFeeBps(), BPS);
        uint256 creatorFee = Math.mulDiv(amount, IFund(cfg.fund).creatorFeeBps(), BPS);
        Currency usdg = cfg.usdgIsCurrency0 ? key.currency0 : key.currency1;
        if (protocolFee != 0) poolManager.take(usdg, factory.protocolFeeRecipient(), protocolFee);
        if (creatorFee != 0) poolManager.take(usdg, IFund(cfg.fund).creatorFeeRecipient(), creatorFee);
        if (protocolFee != 0 || creatorFee != 0) emit SwapFeesTaken(cfg.fund, protocolFee, creatorFee);
        return protocolFee + creatorFee;
    }

    function _settle(
        Currency currency,
        int128 delta
    ) private {
        if (delta >= 0) return;
        uint256 amount = uint256(-int256(delta));
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(
        Currency currency,
        int128 delta,
        address recipient
    ) private returns (uint256 amount) {
        if (delta <= 0) return 0;
        amount = uint256(int256(delta));
        poolManager.take(currency, recipient, amount);
    }

    function _sqrtPriceX96(
        uint256 amount0,
        uint256 amount1
    ) private pure returns (uint160) {
        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) revert InvalidSeed();
        return uint160(sqrtPrice);
    }
}
