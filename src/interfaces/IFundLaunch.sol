// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchConfig} from "./types/FundTypes.sol";

/// @title IFundLaunch — the deposit window that starts a fund
/// @notice For the fund's window (7 days by default), anyone deposits any basket asset or USDG.
///         Deposits are final.
///
///         - Early-deposit yield: each deposit earns `earlyYieldBpsPerDay` of its value per day it
///           sits in the window, paid as extra launch tokens out of the fixed supply.
///         - Close: at the end of the window, or as soon as the deposits are worth the fund's target
///           raise. Assets are valued at closing oracle prices and USDG at $1, raise V. Below the
///           minimum raise the launch fails at once and everyone is refunded.
///         - Overweight haircut: value above an asset's target share of V is credited at
///           `1 - overweightHaircutBps`, shared by that asset's depositors; the tokens held back go
///           to the other depositors. USDG's target share is `poolUsdgBps`, the basket's the rest.
///         - Pool: P = `poolUsdgBps` of V seeds the pool. The fixed supply S is split so the pool
///           opens at `launchPremiumBps` over NAV: the pool gets M fund tokens and depositors share
///           S - M in proportion to their credited value plus early yield. The fund owns the
///           position and counts its USDG as backing, so NAV = V / (S - M) and depositors get
///           exactly what they brought at NAV.
///         - At the close everything moves to the fund and depositors can claim. The manager then
///           rebalances to the target weights and to at least P of idle USDG, free of the daily
///           volume cap, and calls {seedPool}. Until then nobody can trade or mint; redeeming works.
///         - Depositors' tokens stay non-transferable for `depositorLock` after the close; they can
///           be staked (here or later) and redeemed meanwhile.
interface IFundLaunch {
    /// @notice Launch lifecycle.
    enum Status {
        Open,
        Succeeded,
        Failed
    }

    /// @notice One account's deposits of one asset.
    /// @param amount     Asset amount.
    /// @param timeWeight Sum of amount × seconds left in the window at each deposit.
    struct Deposit {
        uint256 amount;
        uint256 timeWeight;
    }

    /// @notice Emitted on a deposit.
    /// @param account Depositor.
    /// @param asset   Basket asset or USDG.
    /// @param amount  Amount received.
    event Deposited(address indexed account, address indexed asset, uint256 amount);

    /// @notice Emitted when the launch succeeds.
    /// @param raised          Value raised at closing prices, 18 decimals USD.
    /// @param poolUsdg        USDG set aside to seed the pool.
    /// @param depositorShares Fund tokens allocated to depositors.
    /// @param poolShares      Fund tokens set aside for the pool.
    event LaunchSucceeded(uint256 raised, uint256 poolUsdg, uint256 depositorShares, uint256 poolShares);

    /// @notice Emitted when the launch fails.
    /// @param raised Value raised at closing prices (zero when marked failed after the grace period).
    event LaunchFailed(uint256 raised);

    /// @notice Emitted when the pool is seeded.
    /// @param usdgAmount USDG added.
    /// @param shares     Fund tokens added.
    event PoolSeeded(uint256 usdgAmount, uint256 shares);

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

    /// @notice The window is still open and the target raise is not reached.
    error WindowOpen();

    /// @notice The pool is already seeded.
    error AlreadySeeded();

    /// @notice The fund holds less idle USDG than the pool needs.
    error InsufficientPoolUsdg();

    /// @notice Caller is neither the fund's manager nor the platform admin.
    error NotManager();

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
    /// @param fund_           The fund.
    /// @param minRaiseUsd_    Minimum value to raise, 18 decimals USD.
    /// @param targetRaiseUsd_ Raise at which the launch can close early, 18 decimals USD (0 for none).
    /// @param launchSupply_   Fixed fund token supply created at launch.
    /// @param config_         Launch rules (with this fund's duration and pool share).
    function initialize(
        address fund_,
        uint256 minRaiseUsd_,
        uint256 targetRaiseUsd_,
        uint256 launchSupply_,
        LaunchConfig calldata config_
    ) external;

    /// @notice Deposit a basket asset or USDG during the window. Deposits are final.
    /// @param asset  Basket asset (target weight above zero) or USDG.
    /// @param amount Amount.
    /// @return received Amount received.
    function deposit(address asset, uint256 amount) external returns (uint256 received);

    /// @notice Close the launch: succeed and hand everything to the fund, or fail. Anyone, after the
    ///         window, or before it ends once the deposits are worth the target raise at live prices.
    ///         The keeper should call it as soon as either holds.
    function finalize() external;

    /// @notice Seed the fund's pool after the close, once the manager has rebalanced the fund to hold
    ///         the pool's USDG. Scaled down by any redemptions since the close. Manager or admin.
    function seedPool() external;

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

    /// @notice When the launch closed (set at success).
    /// @return The timestamp.
    function closedAt() external view returns (uint64);

    /// @notice Last moment the launch can be finalized.
    /// @return The timestamp.
    function finalizeDeadline() external view returns (uint64);

    /// @notice Minimum value to raise, 18 decimals USD.
    /// @return The minimum.
    function minRaiseUsd() external view returns (uint256);

    /// @notice Raise at which the launch can close early, 18 decimals USD (0 for none).
    /// @return The target.
    function targetRaiseUsd() external view returns (uint256);

    /// @notice Fixed fund token supply created at launch.
    /// @return The supply.
    function launchSupply() external view returns (uint256);

    /// @notice Fund tokens allocated to depositors (set at success).
    /// @return The amount.
    function depositorSupply() external view returns (uint256);

    /// @notice USDG set aside at the close to seed the pool.
    /// @return The amount.
    function poolUsdg() external view returns (uint256);

    /// @notice Fund tokens set aside at the close for the pool.
    /// @return The amount.
    function poolShares() external view returns (uint256);

    /// @notice Whether the pool has been seeded.
    /// @return True once seeded.
    function poolSeeded() external view returns (bool);

    /// @notice Live value deposited, at current oracle prices, 18 decimals USD.
    /// @return value The value.
    function raisedValue() external view returns (uint256 value);

    /// @notice Launch rules.
    /// @return The rules.
    function config() external view returns (LaunchConfig memory);

    /// @notice Assets accepted at launch: the basket at creation, then USDG.
    /// @return The assets.
    function launchAssets() external view returns (address[] memory);

    /// @notice An account's deposits of an asset.
    /// @param account The account.
    /// @param asset   The asset.
    /// @return The deposit.
    function depositOf(address account, address asset) external view returns (Deposit memory);

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

    /// @notice Live value deposited per launch asset and its target share of the raise, for showing
    ///         which assets are above target. Values use current oracle prices (zero when
    ///         unavailable), USDG at $1.
    /// @return assets     Launch assets (USDG last).
    /// @return values     Value deposited per asset, 18 decimals USD.
    /// @return weightsBps Target share of the raise per asset.
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
