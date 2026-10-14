// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundOracle — USD prices for fund basket assets and fund tokens
/// @notice One source per asset, normalised to 18 decimals: a Chainlink-style aggregator (`FundPriceHub`
///         feeds for assets without Chainlink), or a ticker on the protocol's in-house oracle verifier
///         (the registry's INHOUSE_ORACLE: Chainlink while the feed is live, the in-house signer within
///         a band of the last Chainlink answer while it is silent, e.g. stocks over the weekend).
///         A fund token's own market price (its pool TWAP, served by `FundTwapFeed`) is read
///         through the same surface, keyed by the fund token address.
interface IFundOracle {
    /// @notice Price source for one asset.
    /// @param aggregator   Chainlink `AggregatorV3`-compatible feed (USD per whole token); zero for a
    ///                     verifier feed.
    /// @param maxStaleness Maximum age of the latest answer, in seconds.
    /// @param ticker       Ticker on the in-house oracle verifier; zero for an aggregator feed.
    struct Feed {
        address aggregator;
        uint32 maxStaleness;
        bytes32 ticker;
    }

    /// @notice Emitted when an asset's feed is set or cleared (aggregator zero).
    /// @param asset        The priced token.
    /// @param aggregator   The aggregator (zero when cleared).
    /// @param maxStaleness Maximum answer age, in seconds.
    event FeedSet(address indexed asset, address aggregator, uint32 maxStaleness);

    /// @notice Emitted when an asset is priced from the in-house oracle verifier.
    /// @param asset        The priced token.
    /// @param ticker       Its ticker on the verifier.
    /// @param maxStaleness Maximum price age, in seconds.
    event VerifierFeedSet(address indexed asset, bytes32 ticker, uint32 maxStaleness);

    /// @notice Caller does not hold the protocol ADMIN role.
    error NotAdmin();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice Staleness bound is zero.
    error InvalidStaleness();

    /// @notice Verifier ticker is zero.
    error InvalidTicker();

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
    ///         The aggregator's decimals are read here, so set the feed again if they ever change.
    /// @param asset        The priced token.
    /// @param aggregator   The aggregator, or zero to clear.
    /// @param maxStaleness Maximum answer age, in seconds (ignored when clearing).
    function setFeed(address asset, address aggregator, uint32 maxStaleness) external;

    /// @notice Price `asset` from `ticker` on the in-house oracle verifier (the registry's
    ///         INHOUSE_ORACLE, resolved on every read), replacing any aggregator. Protocol ADMIN only.
    ///         The ticker must be configured on the verifier. Clear it with {setFeed} and a zero
    ///         aggregator.
    /// @param asset        The priced token.
    /// @param ticker       Its ticker on the verifier (e.g. bytes32("TSLA")).
    /// @param maxStaleness Maximum age of the verifier's price, in seconds.
    function setVerifierFeed(address asset, bytes32 ticker, uint32 maxStaleness) external;

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
