// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title OracleVerifier — In-house signed oracle with push model
/// @notice Authorised signers push single-asset price updates via updatePrice().
///         Batch updates use inherited Multicall. Consumers read cached prices
///         via getPrice(). verifyPrice() is available for inline proof verification.
contract OracleVerifier is IOracleVerifier, Ownable, Multicall {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    struct AssetOracleConfig {
        uint256 maxStaleness;
        uint256 maxDeviation; // in BPS
    }

    struct PriceEntry {
        uint256 price;
        uint256 timestamp;
    }

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    mapping(address => bool) private _signers;
    mapping(bytes32 => AssetOracleConfig) private _assetConfigs;
    mapping(bytes32 => PriceEntry) private _prices;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    constructor(
        address admin
    ) Ownable(admin) {}

    // ──────────────────────────────────────────────────────────
    //  Push — update a single asset price
    // ──────────────────────────────────────────────────────────

    /// @notice Push a signed price update for a single asset.
    ///         Batch updates are done via inherited Multicall.
    /// @param asset     Asset ticker.
    /// @param priceData Encoded as (uint256 price, uint256 timestamp, uint8 v, bytes32 r, bytes32 s).
    function updatePrice(bytes32 asset, bytes calldata priceData) external {
        (uint256 price, uint256 timestamp, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(priceData, (uint256, uint256, uint8, bytes32, bytes32));

        if (price == 0) revert ZeroPrice();

        // Verify signature
        bytes32 messageHash = keccak256(abi.encode(asset, price, timestamp, block.chainid, address(this)));
        address recoveredSigner = messageHash.toEthSignedMessageHash().recover(v, r, s);
        if (!_signers[recoveredSigner]) revert UnauthorizedSigner(recoveredSigner);

        // Staleness check
        AssetOracleConfig storage config = _assetConfigs[asset];
        if (config.maxStaleness > 0 && block.timestamp - timestamp > config.maxStaleness) {
            revert StalePrice(asset, timestamp, config.maxStaleness);
        }

        // Only accept newer prices
        PriceEntry storage existing = _prices[asset];
        if (existing.timestamp > 0 && timestamp <= existing.timestamp) return;

        // Deviation check (skip for first price)
        if (existing.price > 0 && config.maxDeviation > 0) {
            uint256 deviation;
            if (price > existing.price) {
                deviation = ((price - existing.price) * BPS) / existing.price;
            } else {
                deviation = ((existing.price - price) * BPS) / existing.price;
            }
            if (deviation > config.maxDeviation) {
                revert PriceDeviationExceeded(asset, price, existing.price, config.maxDeviation);
            }
        }

        _prices[asset] = PriceEntry(price, timestamp);
        emit PriceUpdated(asset, price, timestamp);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev For in-house oracle, this is a no-op. Use updatePrice() + multicall instead.
    function updatePriceFeeds(
        bytes calldata
    ) external payable override {
        revert("OracleVerifier: use updatePrice + multicall");
    }

    // ──────────────────────────────────────────────────────────
    //  Read — cached prices
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function getPrice(
        bytes32 asset
    ) external view override returns (uint256 price, uint256 timestamp) {
        PriceEntry storage pe = _prices[asset];
        if (pe.price == 0) revert PriceNotAvailable(asset);
        return (pe.price, pe.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  Verify — inline proof (force execution)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev Pure ECDSA verification — no ETH required. payable to satisfy the interface.
    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external payable override returns (uint256 price, uint256 timestamp) {
        uint8 v;
        bytes32 r;
        bytes32 s;
        (price, timestamp, v, r, s) = abi.decode(priceData, (uint256, uint256, uint8, bytes32, bytes32));

        if (price == 0) revert ZeroPrice();

        bytes32 messageHash = keccak256(abi.encode(asset, price, timestamp, block.chainid, address(this)));
        address recoveredSigner = messageHash.toEthSignedMessageHash().recover(v, r, s);
        if (!_signers[recoveredSigner]) revert UnauthorizedSigner(recoveredSigner);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev In-house oracle has no session concept — delegates to verifyPrice, ignoring sessionId.
    function verifyPriceForSession(
        bytes32 asset,
        bytes calldata priceData,
        uint8
    ) external payable override returns (uint256 price, uint256 timestamp) {
        return this.verifyPrice(asset, priceData);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev In-house oracle never needs ETH for proof verification.
    function verifyFee(
        bytes calldata
    ) external pure override returns (uint256) {
        return 0;
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — signer management
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
    //  Admin — per-asset configuration
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function setAssetOracleConfig(bytes32 asset, uint256 maxStaleness, uint256 maxDeviation) external onlyOwner {
        _assetConfigs[asset] = AssetOracleConfig(maxStaleness, maxDeviation);
    }

    /// @inheritdoc IOracleVerifier
    function getAssetOracleConfig(
        bytes32 asset
    ) external view returns (uint256 maxStaleness, uint256 maxDeviation) {
        AssetOracleConfig storage config = _assetConfigs[asset];
        return (config.maxStaleness, config.maxDeviation);
    }
}
