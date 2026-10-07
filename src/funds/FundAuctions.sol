// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundAuctions} from "../interfaces/IFundAuctions.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title FundAuctions — Dutch-auction rebalancing for every fund of a factory
/// @notice See {IFundAuctions}.
/// @dev Holds no tokens: a fill pulls the payment from the filler into the fund, then the fund
///      pays the sold asset out to the filler.
contract FundAuctions is IFundAuctions, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Hard cap on the start premium.
    uint16 public constant MAX_START_PREMIUM_BPS = 5000;

    /// @notice Shortest auction.
    uint32 public constant MIN_DURATION = 15 minutes;

    /// @notice Longest auction.
    uint32 public constant MAX_DURATION = 7 days;

    struct Volume {
        uint192 amount;
        uint64 updatedAt;
    }

    /// @inheritdoc IFundAuctions
    address public immutable override factory;

    /// @inheritdoc IFundAuctions
    uint16 public override startPremiumBps;

    /// @inheritdoc IFundAuctions
    uint32 public override duration;

    Lot[] private _lots;
    mapping(address fund => Volume) private _volume;

    /// @param factory_         The fund factory.
    /// @param startPremiumBps_ Start price above the oracle rate.
    /// @param duration_        Auction length.
    constructor(address factory_, uint16 startPremiumBps_, uint32 duration_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        _setConfig(startPremiumBps_, duration_);
    }

    /// @inheritdoc IFundAuctions
    function openLot(
        address fund,
        address sellAsset,
        address buyAsset,
        uint256 amount
    ) external override nonReentrant returns (uint256 id) {
        IFundFactory fac = IFundFactory(factory);
        if (!fac.isFund(fund)) revert NotFund();
        _checkManager(fac, fund);
        if (!IFundHook(fac.hook()).isSeeded(fund)) revert NotSeeded();
        _checkAssets(fac, fund, sellAsset, buyAsset);
        if (amount == 0 || amount > IERC20(sellAsset).balanceOf(fund)) revert ZeroAmount();

        IFundOracle o = IFundOracle(fac.oracle());
        address usdg = fac.usdg();
        uint256 rate = Math.mulDiv(
            _price(o, usdg, sellAsset) * 10 ** IERC20Metadata(buyAsset).decimals(),
            PRECISION,
            _price(o, usdg, buyAsset) * 10 ** IERC20Metadata(sellAsset).decimals()
        );
        uint256 startPrice = Math.mulDiv(rate, BPS + startPremiumBps, BPS);
        // Rounds up: the floor never sits below the oracle bound.
        uint256 floorPrice = Math.mulDiv(rate, BPS - fac.maxRebalanceSlippageBps(), BPS, Math.Rounding.Ceil);
        if (floorPrice == 0) revert ZeroAmount();

        uint64 endTime = uint64(block.timestamp + duration);
        id = _lots.length;
        _lots.push(
            Lot({
                fund: fund,
                sellAsset: sellAsset,
                buyAsset: buyAsset,
                remaining: SafeCast.toUint128(amount),
                startTime: uint64(block.timestamp),
                endTime: endTime,
                startPrice: startPrice,
                floorPrice: floorPrice
            })
        );
        emit LotOpened(id, fund, sellAsset, buyAsset, amount, startPrice, floorPrice, endTime);
    }

    /// @inheritdoc IFundAuctions
    function cancelLot(
        uint256 id
    ) external override nonReentrant {
        Lot storage l = _active(id);
        _checkManager(IFundFactory(factory), l.fund);
        l.remaining = 0;
        emit LotCancelled(id);
    }

    /// @inheritdoc IFundAuctions
    function fill(
        uint256 id,
        uint256 amount,
        uint256 maxPayment
    ) external override nonReentrant returns (uint256 payment) {
        Lot storage l = _active(id);
        if (amount == 0) revert ZeroAmount();
        if (amount > l.remaining) revert ExceedsLot();
        payment = _cost(l, amount);
        if (payment > maxPayment) revert Slippage();

        IFundFactory fac = IFundFactory(factory);
        address fund = l.fund;
        (address sellAsset, address buyAsset) = (l.sellAsset, l.buyAsset);
        _checkAssets(fac, fund, sellAsset, buyAsset);
        uint256 soldValue = _checkValue(fac, sellAsset, amount, buyAsset, payment);
        _trackVolume(fac, fund, soldValue);
        l.remaining -= uint128(amount);

        uint256 before = IERC20(buyAsset).balanceOf(fund);
        IERC20(buyAsset).safeTransferFrom(msg.sender, fund, payment);
        if (IERC20(buyAsset).balanceOf(fund) - before < payment) revert PaymentShort();
        IFund(fund).auctionPayout(sellAsset, msg.sender, amount);

        emit LotFilled(id, msg.sender, amount, payment);
    }

    /// @inheritdoc IFundAuctions
    function setConfig(uint16 startPremiumBps_, uint32 duration_) external override {
        if (!IFundFactory(factory).isAdmin(msg.sender)) revert NotAdmin();
        _setConfig(startPremiumBps_, duration_);
    }

    /// @inheritdoc IFundAuctions
    function lot(
        uint256 id
    ) external view override returns (Lot memory) {
        return _lots[id];
    }

    /// @inheritdoc IFundAuctions
    function lotCount() external view override returns (uint256) {
        return _lots.length;
    }

    /// @inheritdoc IFundAuctions
    function currentPrice(
        uint256 id
    ) public view override returns (uint256) {
        return _priceNow(_active(id));
    }

    /// @inheritdoc IFundAuctions
    function quote(uint256 id, uint256 amount) external view override returns (uint256 payment) {
        return _cost(_active(id), amount);
    }

    /// @inheritdoc IFundAuctions
    function volumeOf(
        address fund
    ) external view override returns (uint256) {
        Volume memory v = _volume[fund];
        uint256 cap = _cap(IFundFactory(factory), fund);
        uint256 drained = Math.mulDiv(cap, block.timestamp - v.updatedAt, 1 days);
        return v.amount > drained ? v.amount - drained : 0;
    }

    function _active(
        uint256 id
    ) internal view returns (Lot storage l) {
        if (id >= _lots.length) revert LotNotActive(id);
        l = _lots[id];
        if (l.remaining == 0 || block.timestamp >= l.endTime) revert LotNotActive(id);
    }

    function _priceNow(
        Lot storage l
    ) internal view returns (uint256) {
        uint256 span = l.endTime - l.startTime;
        uint256 drop = Math.mulDiv(l.startPrice - l.floorPrice, block.timestamp - l.startTime, span);
        return l.startPrice - drop;
    }

    /// @dev Rounds up: the fund is never paid less than the lot's price.
    function _cost(Lot storage l, uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, _priceNow(l), PRECISION, Math.Rounding.Ceil);
    }

    function _checkManager(IFundFactory fac, address fund) internal view {
        if (msg.sender != IFund(fund).manager() && !fac.isAdmin(msg.sender)) revert NotManager();
    }

    function _checkAssets(IFundFactory fac, address fund, address sellAsset, address buyAsset) internal view {
        IFund f = IFund(fund);
        if (sellAsset == buyAsset || (!f.isAsset(sellAsset) && sellAsset != fac.usdg()) || !f.isAsset(buyAsset)) {
            revert InvalidAssets();
        }
    }

    /// @dev Re-checks the fill against the live oracle with the rebalance slippage bound; returns
    ///      the value sold.
    function _checkValue(
        IFundFactory fac,
        address sellAsset,
        uint256 amount,
        address buyAsset,
        uint256 payment
    ) internal view returns (uint256 soldValue) {
        IFundOracle o = IFundOracle(fac.oracle());
        address usdg = fac.usdg();
        soldValue = _value(sellAsset, amount, _price(o, usdg, sellAsset));
        uint256 paidValue = _value(buyAsset, payment, _price(o, usdg, buyAsset));
        uint256 minValue = Math.mulDiv(soldValue, BPS - fac.maxRebalanceSlippageBps(), BPS, Math.Rounding.Ceil);
        if (paidValue < minValue) revert BelowOracleBound();
    }

    /// @dev The same daily cap as the fund's router swaps, measured against the fund's basket and
    ///      idle USDG, tracked separately for auctions.
    function _trackVolume(IFundFactory fac, address fund, uint256 soldValue) internal {
        Volume memory v = _volume[fund];
        uint256 cap = _cap(fac, fund);
        uint256 drained = Math.mulDiv(cap, block.timestamp - v.updatedAt, 1 days);
        uint256 volume = (v.amount > drained ? v.amount - drained : 0) + soldValue;
        if (volume > cap) revert VolumeExceeded();
        _volume[fund] = Volume({amount: SafeCast.toUint192(volume), updatedAt: uint64(block.timestamp)});
    }

    function _cap(IFundFactory fac, address fund) internal view returns (uint256) {
        IFundOracle o = IFundOracle(fac.oracle());
        address[] memory assets = IFund(fund).assets();
        uint256 tradable;
        for (uint256 i; i < assets.length; ++i) {
            uint256 bal = IERC20(assets[i]).balanceOf(fund);
            if (bal != 0) tradable += _value(assets[i], bal, o.price(assets[i]));
        }
        address usdg = fac.usdg();
        tradable += _value(usdg, IERC20(usdg).balanceOf(fund), PRECISION);
        return Math.mulDiv(tradable, fac.rebalanceVolumeCapBps(), BPS);
    }

    function _price(IFundOracle o, address usdg, address asset) internal view returns (uint256) {
        return asset == usdg ? PRECISION : o.price(asset);
    }

    function _value(address asset, uint256 amount, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** IERC20Metadata(asset).decimals());
    }

    function _setConfig(uint16 startPremiumBps_, uint32 duration_) internal {
        if (startPremiumBps_ > MAX_START_PREMIUM_BPS || duration_ < MIN_DURATION || duration_ > MAX_DURATION) {
            revert InvalidConfig();
        }
        startPremiumBps = startPremiumBps_;
        duration = duration_;
        emit AuctionConfigSet(startPremiumBps_, duration_);
    }
}
