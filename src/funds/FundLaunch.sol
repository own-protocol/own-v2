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
/// @dev Pool sizing. With raise V and pool USDG P = poolUsdgBps of V (both USD, 18 decimals), fixed
///      supply S, pool tokens M and depositor tokens C = S - M, the fund's position counted as
///      backing:
///        NAV = V / C,  pool price = P / M,  pool price = (1 + premium) * NAV
///      which solves to M = P * S / ((1 + premium) * V + P). With a 10% pool share and a 30% premium
///      M is about 7% of S.
///
///      Allocation. Each depositor's points per asset are its credited value at the closing price:
///      (amount + timeWeight * earlyYieldRate) * price * credit, where credit is the asset's
///      post-haircut value over its raw value. Depositors share C in proportion to points. USDG is
///      the last launch asset, priced at $1.
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
    uint64 public override closedAt;

    /// @inheritdoc IFundLaunch
    bool public override poolSeeded;

    /// @inheritdoc IFundLaunch
    uint256 public override minRaiseUsd;

    /// @inheritdoc IFundLaunch
    uint256 public override targetRaiseUsd;

    /// @inheritdoc IFundLaunch
    uint256 public override launchSupply;

    /// @inheritdoc IFundLaunch
    uint256 public override depositorSupply;

    /// @inheritdoc IFundLaunch
    uint256 public override stakedShares;

    /// @inheritdoc IFundLaunch
    uint256 public override poolUsdg;

    /// @inheritdoc IFundLaunch
    uint256 public override poolShares;

    /// @notice Sum of every depositor's points, set at success.
    uint256 public totalPoints;

    IFundFactory private _factory;
    LaunchConfig private _config;
    address private _usdg;
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
        uint256 targetRaiseUsd_,
        uint256 launchSupply_,
        LaunchConfig calldata config_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        if (launchSupply_ == 0) revert ZeroAmount();
        _factory = IFundFactory(msg.sender);
        fund = fund_;
        minRaiseUsd = minRaiseUsd_;
        targetRaiseUsd = targetRaiseUsd_;
        launchSupply = launchSupply_;
        _config = config_;
        startTime = uint64(block.timestamp);
        endTime = uint64(block.timestamp + config_.duration);
        finalizeDeadline = uint64(block.timestamp + config_.duration + config_.finalizeGrace);
        address usdg = IFundFactory(msg.sender).usdg();
        _usdg = usdg;
        _launchAssets = IFund(fund_).assets();
        _launchAssets.push(usdg);
    }

    /// @inheritdoc IFundLaunch
    function deposit(address asset, uint256 amount) external override nonReentrant returns (uint256 received) {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp >= endTime) revert WindowClosed();
        if (depositsPaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();
        // Only listed assets have a weight.
        if (asset != _usdg && IFund(fund).targetWeightBps(asset) == 0) {
            revert AssetNotAccepted(asset);
        }

        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        uint256 timeWeight = received * (endTime - block.timestamp);
        Deposit storage d = _deposits[msg.sender][asset];
        d.amount += received;
        d.timeWeight += timeWeight;
        totalDeposited[asset] += received;
        totalTimeWeight[asset] += timeWeight;

        emit Deposited(msg.sender, asset, received);
    }

    /// @inheritdoc IFundLaunch
    function finalize() external override nonReentrant {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp > finalizeDeadline) revert FinalizeDeadlinePassed();

        uint256 raised = _closeValues();
        if (block.timestamp < endTime && (targetRaiseUsd == 0 || raised < targetRaiseUsd)) revert WindowOpen();

        if (raised == 0 || raised < minRaiseUsd) {
            status = Status.Failed;
            emit LaunchFailed(raised);
            return;
        }

        status = Status.Succeeded;
        closedAt = uint64(block.timestamp);
        uint256 supply = launchSupply;
        uint256 poolValue = Math.mulDiv(raised, _config.poolUsdgBps, BPS);
        uint256 denominator = Math.mulDiv(raised, BPS + _config.launchPremiumBps, BPS) + poolValue;
        uint256 pShares = Math.mulDiv(poolValue, supply, denominator);
        uint256 depositorShares = supply - pShares;
        depositorSupply = depositorShares;
        poolShares = pShares;
        // Rounds down: the pool never claims more USDG than its share of the raise.
        uint256 pUsdg = Math.mulDiv(poolValue, 10 ** IERC20Metadata(_usdg).decimals(), PRECISION);
        poolUsdg = pUsdg;
        totalPoints = _creditAndPoints(raised);

        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 total = totalDeposited[a];
            if (total != 0) IERC20(a).safeTransfer(fund, total);
        }

        IFund f = IFund(fund);
        f.moduleMint(address(this), depositorShares);
        f.markLaunched(uint64(block.timestamp + _config.depositorLock));
        address staking = f.staking();
        IERC20(fund).forceApprove(staking, depositorShares);
        stakedShares = IFundStaking(staking).stake(depositorShares, address(this));

        emit LaunchSucceeded(raised, pUsdg, depositorShares, pShares);
    }

    /// @inheritdoc IFundLaunch
    function seedPool() external override nonReentrant {
        IFund f = IFund(fund);
        if (msg.sender != f.manager() && !_factory.isAdmin(msg.sender)) revert NotManager();
        if (status != Status.Succeeded) revert WrongStatus();
        if (poolSeeded) revert AlreadySeeded();

        // Only redemptions move the supply before the pool opens; the pool shrinks with them.
        uint256 supply = Math.min(IERC20(fund).totalSupply(), depositorSupply);
        uint256 usdgAmount = Math.mulDiv(poolUsdg, supply, depositorSupply);
        uint256 shares = Math.mulDiv(poolShares, supply, depositorSupply);
        if (IERC20(_usdg).balanceOf(fund) < usdgAmount) revert InsufficientPoolUsdg();
        poolSeeded = true;

        address hook = _factory.hook();
        f.moduleMint(hook, shares);
        f.sendPoolUsdg(usdgAmount);
        IFundHook(hook).seedPool(fund, usdgAmount, shares);

        emit PoolSeeded(usdgAmount, shares);
    }

    /// @inheritdoc IFundLaunch
    function markFailed() external override {
        if (status != Status.Open) revert WrongStatus();
        if (block.timestamp <= finalizeDeadline) revert FinalizeDeadlineNotPassed();
        status = Status.Failed;
        emit LaunchFailed(0);
    }

    /// @inheritdoc IFundLaunch
    function distribute(
        address[] calldata accounts
    ) external override nonReentrant {
        if (status != Status.Succeeded) revert WrongStatus();
        IFundStaking staking = IFundStaking(IFund(fund).staking());
        for (uint256 i; i < accounts.length; ++i) {
            uint256 shares = claimable(accounts[i]);
            if (shares != 0) _settle(staking, accounts[i], shares, true);
        }
    }

    /// @inheritdoc IFundLaunch
    function claim(
        bool stake
    ) external override nonReentrant returns (uint256 amount) {
        if (status != Status.Succeeded) revert WrongStatus();
        uint256 shares = claimable(msg.sender);
        if (shares == 0) revert NothingToClaim();
        amount = _settle(IFundStaking(IFund(fund).staking()), msg.sender, shares, stake);
    }

    /// @inheritdoc IFundLaunch
    function refund() external override nonReentrant {
        if (status != Status.Failed) revert WrongStatus();
        if (settled[msg.sender]) revert NothingToClaim();
        settled[msg.sender] = true;

        uint256 n = _launchAssets.length;
        bool any;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 amount = _deposits[msg.sender][a].amount;
            if (amount == 0) continue;
            any = true;
            IERC20(a).safeTransfer(msg.sender, amount);
        }
        if (!any) revert NothingToClaim();
        emit Refunded(msg.sender);
    }

    /// @inheritdoc IFundLaunch
    function setDepositsPaused(
        bool paused
    ) external override {
        if (!_factory.isOperator(msg.sender)) revert NotOperator();
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
        IFundOracle o = _oracle();
        for (uint256 i; i < n; ++i) {
            weightsBps[i] = uint16(_targetBps(assets[i]));
            values[i] = _liveValue(o, assets[i]);
        }
    }

    /// @inheritdoc IFundLaunch
    function raisedValue() public view override returns (uint256 value) {
        uint256 n = _launchAssets.length;
        IFundOracle o = _oracle();
        for (uint256 i; i < n; ++i) {
            value += _liveValue(o, _launchAssets[i]);
        }
    }

    /// @inheritdoc IFundLaunch
    function claimable(
        address account
    ) public view override returns (uint256 shares) {
        if (status != Status.Succeeded || settled[account] || totalPoints == 0) return 0;
        uint256 points;
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            Deposit storage d = _deposits[account][a];
            if (d.amount != 0) points += _points(a, d.amount, d.timeWeight);
        }
        // Rounds down, so all claims together never exceed the launch's stake.
        shares = Math.mulDiv(stakedShares, points, totalPoints);
    }

    /// @dev Hands `account` its claimable `shares` staked, locked, or unstakes them to it with the
    ///      launch lock moved onto the fund tokens.
    function _settle(
        IFundStaking staking,
        address account,
        uint256 shares,
        bool stake
    ) internal returns (uint256 amount) {
        settled[account] = true;
        if (stake) {
            amount = shares;
            staking.transferLocked(account, shares);
        } else {
            amount = staking.unstake(shares, account);
            IFund(fund).addLaunchLock(account, amount);
        }
        emit Claimed(account, amount, stake);
    }

    /// @dev Records closing prices and raw values; returns the raise V.
    function _closeValues() internal returns (uint256 raised) {
        IFundOracle o = _oracle();
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 total = totalDeposited[a];
            if (total == 0) continue;
            uint256 price = a == _usdg ? PRECISION : o.price(a);
            closePrice[a] = price;
            uint256 value = Math.mulDiv(total, price, 10 ** IERC20Metadata(a).decimals());
            rawValue[a] = value;
            raised += value;
        }
    }

    /// @dev Applies the overweight haircut per asset and returns the total points.
    function _creditAndPoints(
        uint256 raised
    ) internal returns (uint256 points) {
        uint256 haircut = _config.overweightHaircutBps;
        uint256 n = _launchAssets.length;
        for (uint256 i; i < n; ++i) {
            address a = _launchAssets[i];
            uint256 value = rawValue[a];
            if (value == 0) continue;
            uint256 targetValue = Math.mulDiv(raised, _targetBps(a), BPS);
            uint256 over = value > targetValue ? value - targetValue : 0;
            // Rounds up: the haircut is never understated.
            creditedValue[a] = value - Math.mulDiv(over, haircut, BPS, Math.Rounding.Ceil);
            points += _points(a, totalDeposited[a], totalTimeWeight[a]);
        }
    }

    /// @dev Time weights run to the scheduled end; an early close takes off the part never served.
    ///      A close after the end (the usual case) served the whole window. An asset whose deposits
    ///      are worth under 1 wei of USD earns no points, as in the total.
    function _points(address asset, uint256 amount, uint256 timeWeight) internal view returns (uint256) {
        uint256 raw = rawValue[asset];
        if (raw == 0) return 0;
        uint256 unserved = closedAt < endTime ? endTime - closedAt : 0;
        uint256 served = timeWeight - amount * unserved;
        uint256 bonus = Math.mulDiv(served, _config.earlyYieldBpsPerDay, BPS * 1 days);
        uint256 value = Math.mulDiv(amount + bonus, closePrice[asset], 10 ** IERC20Metadata(asset).decimals());
        return Math.mulDiv(value, creditedValue[asset], raw);
    }

    /// @dev Target share of the raise: USDG's is the pool share, the basket splits the rest by weight.
    function _targetBps(
        address asset
    ) internal view returns (uint256) {
        uint256 poolBps = _config.poolUsdgBps;
        if (asset == _usdg) return poolBps;
        return Math.mulDiv(IFund(fund).targetWeightBps(asset), BPS - poolBps, BPS);
    }

    /// @dev Zero when the asset has no fresh price.
    function _liveValue(IFundOracle o, address asset) internal view returns (uint256) {
        bool ok = true;
        uint256 price = PRECISION;
        if (asset != _usdg) (ok, price) = o.tryPrice(asset);
        return ok ? Math.mulDiv(totalDeposited[asset], price, 10 ** IERC20Metadata(asset).decimals()) : 0;
    }

    function _oracle() internal view returns (IFundOracle) {
        return IFundOracle(_factory.oracle());
    }
}
