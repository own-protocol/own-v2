// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundPriceHub} from "../interfaces/IFundPriceHub.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {FundPriceFeed} from "./FundPriceFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundPriceHub — keeper-pushed USD prices for fund assets without a Chainlink feed
/// @notice See {IFundPriceHub}.
/// @dev Administered by the ProtocolRegistry's ADMIN role.
contract FundPriceHub is IFundPriceHub {
    bytes32 private constant ADMIN = keccak256("ADMIN");

    // Past this allowed move factor (a 1e18x move) a price is no longer bounded.
    uint256 private constant MAX_FACTOR = 1e36;

    /// @inheritdoc IFundPriceHub
    address public immutable override registry;

    /// @inheritdoc IFundPriceHub
    address public override keeper;

    /// @inheritdoc IFundPriceHub
    uint16 public override maxMoveBps;

    mapping(address asset => Price) private _prices;

    /// @inheritdoc IFundPriceHub
    mapping(address asset => address) public override feedOf;

    modifier onlyAdmin() {
        if (!_isAdmin(msg.sender)) revert NotAdmin();
        _;
    }

    /// @param registry_   ProtocolRegistry resolving the ADMIN role.
    /// @param keeper_     The keeper.
    /// @param maxMoveBps_ Per-push move bound for keeper prices (0 for none).
    constructor(address registry_, address keeper_, uint16 maxMoveBps_) {
        if (registry_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        registry = registry_;
        keeper = keeper_;
        maxMoveBps = maxMoveBps_;
        emit KeeperSet(keeper_);
        emit MaxMoveSet(maxMoveBps_);
    }

    /// @inheritdoc IFundPriceHub
    function pushPrices(address[] calldata assets, uint256[] calldata prices) external override {
        if (msg.sender != keeper) revert NotKeeper();
        if (assets.length != prices.length) revert LengthMismatch();
        uint256 bound = maxMoveBps;
        for (uint256 i; i < assets.length; ++i) {
            uint256 price = prices[i];
            if (price == 0 || price > type(uint192).max) revert InvalidPrice();
            Price storage p = _prices[assets[i]];
            uint256 previous = p.price;
            uint256 stored =
                bound == 0 || previous == 0 ? price : _clamp(previous, price, block.timestamp - p.updatedAt, bound);
            if (stored != price) emit PriceClamped(assets[i], price, stored);
            p.price = uint192(stored);
            p.updatedAt = uint64(block.timestamp);
            emit PricePushed(assets[i], stored);
        }
    }

    /// @inheritdoc IFundPriceHub
    function createFeed(
        address asset
    ) external override onlyAdmin returns (address feed) {
        if (asset == address(0)) revert ZeroAddress();
        if (feedOf[asset] != address(0)) revert FeedExists();
        feed = address(new FundPriceFeed(asset));
        feedOf[asset] = feed;
        emit FeedCreated(asset, feed);
    }

    /// @inheritdoc IFundPriceHub
    function setKeeper(
        address keeper_
    ) external override onlyAdmin {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @inheritdoc IFundPriceHub
    function setMaxMove(
        uint16 maxMoveBps_
    ) external override onlyAdmin {
        maxMoveBps = maxMoveBps_;
        emit MaxMoveSet(maxMoveBps_);
    }

    /// @inheritdoc IFundPriceHub
    function priceOf(
        address asset
    ) external view override returns (uint256 price, uint256 updatedAt) {
        Price memory p = _prices[asset];
        return (p.price, p.updatedAt);
    }

    /// @dev `price` held within `previous` times or divided by the move allowed in `elapsed`:
    ///      `1 + bound` per whole hour, compounding, and a linear share of it for the part hour.
    function _clamp(uint256 previous, uint256 price, uint256 elapsed, uint256 bound) internal pure returns (uint256) {
        uint256 factor = _hourly(PRECISION + Math.mulDiv(PRECISION, bound, BPS), elapsed / 1 hours);
        if (factor >= MAX_FACTOR) return price;
        factor = Math.mulDiv(factor, BPS * 1 hours + bound * (elapsed % 1 hours), BPS * 1 hours);
        uint256 high = Math.mulDiv(previous, factor, PRECISION);
        if (price > high) return high;
        // Rounds up: a falling price never moves further than allowed.
        uint256 low = Math.mulDiv(previous, PRECISION, factor, Math.Rounding.Ceil);
        return price < low ? low : price;
    }

    /// @dev `base` to the power `n`, 18 decimals, saturating at MAX_FACTOR.
    function _hourly(uint256 base, uint256 n) internal pure returns (uint256 factor) {
        factor = PRECISION;
        while (n != 0) {
            if (n & 1 != 0) {
                factor = Math.mulDiv(factor, base, PRECISION);
                if (factor >= MAX_FACTOR) return MAX_FACTOR;
            }
            n >>= 1;
            if (n != 0) base = Math.min(Math.mulDiv(base, base, PRECISION), MAX_FACTOR);
        }
    }

    function _isAdmin(
        address account
    ) internal view returns (bool) {
        return IProtocolRegistry(registry).hasRole(ADMIN, account);
    }
}
