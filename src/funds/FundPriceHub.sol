// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundPriceHub} from "../interfaces/IFundPriceHub.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {FundPriceFeed} from "./FundPriceFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundPriceHub — keeper-pushed USD prices for fund assets without a Chainlink feed
/// @notice See {IFundPriceHub}.
/// @dev Administered by the ProtocolRegistry's ADMIN role.
contract FundPriceHub is IFundPriceHub {
    bytes32 private constant ADMIN = keccak256("ADMIN");

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
        bool admin = _isAdmin(msg.sender);
        if (msg.sender != keeper && !admin) revert NotKeeper();
        if (assets.length != prices.length) revert LengthMismatch();
        uint256 bound = admin ? 0 : maxMoveBps;
        for (uint256 i; i < assets.length; ++i) {
            uint256 price = prices[i];
            if (price == 0 || price > type(uint192).max) revert InvalidPrice();
            Price storage p = _prices[assets[i]];
            uint256 previous = p.price;
            if (bound != 0 && previous != 0) {
                uint256 move = price > previous ? price - previous : previous - price;
                if (move > Math.mulDiv(previous, bound, BPS)) {
                    emit PriceRejected(assets[i], price, previous);
                    continue;
                }
            }
            p.price = uint192(price);
            p.updatedAt = uint64(block.timestamp);
            emit PricePushed(assets[i], price);
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

    function _isAdmin(
        address account
    ) internal view returns (bool) {
        return IProtocolRegistry(registry).hasRole(ADMIN, account);
    }
}
