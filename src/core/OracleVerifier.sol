// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title OracleVerifier — Signed oracle price verification (MVP)
/// @notice Verifies ECDSA-signed price messages from authorised signers.
///         Enforces staleness bounds, price deviation limits, and monotonic
///         sequence numbers per asset.
contract OracleVerifier is IOracleVerifier, Ownable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    struct AssetOracleConfig {
        uint256 maxStaleness;
        uint256 maxDeviation; // in BPS
    }

    struct LastPrice {
        uint256 price;
        uint256 timestamp;
    }

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @dev Authorised signers.
    mapping(address => bool) private _signers;

    /// @dev Per-asset oracle configuration.
    mapping(bytes32 => AssetOracleConfig) private _assetConfigs;

    /// @dev Per-asset last verified price.
    mapping(bytes32 => LastPrice) private _lastPrices;

    /// @dev Per-asset sequence number (last accepted).
    mapping(bytes32 => uint256) private _sequenceNumbers;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param admin Initial owner / admin address.
    constructor(
        address admin
    ) Ownable(admin) {}

    // ──────────────────────────────────────────────────────────
    //  Core function
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external payable override returns (uint256 price, uint256 timestamp, bool marketOpen) {
        // Decode payload
        uint256 sequenceNumber;
        {
            uint8 v;
            bytes32 r;
            bytes32 s;
            (price, timestamp, marketOpen, sequenceNumber, v, r, s) =
                abi.decode(priceData, (uint256, uint256, bool, uint256, uint8, bytes32, bytes32));

            // Zero price
            if (price == 0) revert ZeroPrice();

            // Signature verification
            bytes32 messageHash =
                keccak256(abi.encode(asset, price, timestamp, marketOpen, sequenceNumber, block.chainid, address(this)));
            address recoveredSigner = messageHash.toEthSignedMessageHash().recover(v, r, s);

            if (!_signers[recoveredSigner]) {
                revert UnauthorizedSigner(recoveredSigner);
            }
        }

        // --- Checks ---

        // Staleness
        AssetOracleConfig storage config = _assetConfigs[asset];
        if (config.maxStaleness > 0 && block.timestamp - timestamp > config.maxStaleness) {
            revert StalePrice(asset, timestamp, config.maxStaleness);
        }

        // Sequence number: must be strictly greater than last accepted
        uint256 expectedSeq = _sequenceNumbers[asset] + 1;
        if (sequenceNumber < expectedSeq) {
            revert InvalidSequenceNumber(asset, sequenceNumber, expectedSeq);
        }

        // Deviation check (skip for first price)
        _checkDeviation(asset, price, config.maxDeviation);

        // --- Effects ---

        _sequenceNumbers[asset] = sequenceNumber;
        _lastPrices[asset] = LastPrice(price, timestamp);

        emit PriceVerified(asset, price, timestamp, marketOpen);
    }

    /// @dev Check price deviation against last known price.
    function _checkDeviation(bytes32 asset, uint256 price, uint256 maxDeviation) private view {
        LastPrice storage last = _lastPrices[asset];
        if (last.price == 0 || maxDeviation == 0) return;

        uint256 deviation;
        if (price > last.price) {
            deviation = ((price - last.price) * BPS) / last.price;
        } else {
            deviation = ((last.price - price) * BPS) / last.price;
        }
        if (deviation > maxDeviation) {
            revert PriceDeviationExceeded(asset, price, last.price, maxDeviation);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Signer management (admin)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function addSigner(
        address signer
    ) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        _signers[signer] = true;
        emit SignerAdded(signer);
    }

    /// @inheritdoc IOracleVerifier
    function removeSigner(
        address signer
    ) external onlyOwner {
        _signers[signer] = false;
        emit SignerRemoved(signer);
    }

    /// @inheritdoc IOracleVerifier
    function isSigner(
        address account
    ) external view returns (bool) {
        return _signers[account];
    }

    // ──────────────────────────────────────────────────────────
    //  Per-asset configuration (admin)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function setAssetOracleConfig(bytes32 asset, uint256 maxStaleness, uint256 maxDeviation) external onlyOwner {
        _assetConfigs[asset] = AssetOracleConfig(maxStaleness, maxDeviation);
        emit AssetOracleConfigUpdated(asset, maxStaleness, maxDeviation);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function getLastPrice(
        bytes32 asset
    ) external view returns (uint256 price, uint256 timestamp) {
        LastPrice storage lp = _lastPrices[asset];
        return (lp.price, lp.timestamp);
    }

    /// @inheritdoc IOracleVerifier
    function getSequenceNumber(
        bytes32 asset
    ) external view returns (uint256) {
        return _sequenceNumbers[asset];
    }
}
