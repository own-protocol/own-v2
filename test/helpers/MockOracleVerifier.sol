// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";

/// @title MockOracleVerifier — Configurable oracle for unit tests
/// @notice Returns preset prices and market-open status. Supports simulating
///         staleness, deviation failures, and signer checks for negative tests.
contract MockOracleVerifier is IOracleVerifier {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    struct AssetPrice {
        uint256 price;
        uint256 timestamp;
        bool marketOpen;
    }

    mapping(bytes32 => AssetPrice) private _prices;
    mapping(bytes32 => uint256) private _sequenceNumbers;
    mapping(address => bool) private _signers;

    /// @notice When true, `verifyPrice` always reverts with StalePrice.
    bool public forceStale;

    /// @notice When true, `verifyPrice` always reverts with InvalidSignature.
    bool public forceInvalidSignature;

    /// @notice When true, `verifyPrice` always reverts with PriceDeviationExceeded.
    bool public forceDeviation;

    // ──────────────────────────────────────────────────────────
    //  Test helpers — set prices
    // ──────────────────────────────────────────────────────────

    /// @notice Set the price that `verifyPrice` will return for an asset.
    function setPrice(bytes32 asset, uint256 price, uint256 timestamp, bool marketOpen) external {
        _prices[asset] = AssetPrice(price, timestamp, marketOpen);
    }

    /// @notice Convenience: set price with `block.timestamp` and marketOpen=true.
    function setPrice(bytes32 asset, uint256 price) external {
        _prices[asset] = AssetPrice(price, block.timestamp, true);
    }

    /// @notice Toggle forced staleness revert.
    function setForceStale(
        bool value
    ) external {
        forceStale = value;
    }

    /// @notice Toggle forced invalid signature revert.
    function setForceInvalidSignature(
        bool value
    ) external {
        forceInvalidSignature = value;
    }

    /// @notice Toggle forced deviation revert.
    function setForceDeviation(
        bool value
    ) external {
        forceDeviation = value;
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier implementation
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function verifyPrice(
        bytes32 asset,
        bytes calldata /* priceData */
    ) external override returns (uint256 price, uint256 timestamp, bool marketOpen) {
        if (forceStale) revert StalePrice(asset, 0, 0);
        if (forceInvalidSignature) revert InvalidSignature();
        if (forceDeviation) revert PriceDeviationExceeded(asset, 0, 0, 0);

        AssetPrice storage ap = _prices[asset];
        require(ap.price > 0, "MockOracleVerifier: price not set");

        price = ap.price;
        timestamp = ap.timestamp;
        marketOpen = ap.marketOpen;

        _sequenceNumbers[asset]++;

        emit PriceVerified(asset, price, timestamp, marketOpen);
    }

    /// @inheritdoc IOracleVerifier
    function addSigner(
        address signer
    ) external override {
        _signers[signer] = true;
        emit SignerAdded(signer);
    }

    /// @inheritdoc IOracleVerifier
    function removeSigner(
        address signer
    ) external override {
        _signers[signer] = false;
        emit SignerRemoved(signer);
    }

    /// @inheritdoc IOracleVerifier
    function isSigner(
        address account
    ) external view override returns (bool) {
        return _signers[account];
    }

    /// @inheritdoc IOracleVerifier
    function setAssetOracleConfig(bytes32 asset, uint256 maxStaleness, uint256 maxDeviation) external override {
        emit AssetOracleConfigUpdated(asset, maxStaleness, maxDeviation);
    }

    /// @inheritdoc IOracleVerifier
    function getLastPrice(
        bytes32 asset
    ) external view override returns (uint256 price, uint256 timestamp) {
        AssetPrice storage ap = _prices[asset];
        return (ap.price, ap.timestamp);
    }

    /// @inheritdoc IOracleVerifier
    function getSequenceNumber(
        bytes32 asset
    ) external view override returns (uint256) {
        return _sequenceNumbers[asset];
    }
}
