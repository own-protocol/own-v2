// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPositionManager} from "./external/IPositionManager.sol";
import {YieldPoint} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title IFundStaking — staked fund tokens (e.g. sOCF1) earning tiered yield, Premium Boosts and
///        the Premium Pot
/// @notice Stakers deposit fund tokens and receive vault shares. Three kinds of yield:
///
///         - Tier yield: the vault mints new fund tokens to itself at the yearly rate of the fund's
///           level, the highest tier point at or below the fund's premium over NAV (by default 12%
///           from NAV, 24% from 1.25x NAV, 48% from 2x NAV; nothing below NAV), so each share is
///           worth more fund tokens. The new tokens have no new backing: non-stakers are diluted,
///           which is the incentive to stake. Yield accrues before every stake and unstake, so late
///           stakers cannot capture it. Rates are capped by the factory's admin-set yield cap.
///         - Premium Pot: part of the premium the hook captures on pool buys is minted as fund
///           tokens at NAV and held here, then drips into the vault over the drip period (7 days
///           by default). Variable, never promised; with less than one whole share staked the drip
///           is burned into backing.
///         - Premium Boost: a direct mint ({IFund-mint}) is staked here for the minter, locked for the
///           fund's mint lock, and carries a personal boost: fund tokens (the boost share of the
///           premium it paid over NAV, in fund tokens at NAV) minted at once and held here, paid at a
///           fixed speed (a yearly rate on the payment in fund tokens at NAV) as new staked shares,
///           until none are left. Held boost tokens ride the fund's price like any other token. It
///           is settled lazily: on stake, unstake, redeem, transfer, a new direct mint, or
///           {settleBoost}. The boost belongs to the minter: shares that leave the account (unstaked,
///           redeemed or transferred; the governor excepted) scale it down, and the unpaid boost
///           tokens of what left are burned into backing. It never comes back.
///
///         The curators get a share of the stakers' yield minted on top of it (15% by default,
///         admin-set per fund, optionally capped at a yearly share of the staked balance), so
///         stakers keep the full rate. It is paid to the curators module as shares, so it stays
///         staked.
///
///         Shares staked from launch-locked fund tokens are locked the same way until the fund's
///         depositor unlock: they can be deposited in the governor (and come back to the same
///         account) or unstaked (the fund tokens come back locked), but not transferred.
///
///         LPs can stake their Uniswap v4 position NFT for a full-range position in the fund's
///         pool. It earns the same yearly rate on the fund tokens it holds (valued at the pool TWAP;
///         its USDG earns nothing), paid in fund tokens they claim. The position's swap fees stay
///         theirs: they can collect them while staked or after. Staked positions do not vote.
interface IFundStaking is IERC20, IERC721Receiver {
    /// @notice An account's lock on shares from direct mints or mints at NAV. Locked shares can be
    ///         redeemed (see {redeem}) or escrowed in the governor, but not transferred or unstaked.
    ///         A NAV mint lock never ends (`unlockAt` is the largest uint64), and covers the yield
    ///         its shares earn, so a mint at NAV only ever leaves at NAV.
    /// @param shares   Shares locked.
    /// @param unlockAt When the lock ends.
    struct MintLock {
        uint128 shares;
        uint64 unlockAt;
    }

    /// @notice An account's Premium Boost from direct mints.
    /// @param perSec     Payout speed, fund tokens a second (summed over its direct mints).
    /// @param left       Fund tokens still to pay, held here.
    /// @param shares     Shares carrying the boost; holding fewer scales it down.
    /// @param lastSettle Last settlement time.
    struct Boost {
        uint128 perSec;
        uint128 left;
        uint128 shares;
        uint64 lastSettle;
    }

