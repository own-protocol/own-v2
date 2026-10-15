// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IssuanceConfig, PoolSettings} from "./types/FundTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title IFundVenue — where one fund trades
/// @notice One per fund, and the only contract that knows where the fund trades. Everything else
///         (the fund, staking, the app) reads the venue pointer, {poolKey}. Today the fund trades in
///         a Uniswap v4 pool on Hookr's shared hook, which Uniswap's routing allowlists, so the fund
///         token trades in the Uniswap app, wallets and aggregators from launch. The venue:
///         - opens the fund's pool, fund token against USDG, with the fund's own fees
///           ({PoolSettings}): a buy and a sell tax in USDG, the fund fee on swaps, paid straight to
///           the fund's curators module less Hookr's share, and an LP fee for everyone providing
///           liquidity. The fees are frozen for the life of the pool;
///         - holds the fund's own full-range position. The fund counts it as backing (at the fund
///           token's oracle price). It leaves the pool only through the fund's redeems (a pro-rata
///           slice) or an admin withdrawal, and both return it to the fund side: USDG to the fund or
///           the redeemer, fund tokens burned. Its LP fees go to the fund the same way;
///         - issues new fund tokens while the pool trades above NAV by more than the fund's issuance
///           start ({issue}): after buys move the price up, it mints fund tokens and sells them into
///           the pool, filling the share of the move that a density (a share of circulating supply
///           per doubling of price, stepping up with the premium) gives, within an hourly cap. The
///           USDG goes to the fund; the pot share of the premium over NAV is minted as fund tokens at
///           NAV for the fund's Premium Pot, the rest raises NAV;
///         - moves the fund to a new pool in one admin call ({migrate}).
interface IFundVenue {
    /// @notice Emitted when the fund's pool settings change (before the pool opens) or a pool opens.
    /// @param settings The settings.
    event PoolSettingsSet(PoolSettings settings);

    /// @notice Emitted when a pool opens with the fund's position in it.
    /// @param poolId    The pool.
    /// @param family    Its Hookr family.
    /// @param liquidity The fund's liquidity.
    /// @param usdg      USDG added.
    /// @param shares    Fund tokens added.
    event PoolOpened(bytes32 indexed poolId, bytes32 family, uint128 liquidity, uint256 usdg, uint256 shares);

    /// @notice Emitted when the fund moves to a new pool.
    /// @param fromPoolId The old pool, which keeps trading under its frozen rules.
    /// @param toPoolId   The new pool.
    event Migrated(bytes32 indexed fromPoolId, bytes32 indexed toPoolId);

    /// @notice Emitted when the admin adds to the fund's position after launch.
    /// @param liquidity Liquidity added.
    /// @param usdg      USDG added (from the fund).
    /// @param shares    Fund tokens minted into the position.
    event PositionIncreased(uint128 liquidity, uint256 usdg, uint256 shares);

    /// @notice Emitted when LP fees on the fund's position are collected.
    /// @param usdgAmount USDG sent to the fund.
    /// @param burned     Fund tokens burned.
    event LpFeesCollected(uint256 usdgAmount, uint256 burned);

    /// @notice Emitted when part of the fund's position leaves the pool.
    /// @param liquidity  Liquidity removed.
    /// @param usdgPaid   USDG paid to the redeemer (zero for an admin withdrawal).
    /// @param usdgToFund USDG sent to the fund.
    /// @param burned     Fund tokens burned.
    event PositionReduced(uint128 liquidity, uint256 usdgPaid, uint256 usdgToFund, uint256 burned);

    /// @notice Emitted when the venue issues fund tokens into the pool.
    /// @param usdgIn USDG the sale raised (after the pool's sell tax), sent to the fund.
    /// @param issued Fund tokens issued and sold.
    /// @param pot    Fund tokens minted for the Premium Pot.
    event Issued(uint256 usdgIn, uint256 issued, uint256 pot);

    /// @notice Emitted when the fund's issuance settings change.
    /// @param config The settings.
    event IssuanceSet(IssuanceConfig config);

    /// @notice Caller is not the pool manager.
    error NotPoolManager();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is not the fund's launch module.
    error NotLaunch();

    /// @notice Caller is not the fund.
    error NotFund();

    /// @notice The fund's pool is not open yet.
    error NotSeeded();

    /// @notice The fund's pool is already open.
    error AlreadySeeded();

    /// @notice The opening price is outside Uniswap's range, or an amount is zero.
    error InvalidSeed();

    /// @notice A pool setting is out of bounds.
    error InvalidSettings();

    /// @notice The pot share is above 100%, or the steps are too many, not ascending or too dense.
    error InvalidIssuance();

    /// @notice More liquidity than the fund's position holds.
    error InsufficientLiquidity();

    /// @notice The pool's spot price is too far from the fund token's oracle price to move the
    ///         position safely.
    error PriceOffReference();

    /// @notice Initialise the venue proxy. Called once by the factory at fund creation.
    /// @param fund     The fund.
    /// @param settings The fees the fund's pool opens with.
    function initialize(address fund, PoolSettings calldata settings) external;

    /// @notice Open the fund's pool with the launch tokens and USDG already sent here, priced at
    ///         their ratio, as the fund's full-range position. Launch only; `msg.value` is Hookr's
    ///         launch fee (zero today).
    /// @param usdgAmount  USDG for the pool.
    /// @param shareAmount Fund tokens for the pool.
    function seedPool(uint256 usdgAmount, uint256 shareAmount) external payable;

