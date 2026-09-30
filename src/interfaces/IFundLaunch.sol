// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchConfig} from "./types/FundTypes.sol";

/// @title IFundLaunch — the deposit window that starts a fund
/// @notice For a fixed window, anyone deposits any basket asset plus USDG worth `usdgRatioBps` of
///         the asset's value. When the window closes:
///         - below the minimum raise (valued at closing prices), everyone is refunded;
///         - otherwise every basket asset moves into the fund, each depositor can claim one fund
///           token per dollar of basket value they brought (at closing prices), and all the USDG
///           plus newly minted fund tokens seed the fund's Uniswap v4 pool as permanently locked,
///           full-range liquidity. The pool's fund-token side is sized so the pool opens at
///           `launchPremiumBps` over NAV, with every fund token (including the pool's) counted in
///           NAV.
///         Deposits are not capped per asset: any excess over target weights is rebalanced by the
///         manager after launch.
interface IFundLaunch {
    /// @notice Launch lifecycle.
    enum Status {
        Open,
        Succeeded,
        Failed
    }

    /// @notice Emitted on a deposit.
    /// @param account Depositor.
    /// @param asset   Basket asset.
    /// @param amount  Asset amount received.
    /// @param usdg    USDG received with it.
    event Deposited(address indexed account, address indexed asset, uint256 amount, uint256 usdg);

    /// @notice Emitted when the launch succeeds.
    /// @param basketValue  Basket value at closing prices, 18 decimals USD.
    /// @param depositorShares Fund tokens allocated to depositors.
    /// @param poolShares   Fund tokens seeded into the pool.
    /// @param poolUsdg     USDG seeded into the pool.
    event LaunchSucceeded(uint256 basketValue, uint256 depositorShares, uint256 poolShares, uint256 poolUsdg);

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
    /// @param fund_            The fund.
    /// @param minGraduationUsd Minimum basket value to raise, 18 decimals USD.
    /// @param config           Launch parameters.
    function initialize(
        address fund_,
        uint256 minGraduationUsd,
        LaunchConfig calldata config
    ) external;

    /// @notice Deposit a basket asset plus the required USDG.
    /// @param asset  Basket asset.
    /// @param amount Asset amount.
    /// @return usdgPaid USDG pulled alongside it.
    function deposit(
        address asset,
        uint256 amount
    ) external returns (uint256 usdgPaid);

    /// @notice Close the launch once the window has ended. Anyone can call.
    function finalize() external;

    /// @notice Mark the launch failed if it was not finalized in time. Anyone can call.
    function markFailed() external;

    /// @notice Claim the caller's fund tokens after a successful launch.
    /// @param stake Whether to stake them on the caller's behalf.
    /// @return shares Fund tokens claimed.
    function claim(
        bool stake
    ) external returns (uint256 shares);

    /// @notice Recover the caller's deposits after a failed launch.
    function refund() external;

    /// @notice Pause or unpause deposits. Admin only.
    /// @param paused Whether deposits are paused.
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
    /// @return Timestamp.
    function startTime() external view returns (uint64);

    /// @notice Window end.
    /// @return Timestamp.
    function endTime() external view returns (uint64);

    /// @notice Last time {finalize} can be called.
    /// @return Timestamp.
    function finalizeDeadline() external view returns (uint64);

    /// @notice Minimum basket value to raise, 18 decimals USD.
    /// @return The minimum.
    function minGraduationUsd() external view returns (uint256);

    /// @notice Launch parameters.
    /// @return The parameters.
    function config() external view returns (LaunchConfig memory);

    /// @notice Basket assets accepted, fixed at initialisation.
    /// @return The assets.
    function launchAssets() external view returns (address[] memory);

    /// @notice Amount of `asset` deposited by `account`.
    /// @param account Depositor.
    /// @param asset   Asset.
    /// @return The amount.
    function depositOf(
        address account,
        address asset
    ) external view returns (uint256);

    /// @notice USDG deposited by `account`.
    /// @param account Depositor.
    /// @return The amount.
    function usdgOf(
        address account
    ) external view returns (uint256);

    /// @notice Total of `asset` deposited.
    /// @param asset Asset.
    /// @return The amount.
    function totalDeposited(
        address asset
    ) external view returns (uint256);

    /// @notice Total USDG deposited.
    /// @return The amount.
    function totalUsdg() external view returns (uint256);

    /// @notice Price of `asset` recorded at finalization, 18 decimals USD.
    /// @param asset Asset.
    /// @return The price.
    function closePrice(
        address asset
    ) external view returns (uint256);

    /// @notice Fund tokens `account` can claim (zero before success or after claiming).
    /// @param account Depositor.
    /// @return The amount.
    function claimable(
        address account
    ) external view returns (uint256);

    /// @notice Whether `account` has claimed or been refunded.
    /// @param account Depositor.
    /// @return True once settled.
    function settled(
        address account
    ) external view returns (bool);
}
