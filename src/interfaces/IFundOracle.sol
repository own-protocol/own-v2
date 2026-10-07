// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundOracle — USD prices for fund basket assets and fund tokens
/// @notice One Chainlink-style aggregator per asset (real Chainlink feeds, or `FundPriceHub` feeds
///         for assets without one), normalised to 18 decimals.
///         A fund token's own market price (its pool TWAP, served by `FundTwapFeed`) is read
///         through the same surface, keyed by the fund token address.
interface IFundOracle {
    /// @notice Price source for one asset.
    /// @param aggregator   Chainlink `AggregatorV3`-compatible feed (USD per whole token).
    /// @param maxStaleness Maximum age of the latest answer, in seconds.
    struct Feed {
        address aggregator;
        uint32 maxStaleness;
    }

    /// @notice Emitted when an asset's feed is set or cleared (aggregator zero).
    /// @param asset        The priced token.
    /// @param aggregator   The aggregator (zero when cleared).
    /// @param maxStaleness Maximum answer age, in seconds.
    event FeedSet(address indexed asset, address aggregator, uint32 maxStaleness);

    /// @notice Caller does not hold the protocol ADMIN role.
    error NotAdmin();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice Staleness bound is zero.
    error InvalidStaleness();

    /// @notice The asset has no feed.
    /// @param asset The asset.
    error NoFeed(address asset);

    /// @notice The feed's latest answer is older than its staleness bound.
    /// @param asset The asset.
    error StalePrice(address asset);

    /// @notice The feed returned a non-positive answer.
    /// @param asset The asset.
    error InvalidPrice(address asset);

    /// @notice Set, replace or clear (aggregator zero) the feed for `asset`. Protocol ADMIN only.
    /// @param asset        The priced token.
    /// @param aggregator   The aggregator, or zero to clear.
    /// @param maxStaleness Maximum answer age, in seconds (ignored when clearing).
    function setFeed(address asset, address aggregator, uint32 maxStaleness) external;

    /// @notice USD price of one whole `asset`, 18 decimals. Reverts when missing, stale or invalid.
    /// @param asset The asset.
    /// @return The price.
    function price(
        address asset
    ) external view returns (uint256);

    /// @notice Non-reverting {price}.
    /// @param asset The asset.
    /// @return ok    Whether a fresh, positive price exists.
    /// @return value The price (zero when `ok` is false).
    function tryPrice(
        address asset
    ) external view returns (bool ok, uint256 value);

    /// @notice Whether `asset` has a feed.
    /// @param asset The asset.
    /// @return True if a feed is configured.
    function hasFeed(
        address asset
    ) external view returns (bool);

    /// @notice The feed configured for `asset`.
    /// @param asset The asset.
    /// @return The feed (zero aggregator when none).
    function feedOf(
        address asset
    ) external view returns (Feed memory);

    /// @notice The protocol registry whose ADMIN role administers this oracle.
    /// @return The registry.
    function registry() external view returns (address);
}
