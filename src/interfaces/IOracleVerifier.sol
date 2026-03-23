// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracleVerifier — Backend-agnostic price verification
/// @notice Accepts opaque price data, verifies it against the configured
///         backend (signed oracle for MVP), and returns a validated price,
///         timestamp, and market-open status.
///
/// @dev Downstream contracts (OwnMarket, LiquidationEngine) call only
///      `verifyPrice()`. They never know which backend produced the data.
///      Swapping backends requires deploying a new verifier — no changes
///      to downstream contracts.
interface IOracleVerifier {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted after a price is successfully verified.
    /// @param asset      Asset ticker.
    /// @param price      Verified price (18 decimals).
    /// @param timestamp  Price timestamp.
    /// @param marketOpen Whether the market is open for this asset.
    event PriceVerified(bytes32 indexed asset, uint256 price, uint256 timestamp, bool marketOpen);

    /// @notice Emitted when an authorised signer is added.
    /// @param signer The new signer address.
    event SignerAdded(address indexed signer);

    /// @notice Emitted when an authorised signer is removed.
    /// @param signer The removed signer address.
    event SignerRemoved(address indexed signer);

    /// @notice Emitted when per-asset oracle configuration is updated.
    /// @param asset        Asset ticker.
    /// @param maxStaleness New max price age in seconds.
    /// @param maxDeviation New max price deviation in BPS.
    event AssetOracleConfigUpdated(bytes32 indexed asset, uint256 maxStaleness, uint256 maxDeviation);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice The price is older than the allowed staleness window.
    error StalePrice(bytes32 asset, uint256 priceTimestamp, uint256 maxStaleness);

    /// @notice The price deviates too far from the last known price.
    error PriceDeviationExceeded(bytes32 asset, uint256 reportedPrice, uint256 lastPrice, uint256 maxDeviation);

    /// @notice The ECDSA signature is malformed or invalid.
    error InvalidSignature();

    /// @notice The recovered signer is not authorised.
    error UnauthorizedSigner(address signer);

    /// @notice The sequence number is not strictly increasing.
    error InvalidSequenceNumber(bytes32 asset, uint256 provided, uint256 expected);

    /// @notice A zero price was submitted.
    error ZeroPrice();

    /// @notice The chain ID in the signed message does not match.
    error ChainIdMismatch(uint256 expected, uint256 provided);

    /// @notice The contract address in the signed message does not match.
    error ContractAddressMismatch(address expected, address provided);

    /// @notice A zero address was provided.
    error ZeroAddress();

    // ──────────────────────────────────────────────────────────
    //  Core function
    // ──────────────────────────────────────────────────────────

    /// @notice Verify price data for an asset.
    /// @dev Not `view` because it may update internal state (e.g. sequence
    ///      numbers) to prevent replay. The `priceData` format is opaque —
    ///      each backend implementation decodes it differently.
    /// @param asset     Asset ticker (e.g. bytes32("TSLA")).
    /// @param priceData Backend-specific encoded price payload.
    /// @return price     Verified price in 18 decimals.
    /// @return timestamp Timestamp of the price observation.
    /// @return marketOpen Whether the asset's market is currently open.
    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external returns (uint256 price, uint256 timestamp, bool marketOpen);

    // ──────────────────────────────────────────────────────────
    //  Signer management (admin)
    // ──────────────────────────────────────────────────────────

    /// @notice Add an authorised oracle signer.
    /// @param signer Address to authorise.
    function addSigner(
        address signer
    ) external;

    /// @notice Remove an authorised oracle signer.
    /// @param signer Address to de-authorise.
    function removeSigner(
        address signer
    ) external;

    /// @notice Check whether an address is an authorised signer.
    /// @param account Address to check.
    /// @return True if authorised.
    function isSigner(
        address account
    ) external view returns (bool);

    // ──────────────────────────────────────────────────────────
    //  Per-asset configuration (admin)
    // ──────────────────────────────────────────────────────────

    /// @notice Set the staleness and deviation limits for an asset.
    /// @param asset        Asset ticker.
    /// @param maxStaleness Max acceptable price age in seconds.
    /// @param maxDeviation Max deviation from last known price, in BPS.
    function setAssetOracleConfig(bytes32 asset, uint256 maxStaleness, uint256 maxDeviation) external;

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @notice Return the last verified price for an asset.
    /// @param asset Asset ticker.
    /// @return price     Last verified price (18 decimals).
    /// @return timestamp Timestamp of the last verification.
    function getLastPrice(
        bytes32 asset
    ) external view returns (uint256 price, uint256 timestamp);

    /// @notice Return the current sequence number for an asset.
    /// @param asset Asset ticker.
    /// @return The latest accepted sequence number.
    function getSequenceNumber(
        bytes32 asset
    ) external view returns (uint256);
}
