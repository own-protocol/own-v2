// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @notice Minimal Chainlink AggregatorV3 proxy surface used by this verifier.
interface IAggregatorV3 {
    /// @notice Decimals of the feed's answer.
    /// @return Answer decimals.
    function decimals() external view returns (uint8);

    /// @notice Latest round of the feed.
    /// @return roundId         Round id.
    /// @return answer          Price answer, in the feed's decimals.
    /// @return startedAt       Round start timestamp.
    /// @return updatedAt       Timestamp of the answer.
    /// @return answeredInRound Round in which the answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice ERC-8056 (Scaled UI Amount) surface — the corporate-action multiplier on Gen-2 Stock Tokens.
interface IScaledUiToken {
    /// @notice Current UI multiplier (18 decimals).
    /// @return The multiplier.
    function uiMultiplier() external view returns (uint256);
}

/// @title ChainlinkOracleVerifier — Chainlink-primary oracle with band-limited in-house fallback
/// @notice Chainlink is the primary price source. The in-house signer may quote only while the
///         asset's feed has been silent longer than `clSilence`, and only within `bandBps` of the
///         last Chainlink answer (the anchor), so a compromised signer can never move a price more
///         than the band away from Chainlink and cannot quote at all while the feed is live.
///         Robinhood stock feeds return the token price (share price × ERC-8056 `uiMultiplier`);
///         tickers tracking the underlying set `multiplierToken` so reads divide by it.
/// @dev Feeds are deviation-driven and go silent outside market hours. While an answer is younger
///      than `clFreshWindow` reads report `block.timestamp` for it; beyond that they report the raw
///      `updatedAt`, so consumers' staleness checks fall through to the in-house leg.
///      Configuration is ADMIN-gated; the emergency levers {disableAsset} and {removeSigner} are
///      OPERATOR-gated. Roles resolve through the ProtocolRegistry. Signatures are EIP-712
///      `PriceAttestation`s bound to this contract's address.
contract ChainlinkOracleVerifier is IOracleVerifier, Multicall, EIP712 {
    using ECDSA for bytes32;

    /// @dev EIP-712 typehash for signed price attestations.
    bytes32 private constant PRICE_ATTESTATION_TYPEHASH =
        keccak256("PriceAttestation(bytes32 asset,uint256 price,uint256 timestamp)");

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Per-asset oracle configuration.
    /// @param aggregator          Chainlink proxy address.
    /// @param clSilence           Feed silence required before in-house prices are accepted (seconds).
    /// @param clFreshWindow       Feed age reported as current on reads (seconds).
    /// @param bandBps             Max in-house deviation from the anchor (BPS); 0 disables the in-house leg.
    /// @param clDecimals          Cached aggregator decimals.
    /// @param multiplierToken     ERC-8056 token whose `uiMultiplier` divides the feed (0 = none).
    /// @param maxAnchorAge        Feed age beyond which the Chainlink leg and anchor are unusable (seconds).
    /// @param inhouseMaxStaleness Max age of an in-house price at read and push time (seconds).
    struct AssetConfig {
        address aggregator;
        uint32 clSilence;
        uint32 clFreshWindow;
        uint16 bandBps;
        uint8 clDecimals;
        address multiplierToken;
        uint32 maxAnchorAge;
        uint32 inhouseMaxStaleness;
    }

    /// @notice Last pushed in-house price.
    /// @param price     Price (18 decimals).
    /// @param timestamp Attestation timestamp (unix seconds).
    struct PriceEntry {
        uint256 price;
        uint256 timestamp;
    }

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice In-house quoting is disabled for this asset (bandBps == 0).
    /// @param asset Asset ticker.
    error InhouseDisabled(bytes32 asset);
    /// @notice The Chainlink feed updated within `clSilence`, so the in-house signer may not quote.
    /// @param updatedAt The feed's latest round timestamp (unix seconds).
    /// @param asset     Asset ticker.
    error ChainlinkFresh(bytes32 asset, uint256 updatedAt);
    /// @notice No usable Chainlink anchor (no answer, a bad answer, or older than `maxAnchorAge`).
    /// @param asset Asset ticker.
    error NoAnchor(bytes32 asset);
    /// @notice Signed price timestamp is in the future.
    /// @param timestamp The offending attestation timestamp (unix seconds).
    /// @param asset     Asset ticker.
    error FutureTimestamp(bytes32 asset, uint256 timestamp);
    /// @notice The token's uiMultiplier() is zero.
    /// @param asset Asset ticker.
    error ZeroMultiplier(bytes32 asset);
    /// @notice Config bounds are inconsistent (see {setChainlinkConfig}).
    error InvalidConfig();

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when an asset's Chainlink config is set.
    /// @param asset               Asset ticker.
    /// @param aggregator          Chainlink proxy address.
    /// @param multiplierToken     ERC-8056 token dividing the feed (0 = feed used as-is).
    /// @param clSilence           Feed silence required before in-house quotes (seconds).
    /// @param clFreshWindow       Feed age treated as current on reads (seconds).
    /// @param maxAnchorAge        Feed age beyond which the Chainlink leg/anchor is unusable (seconds).
    /// @param inhouseMaxStaleness Max age of an in-house price at read/push time (seconds).
    /// @param bandBps             Max in-house deviation from the anchor (BPS); 0 disables in-house.
    event ChainlinkConfigSet(
        bytes32 indexed asset,
        address aggregator,
        address multiplierToken,
        uint32 clSilence,
        uint32 clFreshWindow,
        uint32 maxAnchorAge,
        uint32 inhouseMaxStaleness,
        uint16 bandBps
    );

    /// @notice Emitted when an asset is disabled.
    /// @param asset Asset ticker disabled.
    event AssetDisabled(bytes32 indexed asset);

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve the ADMIN and OPERATOR roles.
    IProtocolRegistry public immutable registry;

    /// @dev Signer => authorized.
    mapping(address => bool) private _signers;

    /// @dev Asset ticker => oracle config.
    mapping(bytes32 => AssetConfig) private _configs;

    /// @dev Asset ticker => last pushed in-house price.
    mapping(bytes32 => PriceEntry) private _prices;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    /// @dev ProtocolRegistry role for asset configs and adding signers.
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @dev ProtocolRegistry role for {disableAsset} and {removeSigner}.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @dev Reverts unless the caller holds ADMIN in the registry.
    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @dev Reverts unless the caller holds OPERATOR in the registry.
    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param registry_ ProtocolRegistry address.
    constructor(
        address registry_
    ) EIP712("Own Protocol", "1") {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
    }

    // ──────────────────────────────────────────────────────────
    //  Push — signed in-house price
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev Permissionless; the signature authenticates the price. Accepted only while the feed has
    ///      been silent longer than `clSilence`, within `bandBps` of the anchor and no older than
    ///      `inhouseMaxStaleness`. A price not newer than the stored one is ignored, so batched
    ///      pushes (via {multicall}) are idempotent.
    function updatePrice(bytes32 asset, bytes calldata priceData) external override {
        (uint256 price, uint256 timestamp, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(priceData, (uint256, uint256, uint8, bytes32, bytes32));

        if (price == 0) revert ZeroPrice();
        if (timestamp > block.timestamp) revert FutureTimestamp(asset, timestamp);

        address recoveredSigner = priceDigest(asset, price, timestamp).recover(v, r, s);
        if (!_signers[recoveredSigner]) revert UnauthorizedSigner(recoveredSigner);

        AssetConfig storage cfg = _configs[asset];
        if (cfg.aggregator == address(0)) revert OracleConfigNotSet(asset);
        if (cfg.bandBps == 0) revert InhouseDisabled(asset);
        if (block.timestamp - timestamp > cfg.inhouseMaxStaleness) {
            revert StalePrice(asset, timestamp, cfg.inhouseMaxStaleness);
        }

        PriceEntry storage existing = _prices[asset];
        if (existing.timestamp > 0 && timestamp <= existing.timestamp) return;

        _checkAnchorBand(asset, cfg, price);

        _prices[asset] = PriceEntry(price, timestamp);
        emit PriceUpdated(asset, price, timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  Read
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev Returns the newer of the two valid legs. A Chainlink answer younger than
    ///      `clFreshWindow` reports `block.timestamp`; older answers report their raw `updatedAt`.
    function getPrice(
        bytes32 asset
    ) external view override returns (uint256 price, uint256 timestamp) {
        AssetConfig storage cfg = _configs[asset];
        if (cfg.aggregator == address(0)) revert OracleConfigNotSet(asset);

        (uint256 clPrice, uint256 clUpdated, bool clValid) = _chainlink(asset, cfg);

        PriceEntry storage ih = _prices[asset];
        bool ihValid = ih.price > 0 && block.timestamp - ih.timestamp <= cfg.inhouseMaxStaleness;

        if (ihValid && (!clValid || ih.timestamp > clUpdated)) return (ih.price, ih.timestamp);
        if (clValid) {
            return (clPrice, block.timestamp - clUpdated <= cfg.clFreshWindow ? block.timestamp : clUpdated);
        }
        if (ih.price > 0) revert StalePrice(asset, ih.timestamp, cfg.inhouseMaxStaleness);
        revert PriceNotAvailable(asset);
    }

    /// @notice The EIP-712 digest a signer must sign to attest a price.
    /// @param asset     Asset ticker.
    /// @param price     Price (18 decimals).
    /// @param timestamp Price observation timestamp (unix seconds).
    /// @return The EIP-712 digest.
    function priceDigest(bytes32 asset, uint256 price, uint256 timestamp) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PRICE_ATTESTATION_TYPEHASH, asset, price, timestamp)));
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Read and scale the asset's Chainlink answer to 18 decimals. `valid` is false (instead of
    ///      reverting) for a non-positive, future-dated or older-than-`maxAnchorAge` answer, so the
    ///      in-house leg can still serve.
    /// @param asset Asset ticker.
    /// @param cfg   The asset's config.
    /// @return price     Price (18 decimals).
    /// @return updatedAt Timestamp of the answer.
    /// @return valid     Whether the answer is usable.
    function _chainlink(
        bytes32 asset,
        AssetConfig storage cfg
    ) private view returns (uint256 price, uint256 updatedAt, bool valid) {
        (, int256 answer,, uint256 updated,) = IAggregatorV3(cfg.aggregator).latestRoundData();
        if (answer <= 0 || updated == 0 || updated > block.timestamp) return (0, updated, false);
        if (block.timestamp - updated > cfg.maxAnchorAge) return (0, updated, false);

        price = uint256(answer) * (10 ** (18 - cfg.clDecimals));
        if (cfg.multiplierToken != address(0)) {
            uint256 mult = IScaledUiToken(cfg.multiplierToken).uiMultiplier();
            if (mult == 0) revert ZeroMultiplier(asset);
            price = price * PRECISION / mult;
        }
        return (price, updated, true);
    }

    /// @dev Gate an in-house price: a valid anchor must exist, the feed must have been silent longer
    ///      than `clSilence`, and the price must sit within `bandBps` of the anchor.
    /// @param asset Asset ticker.
    /// @param cfg   The asset's config.
    /// @param price Proposed in-house price (18 decimals).
    function _checkAnchorBand(bytes32 asset, AssetConfig storage cfg, uint256 price) private view {
        (uint256 anchor, uint256 clUpdated, bool clValid) = _chainlink(asset, cfg);
        if (!clValid) revert NoAnchor(asset);
        if (block.timestamp - clUpdated <= cfg.clSilence) revert ChainlinkFresh(asset, clUpdated);

        uint256 diff = price > anchor ? price - anchor : anchor - price;
        if (diff * BPS > anchor * cfg.bandBps) {
            revert PriceDeviationExceeded(asset, price, anchor, cfg.bandBps);
        }
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
    /// @dev OPERATOR-gated so a compromised signer can be revoked immediately.
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

    /// @notice Set an asset's Chainlink config (ADMIN). Reads and caches the aggregator's decimals.
    ///         Requires `0 < clSilence <= clFreshWindow <= maxAnchorAge`, and a nonzero
    ///         `inhouseMaxStaleness` when the in-house leg is enabled.
    /// @param asset               Asset ticker.
    /// @param aggregator          Chainlink proxy address.
    /// @param multiplierToken     ERC-8056 token whose `uiMultiplier` divides the feed (0 = use as is).
    /// @param clSilence           Feed silence required before in-house prices are accepted (seconds).
    /// @param clFreshWindow       Feed age reported as current on reads (seconds).
    /// @param maxAnchorAge        Feed age beyond which the Chainlink leg and anchor are unusable (seconds).
    /// @param inhouseMaxStaleness Max age of an in-house price at read and push time (seconds).
    /// @param bandBps             Max in-house deviation from the anchor (BPS); 0 disables the in-house leg.
    function setChainlinkConfig(
        bytes32 asset,
        address aggregator,
        address multiplierToken,
        uint32 clSilence,
        uint32 clFreshWindow,
        uint32 maxAnchorAge,
        uint32 inhouseMaxStaleness,
        uint16 bandBps
    ) external onlyAdmin {
        if (aggregator == address(0)) revert ZeroAddress();
        if (clSilence == 0 || clFreshWindow < clSilence || maxAnchorAge < clFreshWindow) revert InvalidConfig();
        if (bandBps > 0 && inhouseMaxStaleness == 0) revert InvalidConfig();

        uint8 dec = IAggregatorV3(aggregator).decimals();
        if (dec > 18) revert InvalidConfig();
        if (multiplierToken != address(0) && IScaledUiToken(multiplierToken).uiMultiplier() == 0) {
            revert InvalidConfig();
        }

        _configs[asset] = AssetConfig({
            aggregator: aggregator,
            clSilence: clSilence,
            clFreshWindow: clFreshWindow,
            bandBps: bandBps,
            clDecimals: dec,
            multiplierToken: multiplierToken,
            maxAnchorAge: maxAnchorAge,
            inhouseMaxStaleness: inhouseMaxStaleness
        });
        emit ChainlinkConfigSet(
            asset, aggregator, multiplierToken, clSilence, clFreshWindow, maxAnchorAge, inhouseMaxStaleness, bandBps
        );
    }

    /// @notice Emergency stop (OPERATOR): clear an asset's config and cached in-house price, so every
    ///         read reverts `OracleConfigNotSet` until ADMIN configures it again.
    /// @param asset Asset ticker to disable.
    function disableAsset(
        bytes32 asset
    ) external onlyOperator {
        delete _configs[asset];
        delete _prices[asset];
        emit AssetDisabled(asset);
    }

    /// @notice An asset's oracle config.
    /// @param asset Asset ticker.
    /// @return The config (all zero if unset).
    function getChainlinkConfig(
        bytes32 asset
    ) external view returns (AssetConfig memory) {
        return _configs[asset];
    }

    /// @notice The last pushed in-house price, unfiltered by staleness ((0, 0) if none).
    /// @param asset Asset ticker.
    /// @return price     Last pushed price (18 dec).
    /// @return timestamp Attestation timestamp of that price (unix seconds).
    function getInhousePrice(
        bytes32 asset
    ) external view returns (uint256 price, uint256 timestamp) {
        PriceEntry storage pe = _prices[asset];
        return (pe.price, pe.timestamp);
    }
}
