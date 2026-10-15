// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title FundOracle — per-asset USD price registry for Own Curated Funds
/// @notice See {IFundOracle}. Never reads onchain spot prices: every value comes from an
///         admin-configured aggregator, or a ticker on the protocol's in-house oracle verifier, with
///         a staleness bound.
/// @dev Administered by the ProtocolRegistry's FUND_ADMIN role. An asset has an aggregator or a
///      ticker, never both, so reads check the aggregator's slot first and touch the ticker's only
///      without one. An aggregator's decimals are read once, when its feed is set. The verifier is
///      resolved from the registry on every read, so it follows the registry's INHOUSE_ORACLE slot.
contract FundOracle is IFundOracle {
    bytes32 private constant ADMIN = keccak256("FUND_ADMIN");

    struct StoredFeed {
        address aggregator;
        uint32 maxStaleness;
        uint8 decimals;
        bytes32 ticker;
    }

    /// @inheritdoc IFundOracle
    address public immutable override registry;

    mapping(address asset => StoredFeed) private _feeds;

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
        _feeds[asset] = StoredFeed({
            aggregator: aggregator,
            maxStaleness: maxStaleness,
            decimals: IAggregatorV3(aggregator).decimals(),
            ticker: bytes32(0)
        });
        emit FeedSet(asset, aggregator, maxStaleness);
    }

    /// @inheritdoc IFundOracle
    function setVerifierFeed(address asset, bytes32 ticker, uint32 maxStaleness) external override onlyAdmin {
        if (asset == address(0)) revert ZeroAddress();
        if (ticker == bytes32(0)) revert InvalidTicker();
        if (maxStaleness == 0) revert InvalidStaleness();
        _feeds[asset] = StoredFeed({aggregator: address(0), maxStaleness: maxStaleness, decimals: 18, ticker: ticker});
        emit VerifierFeedSet(asset, ticker, maxStaleness);
    }

    /// @inheritdoc IFundOracle
    function price(
        address asset
    ) external view override returns (uint256) {
        StoredFeed storage feed = _feeds[asset];
        address aggregator = feed.aggregator;
        if (aggregator == address(0)) {
            bytes32 ticker = feed.ticker;
            if (ticker == bytes32(0)) revert NoFeed(asset);
            (uint256 value, uint256 at) = _verifier().getPrice(ticker);
            if (value == 0) revert InvalidPrice(asset);
            if (at > block.timestamp || block.timestamp - at > feed.maxStaleness) revert StalePrice(asset);
            return value;
        }
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(aggregator).latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > feed.maxStaleness) revert StalePrice(asset);
        return _normalise(uint256(answer), feed.decimals);
    }

    /// @inheritdoc IFundOracle
    function tryPrice(
        address asset
    ) external view override returns (bool ok, uint256 value) {
        StoredFeed storage feed = _feeds[asset];
        address aggregator = feed.aggregator;
        if (aggregator == address(0)) return _tryVerifier(feed);
        try IAggregatorV3(aggregator).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > feed.maxStaleness) {
                return (false, 0);
            }
            return (true, _normalise(uint256(answer), feed.decimals));
        } catch {
            return (false, 0);
        }
    }

    /// @inheritdoc IFundOracle
    function lastPrice(
        address asset
    ) external view override returns (uint256) {
        StoredFeed storage feed = _feeds[asset];
        address aggregator = feed.aggregator;
        if (aggregator == address(0)) {
            bytes32 ticker = feed.ticker;
            if (ticker == bytes32(0)) return 0;
            try _verifier().getPrice(ticker) returns (uint256 value, uint256) {
                return value;
            } catch {
                return 0;
            }
        }
        try IAggregatorV3(aggregator).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            return answer > 0 ? _normalise(uint256(answer), feed.decimals) : 0;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc IFundOracle
    function hasFeed(
        address asset
    ) external view override returns (bool) {
        StoredFeed storage feed = _feeds[asset];
        return feed.aggregator != address(0) || feed.ticker != bytes32(0);
    }

    /// @inheritdoc IFundOracle
    function feedOf(
        address asset
    ) external view override returns (Feed memory) {
        StoredFeed storage feed = _feeds[asset];
        return Feed({aggregator: feed.aggregator, maxStaleness: feed.maxStaleness, ticker: feed.ticker});
    }

    function _verifier() private view returns (IOracleVerifier) {
        return IOracleVerifier(IProtocolRegistry(registry).inhouseOracle());
    }

    function _tryVerifier(
        StoredFeed storage feed
    ) private view returns (bool, uint256) {
        bytes32 ticker = feed.ticker;
        if (ticker == bytes32(0)) return (false, 0);
        IOracleVerifier v = _verifier();
        // A call to an address without code would revert outside the try.
        if (address(v).code.length == 0) return (false, 0);
        try v.getPrice(ticker) returns (uint256 p, uint256 updatedAt) {
            if (p == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > feed.maxStaleness) {
                return (false, 0);
            }
            return (true, p);
        } catch {
            return (false, 0);
        }
    }

    function _normalise(uint256 answer, uint8 dec) private pure returns (uint256) {
        if (dec == 18) return answer;
        if (dec < 18) return answer * 10 ** (18 - dec);
        return answer / 10 ** (dec - 18);
    }
}
