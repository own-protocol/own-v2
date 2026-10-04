// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchConfig} from "./types/FundTypes.sol";

/// @title IFundLaunch — the deposit window that starts a fund
/// @notice For the fund's window (7 days by default), anyone deposits any basket asset plus USDG
///         worth `usdgRatioBps` of the asset's value. Deposits can be withdrawn until
///         `withdrawCutoff` before the close; after that they are final.
///
///         - Early-deposit yield: each deposit earns `earlyYieldBpsPerDay` of its value per day it
///           sits in the window, paid as extra launch tokens out of the fixed supply. Withdrawing
///           forfeits it on the amount withdrawn.
///         - At the close assets are valued at closing oracle prices: basket value R, USDG U. Below
///           the minimum raise the launch fails at once and everyone is refunded.
///         - Overweight haircut: an asset's value above its target weight of R is credited at
///           `1 - overweightHaircutBps`, shared by that asset's depositors; the tokens held back go
///           to the other depositors.
///         - The fixed supply S is split so the pool opens at `launchPremiumBps` over NAV: the
///           fund's pool position gets M fund tokens plus all of U, and depositors share S - M in
///           proportion to their credited value plus early yield. The fund owns the position and
///           counts its USDG as backing, so NAV = (R + U) / (S - M) and depositors get exactly what
///           they brought at NAV.
///         - Depositors' tokens stay non-transferable for `depositorLock` after launch; they can be
///           staked (here or later) and redeemed meanwhile.
interface IFundLaunch {
    /// @notice Launch lifecycle.
    enum Status {
        Open,
        Succeeded,
        Failed
    }

    /// @notice One account's deposits of one asset.
    /// @param amount     Asset amount.
    /// @param usdg       USDG paid with it.
    /// @param timeWeight Sum of amount × seconds left in the window at each deposit.
    struct Deposit {
        uint256 amount;
        uint256 usdg;
        uint256 timeWeight;
    }

    /// @notice Emitted on a deposit.
    /// @param account Depositor.
    /// @param asset   Basket asset.
    /// @param amount  Asset amount received.
    /// @param usdg    USDG received with it.
    event Deposited(address indexed account, address indexed asset, uint256 amount, uint256 usdg);

    /// @notice Emitted on a withdrawal.
    /// @param account Depositor.
    /// @param asset   Basket asset.
    /// @param amount  Asset amount returned.
    /// @param usdg    USDG returned with it.
    event Withdrawn(address indexed account, address indexed asset, uint256 amount, uint256 usdg);

    /// @notice Emitted when the launch succeeds.
    /// @param basketValue     Basket value at closing prices, 18 decimals USD.
    /// @param usdgValue       USDG raised, 18 decimals USD.
    /// @param depositorShares Fund tokens allocated to depositors.
    /// @param poolShares      Fund tokens in the fund's pool position.
    event LaunchSucceeded(uint256 basketValue, uint256 usdgValue, uint256 depositorShares, uint256 poolShares);

    /// @notice Emitted when the launch fails.
    /// @param basketValue Basket value at closing prices (zero when marked failed after the grace period).
    event LaunchFailed(uint256 basketValue);

    /// @notice Emitted when a depositor claims fund tokens.
    /// @param account Depositor.
    /// @param shares  Fund tokens.
    /// @param staked  Whether they were staked on the depositor's behalf.
    event Claimed(address indexed account, uint256 shares, bool staked);

    /// @notice Emitted when a depositor is refunded.
    /// @param account Depositor.
    event Refunded(address indexed account);

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice The window is closed.
    error WindowClosed();

    /// @notice The window is still open.
    error WindowOpen();

    /// @notice Deposits can no longer be withdrawn.
    error WithdrawalsClosed();

    /// @notice More than the account deposited.
    error InsufficientDeposit();

    /// @notice The launch is not in the required status.
    error WrongStatus();

    /// @notice The finalization deadline passed; mark the launch failed instead.
    error FinalizeDeadlinePassed();

    /// @notice The finalization deadline has not passed yet.
    error FinalizeDeadlineNotPassed();

    /// @notice The asset is not a mintable basket asset.
    /// @param asset The asset.
    error AssetNotAccepted(address asset);

    /// @notice Nothing to claim or refund.
    error NothingToClaim();