    /// @notice Emitted on a stake.
    /// @param sender   Payer of the fund tokens.
    /// @param receiver Receiver of the shares.
    /// @param assets   Fund tokens staked.
    /// @param shares   Shares minted.
    event Staked(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted on an unstake.
    /// @param owner    Share owner.
    /// @param receiver Receiver of the fund tokens.
    /// @param assets   Fund tokens paid out.
    /// @param shares   Shares burned.
    event Unstaked(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    /// @notice Emitted when yield accrues.
    /// @param elapsed        Seconds covered.
    /// @param premiumBps     Premium read.
    /// @param ratePerYearWad Yearly rate applied (the lower of the rate read now and the one read at
    ///                       the last accrual), as a fraction of the staked balance (1e18 = 100%).
    /// @param minted         Fund tokens minted to the vault: the stakers' yield plus the curators' share.
    /// @param lpMinted       Fund tokens minted for staked LP positions.
    /// @param curatorShares  Shares minted to the curators module for their share.
    event YieldAccrued(
        uint256 elapsed,
        int256 premiumBps,
        uint256 ratePerYearWad,
        uint256 minted,
        uint256 lpMinted,
        uint256 curatorShares
    );

    /// @notice Emitted when the curators' share of staker yield changes.
    /// @param shareBps      Curators' yield as a share of the stakers' yield, in basis points.
    /// @param capBpsPerYear Cap, in basis points of the staked balance a year (0 for none).
    event CuratorYieldSet(uint16 shareBps, uint16 capBpsPerYear);

    /// @notice Emitted when an LP position is staked.
    /// @param owner     Owner credited with the position.
    /// @param tokenId   The position.
    /// @param liquidity Its liquidity.
    event PositionStaked(address indexed owner, uint256 indexed tokenId, uint128 liquidity);

    /// @notice Emitted when an LP position is unstaked.
    /// @param owner   Its owner.
    /// @param tokenId The position.
    /// @param to      Receiver of the position.
    event PositionUnstaked(address indexed owner, uint256 indexed tokenId, address to);

    /// @notice Emitted when a staked position's yield is paid.
    /// @param tokenId The position.
    /// @param to      Receiver.
    /// @param amount  Fund tokens paid.
    event PositionYieldClaimed(uint256 indexed tokenId, address indexed to, uint256 amount);

    /// @notice Emitted when a staked position's swap fees are collected.
    /// @param tokenId The position.
    /// @param to      Receiver.
    event PositionFeesCollected(uint256 indexed tokenId, address indexed to);

    /// @notice Emitted when an account's locked shares change.
    /// @param account The account.
    /// @param locked  Shares now locked.
    event LockedSharesSet(address indexed account, uint256 locked);

    /// @notice Emitted when an account's mint lock changes.
    /// @param account  The account.
    /// @param shares   Shares locked.
    /// @param unlockAt When the lock ends.
    /// @param atNav    Whether it is the NAV mint lock (else the direct mint lock).
    event MintLockSet(address indexed account, uint256 shares, uint64 unlockAt, bool atNav);

    /// @notice Emitted when a direct mint adds to an account's boost.
    /// @param account    The account.
    /// @param added      Fund tokens added.
    /// @param perSec     Payout speed now.
    /// @param left       Fund tokens left now.
    /// @param shares     Shares carrying the boost now.
    event BoostAdded(address indexed account, uint256 added, uint256 perSec, uint256 left, uint256 shares);

    /// @notice Emitted when an account's boost is paid.
    /// @param account The account.
    /// @param assets  Fund tokens paid into the vault.
    /// @param shares  Shares minted to the account.
    event BoostPaid(address indexed account, uint256 assets, uint256 shares);

    /// @notice Emitted when shares leaving an account scale its boost down.
    /// @param account   The account.
    /// @param forfeited Fund tokens burned into backing.
    /// @param left      Fund tokens left.
    event BoostForfeited(address indexed account, uint256 forfeited, uint256 left);

    /// @notice Emitted when the Premium Pot is topped up.
    /// @param tokens  Fund tokens added.
    /// @param potLeft Fund tokens left to drip.
    /// @param potEnd  When the drip ends.
    event PotAdded(uint256 tokens, uint256 potLeft, uint64 potEnd);

    /// @notice Emitted when the dripped pot is paid.
    /// @param tokens    Fund tokens released.
    /// @param toStakers Whether they went into the vault (else burned into backing).
    event PotReleased(uint256 tokens, bool toStakers);

    /// @notice Emitted when the boost and pot settings change.
    /// @param boostShareBps        Share of a direct mint's premium paid back as boost.
    /// @param boostSpeedBpsPerYear Boost speed, a yearly rate on the mint payment.
    /// @param potDripPeriod        Drip period of each pot top-up.
    event PremiumConfigSet(uint16 boostShareBps, uint32 boostSpeedBpsPerYear, uint32 potDripPeriod);

    /// @notice Emitted when the yield curve changes.
    /// @param curve New curve points.
    event YieldCurveSet(YieldPoint[] curve);

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Too many points, premiums not strictly ascending, or a rate above the factory's yield cap.
    error InvalidYieldCurve();

    /// @notice The curators' share of staker yield is above its cap.
    error InvalidCuratorYield();

    /// @notice Caller is not the fund's launch module.
    error NotLaunch();

    /// @notice Caller is not the fund.
    error NotFund();

    /// @notice A boost or pot setting is out of bounds.
    error InvalidPremiumConfig();

    /// @notice The transfer would move shares that are still locked, or would unstake them to
    ///         another account.
    error SharesLocked();

    /// @notice An ERC-721 arrived from a contract other than the PositionManager.
    error NotPositionManager();

    /// @notice The position is not in the fund's pool.
    error NotFundPosition();

    /// @notice The position is not full range.
    error NotFullRange();

    /// @notice Caller did not stake the position.
    error NotPositionOwner();

    /// @notice The position is staked, so it cannot be recovered.
    error PositionIsStaked();

    /// @notice Initialise a staking proxy. Called once by the factory. Boost and pot settings start
    ///         at the factory's defaults.
    /// @param fund_  The fund token.
    /// @param curve_ Yield tiers set by Own at launch (empty for the factory's default tiers).
    function initialize(address fund_, YieldPoint[] calldata curve_) external;

    /// @notice Hand a depositor their share of the stake the launch made at the close; every share
    ///         moved is locked until the depositor unlock. Launch only.
    /// @param to     The depositor.
    /// @param shares Shares moved from the launch.
    function transferLocked(address to, uint256 shares) external;

    /// @notice Stake fund tokens the fund just minted here for a direct mint or a mint at NAV: the
    ///         shares go to `account`, locked until `unlockAt` (one lock of each kind per account:
    ///         a mint during a running lock of its kind joins it, and the lock ends at the
    ///         share-weighted average of the two ends), and its boost grows by `boost`, paid at the
    ///         boost speed on `payment`. Settles the account's boost first. Fund only.
    /// @param account    The minter.
    /// @param assets     Fund tokens minted here to stake.
    /// @param payment    Value paid, in fund tokens at NAV.
    /// @param boost      Boost fund tokens the fund minted here on top of `assets`.
    /// @param unlockAt   When the lock ends (no lock if not in the future; the largest uint64 for
    ///                   a mint at NAV, which never unlocks).
    /// @param atNav      Whether this is a mint at NAV (its own lock).
    /// @return shares Shares minted to `account`.
    function stakeMinted(
        address account,
        uint256 assets,
        uint256 payment,
        uint256 boost,
        uint64 unlockAt,
        bool atNav
    ) external returns (uint256 shares);

    /// @notice Top up the Premium Pot with `tokens` the fund just minted here: everything not yet
    ///         dripped drips again over a full drip period from now. Fund only.
    /// @param tokens Fund tokens added.
    function addPot(
        uint256 tokens
    ) external;

    /// @notice Pay `account`'s boost owed up to now. Anyone can call.
    /// @param account The account.
    function settleBoost(
        address account
    ) external;

    /// @notice Redeem shares straight for the fund's basket at NAV (see {IFund-redeem}), also while
    ///         they are mint-locked or launch-locked. Settles the caller's boost first; the shares
    ///         redeemed scale it down.
    /// @param shares        Shares burned.
    /// @param receiver      Receiver of the basket assets and USDG.
    /// @param minAmountsOut Per-asset minimum, in the fund's asset order (empty to skip).
    /// @param minUsdgOut    Minimum USDG paid out.
    /// @return amounts    Amount of each asset paid out.
    /// @return usdgAmount USDG paid out.
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut
    ) external returns (uint256[] memory amounts, uint256 usdgAmount);

    /// @notice Set the boost and pot settings. Admin only. A new speed applies to later mints; a new
    ///         drip period to later pot top-ups.
    /// @param boostShareBps_        Share of a direct mint's premium paid back as boost (at most 100%).
    /// @param boostSpeedBpsPerYear_ Boost speed, a yearly rate on the mint payment (non-zero, at most
    ///                              1 000 000 bps).
    /// @param potDripPeriod_        Drip period (1 hour to 365 days).
    function setPremiumConfig(uint16 boostShareBps_, uint32 boostSpeedBpsPerYear_, uint32 potDripPeriod_) external;

    /// @notice `account`'s boost.
    /// @param account The account.
    /// @return The boost.
    function boostOf(
        address account
    ) external view returns (Boost memory);

    /// @notice `account`'s boost owed since its last settlement, in fund tokens.
    /// @param account The account.
    /// @return The fund tokens owed.
    function pendingBoost(
        address account
    ) external view returns (uint256);

    /// @notice `account`'s direct or NAV mint lock.
    /// @param account The account.
    /// @param atNav   The NAV mint lock (else the direct mint lock).
    /// @return The lock.
    function mintLockOf(address account, bool atNav) external view returns (MintLock memory);

    /// @notice Share of a direct mint's premium paid back as boost, in basis points.
    /// @return The share.
    function boostShareBps() external view returns (uint16);

    /// @notice Boost speed, a yearly rate on the mint payment, in basis points.
    /// @return The speed.
    function boostSpeedBpsPerYear() external view returns (uint32);

    /// @notice Drip period of each Premium Pot top-up, in seconds.
    /// @return The period.
    function potDripPeriod() external view returns (uint32);

    /// @notice Premium Pot fund tokens not yet dripped, as of the last checkpoint.
    /// @return The fund tokens.
    function potLeft() external view returns (uint128);

    /// @notice When the pot's current drip ends.
    /// @return The timestamp.
    function potEnd() external view returns (uint64);

    /// @notice Pot fund tokens dripped but not yet paid (paid at the next accrual).
    /// @return The fund tokens.
    function potPending() external view returns (uint256);

    /// @notice Shares of `account` that are still locked (meaningful only before the fund's
    ///         depositor unlock).
    /// @param account The account.
    /// @return The locked shares.
    function lockedShares(
        address account
    ) external view returns (uint256);

    /// @notice Stake fund tokens. Launch-locked tokens can be staked only for the caller (reverts
    ///         {SharesLocked} otherwise); their lock moves onto the shares.
    /// @param assets   Fund tokens.
    /// @param receiver Receiver of the shares.
    /// @return shares Shares minted.
    function stake(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Unstake shares for fund tokens. Launch-locked shares can be unstaked only to the
    ///         caller; mint-locked shares cannot be unstaked until their lock ends. Settles the
    ///         caller's boost first; the shares unstaked scale it down.
    /// @param shares   Shares burned.
    /// @param receiver Receiver of the fund tokens.
    /// @return assets Fund tokens paid out.
    function unstake(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Accrue yield up to now, at the lower of the rate read now and the rate read at the
    ///         last accrual. Without a fresh premium reading nothing is paid and the time waits for
    ///         the next one. Anyone can call; the keeper calls it hourly.
    /// @return minted Fund tokens minted for stakers (staked LP positions' yield is in the event).
    function accrue() external returns (uint256 minted);

    /// @notice Stake a full-range position in the fund's pool. The caller must own it and have
    ///         approved this contract; sending it with the PositionManager's `safeTransferFrom`
    ///         does the same in one step.
    /// @param tokenId The position.
    function stakePosition(
        uint256 tokenId
    ) external;

    /// @notice Return a staked position with its yield. Its swap fees stay on the position.
    /// @param tokenId The position.
    /// @param to      Receiver of the position and the yield.
    /// @return paid Fund tokens paid.
    function unstakePosition(uint256 tokenId, address to) external returns (uint256 paid);

    /// @notice Claim a staked position's yield.
    /// @param tokenId The position.
    /// @param to      Receiver.
    /// @return paid Fund tokens paid.
    function claimPositionYield(uint256 tokenId, address to) external returns (uint256 paid);

    /// @notice Collect a staked position's swap fees, in both currencies.
    /// @param tokenId The position.
    /// @param to      Receiver.
    function collectPositionFees(uint256 tokenId, address to) external;

    /// @notice Return a position NFT that reached this contract without being staked (for example
    ///         minted straight to it). Admin only.
    /// @param tokenId The position.
    /// @param to      Receiver.
    function recoverPosition(uint256 tokenId, address to) external;

    /// @notice The Uniswap v4 PositionManager whose positions can be staked.
    /// @return The PositionManager.
    function positionManager() external view returns (IPositionManager);

    /// @notice Liquidity of all staked positions.
    /// @return The liquidity.
    function lpLiquidity() external view returns (uint128);

    /// @notice A staked position.
    /// @param tokenId The position.
    /// @return owner     Who staked it (zero if not staked).
    /// @return liquidity Its liquidity.
    function positionOf(
        uint256 tokenId
    ) external view returns (address owner, uint128 liquidity);

    /// @notice A staked position's unclaimed yield (excluding unaccrued yield).
    /// @param tokenId The position.
    /// @return Fund tokens.
    function pendingPositionYield(
        uint256 tokenId
    ) external view returns (uint256);

    /// @notice Replace the yield tiers. Admin only.
    /// @param curve_ New tier points.
    function setYieldCurve(
        YieldPoint[] calldata curve_
    ) external;

    /// @notice Set the curators' yield, minted on top of the stakers' yield. Admin only; yield up to
    ///         now accrues first.
    /// @param shareBps      Curators' yield as a share of the stakers' yield, in basis points (at
    ///                      most 50%).
    /// @param capBpsPerYear Cap on it, in basis points of the staked balance a year (0 for none).
    function setCuratorYield(uint16 shareBps, uint16 capBpsPerYear) external;

    /// @notice The curators' yield as a share of the stakers' yield, in basis points.
    /// @return The share.
    function curatorYieldBps() external view returns (uint16);

    /// @notice Cap on the curators' share, in basis points of the staked balance a year (0 for none).
    /// @return The cap.
    function curatorYieldCapBps() external view returns (uint16);

    /// @notice The fund token.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice Fund tokens staked plus yield minted to the vault. Tokens sent to the vault directly
    ///         are not counted and earn nothing.
    /// @return The amount.
    function totalAssets() external view returns (uint256);

    /// @notice Last accrual time.
    /// @return Timestamp.
    function lastAccrual() external view returns (uint64);

    /// @notice Yield curve points.
    /// @return The points.
    function yieldCurve() external view returns (YieldPoint[] memory);

    /// @notice Yearly rate paid at a premium: the rate of the highest tier point at or below it
    ///         (zero below the first), after the factory's yield cap.
    /// @param premiumBps Premium over NAV, in basis points.
    /// @return Rate per year, as a fraction of the staked balance (1e18 = 100%).
    function rateForPremium(
        int256 premiumBps
    ) external view returns (uint256);

    /// @notice Shares for `assets` at the current exchange rate (excluding unaccrued yield).
    /// @param assets Fund tokens.
    /// @return Shares.
    function convertToShares(
        uint256 assets
    ) external view returns (uint256);

    /// @notice Shares counted as staked in weekly `epoch`: shares minted count from the next epoch,
    ///         shares burned leave at once.
    /// @param epoch The epoch.
    /// @return Staked shares.
    function totalSupplyAt(
        uint256 epoch
    ) external view returns (uint256);

    /// @notice Fund tokens for `shares` at the current exchange rate (excluding unaccrued yield).
    /// @param shares Shares.
    /// @return Fund tokens.
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256);
}
