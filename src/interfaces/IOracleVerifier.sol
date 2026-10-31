// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracleVerifier — price oracle read by EUSDManager
/// @notice Prices are read with {getPrice}. Signed in-house prices are pushed with {updatePrice}
///         (batched via multicall); Chainlink legs need no push.
interface IOracleVerifier {
    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when an in-house price is pushed.
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

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice Price is older than the asset's max staleness.
    /// @param priceTimestamp Price observation timestamp (unix seconds).
    /// @param maxStaleness   Max accepted age (seconds).
    error StalePrice(bytes32 asset, uint256 priceTimestamp, uint256 maxStaleness);
    /// @notice New price deviates from the reference price beyond the allowed band.
    /// @param reportedPrice New price (18 dec).
    /// @param lastPrice     Reference price (18 dec).
    /// @param maxDeviation  Allowed deviation (BPS).
    error PriceDeviationExceeded(bytes32 asset, uint256 reportedPrice, uint256 lastPrice, uint256 maxDeviation);
    /// @notice Price was signed by an address that is not an authorised signer.
    error UnauthorizedSigner(address signer);
    /// @notice Price is zero.
    error ZeroPrice();
    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice No usable price exists for the asset.
    error PriceNotAvailable(bytes32 asset);
    /// @notice The asset has no oracle config.
    error OracleConfigNotSet(bytes32 asset);
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();

    // ──────────────────────────────────────────────────────────
    //  Prices
    // ──────────────────────────────────────────────────────────

    /// @notice Return the latest price for an asset.
    /// @param asset Asset ticker (e.g. bytes32("SPY")).
    /// @return price     Price in 18 decimals.
    /// @return timestamp Timestamp of the price observation.
    function getPrice(
        bytes32 asset
    ) external view returns (uint256 price, uint256 timestamp);

    /// @notice Push a signed in-house price for an asset.
    /// @param asset     Asset ticker.
    /// @param priceData Encoded as (uint256 price, uint256 timestamp, uint8 v, bytes32 r, bytes32 s).
    function updatePrice(bytes32 asset, bytes calldata priceData) external;

    // ──────────────────────────────────────────────────────────
    //  Signers
    // ──────────────────────────────────────────────────────────

    /// @notice Add an authorised oracle signer.
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
}
