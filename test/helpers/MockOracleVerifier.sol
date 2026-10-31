// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";

/// @title MockOracleVerifier — Configurable oracle for unit tests
/// @notice Prices are set directly via test helpers rather than signed data.
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
    /// @dev When set, getPrice returns (0, now) instead of reverting — mimics a Pyth feed that
    ///      normalises (via exponent truncation) to exactly zero, exercising consumers' `price == 0` guards.
    bool public forceZeroPrice;

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

    function setForceZeroPrice(
        bool value
    ) external {
        forceZeroPrice = value;
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — push
    // ──────────────────────────────────────────────────────────

    /// @dev In mock, priceData is abi.encode(uint256 price, uint256 timestamp); no signature check.
    function updatePrice(bytes32 asset, bytes calldata priceData) external override {
        (uint256 price, uint256 timestamp) = abi.decode(priceData, (uint256, uint256));
        _prices[asset] = AssetPrice(price, timestamp);
        emit PriceUpdated(asset, price, timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — read
    // ──────────────────────────────────────────────────────────

    function getPrice(
        bytes32 asset
    ) external view override returns (uint256 price, uint256 timestamp) {
        if (forceStale) revert StalePrice(asset, 0, 0);
        if (forceZeroPrice) return (0, block.timestamp);

        AssetPrice storage ap = _prices[asset];
        if (ap.price == 0) revert PriceNotAvailable(asset);
        return (ap.price, ap.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — signers
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
}
