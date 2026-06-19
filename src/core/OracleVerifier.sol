// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title OracleVerifier — In-house signed oracle with push model
/// @notice Authorised signers push single-asset price updates via updatePrice().
///         Batch updates use inherited Multicall. Consumers read cached prices
///         via getPrice(). verifyPrice() is available for inline proof verification.
///         Price attestations are EIP-712 typed signatures over `PriceAttestation`.
/// @dev Config is gated by ADMIN (add signer, per-asset config); the emergency
///      `removeSigner` is gated by the instant OPERATOR role. Both resolved via the
///      ProtocolRegistry.
contract OracleVerifier is IOracleVerifier, Multicall, EIP712 {
    using ECDSA for bytes32;

    /// @dev EIP-712 typehash for signed price attestations.
    bytes32 private constant PRICE_ATTESTATION_TYPEHASH =
        keccak256("PriceAttestation(bytes32 asset,uint256 price,uint256 timestamp)");

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

    /// @notice ProtocolRegistry used to resolve ADMIN / OPERATOR roles.
    IProtocolRegistry public immutable registry;

    mapping(address => bool) private _signers;
    mapping(bytes32 => AssetOracleConfig) private _assetConfigs;
    mapping(bytes32 => PriceEntry) private _prices;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    bytes32 private constant ADMIN = keccak256("ADMIN");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param registry_ ProtocolRegistry address (resolves ADMIN / OPERATOR roles).
    constructor(
        address registry_
    ) EIP712("Own Protocol", "1") {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
    }

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
        address recoveredSigner = priceDigest(asset, price, timestamp).recover(v, r, s);
        if (!_signers[recoveredSigner]) revert UnauthorizedSigner(recoveredSigner);

        // No config, no prices: an unconfigured asset must not accept unbounded pushes.
        AssetOracleConfig storage config = _assetConfigs[asset];
        if (config.maxStaleness == 0 || config.maxDeviation == 0) revert OracleConfigNotSet(asset);

        // Staleness check
        if (block.timestamp - timestamp > config.maxStaleness) {
            revert StalePrice(asset, timestamp, config.maxStaleness);
        }

        // Only accept newer prices
        PriceEntry storage existing = _prices[asset];
        if (existing.timestamp > 0 && timestamp <= existing.timestamp) return;

        // Deviation check (skip for first price)
        if (existing.price > 0) {
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
        // Match the Pyth path: reject a cached price older than the asset's configured max age.
        uint256 maxStaleness = _assetConfigs[asset].maxStaleness;
        if (block.timestamp - pe.timestamp > maxStaleness) {
            revert StalePrice(asset, pe.timestamp, maxStaleness);
        }
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

        address recoveredSigner = priceDigest(asset, price, timestamp).recover(v, r, s);
        if (!_signers[recoveredSigner]) revert UnauthorizedSigner(recoveredSigner);
    }

    /// @notice The EIP-712 digest a signer must sign to attest a price.
    function priceDigest(bytes32 asset, uint256 price, uint256 timestamp) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PRICE_ATTESTATION_TYPEHASH, asset, price, timestamp)));
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
    ) external onlyAdmin {
        if (signer == address(0)) revert ZeroAddress();
        _signers[signer] = true;
        emit SignerAdded(signer);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev Emergency lever — gated by the instant OPERATOR role so a compromised
    ///      signer can be revoked without a timelock delay.
    function removeSigner(
        address signer
    ) external onlyOperator {
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
    function setAssetOracleConfig(bytes32 asset, uint256 maxStaleness, uint256 maxDeviation) external onlyAdmin {
        if (maxStaleness == 0 || maxDeviation == 0) revert InvalidOracleConfig();
        _assetConfigs[asset] = AssetOracleConfig(maxStaleness, maxDeviation);
        emit AssetOracleConfigSet(asset, maxStaleness, maxDeviation);
    }

    /// @inheritdoc IOracleVerifier
    function getAssetOracleConfig(
        bytes32 asset
    ) external view returns (uint256 maxStaleness, uint256 maxDeviation) {
        AssetOracleConfig storage config = _assetConfigs[asset];
        return (config.maxStaleness, config.maxDeviation);
    }
}