    /// @notice Issue fund tokens into the pool while it trades above the issuance start: mints and
    ///         sells them until the pool and the supply are where issuing the density along the
    ///         rise since the last issue (or since the start, if higher) would have left them,
    ///         within the hourly cap; what the cap cuts short stays due for the next call. Anyone
    ///         may call (a keeper does after buys); it never sells below that point or the start.
    /// @return issued Fund tokens issued.
    /// @return usdgIn USDG raised, sent to the fund.
    function issue() external returns (uint256 issued, uint256 usdgIn);

    /// @notice Collect the LP fees on the fund's position: USDG to the fund, fund tokens burned.
    ///         Anyone may call.
    /// @return usdgAmount USDG sent to the fund.
    /// @return burned     Fund tokens burned.
    function collectLpFees() external returns (uint256 usdgAmount, uint256 burned);

    /// @notice Pay the fund's share of the swap tax waiting in the pool's tax queues to the fund's
    ///         curators module. Anyone may call (also on the queues directly).
    /// @return paid USDG paid to the curators module.
    function collectTax() external returns (uint256 paid);

    /// @notice Pay a redeemer their share of the fund's position: removes `numerator/denominator`
    ///         of it, sends its USDG to `receiver` up to its value at the fund token's oracle price
    ///         (any excess to the fund) and burns its fund tokens. Fund only.
    /// @param numerator   Share of the position, numerator.
    /// @param denominator Share of the position, denominator.
    /// @param receiver    Receiver of the USDG.
    /// @return usdgPaid USDG paid to `receiver`.
    function redeemPosition(
        uint256 numerator,
        uint256 denominator,
        address receiver
    ) external returns (uint256 usdgPaid);

    /// @notice Add `usdgAmount` of USDG, already sent here by the fund, to the fund's position with
    ///         matching newly minted fund tokens, at a spot price within about 1% of the oracle
    ///         price. Fund only (its admin call).
    /// @param usdgAmount USDG to add.
    /// @return liquidity Liquidity added.
    function increasePosition(
        uint256 usdgAmount
    ) external returns (uint128 liquidity);

    /// @notice Remove `liquidity` from the fund's position: USDG to the fund, fund tokens burned.
    ///         Admin only.
    /// @param liquidity Liquidity to remove.
    function withdrawPosition(
        uint128 liquidity
    ) external;

    /// @notice Move the fund to a new pool with `settings`: removes the whole position, opens the
    ///         new pool at the old pool's spot price (within about 1% of the oracle price) with it,
    ///         and switches the venue pointer. The old pool keeps trading under its frozen rules, and
    ///         staked LP positions in it stop earning staking yield. Admin only; `msg.value` is
    ///         Hookr's launch fee (zero today).
    /// @param settings The new pool's fees; its tick spacing must differ from every earlier pool's.
    function migrate(
        PoolSettings calldata settings
    ) external payable;

    /// @notice Replace the settings the fund's pool will open with. Admin only, before the pool opens.
    /// @param settings The settings.
    function setPoolSettings(
        PoolSettings calldata settings
    ) external;

    /// @notice Replace the fund's issuance settings. Admin only.
    /// @param config The settings.
    function setIssuance(
        IssuanceConfig calldata config
    ) external;

    /// @notice The fund.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice The venue pointer: the pool the fund trades in now (zero before it opens).
    /// @return The pool key.
    function poolKey() external view returns (PoolKey memory);

    /// @notice The current pool's fees.
    /// @return The settings.
    function poolSettings() external view returns (PoolSettings memory);

    /// @notice The current pool's Hookr family, which holds the fund's position.
    /// @return The family id.
    function family() external view returns (bytes32);

    /// @notice The current pool's buy and sell tax queues.
    /// @return buyQueue  The buy tax queue (zero without a buy tax).
    /// @return sellQueue The sell tax queue (zero without a sell tax).
    function taxQueues() external view returns (address buyQueue, address sellQueue);

    /// @notice Whether the fund's pool is open.
    /// @return True once seeded.
    function isSeeded() external view returns (bool);

    /// @notice The fund's liquidity in the current pool.
    /// @return The liquidity.
    function positionLiquidity() external view returns (uint128);

    /// @notice USDG and fund tokens in the fund's position, at the fund token's oracle price.
    /// @return usdgAmount USDG.
    /// @return fundTokens Fund tokens.
    function positionAmounts() external view returns (uint256 usdgAmount, uint256 fundTokens);

    /// @notice The fund's position read at both the oracle price and the spot price, each amount at
    ///         whichever reading is higher (`high`) or lower, so a move of either alone never favours
    ///         a mint or a redeem.
    /// @param high Whether to take the higher amounts.
    /// @return usdgAmount USDG.
    /// @return fundTokens Fund tokens.
    function positionBounds(
        bool high
    ) external view returns (uint256 usdgAmount, uint256 fundTokens);

    /// @notice USDG and fund tokens a full-range position of `liquidity` in the current pool holds, at
    ///         the fund token's oracle price.
    /// @param liquidity The liquidity.
    /// @return usdgAmount USDG.
    /// @return fundTokens Fund tokens.
    function liquidityAmounts(
        uint128 liquidity
    ) external view returns (uint256 usdgAmount, uint256 fundTokens);

    /// @notice The current pool's spot price, USD per fund token (18 decimals, USDG at $1); zero
    ///         before the pool opens.
    /// @return The price.
    function spotPrice() external view returns (uint256);

    /// @notice The fund's issuance settings.
    /// @return The settings.
    function issuanceOf() external view returns (IssuanceConfig memory);
}
