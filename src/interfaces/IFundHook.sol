// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title IFundHook — Uniswap v4 hook for every fund's USDG pool
/// @notice One hook serves all funds. Each fund gets one dynamic-fee pool against USDG that only
///         this hook can initialise. The hook:
///         - takes the protocol fee and the fund's curator fee in USDG on every swap, on top of the
///           pool's LP fee, and sends them straight to their recipients;
///         - holds each fund's launch liquidity as a full-range position on the fund's behalf. The
///           fund counts it as backing (at the pool TWAP). It leaves the pool only through the
///           fund's redeems (a pro-rata slice) or an admin withdrawal, and both return it to the
///           fund side: USDG to the fund or the redeemer, fund tokens burned. LP fees it earns go
///           to the fund the same way. Outside LPs can add their own positions; only the fund's
///           counts;
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
    /// @param curatorFee  USDG to the curators module.
    event SwapFeesTaken(address indexed fund, uint256 protocolFee, uint256 curatorFee);

    /// @notice Emitted when LP fees on the fund's position are collected.
    /// @param fund       The fund.
    /// @param usdgAmount USDG sent to the fund.
    /// @param burned     Fund tokens burned.
    event LpFeesCollected(address indexed fund, uint256 usdgAmount, uint256 burned);

    /// @notice Emitted when part of the fund's position leaves the pool.
    /// @param fund        The fund.
    /// @param liquidity   Liquidity removed.
    /// @param usdgPaid    USDG paid to the redeemer (zero for an admin withdrawal).
    /// @param usdgToFund  USDG sent to the fund.
    /// @param burned      Fund tokens burned.
    event PositionReduced(
        address indexed fund, uint128 liquidity, uint256 usdgPaid, uint256 usdgToFund, uint256 burned
    );

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

    /// @notice Caller is not the launch module.
    error NotLaunch();

    /// @notice Caller is not the fund.
    error NotFund();

    /// @notice More liquidity than the fund's position holds.
    error InsufficientLiquidity();

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

    /// @notice Initialise the fund's pool at `usdgAmount / shareAmount` and add both amounts as
    ///         the fund's full-range position. The fund's launch only, once; the tokens must already be held
    ///         by the hook. Dust left over is burned (fund tokens) or sent to the fund (USDG).
    /// @param fund        The fund.
    /// @param usdgAmount  USDG to add.
    /// @param shareAmount Fund tokens to add.
    function seedPool(address fund, uint256 usdgAmount, uint256 shareAmount) external;

    /// @notice Collect LP fees earned by the fund's position: USDG to the fund, fund tokens burned.
    ///         Anyone can call.
    /// @param fund The fund.
    /// @return usdgAmount USDG sent to the fund.
    /// @return burned     Fund tokens burned.
    function collectLpFees(
        address fund
    ) external returns (uint256 usdgAmount, uint256 burned);

    /// @notice Remove `numerator / denominator` of the fund's position for a redeem. The fund
    ///         only. The fund tokens removed are burned; the redeemer gets the USDG removed, capped
    ///         at that slice's USDG at the pool TWAP, and any excess (and any LP fees the removal
    ///         collects) goes to the fund.
    /// @param numerator   Share of the position, numerator.
    /// @param denominator Share of the position, denominator.
    /// @param receiver    Receiver of the USDG.
    /// @return usdgPaid USDG paid to `receiver`.
    function redeemPosition(
        uint256 numerator,
        uint256 denominator,
        address receiver
    ) external returns (uint256 usdgPaid);

    /// @notice Withdraw `liquidity` of the fund's position out of the pool, in rare cases. Admin
    ///         only. The USDG goes to the fund and the fund tokens are burned; nothing goes to a
    ///         wallet.
    /// @param fund      The fund.
    /// @param liquidity Liquidity to remove.
    function withdrawPosition(address fund, uint128 liquidity) external;

    /// @notice Set a fund pool's LP fee. Admin only.
    /// @param fund  The fund.
    /// @param lpFee LP fee, in hundredths of a basis point (capped).
    function setLpFee(address fund, uint24 lpFee) external;

    /// @notice Time-weighted mean tick of the fund's pool over at least the last `window` seconds.
    ///         The measured period starts at the newest checkpoint at least `window` old, so it can
    ///         run longer than `window` when trading is quiet.
    /// @param fund   The fund.
    /// @param window Minimum period, in seconds (up to {maxTwapWindow}).
    /// @return ok       False if the pool is not seeded, the window is out of range, or there is
    ///                  not yet enough history.
    /// @return meanTick Arithmetic mean tick, rounded towards negative infinity.
    /// @return period   Seconds actually measured.
    function consult(address fund, uint32 window) external view returns (bool ok, int24 meanTick, uint32 period);

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

    /// @notice Liquidity in the fund's own position.
    /// @param fund The fund.
    /// @return The liquidity.
    function positionLiquidity(
        address fund
    ) external view returns (uint128);

    /// @notice The fund's position valued at the pool TWAP (a 30-minute window, or the history
    ///         there is right after seeding, or the price at the start of the block in the seeding
    ///         block). Zero before seeding.
    /// @param fund The fund.
    /// @return usdgAmount USDG in the position.
    /// @return fundTokens Fund tokens in the position.
    function positionAmounts(
        address fund
    ) external view returns (uint256 usdgAmount, uint256 fundTokens);
}
