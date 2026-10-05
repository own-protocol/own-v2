// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldPoint} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFundStaking — staked fund tokens (e.g. sOCF1) earning premium-based yield
/// @notice Stakers deposit fund tokens and receive vault shares. While the fund trades at a premium
///         to NAV, the vault mints new fund tokens to itself at the rate the yield curve gives for
///         that premium, so each share is worth more fund tokens. No premium, no yield. The new
///         tokens have no new backing: non-stakers are diluted, which is the incentive to stake.
///         Yield accrues before every stake and unstake, so late stakers cannot capture it. The
///         curve is a set of (premium, daily rate) points interpolated linearly, so the admin can
///         shape it as a hump that peaks mid-premium and falls towards the mint ceiling. Rates are
///         capped by the factory's admin-set yield cap (3% a day by default).
///
///         Shares staked from launch-locked fund tokens are locked the same way until the fund's
///         depositor unlock: they can be deposited in the governor (and come back to the same
///         account) or unstaked (the fund tokens come back locked), but not transferred.
interface IFundStaking is IERC20 {
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
    /// @param ratePerDayWad  Daily rate applied, as a fraction of the staked balance (1e18 = 100%).
    /// @param minted         Fund tokens minted to the vault.
    event YieldAccrued(uint256 elapsed, int256 premiumBps, uint256 ratePerDayWad, uint256 minted);

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

    /// @notice Caller is not the fund's launch module.
    error NotLaunch();

    /// @notice The transfer would move shares that are still locked, or would unstake them to
    ///         another account.
    error SharesLocked();

    /// @notice Initialise a staking proxy. Called once by the factory.
    /// @param fund_  The fund token.
    /// @param curve_ Yield curve set by Own at launch.
    function initialize(address fund_, YieldPoint[] calldata curve_) external;

    /// @notice Stake fund tokens the launch is releasing to a depositor; every share minted is
    ///         locked until the depositor unlock. Launch only.
    /// @param assets   Fund tokens staked (pulled from the launch).
    /// @param receiver Receiver of the shares.
    /// @return shares Shares minted.
    function stakeLocked(uint256 assets, address receiver) external returns (uint256 shares);

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
    /// @return minted Fund tokens minted.
    function accrue() external returns (uint256 minted);

    /// @notice Replace the yield curve. Admin only.
    /// @param curve_ New curve points.
    function setYieldCurve(
        YieldPoint[] calldata curve_
    ) external;

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

    /// @notice Daily rate paid at a premium: the curve interpolated linearly between its points,
    ///         after the factory's yield cap.
    /// @param premiumBps Premium over NAV, in basis points.
    /// @return Rate per day, as a fraction of the staked balance (1e18 = 100%).
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
