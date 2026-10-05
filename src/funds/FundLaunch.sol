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

/// @title FundLaunch — deposit window, graduation and pool seeding for one fund
/// @notice See {IFundLaunch}.
/// @dev Pool sizing. With basket value R and USDG U (both USD, 18 decimals), fixed supply S, pool
///      tokens M and depositor tokens C = S - M, the fund's position counted as backing:
///        NAV = (R + U) / C,  pool price = U / M,  pool price = (1 + premium) * NAV
///      which solves to M = U * S / ((1 + premium) * (R + U) + U). With a 30% USDG ratio and a 30%
///      premium M is about 15% of S.
///
///      Allocation. Each depositor's points per asset are its credited value at the closing price:
///      (amount + timeWeight * earlyYieldRate) * price * credit, where credit is the asset's
///      post-haircut value over its raw value. Depositors share C in proportion to points.
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
    uint256 public override minRaiseUsd;

    /// @inheritdoc IFundLaunch
    uint256 public override launchSupply;

    /// @inheritdoc IFundLaunch
    uint256 public override totalUsdg;

    /// @inheritdoc IFundLaunch
    uint256 public override depositorSupply;

    /// @notice Sum of every depositor's points, set at success.
    uint256 public totalPoints;

    IFundFactory private _factory;
    LaunchConfig private _config;
    address[] private _launchAssets;

    mapping(address account => mapping(address asset => Deposit)) private _deposits;

    /// @inheritdoc IFundLaunch
    mapping(address asset => uint256) public override totalDeposited;

    /// @notice Sum of every deposit's time weight per asset.
    mapping(address asset => uint256) public totalTimeWeight;

    /// @inheritdoc IFundLaunch
    mapping(address asset => uint256) public override closePrice;

    /// @notice Per asset, value credited after the overweight haircut (set at success).
    mapping(address asset => uint256) public creditedValue;

    /// @notice Per asset, raw value at closing prices (set at success).
    mapping(address asset => uint256) public rawValue;

    /// @inheritdoc IFundLaunch
    mapping(address account => bool) public override settled;

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFundLaunch
    function initialize(
        address fund_,
        uint256 minRaiseUsd_,
        uint256 launchSupply_,
        LaunchConfig calldata config_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        if (launchSupply_ == 0) revert ZeroAmount();
        _factory = IFundFactory(msg.sender);
        fund = fund_;
        minRaiseUsd = minRaiseUsd_;
        launchSupply = launchSupply_;
        _config = config_;
        startTime = uint64(block.timestamp);
        endTime = uint64(block.timestamp + config_.duration);
        finalizeDeadline = uint64(block.timestamp + config_.duration + config_.finalizeGrace);
        _launchAssets = IFund(fund_).assets();
    }

    /// @inheritdoc IFundLaunch
    function deposit(address asset, uint256 amount) external override nonReentrant returns (uint256 usdgPaid) {
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
        uint256 timeWeight = received * (endTime - block.timestamp);

        Deposit storage d = _deposits[msg.sender][asset];
        d.amount += received;
        d.usdg += usdgPaid;
        d.timeWeight += timeWeight;
        totalDeposited[asset] += received;
        totalTimeWeight[asset] += timeWeight;
        totalUsdg += usdgPaid;

        IERC20(usdg).safeTransferFrom(msg.sender, address(this), usdgPaid);

        emit Deposited(msg.sender, asset, received, usdgPaid);
    }

    /// @inheritdoc IFundLaunch
    function withdraw(address asset, uint256 amount) external override nonReentrant returns (uint256 usdgReturned) {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp >= withdrawDeadline()) revert WithdrawalsClosed();
        if (amount == 0) revert ZeroAmount();
        Deposit storage d = _deposits[msg.sender][asset];
        uint256 held = d.amount;
        if (amount > held) revert InsufficientDeposit();

        // Rounds down for the USDG returned and up for the time weight forfeited.
        usdgReturned = Math.mulDiv(d.usdg, amount, held);
        uint256 forfeited = Math.mulDiv(d.timeWeight, amount, held, Math.Rounding.Ceil);
        d.amount = held - amount;
        d.usdg -= usdgReturned;
        d.timeWeight -= forfeited;
        totalDeposited[asset] -= amount;
        totalTimeWeight[asset] -= forfeited;
        totalUsdg -= usdgReturned;

        IERC20(asset).safeTransfer(msg.sender, amount);
        if (usdgReturned != 0) IERC20(_factory.usdg()).safeTransfer(msg.sender, usdgReturned);
        emit Withdrawn(msg.sender, asset, amount, usdgReturned);
    }

    /// @inheritdoc IFundLaunch
    function finalize() external override nonReentrant {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp < endTime) revert WindowOpen();
        if (block.timestamp > finalizeDeadline) revert FinalizeDeadlinePassed();

        uint256 basketValue = _closeValues();
        address usdg = _factory.usdg();
        uint256 usdgValue = Math.mulDiv(totalUsdg, PRECISION, 10 ** IERC20Metadata(usdg).decimals());

        if (basketValue == 0 || basketValue < minRaiseUsd || usdgValue == 0) {
            status = Status.Failed;
            emit LaunchFailed(basketValue);
            return;
        }

        status = Status.Succeeded;
        uint256 supply = launchSupply;
        uint256 denominator = Math.mulDiv(basketValue + usdgValue, BPS + _config.launchPremiumBps, BPS) + usdgValue;
        uint256 poolShares = Math.mulDiv(usdgValue, supply, denominator);
        uint256 depositorShares = supply - poolShares;
        depositorSupply = depositorShares;
        totalPoints = _creditAndPoints(basketValue);

        uint256 n = _launchAssets.length;
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
        IFund(fund).markLaunched(uint64(block.timestamp + _config.depositorLock));

        emit LaunchSucceeded(basketValue, usdgValue, depositorShares, poolShares);
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

        IFund f = IFund(fund);
        if (stake) {
            address staking = f.staking();
            IERC20(fund).forceApprove(staking, shares);
            IFundStaking(staking).stakeLocked(shares, msg.sender);
        } else {
            IERC20(fund).safeTransfer(msg.sender, shares);
            f.addLaunchLock(msg.sender, shares);
        }
        emit Claimed(msg.sender, shares, stake);
    }

    /// @inheritdoc IFundLaunch
    function refund() external override nonReentrant {
        if (status != Status.Failed) revert WrongStatus();
        if (settled[msg.sender]) revert NothingToClaim();
        settled[msg.sender] = true;

        uint256 usdgAmount;
        uint256 n = _launchAssets.length;
        bool any;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            Deposit storage d = _deposits[msg.sender][a];
            usdgAmount += d.usdg;
            if (d.amount == 0) continue;
            any = true;
            IERC20(a).safeTransfer(msg.sender, d.amount);
        }
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
    function withdrawDeadline() public view override returns (uint64) {
        uint64 cutoff = _config.withdrawCutoff;
        return endTime > startTime + cutoff ? endTime - cutoff : startTime;
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
    function depositOf(address account, address asset) external view override returns (Deposit memory) {
        return _deposits[account][asset];
    }

    /// @inheritdoc IFundLaunch
    function depositValues()
        external
        view
        override
        returns (address[] memory assets, uint256[] memory values, uint16[] memory weightsBps)
    {
        assets = _launchAssets;
        uint256 n = assets.length;
        values = new uint256[](n);
        weightsBps = new uint16[](n);
        IFundOracle o = IFundOracle(_factory.oracle());
        IFund f = IFund(fund);
        for (uint256 i; i < n; ++i) {
            address a = assets[i];
            weightsBps[i] = f.targetWeightBps(a);
            (bool ok, uint256 p) = o.tryPrice(a);
            if (ok) values[i] = Math.mulDiv(totalDeposited[a], p, 10 ** IERC20Metadata(a).decimals());
        }
    }

    /// @inheritdoc IFundLaunch
    function claimable(
        address account
    ) public view override returns (uint256 shares) {
        if (status != Status.Succeeded || settled[account] || totalPoints == 0) return 0;
        uint256 points;
        uint256 usdgPaid;
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            Deposit storage d = _deposits[account][a];
            usdgPaid += d.usdg;
            if (d.amount != 0) points += _points(a, d.amount, d.timeWeight);
        }
        points += _usdgPoints(usdgPaid);
        // Rounds down, so all claims together never exceed the depositor allocation.
        shares = Math.mulDiv(depositorSupply, points, totalPoints);
    }

    /// @dev Records closing prices and raw values; returns the basket value R.
    function _closeValues() internal returns (uint256 basketValue) {
        IFundOracle o = IFundOracle(_factory.oracle());
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 total = totalDeposited[a];
            if (total == 0) continue;
            uint256 price = o.price(a);
            closePrice[a] = price;
            uint256 value = Math.mulDiv(total, price, 10 ** IERC20Metadata(a).decimals());
            rawValue[a] = value;
            basketValue += value;
        }
    }

    /// @dev Applies the overweight haircut per asset and returns the total points.
    function _creditAndPoints(
        uint256 basketValue
    ) internal returns (uint256 points) {
        IFund f = IFund(fund);
        uint256 haircut = _config.overweightHaircutBps;
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 value = rawValue[a];
            if (value == 0) continue;
            uint256 targetValue = Math.mulDiv(basketValue, f.targetWeightBps(a), BPS);
            uint256 over = value > targetValue ? value - targetValue : 0;
            // Rounds up: the haircut is never understated.
            creditedValue[a] = value - Math.mulDiv(over, haircut, BPS, Math.Rounding.Ceil);
            points += _points(a, totalDeposited[a], totalTimeWeight[a]);
        }
        points += _usdgPoints(totalUsdg);
    }

    /// @dev The USDG actually paid is added on top (see _usdgPoints), so USDG priced at deposit time
    ///      buys no extra share; the early bonus covers the USDG part of the deposit too.
    function _points(address asset, uint256 amount, uint256 timeWeight) internal view returns (uint256) {
        uint256 bonus = Math.mulDiv(timeWeight, _config.earlyYieldBpsPerDay, BPS * 1 days);
        uint256 scale = 10 ** IERC20Metadata(asset).decimals();
        uint256 value = Math.mulDiv(amount + bonus, closePrice[asset], scale);
        return Math.mulDiv(value, creditedValue[asset], rawValue[asset])
            + Math.mulDiv(bonus, closePrice[asset] * _config.usdgRatioBps, scale * BPS);
    }

    function _usdgPoints(
        uint256 amount
    ) internal view returns (uint256) {
        return Math.mulDiv(amount, PRECISION, 10 ** IERC20Metadata(_factory.usdg()).decimals());
    }
}
