// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title FundOracle — per-asset USD price registry for Own Curated Funds
/// @notice See {IFundOracle}. Never reads onchain spot prices: every value comes from an
///         admin-configured aggregator with a staleness bound.
/// @dev Administered by the ProtocolRegistry's ADMIN role.
contract FundOracle is IFundOracle {
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @inheritdoc IFundOracle
    address public immutable override registry;

    mapping(address asset => Feed) private _feeds;

    modifier onlyAdmin() {
        if (!IProtocolRegistry(registry).hasRole(ADMIN, msg.sender)) revert NotAdmin();
        _;
    }

    constructor(
        address registry_
    ) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @inheritdoc IFundOracle
    function setFeed(address asset, address aggregator, uint32 maxStaleness) external override onlyAdmin {
        if (asset == address(0)) revert ZeroAddress();
        if (aggregator == address(0)) {
            delete _feeds[asset];
            emit FeedSet(asset, address(0), 0);
            return;
        }
        if (maxStaleness == 0) revert InvalidStaleness();
        _feeds[asset] = Feed({aggregator: aggregator, maxStaleness: maxStaleness});
        emit FeedSet(asset, aggregator, maxStaleness);
    }

    /// @inheritdoc IFundOracle
    function price(
        address asset
    ) external view override returns (uint256) {
        Feed memory feed = _feeds[asset];
        if (feed.aggregator == address(0)) revert NoFeed(asset);
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed.aggregator).latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > feed.maxStaleness) revert StalePrice(asset);
        return _normalise(uint256(answer), IAggregatorV3(feed.aggregator).decimals());
    }

    /// @inheritdoc IFundOracle
    function tryPrice(
        address asset
    ) external view override returns (bool ok, uint256 value) {
        Feed memory feed = _feeds[asset];
        if (feed.aggregator == address(0)) return (false, 0);
        try IAggregatorV3(feed.aggregator).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > feed.maxStaleness) {
                return (false, 0);
            }
            try IAggregatorV3(feed.aggregator).decimals() returns (uint8 dec) {
                return (true, _normalise(uint256(answer), dec));
            } catch {
                return (false, 0);
            }
        } catch {
            return (false, 0);
        }
    }

    /// @inheritdoc IFundOracle
    function hasFeed(
        address asset
    ) external view override returns (bool) {
        return _feeds[asset].aggregator != address(0);
    }

    /// @inheritdoc IFundOracle
    function feedOf(
        address asset
    ) external view override returns (Feed memory) {
        return _feeds[asset];
    }

    function _normalise(uint256 answer, uint8 dec) private pure returns (uint256) {
        if (dec == 18) return answer;
        if (dec < 18) return answer * 10 ** (18 - dec);
        return answer / 10 ** (dec - 18);
    }
}
