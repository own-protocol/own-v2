// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldTier} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFundStaking — staked fund tokens (e.g. sMF1) earning premium-tiered yield
/// @notice Stakers deposit fund tokens and receive vault shares. While the fund trades at a premium
///         to NAV, the vault mints new fund tokens to itself at the rate of the highest tier the
///         premium reaches, so each share is worth more fund tokens. No premium, no yield. The new
///         tokens have no new backing: non-stakers are diluted, which is the incentive to stake.
///         Yield accrues before every stake and unstake, so late stakers cannot capture it. Tier
///         rates are daily and capped by the factory's admin-set yield cap (3% a day by default).
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
    /// @param rateBpsPerDay  Daily rate applied.
    /// @param minted         Fund tokens minted to the vault.
    event YieldAccrued(uint256 elapsed, int256 premiumBps, uint256 rateBpsPerDay, uint256 minted);

    /// @notice Emitted when the yield tiers change.
    /// @param tiers New tiers.
    event YieldTiersSet(YieldTier[] tiers);

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Tiers are not ascending, or a rate exceeds the factory's yield cap.
    error InvalidTiers();

    /// @notice Initialise a staking proxy. Called once by the factory.
    /// @param fund_  The fund token.
    /// @param tiers_ Yield tiers chosen by the creator.
    function initialize(
        address fund_,
        YieldTier[] calldata tiers_
    ) external;

    /// @notice Stake fund tokens.
    /// @param assets   Fund tokens.
    /// @param receiver Receiver of the shares.
    /// @return shares Shares minted.
    function stake(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Unstake shares for fund tokens.
    /// @param shares   Shares burned.
    /// @param receiver Receiver of the fund tokens.
    /// @return assets Fund tokens paid out.
    function unstake(
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);

    /// @notice Accrue yield up to now. Anyone can call; keepers call it every epoch.
    /// @return minted Fund tokens minted.
    function accrue() external returns (uint256 minted);

    /// @notice Replace the yield tiers. Admin only (creators set them once, at launch).
    /// @param tiers_ New tiers.
    function setYieldTiers(
        YieldTier[] calldata tiers_
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

    /// @notice Yield tiers.
    /// @return The tiers.
    function yieldTiers() external view returns (YieldTier[] memory);

    /// @notice Daily rate paid at a premium, after the factory's yield cap.
    /// @param premiumBps Premium over NAV, in basis points.
    /// @return Rate, in basis points per day.
    function rateForPremium(
        int256 premiumBps
    ) external view returns (uint256);

    /// @notice Shares for `assets` at the current exchange rate (excluding unaccrued yield).
    /// @param assets Fund tokens.
    /// @return Shares.
    function convertToShares(
        uint256 assets
    ) external view returns (uint256);

    /// @notice Fund tokens for `shares` at the current exchange rate (excluding unaccrued yield).
    /// @param shares Shares.
    /// @return Fund tokens.
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256);
}
