// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracleVerifier — Backend-agnostic price oracle
/// @notice Unified interface for both Pyth and in-house oracle backends.
///         Prices are pushed on-chain by keepers/signers via updatePriceFeeds(),
///         then read by consumers via getPrice(). The verifyPrice() function is
///         retained for force execution proofs where inline verification is needed.
interface IOracleVerifier {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a price feed is updated.
    /// @param asset     Asset ticker.
    /// @param price     New price (18 dec).
    /// @param timestamp Price observation timestamp (unix seconds).
    event PriceUpdated(bytes32 indexed asset, uint256 price, uint256 timestamp);

    /// @notice Emitted when an authorised signer is added.
    /// @param signer Newly authorised oracle signer.
    event SignerAdded(address indexed signer);

    /// @notice Emitted when an authorised signer is removed.
    /// @param signer Signer whose authorisation was revoked.
    event SignerRemoved(address indexed signer);

    /// @notice Emitted when an asset's oracle bounds are configured (in-house oracle only).
    /// @param asset        Asset ticker.
    /// @param maxStaleness Max accepted price age (seconds).
    /// @param maxDeviation Max accepted deviation from the last price (BPS).
    event AssetOracleConfigSet(bytes32 indexed asset, uint256 maxStaleness, uint256 maxDeviation);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Cached/proven price is older than the asset's max staleness.
    /// @param priceTimestamp Price observation timestamp (unix seconds).
    /// @param maxStaleness   Max accepted age (seconds).
    error StalePrice(bytes32 asset, uint256 priceTimestamp, uint256 maxStaleness);
    /// @notice New price deviates from the last cached price beyond the allowed band.
    /// @param reportedPrice New price (18 dec).
    /// @param lastPrice     Previous cached price (18 dec).
    /// @param maxDeviation  Allowed deviation (BPS).
    error PriceDeviationExceeded(bytes32 asset, uint256 reportedPrice, uint256 lastPrice, uint256 maxDeviation);
    /// @notice Price was signed by an address that is not an authorised signer.
    error UnauthorizedSigner(address signer);
    /// @notice Price is zero.
    error ZeroPrice();
    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice No cached price exists for the asset.
    error PriceNotAvailable(bytes32 asset);
    /// @notice The asset has no oracle config (staleness/deviation bounds unset).
    error OracleConfigNotSet(bytes32 asset);
    /// @notice Oracle config is invalid (zero staleness or deviation).
    error InvalidOracleConfig();
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();

    // ──────────────────────────────────────────────────────────
    //  Push — update price feeds (keeper / signer)
    // ──────────────────────────────────────────────────────────

    /// @notice Push one or more price updates on-chain.
    ///         For Pyth: wraps pyth.updatePriceFeeds(). Caller may need to send ETH for Pyth fees.
    ///         For in-house: verifies signatures and stores prices.
    /// @param updateData Backend-specific encoded price update payload.
    function updatePriceFeeds(
        bytes calldata updateData
    ) external payable;

    // ──────────────────────────────────────────────────────────
    //  Read — consume cached prices (view)
    // ──────────────────────────────────────────────────────────

    /// @notice Return the latest cached price for an asset.
    /// @param asset Asset ticker (e.g. bytes32("TSLA")).
    /// @return price     Price in 18 decimals.
    /// @return timestamp Timestamp of the price observation.
    function getPrice(
        bytes32 asset
    ) external view returns (uint256 price, uint256 timestamp);

    // ──────────────────────────────────────────────────────────
    //  Verify — inline price proof (force execution only)
    // ──────────────────────────────────────────────────────────

    /// @notice Verify a signed price proof inline. Used by force execution to
    ///         prove a price existed at a specific timestamp without requiring
    ///         it to be pre-pushed on-chain.
    ///         For Pyth: caller must send ETH to cover parsePriceFeedUpdates fee.
    ///         For in-house: no ETH required (pure ECDSA verification).
    /// @param asset     Asset ticker.
    /// @param priceData Backend-specific encoded signed price proof.
    /// @return price     Verified price in 18 decimals.
    /// @return timestamp Timestamp of the price observation.
    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external payable returns (uint256 price, uint256 timestamp);

    /// @notice Verify a signed price proof for a specific trading session.
    ///         Used by confirmOrder to support multi-session price feeds (e.g. Pyth equity feeds
    ///         have separate feeds for regular, pre-market, post-market, and overnight sessions).
    ///         For in-house oracle: sessionId is ignored (delegates to verifyPrice).
    /// @param asset     Asset ticker.
    /// @param priceData Backend-specific encoded signed price proof.
    /// @param sessionId Trading session index (0=regular, 1=pre-market, 2=post-market, 3=overnight).
    /// @return price     Verified price in 18 decimals.
    /// @return timestamp Timestamp of the price observation.
    function verifyPriceForSession(
        bytes32 asset,
        bytes calldata priceData,
        uint8 sessionId
    ) external payable returns (uint256 price, uint256 timestamp);

    /// @notice Return the ETH fee required to call verifyPrice for the given priceData.
    ///         For Pyth: returns pyth.getUpdateFee(updateData).
    ///         For in-house: always returns 0.
    /// @param priceData The same priceData that will be passed to verifyPrice.
    function verifyFee(
        bytes calldata priceData
    ) external view returns (uint256);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Add an authorised oracle signer (in-house oracle only).
    function addSigner(
        address signer
    ) external;

    /// @notice Remove an authorised oracle signer.
    function removeSigner(
        address signer
    ) external;

    /// @notice Check whether an address is an authorised signer.
    function isSigner(
        address account
    ) external view returns (bool);

    /// @notice Set the staleness and deviation limits for an asset.
    function setAssetOracleConfig(bytes32 asset, uint256 maxStaleness, uint256 maxDeviation) external;

    /// @notice Return the staleness and deviation limits for an asset.
    function getAssetOracleConfig(
        bytes32 asset
    ) external view returns (uint256 maxStaleness, uint256 maxDeviation);
}
