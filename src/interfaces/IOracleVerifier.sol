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
    event PriceUpdated(bytes32 indexed asset, uint256 price, uint256 timestamp);

    /// @notice Emitted when an authorised signer is added.
    event SignerAdded(address indexed signer);

    /// @notice Emitted when an authorised signer is removed.
    event SignerRemoved(address indexed signer);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error StalePrice(bytes32 asset, uint256 priceTimestamp, uint256 maxStaleness);
    error PriceDeviationExceeded(bytes32 asset, uint256 reportedPrice, uint256 lastPrice, uint256 maxDeviation);
    error InvalidSignature();
    error UnauthorizedSigner(address signer);
    error ZeroPrice();
    error ZeroAddress();
    error PriceNotAvailable(bytes32 asset);

    // ──────────────────────────────────────────────────────────
    //  Push — update price feeds (keeper / signer)
    // ──────────────────────────────────────────────────────────

    /// @notice Push one or more price updates on-chain.
    ///         For Pyth: wraps pyth.updatePriceFeeds(). Caller may need to send ETH for Pyth fees.
    ///         For in-house: verifies signatures and stores prices.
    /// @param updateData Backend-specific encoded price update payload.
    function updatePriceFeeds(bytes calldata updateData) external payable;

    // ──────────────────────────────────────────────────────────
    //  Read — consume cached prices (view)
    // ──────────────────────────────────────────────────────────

    /// @notice Return the latest cached price for an asset.
    /// @param asset Asset ticker (e.g. bytes32("TSLA")).
    /// @return price     Price in 18 decimals.
    /// @return timestamp Timestamp of the price observation.
    function getPrice(bytes32 asset) external view returns (uint256 price, uint256 timestamp);

    // ──────────────────────────────────────────────────────────
    //  Verify — inline price proof (force execution only)
    // ──────────────────────────────────────────────────────────

    /// @notice Verify a signed price proof inline. Used by force execution to
    ///         prove a price existed at a specific timestamp without requiring
    ///         it to be pre-pushed on-chain.
    /// @param asset     Asset ticker.
    /// @param priceData Backend-specific encoded signed price proof.
    /// @return price     Verified price in 18 decimals.
    /// @return timestamp Timestamp of the price observation.
    function verifyPrice(bytes32 asset, bytes calldata priceData)
        external
        view
        returns (uint256 price, uint256 timestamp);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Add an authorised oracle signer (in-house oracle only).
    function addSigner(address signer) external;

    /// @notice Remove an authorised oracle signer.
    function removeSigner(address signer) external;

    /// @notice Check whether an address is an authorised signer.
    function isSigner(address account) external view returns (bool);

    /// @notice Set the staleness and deviation limits for an asset.
    function setAssetOracleConfig(bytes32 asset, uint256 maxStaleness, uint256 maxDeviation) external;
}
