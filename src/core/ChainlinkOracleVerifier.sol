// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IScaledUiToken {
    function uiMultiplier() external view returns (uint256);
}

/// @title ChainlinkOracleVerifier — Chainlink-primary oracle with band-limited in-house fallback
/// @notice Chainlink is the authoritative price source. The in-house signer may quote only while
///         the asset's Chainlink feed has been silent longer than `clSilence`, and only within
///         `bandBps` of the last Chainlink answer (the anchor) — so a compromised signer can never
///         move a price more than the band away from Chainlink, and cannot quote at all while the
///         feed is live. Robinhood stock feeds return the TOKEN price (share price x ERC-8056
///         uiMultiplier); tickers tracking the underlying set `multiplierToken` so reads divide the
///         feed by the token's live uiMultiplier().
/// @dev Feeds are deviation-driven (0.5%) with a 24h in-session heartbeat and go fully silent off
///      market hours (see docs/chainlink-feeds-robinhood.md). While a Chainlink answer is younger
///      than `clFreshWindow` its value is within the deviation band of spot, so reads report
///      `block.timestamp` for it; beyond that the raw `updatedAt` is reported and consumers' own
///      staleness checks push them onto the in-house leg.
///      Config is gated by ADMIN; the emergency `disableAsset` / `removeSigner` levers are gated by
///      the instant OPERATOR role. Both resolved via the ProtocolRegistry. Signature scheme (EIP-712
///      domain and PriceAttestation typehash) matches OracleVerifier, so the signer service needs no
///      changes.
contract ChainlinkOracleVerifier is IOracleVerifier, Multicall, EIP712 {
    using ECDSA for bytes32;

    /// @dev EIP-712 typehash for signed price attestations.
    bytes32 private constant PRICE_ATTESTATION_TYPEHASH =
        keccak256("PriceAttestation(bytes32 asset,uint256 price,uint256 timestamp)");

    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    struct AssetConfig {
        address aggregator; // Chainlink proxy (required)
        uint32 clSilence; // in-house quotes allowed only when the feed is silent longer than this
        uint32 clFreshWindow; // feed age within which reads report block.timestamp (e.g. 12h)
        uint16 bandBps; // max in-house deviation from the Chainlink anchor; 0 disables the in-house leg
        uint8 clDecimals; // cached aggregator.decimals()
        address multiplierToken; // when set, reads divide the feed by its uiMultiplier() (underlying tickers)
        uint32 maxAnchorAge; // feed age beyond which the Chainlink leg (and the anchor) is unusable
        uint32 inhouseMaxStaleness; // max age of an in-house price at read/push time
    }

    struct PriceEntry {
        uint256 price;
        uint256 timestamp;
    }

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice In-house quoting is disabled for this asset (bandBps == 0).
    error InhouseDisabled(bytes32 asset);
    /// @notice The Chainlink feed updated within `clSilence` — the in-house signer may not quote.
    error ChainlinkFresh(bytes32 asset, uint256 updatedAt);
    /// @notice No usable Chainlink anchor (feed dead, halted beyond maxAnchorAge, or bad answer).
    error NoAnchor(bytes32 asset);
    /// @notice Signed price timestamp is in the future.
    error FutureTimestamp(bytes32 asset, uint256 timestamp);
    /// @notice Chainlink returned a non-positive answer.
    error NonPositiveAnswer(bytes32 asset, int256 answer);
    /// @notice The token's uiMultiplier() is zero.
    error ZeroMultiplier(bytes32 asset);
    /// @notice Config bounds are inconsistent (see setChainlinkConfig).
    error InvalidConfig();

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when an asset's Chainlink config is set.
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

    /// @notice Emitted when an asset is disabled (emergency kill-switch).
    event AssetDisabled(bytes32 indexed asset);

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve ADMIN / OPERATOR roles.
    IProtocolRegistry public immutable registry;

    mapping(address => bool) private _signers;
    mapping(bytes32 => AssetConfig) private _configs;
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
    //  Push — in-house signed quote (off-hours / feed-silent only)
    // ──────────────────────────────────────────────────────────

    /// @notice Push a signed in-house price for `asset`. Accepted only while the Chainlink feed has
    ///         been silent longer than `clSilence`, and only within `bandBps` of the last Chainlink
    ///         answer. Batch updates via inherited Multicall.
    /// @param asset     Asset ticker.
    /// @param priceData Encoded as (uint256 price, uint256 timestamp, uint8 v, bytes32 r, bytes32 s).
    function updatePrice(bytes32 asset, bytes calldata priceData) external {
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

        // Only accept newer prices (idempotent multicall / relay races).
        PriceEntry storage existing = _prices[asset];
        if (existing.timestamp > 0 && timestamp <= existing.timestamp) return;

        _checkAnchorBand(asset, cfg, price);

        _prices[asset] = PriceEntry(price, timestamp);
        emit PriceUpdated(asset, price, timestamp);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev Chainlink pushes itself; in-house pushes go through updatePrice + multicall.
    function updatePriceFeeds(
        bytes calldata
    ) external payable override {
        revert("ChainlinkOracle: use updatePrice + multicall");
    }

    // ──────────────────────────────────────────────────────────
    //  Read — cached prices
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev Returns the freshest valid leg. A Chainlink answer younger than `clFreshWindow` reports
    ///      `block.timestamp` (deviation guarantee holds while the feed is live); older answers
    ///      report raw `updatedAt` so consumer staleness checks fail over to the in-house leg.
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

    // ──────────────────────────────────────────────────────────
    //  Verify — inline proof (borrow / liquidate / force execution)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev Chainlink-first: while the feed is fresh (<= clSilence) the proof is ignored and the
    ///      Chainlink price is returned as current. When the feed is silent a signed proof is
    ///      verified against the anchor band. An empty proof falls back to Chainlink within
    ///      `clFreshWindow`. No ETH required. payable to satisfy the interface.
    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external payable override returns (uint256 price, uint256 timestamp) {
        AssetConfig storage cfg = _configs[asset];
        if (cfg.aggregator == address(0)) revert OracleConfigNotSet(asset);

        (uint256 clPrice, uint256 clUpdated, bool clValid) = _chainlink(asset, cfg);
        uint256 clAge = clValid ? block.timestamp - clUpdated : type(uint256).max;

        if (clValid && clAge <= cfg.clSilence) return (clPrice, block.timestamp);

        if (priceData.length > 0) return _verifyInhouseProof(asset, cfg, priceData);

        if (clValid && clAge <= cfg.clFreshWindow) return (clPrice, block.timestamp);
        revert PriceNotAvailable(asset);
    }

    /// @dev Verify a signed in-house proof against the anchor band (the feed-silent leg of verifyPrice).
    function _verifyInhouseProof(
        bytes32 asset,
        AssetConfig storage cfg,
        bytes calldata priceData
    ) private view returns (uint256 price, uint256 timestamp) {
        uint8 v;
        bytes32 r;
        bytes32 s;
        (price, timestamp, v, r, s) = abi.decode(priceData, (uint256, uint256, uint8, bytes32, bytes32));

        if (price == 0) revert ZeroPrice();
        if (timestamp > block.timestamp) revert FutureTimestamp(asset, timestamp);

        address recoveredSigner = priceDigest(asset, price, timestamp).recover(v, r, s);
        if (!_signers[recoveredSigner]) revert UnauthorizedSigner(recoveredSigner);
        if (cfg.bandBps == 0) revert InhouseDisabled(asset);

        _checkAnchorBand(asset, cfg, price);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev Sessions are a Pyth concept — delegates to verifyPrice, ignoring sessionId.
    function verifyPriceForSession(
        bytes32 asset,
        bytes calldata priceData,
        uint8
    ) external payable override returns (uint256 price, uint256 timestamp) {
        return this.verifyPrice(asset, priceData);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev Never needs ETH for proof verification.
    function verifyFee(
        bytes calldata
    ) external pure override returns (uint256) {
        return 0;
    }

    /// @notice The EIP-712 digest a signer must sign to attest a price.
    function priceDigest(bytes32 asset, uint256 price, uint256 timestamp) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PRICE_ATTESTATION_TYPEHASH, asset, price, timestamp)));
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Read + normalize the asset's Chainlink leg. `valid` is false when the feed has no
    ///      usable answer (non-positive, future-dated, or older than maxAnchorAge) — callers treat
    ///      that as "no Chainlink leg" rather than reverting, so the in-house leg can still serve.
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

    /// @dev Gate an in-house price: the feed must have been silent longer than `clSilence`, a valid
    ///      anchor must exist, and the price must sit within `bandBps` of it. Fail closed on all three.
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

    /// @notice Set an asset's Chainlink config. Reads and caches the aggregator's decimals.
    /// @param asset               Asset ticker.
    /// @param aggregator          Chainlink proxy address.
    /// @param multiplierToken     ERC-8056 token whose uiMultiplier() divides the feed (0 = use as-is).
    /// @param clSilence           Feed silence required before in-house quotes are accepted (e.g. 15 min).
    /// @param clFreshWindow       Feed age treated as current on reads (e.g. 12h); older reads report the
    ///                            raw feed timestamp, pushing consumers onto the in-house leg.
    /// @param maxAnchorAge        Feed age beyond which the Chainlink leg/anchor is unusable (e.g. 5 days).
    /// @param inhouseMaxStaleness Max age of an in-house price at read/push time.
    /// @param bandBps             Max in-house deviation from the anchor; 0 disables in-house quoting.
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

    /// @notice Emergency kill-switch: clear an asset's config so all reads/verifies revert
    ///         `OracleConfigNotSet`. Gated by the instant OPERATOR role.
    function disableAsset(
        bytes32 asset
    ) external onlyOperator {
        delete _configs[asset];
        delete _prices[asset];
        emit AssetDisabled(asset);
    }

    /// @notice Return an asset's full Chainlink config.
    function getChainlinkConfig(
        bytes32 asset
    ) external view returns (AssetConfig memory) {
        return _configs[asset];
    }

    /// @notice Return the last in-house pushed price (0,0 if none).
    function getInhousePrice(
        bytes32 asset
    ) external view returns (uint256 price, uint256 timestamp) {
        PriceEntry storage pe = _prices[asset];
        return (pe.price, pe.timestamp);
    }

    /// @inheritdoc IOracleVerifier
    function setAssetOracleConfig(bytes32, uint256, uint256) external pure override {
        revert("ChainlinkOracle: use setChainlinkConfig");
    }

    /// @inheritdoc IOracleVerifier
    function getAssetOracleConfig(
        bytes32
    ) external pure override returns (uint256, uint256) {
        revert("ChainlinkOracle: use getChainlinkConfig");
    }
}
