// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundLaunch} from "../interfaces/IFundLaunch.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {LaunchConfig} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundLaunch — deposit window, graduation and locked pool seeding for one fund
/// @notice See {IFundLaunch}.
/// @dev Pool sizing. With basket value R, USDG raised U (both USD, 18 decimals), depositor
///      allocation C = R fund tokens and pool allocation M, every token counted in NAV:
///        NAV = R / (C + M),  pool price = U / M,  pool price = (1 + premium) * NAV
///      which solves to M = U * C / ((1 + premium) * R - U). With a 30% USDG ratio and a 30%
///      premium the pool opens at $1.00 against a NAV of about $0.77.
contract FundLaunch is IFundLaunch, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFundLaunch
    address public override fund;

    /// @inheritdoc IFundLaunch
    Status public override status;

    /// @inheritdoc IFundLaunch
    uint64 public override startTime;

    /// @inheritdoc IFundLaunch
    uint64 public override endTime;

    /// @inheritdoc IFundLaunch
    uint64 public override finalizeDeadline;

    /// @notice Whether deposits are paused.
    bool public depositsPaused;

    /// @inheritdoc IFundLaunch
    uint256 public override minGraduationUsd;

    /// @inheritdoc IFundLaunch
    uint256 public override totalUsdg;

    IFundFactory private _factory;
    LaunchConfig private _config;
    address[] private _launchAssets;

    mapping(address account => mapping(address asset => uint256)) private _deposits;

    /// @inheritdoc IFundLaunch
    mapping(address account => uint256) public override usdgOf;

    /// @inheritdoc IFundLaunch
    mapping(address asset => uint256) public override totalDeposited;

    /// @inheritdoc IFundLaunch
    mapping(address asset => uint256) public override closePrice;

    /// @inheritdoc IFundLaunch
    mapping(address account => bool) public override settled;

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFundLaunch
    function initialize(
        address fund_,
        uint256 minGraduationUsd_,
        LaunchConfig calldata config_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        _factory = IFundFactory(msg.sender);
        fund = fund_;
        minGraduationUsd = minGraduationUsd_;
        _config = config_;
        startTime = uint64(block.timestamp);
        endTime = uint64(block.timestamp + config_.duration);
        finalizeDeadline = uint64(block.timestamp + config_.duration + config_.finalizeGrace);
        _launchAssets = IFund(fund_).assets();
    }

    /// @inheritdoc IFundLaunch
    function deposit(
        address asset,
        uint256 amount
    ) external override nonReentrant returns (uint256 usdgPaid) {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp >= endTime) revert WindowClosed();
        if (depositsPaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();
        address usdg = _factory.usdg();
        if (asset == usdg || !IFund(fund).isAsset(asset) || IFund(fund).targetWeightBps(asset) == 0) {
            revert AssetNotAccepted(asset);
        }

        uint256 price = IFundOracle(_factory.oracle()).price(asset);

        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        uint256 value = Math.mulDiv(received, price, 10 ** IERC20Metadata(asset).decimals());
        // Rounds up: the depositor always brings at least the configured USDG ratio.
        usdgPaid = Math.mulDiv(
            value,
            uint256(_config.usdgRatioBps) * 10 ** IERC20Metadata(usdg).decimals(),
            BPS * PRECISION,
            Math.Rounding.Ceil
        );

        _deposits[msg.sender][asset] += received;
        totalDeposited[asset] += received;
        usdgOf[msg.sender] += usdgPaid;
        totalUsdg += usdgPaid;

        IERC20(usdg).safeTransferFrom(msg.sender, address(this), usdgPaid);

        emit Deposited(msg.sender, asset, received, usdgPaid);
    }

    /// @inheritdoc IFundLaunch
    function finalize() external override nonReentrant {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp < endTime) revert WindowOpen();
        if (block.timestamp > finalizeDeadline) revert FinalizeDeadlinePassed();

        IFundOracle o = IFundOracle(_factory.oracle());
        uint256 basketValue;
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 total = totalDeposited[a];
            if (total == 0) continue;
            uint256 price = o.price(a);
            closePrice[a] = price;
            basketValue += Math.mulDiv(total, price, 10 ** IERC20Metadata(a).decimals());
        }

        address usdg = _factory.usdg();
        uint256 usdgValue = Math.mulDiv(totalUsdg, PRECISION, 10 ** IERC20Metadata(usdg).decimals());
        uint256 premiumValue = Math.mulDiv(basketValue, BPS + _config.launchPremiumBps, BPS);

        if (basketValue == 0 || basketValue < minGraduationUsd || usdgValue == 0 || premiumValue <= usdgValue) {
            status = Status.Failed;
            emit LaunchFailed(basketValue);
            return;
        }

        status = Status.Succeeded;
        uint256 depositorShares = basketValue;
        uint256 poolShares = Math.mulDiv(usdgValue, depositorShares, premiumValue - usdgValue);

        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 total = totalDeposited[a];
            if (total != 0) IERC20(a).safeTransfer(fund, total);
        }

        address hook = _factory.hook();
        IFund(fund).moduleMint(address(this), depositorShares);
        IFund(fund).moduleMint(hook, poolShares);
        IERC20(usdg).safeTransfer(hook, totalUsdg);
        IFundHook(hook).seedPool(fund, totalUsdg, poolShares);
        IFund(fund).markLaunched();

        emit LaunchSucceeded(basketValue, depositorShares, poolShares, totalUsdg);
    }

    /// @inheritdoc IFundLaunch
    function markFailed() external override {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp <= finalizeDeadline) revert FinalizeDeadlineNotPassed();
        status = Status.Failed;
        emit LaunchFailed(0);
    }

    /// @inheritdoc IFundLaunch
    function claim(
        bool stake
    ) external override nonReentrant returns (uint256 shares) {
        if (status != Status.Succeeded) revert WrongStatus();
        shares = claimable(msg.sender);
        if (shares == 0) revert NothingToClaim();
        settled[msg.sender] = true;

        if (stake) {
            address staking = IFund(fund).staking();
            IERC20(fund).forceApprove(staking, shares);
            IFundStaking(staking).stake(shares, msg.sender);
        } else {
            IERC20(fund).safeTransfer(msg.sender, shares);
        }
        emit Claimed(msg.sender, shares, stake);
    }

    /// @inheritdoc IFundLaunch
    function refund() external override nonReentrant {
        if (status != Status.Failed) revert WrongStatus();
        if (settled[msg.sender]) revert NothingToClaim();
        settled[msg.sender] = true;

        bool any;
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 amount = _deposits[msg.sender][a];
            if (amount == 0) continue;
            any = true;
            IERC20(a).safeTransfer(msg.sender, amount);
        }
        uint256 usdgAmount = usdgOf[msg.sender];
        if (usdgAmount != 0) {
            any = true;
            IERC20(_factory.usdg()).safeTransfer(msg.sender, usdgAmount);
        }
        if (!any) revert NothingToClaim();
        emit Refunded(msg.sender);
    }

    /// @inheritdoc IFundLaunch
    function setDepositsPaused(
        bool paused
    ) external override {
        if (msg.sender != _factory.owner()) revert NotAdmin();
        depositsPaused = paused;
    }

    /// @inheritdoc IFundLaunch
    function config() external view override returns (LaunchConfig memory) {
        return _config;
    }

    /// @inheritdoc IFundLaunch
    function launchAssets() external view override returns (address[] memory) {
        return _launchAssets;
    }

    /// @inheritdoc IFundLaunch
    function depositOf(
        address account,
        address asset
    ) external view override returns (uint256) {
        return _deposits[account][asset];
    }

    /// @inheritdoc IFundLaunch
    function claimable(
        address account
    ) public view override returns (uint256 shares) {
        if (status != Status.Succeeded || settled[account]) return 0;
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 amount = _deposits[account][a];
            // Rounds down per asset, so all claims together never exceed the depositor allocation.
            if (amount != 0) shares += Math.mulDiv(amount, closePrice[a], 10 ** IERC20Metadata(a).decimals());
        }
    }
}
