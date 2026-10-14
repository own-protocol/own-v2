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
///         Only the keeper pushes. An optional move bound, `maxMoveBps` per hour since the asset's
///         last push (compounding, pro rata within the hour), holds every push: a price beyond it
///         is stored at the bound instead (and reported), so a genuine jump catches up over a few
///         hours and repeated pushes gain nothing. The admin sets the bound and the keeper.
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

    /// @notice Emitted when a pushed price moved more than the bound allows and is stored at the
    ///         bound instead.
    /// @param asset  The asset.
    /// @param price  The price pushed.
    /// @param stored The price stored.
    event PriceClamped(address indexed asset, uint256 price, uint256 stored);

    /// @notice Emitted when the keeper changes.
    /// @param keeper The new keeper.
    event KeeperSet(address keeper);

    /// @notice Emitted when the move bound changes.
    /// @param maxMoveBps The new bound per hour (0 for none).
    event MaxMoveSet(uint16 maxMoveBps);

    /// @notice Emitted when an asset's adapter is deployed.
    /// @param asset The asset.
    /// @param feed  Its adapter.
    event FeedCreated(address indexed asset, address feed);

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is not the keeper.
    error NotKeeper();

    /// @notice The asset and price lists differ in length.
    error LengthMismatch();

    /// @notice A price is zero or does not fit.
    error InvalidPrice();

    /// @notice The asset already has an adapter.
    error FeedExists();

    /// @notice Store USD prices (18 decimals per whole token). Keeper only; a price that breaks
    ///         the move bound is stored at the bound.
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

    /// @notice Set the move bound. Admin only.
    /// @param maxMoveBps_ Largest move per hour since an asset's last push, in basis points (0 for
    ///                    none).
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

    /// @notice The move bound per hour since an asset's last push (0 for none).
    /// @return The bound, in basis points.
    function maxMoveBps() external view returns (uint16);

    /// @notice ProtocolRegistry whose ADMIN role administers the hub.
    /// @return The registry.
    function registry() external view returns (address);
}
