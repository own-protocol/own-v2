// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundOracle — USD prices for fund basket assets and fund tokens
/// @notice One Chainlink-style aggregator per asset (keeper-pushed TWAP feeds such as
///         `MoneyPriceFeed`, or real Chainlink feeds for stock tokens), normalised to 18 decimals.
///         A fund token's own market price (the TWAP of its pool, pushed by our keeper) is read
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

    /// @notice Emitted when a two-step ownership transfer starts.
    /// @param newOwner The pending owner.
    event OwnershipTransferStarted(address indexed newOwner);

    /// @notice Emitted when ownership changes.
    /// @param previousOwner The previous owner.
    /// @param newOwner      The new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Caller is not the owner.
    error NotOwner();

    /// @notice Caller is not the pending owner.
    error NotPendingOwner();

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

    /// @notice Set, replace or clear (aggregator zero) the feed for `asset`. Owner only.
    /// @param asset        The priced token.
    /// @param aggregator   The aggregator, or zero to clear.
    /// @param maxStaleness Maximum answer age, in seconds (ignored when clearing).
    function setFeed(
        address asset,
        address aggregator,
        uint32 maxStaleness
    ) external;

    /// @notice Start a two-step ownership transfer. Owner only.
    /// @param newOwner The pending owner.
    function transferOwnership(
        address newOwner
    ) external;

    /// @notice Accept a pending ownership transfer. Pending owner only.
    function acceptOwnership() external;

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

    /// @notice Current owner.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice Pending owner of a two-step transfer.
    /// @return The pending owner.
    function pendingOwner() external view returns (address);
}
