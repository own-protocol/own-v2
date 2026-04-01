// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";

/// @title MockOracleVerifier — Configurable oracle for unit tests
/// @notice Implements the push-model IOracleVerifier interface.
///         Prices are set directly via test helpers rather than signed data.
contract MockOracleVerifier is IOracleVerifier {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    struct AssetPrice {
        uint256 price;
        uint256 timestamp;
    }

    mapping(bytes32 => AssetPrice) private _prices;
    mapping(address => bool) private _signers;

    bool public forceStale;
    bool public forceInvalidSignature;
    bool public forceDeviation;

    // ──────────────────────────────────────────────────────────
    //  Test helpers — set prices directly
    // ──────────────────────────────────────────────────────────

    function setPrice(bytes32 asset, uint256 price, uint256 timestamp) external {
        _prices[asset] = AssetPrice(price, timestamp);
    }

    function setPrice(bytes32 asset, uint256 price) external {
        _prices[asset] = AssetPrice(price, block.timestamp);
    }

    function setForceStale(
        bool value
    ) external {
        forceStale = value;
    }

    function setForceInvalidSignature(
        bool value
    ) external {
        forceInvalidSignature = value;
    }

    function setForceDeviation(
        bool value
    ) external {
        forceDeviation = value;
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — push
    // ──────────────────────────────────────────────────────────

    function updatePriceFeeds(
        bytes calldata updateData
    ) external payable override {
        // In mock, decode as (bytes32[] assets, uint256[] prices, uint256[] timestamps)
        (bytes32[] memory assets, uint256[] memory prices, uint256[] memory timestamps) =
            abi.decode(updateData, (bytes32[], uint256[], uint256[]));

        for (uint256 i; i < assets.length; i++) {
            _prices[assets[i]] = AssetPrice(prices[i], timestamps[i]);
            emit PriceUpdated(assets[i], prices[i], timestamps[i]);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — read
    // ──────────────────────────────────────────────────────────

    function getPrice(
        bytes32 asset
    ) external view override returns (uint256 price, uint256 timestamp) {
        if (forceStale) revert StalePrice(asset, 0, 0);

        AssetPrice storage ap = _prices[asset];
        if (ap.price == 0) revert PriceNotAvailable(asset);
        return (ap.price, ap.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — verify (inline proof for force execution)
    // ──────────────────────────────────────────────────────────

    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external payable override returns (uint256 price, uint256 timestamp) {
        if (forceStale) revert StalePrice(asset, 0, 0);
        if (forceInvalidSignature) revert InvalidSignature();

        // In mock, priceData is just abi.encode(uint256 price, uint256 timestamp)
        (price, timestamp) = abi.decode(priceData, (uint256, uint256));
        if (price == 0) revert ZeroPrice();
    }

    /// @dev Session-aware variant — delegates to verifyPrice in mock (sessions are irrelevant).
    function verifyPriceForSession(
        bytes32 asset,
        bytes calldata priceData,
        uint8
    ) external payable override returns (uint256 price, uint256 timestamp) {
        return this.verifyPrice(asset, priceData);
    }

    /// @dev Mock always returns 0 fee — no ETH needed for test proofs.
    function verifyFee(
        bytes calldata
    ) external pure override returns (uint256) {
        return 0;
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — admin (no-op in mock)
    // ──────────────────────────────────────────────────────────

    function addSigner(
        address signer
    ) external override {
        _signers[signer] = true;
        emit SignerAdded(signer);
    }

    function removeSigner(
        address signer
    ) external override {
        _signers[signer] = false;
        emit SignerRemoved(signer);
    }

    function isSigner(
        address account
    ) external view override returns (bool) {
        return _signers[account];
    }

    function setAssetOracleConfig(bytes32, uint256, uint256) external override {}
}