    /// @notice Deposits are paused.
    error DepositsPaused();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Initialise a launch proxy. Called once by the factory.
    /// @param fund_         The fund.
    /// @param minRaiseUsd_  Minimum basket value to raise, 18 decimals USD.
    /// @param launchSupply_ Fixed fund token supply created at launch.
    /// @param config_       Launch rules (with this fund's duration).
    function initialize(
        address fund_,
        uint256 minRaiseUsd_,
        uint256 launchSupply_,
        LaunchConfig calldata config_
    ) external;

    /// @notice Deposit a basket asset plus its USDG during the window.
    /// @param asset  Basket asset (target weight above zero).
    /// @param amount Amount.
    /// @return usdgPaid USDG pulled with it (rounded up).
    function deposit(
        address asset,
        uint256 amount
    ) external returns (uint256 usdgPaid);

    /// @notice Withdraw part of a deposit (and its USDG) until the withdrawal cutoff. The amount
    ///         withdrawn forfeits its early-deposit yield.
    /// @param asset  Basket asset.
    /// @param amount Amount.
    /// @return usdgReturned USDG returned with it.
    function withdraw(
        address asset,
        uint256 amount
    ) external returns (uint256 usdgReturned);

    /// @notice Close the launch after the window: succeed and seed the pool, or fail. Anyone.
    ///         The keeper should call it right at the close.
    function finalize() external;

    /// @notice Mark the launch failed when nobody finalized it in time. Anyone.
    function markFailed() external;

    /// @notice Claim the caller's fund tokens after a successful launch, optionally staked.
    /// @param stake Whether to stake them on the caller's behalf.
    /// @return shares Fund tokens claimed.
    function claim(
        bool stake
    ) external returns (uint256 shares);

    /// @notice Take back the caller's deposits after a failed launch.
    function refund() external;

    /// @notice Pause or unpause deposits. Admin only.
    /// @param paused Whether paused.
    function setDepositsPaused(
        bool paused
    ) external;

    /// @notice The fund.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice Current status.
    /// @return The status.
    function status() external view returns (Status);

    /// @notice Window start.
    /// @return The timestamp.
    function startTime() external view returns (uint64);

    /// @notice Window end.
    /// @return The timestamp.
    function endTime() external view returns (uint64);

    /// @notice Last moment deposits can be withdrawn.
    /// @return The timestamp.
    function withdrawDeadline() external view returns (uint64);

    /// @notice Last moment the launch can be finalized.
    /// @return The timestamp.
    function finalizeDeadline() external view returns (uint64);

    /// @notice Minimum basket value to raise, 18 decimals USD.
    /// @return The minimum.
    function minRaiseUsd() external view returns (uint256);

    /// @notice Fixed fund token supply created at launch.
    /// @return The supply.
    function launchSupply() external view returns (uint256);

    /// @notice Total USDG deposited.
    /// @return The amount.
    function totalUsdg() external view returns (uint256);

    /// @notice Fund tokens allocated to depositors (set at success).
    /// @return The amount.
    function depositorSupply() external view returns (uint256);

    /// @notice Launch rules.
    /// @return The rules.
    function config() external view returns (LaunchConfig memory);

    /// @notice Assets accepted at launch (the basket at creation).
    /// @return The assets.
    function launchAssets() external view returns (address[] memory);

    /// @notice An account's deposits of an asset.
    /// @param account The account.
    /// @param asset   The asset.
    /// @return The deposit.
    function depositOf(
        address account,
        address asset
    ) external view returns (Deposit memory);

    /// @notice Total deposited of an asset.
    /// @param asset The asset.
    /// @return The amount.
    function totalDeposited(
        address asset
    ) external view returns (uint256);

    /// @notice Closing price of an asset (set at finalization).
    /// @param asset The asset.
    /// @return 18-decimal USD price.
    function closePrice(
        address asset
    ) external view returns (uint256);

    /// @notice Whether the account has claimed or been refunded.
    /// @param account The account.
    /// @return True once settled.
    function settled(
        address account
    ) external view returns (bool);

    /// @notice Live value deposited per launch asset and its target weight, for showing which
    ///         assets are above target. Values use current oracle prices (zero when unavailable).
    /// @return assets     Launch assets.
    /// @return values     Value deposited per asset, 18 decimals USD.
    /// @return weightsBps Target weight per asset.
    function depositValues()
        external
        view
        returns (address[] memory assets, uint256[] memory values, uint16[] memory weightsBps);

    /// @notice Fund tokens the account can claim (zero unless the launch succeeded).
    /// @param account The account.
    /// @return shares Fund tokens.
    function claimable(
        address account
    ) external view returns (uint256 shares);
}
