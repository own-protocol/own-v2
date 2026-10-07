// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundPriceHub — keeper-pushed USD prices for fund assets without a Chainlink feed
/// @notice One contract holds the prices of every such asset (for example Pons-launched tokens):
///         own-oracle samples each token's pool, prices the pool's pair through its own signed
///         marks, signs a TWAP, and own-keeper verifies the signature off-chain and pushes every
///         price in one transaction. Each asset gets a {FundPriceFeed} adapter (Chainlink
///         `AggregatorV3` surface) that the FundOracle registers like any other feed, with its
///         own staleness bound.
///
///         An optional per-push move bound skips (and reports) a keeper price that moved more
///         than `maxMoveBps` from the asset's last price; the admin's pushes are never bounded,
///         so a genuine jump is re-anchored by the admin.
interface IFundPriceHub {
    /// @notice An asset's latest price.
    /// @param price     USD per whole token, 18 decimals.
    /// @param updatedAt When it was pushed.
    struct Price {
        uint192 price;
        uint64 updatedAt;
    }

    /// @notice Emitted when a price is stored.
    /// @param asset The asset.
    /// @param price USD per whole token, 18 decimals.
    event PricePushed(address indexed asset, uint256 price);

    /// @notice Emitted when a keeper price is skipped for moving more than the bound.
    /// @param asset    The asset.
    /// @param price    The skipped price.
    /// @param previous The price kept.
    event PriceRejected(address indexed asset, uint256 price, uint256 previous);

    /// @notice Emitted when the keeper changes.
    /// @param keeper The new keeper.
    event KeeperSet(address keeper);

    /// @notice Emitted when the move bound changes.
    /// @param maxMoveBps The new bound (0 for none).
    event MaxMoveSet(uint16 maxMoveBps);

    /// @notice Emitted when an asset's adapter is deployed.
    /// @param asset The asset.
    /// @param feed  Its adapter.
    event FeedCreated(address indexed asset, address feed);

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is neither the keeper nor the admin.
    error NotKeeper();

    /// @notice The asset and price lists differ in length.
    error LengthMismatch();

    /// @notice A price is zero or does not fit.
    error InvalidPrice();

    /// @notice The asset already has an adapter.
    error FeedExists();

    /// @notice Store USD prices (18 decimals per whole token). Keeper or admin; keeper prices
    ///         that break the move bound are skipped.
    /// @param assets The assets.
    /// @param prices Their prices.
    function pushPrices(address[] calldata assets, uint256[] calldata prices) external;

    /// @notice Deploy the price adapter for `asset`. Admin only.
    /// @param asset The asset.
    /// @return feed The adapter, to register in the FundOracle.
    function createFeed(
        address asset
    ) external returns (address feed);

    /// @notice Set the keeper. Admin only.
    /// @param keeper_ The keeper.
    function setKeeper(
        address keeper_
    ) external;

    /// @notice Set the per-push move bound for keeper prices. Admin only.
    /// @param maxMoveBps_ Largest move from the last price, in basis points (0 for none).
    function setMaxMove(
        uint16 maxMoveBps_
    ) external;

    /// @notice An asset's latest price.
    /// @param asset The asset.
    /// @return price     USD per whole token, 18 decimals (0 before the first push).
    /// @return updatedAt When it was pushed.
    function priceOf(
        address asset
    ) external view returns (uint256 price, uint256 updatedAt);

    /// @notice An asset's adapter.
    /// @param asset The asset.
    /// @return The adapter (zero if none).
    function feedOf(
        address asset
    ) external view returns (address);

    /// @notice The keeper.
    /// @return The keeper.
    function keeper() external view returns (address);

    /// @notice The per-push move bound for keeper prices (0 for none).
    /// @return The bound, in basis points.
    function maxMoveBps() external view returns (uint16);

    /// @notice ProtocolRegistry whose ADMIN role administers the hub.
    /// @return The registry.
    function registry() external view returns (address);
}
