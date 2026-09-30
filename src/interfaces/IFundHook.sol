// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title IFundHook — Uniswap v4 hook for every fund's USDG pool
/// @notice One hook serves all funds. Each fund gets one dynamic-fee pool against USDG that only
///         this hook can initialise. The hook:
///         - takes the protocol fee and the fund's creator fee in USDG on every swap, on top of the
///           pool's LP fee, and sends them straight to their recipients;
///         - owns each pool's launch liquidity as a full-range position with no removal path, so it
///           is locked forever (LP fees on it can still be collected to the LP fee recipient);
///         - lets the platform admin set each pool's LP fee;
///         - records a tick accumulator before every swap, so each pool's time-weighted average
///           price can be read onchain without a keeper ({consult}).
interface IFundHook {
    /// @notice Emitted when a fund's pool is registered.
    /// @param fund   The fund.
    /// @param poolId The pool id.
    event FundRegistered(address indexed fund, bytes32 indexed poolId);

    /// @notice Emitted when a fund's pool is created and seeded.
    /// @param fund      The fund.
    /// @param liquidity Liquidity locked.
    /// @param usdg      USDG added.
    /// @param shares    Fund tokens added.
    event PoolSeeded(address indexed fund, uint128 liquidity, uint256 usdg, uint256 shares);

    /// @notice Emitted when USDG fees are taken on a swap.
    /// @param fund        The fund.
    /// @param protocolFee USDG to the protocol fee recipient.
    /// @param creatorFee  USDG to the creator fee recipient.
    event SwapFeesTaken(address indexed fund, uint256 protocolFee, uint256 creatorFee);

    /// @notice Emitted when LP fees are collected from a locked position.
    /// @param fund      The fund.
    /// @param recipient Recipient.
    /// @param amount0   Currency0 collected.
    /// @param amount1   Currency1 collected.
    event LpFeesCollected(address indexed fund, address recipient, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a pool's LP fee changes.
    /// @param fund  The fund.
    /// @param lpFee LP fee, in hundredths of a basis point.
    event LpFeeSet(address indexed fund, uint24 lpFee);

    /// @notice Caller is not the pool manager.
    error NotPoolManager();

    /// @notice Caller is not the factory.
    error NotFactory();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is not the fund's launch.
    error NotLaunch();

    /// @notice Pools using this hook can only be initialised by the hook.
    error InitializeNotAllowed();

    /// @notice The fund is already registered.
    error AlreadyRegistered();

    /// @notice The fund is not registered.
    error NotRegistered();

    /// @notice The pool was already seeded.
    error AlreadySeeded();

    /// @notice The launch price is outside Uniswap's range, or an amount is zero.
    error InvalidSeed();

    /// @notice The LP fee is above its cap.
    error LpFeeTooHigh();

    /// @notice A hook entry point this hook does not enable was called.
    error HookNotImplemented();

    /// @notice Record the pool's current price in its TWAP accumulator. Anyone can call; swaps do
    ///         it automatically, so this only keeps checkpoints regular while trading is quiet.
    /// @param fund The fund.
    function poke(
        address fund
    ) external;

    /// @notice Register a fund's pool. Factory only.
    /// @param fund The fund.
    function registerFund(
        address fund
    ) external;

    /// @notice Initialise the fund's pool at `usdgAmount / shareAmount` and lock both amounts as
    ///         full-range liquidity. The fund's launch only, once; the tokens must already be held
    ///         by the hook. Dust left over is burned (fund tokens) or sent to the protocol fee
    ///         recipient (USDG).
    /// @param fund        The fund.
    /// @param usdgAmount  USDG to add.
    /// @param shareAmount Fund tokens to add.
    function seedPool(
        address fund,
        uint256 usdgAmount,
        uint256 shareAmount
    ) external;

    /// @notice Collect LP fees earned by a fund's locked position to the LP fee recipient. Anyone
    ///         can call.
    /// @param fund The fund.
    /// @return amount0 Currency0 collected.
    /// @return amount1 Currency1 collected.
    function collectLpFees(
        address fund
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Set a fund pool's LP fee. Admin only.
    /// @param fund  The fund.
    /// @param lpFee LP fee, in hundredths of a basis point (capped).
    function setLpFee(
        address fund,
        uint24 lpFee
    ) external;

    /// @notice Time-weighted mean tick of the fund's pool over at least the last `window` seconds.
    ///         The measured period starts at the newest checkpoint at least `window` old, so it can
    ///         run longer than `window` when trading is quiet.
    /// @param fund   The fund.
    /// @param window Minimum period, in seconds (up to {maxTwapWindow}).
    /// @return ok       False if the pool is not seeded, the window is out of range, or there is
    ///                  not yet enough history.
    /// @return meanTick Arithmetic mean tick, rounded towards negative infinity.
    /// @return period   Seconds actually measured.
    function consult(
        address fund,
        uint32 window
    ) external view returns (bool ok, int24 meanTick, uint32 period);

    /// @notice Longest window {consult} serves, in seconds.
    /// @return The window.
    function maxTwapWindow() external view returns (uint32);

    /// @notice The Uniswap v4 pool manager.
    /// @return The pool manager.
    function poolManager() external view returns (IPoolManager);

    /// @notice The fund's pool key.
    /// @param fund The fund.
    /// @return The key.
    function poolKeyOf(
        address fund
    ) external view returns (PoolKey memory);

    /// @notice Whether the fund's pool has been seeded.
    /// @param fund The fund.
    /// @return True once seeded.
    function isSeeded(
        address fund
    ) external view returns (bool);

    /// @notice Liquidity locked in the fund's pool.
    /// @param fund The fund.
    /// @return The liquidity.
    function lockedLiquidity(
        address fund
    ) external view returns (uint128);
}
