// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPositionManager} from "./external/IPositionManager.sol";
import {YieldPoint} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title IFundStaking — staked fund tokens (e.g. sOCF1) earning premium-based yield
/// @notice Stakers deposit fund tokens and receive vault shares. The vault mints new fund tokens to
///         itself at the rate the yield curve gives for the fund's premium over NAV, so each share
///         is worth more fund tokens; nothing below the curve's first point. The new tokens have no
///         new backing: non-stakers are diluted, which is the incentive to stake.
///         Yield accrues before every stake and unstake, so late stakers cannot capture it. The
///         curve is a set of (premium, yearly rate) points interpolated linearly, so the admin can
///         shape it, for example paying a base rate at NAV and peaking mid-premium. Rates are
///         capped by the factory's admin-set yield cap (109 500 bps a year, 3% a day, by default).
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
    /// @param ratePerYearWad Yearly rate applied, as a fraction of the staked balance (1e18 = 100%).
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

    /// @notice Initialise a staking proxy. Called once by the factory.
    /// @param fund_  The fund token.
    /// @param curve_ Yield curve set by Own at launch.
    function initialize(address fund_, YieldPoint[] calldata curve_) external;

    /// @notice Hand a depositor their share of the stake the launch made at the close; every share
    ///         moved is locked until the depositor unlock. Launch only.
    /// @param to     The depositor.
    /// @param shares Shares moved from the launch.
    function transferLocked(address to, uint256 shares) external;

    /// @notice Shares of `account` that are still locked (meaningful only before the fund's
    ///         depositor unlock).
    /// @param account The account.
    /// @return The locked shares.
    function lockedShares(
        address account
    ) external view returns (uint256);

    /// @notice Stake fund tokens.
    /// @param assets   Fund tokens.
    /// @param receiver Receiver of the shares.
    /// @return shares Shares minted.
    function stake(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Unstake shares for fund tokens. Locked shares can be unstaked only to the caller.
    /// @param shares   Shares burned.
    /// @param receiver Receiver of the fund tokens.
    /// @return assets Fund tokens paid out.
    function unstake(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Accrue yield up to now. Anyone can call; keepers call it every epoch.
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

    /// @notice Replace the yield curve. Admin only.
    /// @param curve_ New curve points.
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

    /// @notice Yearly rate paid at a premium: the curve interpolated linearly between its points,
    ///         after the factory's yield cap.
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
