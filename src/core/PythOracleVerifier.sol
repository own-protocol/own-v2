// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {IPyth} from "@pythnetwork/IPyth.sol";
import {PythStructs} from "@pythnetwork/PythStructs.sol";

/// @title PythOracleVerifier — Pyth Network oracle with push model
/// @notice Wraps the Pyth oracle on Base to implement IOracleVerifier.
///         Prices are pushed via updatePriceFeeds() and read via getPrice().
///         verifyPrice() parses a Pyth update inline for force execution proofs.
/// @dev Feed/age/confidence config is gated by ADMIN; the emergency `disableFeed`
///      kill-switch is gated by the instant PYTH_ORACLE_OPERATOR role. Both resolved via the
///      ProtocolRegistry.
contract PythOracleVerifier is IOracleVerifier {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice ProtocolRegistry used to resolve ADMIN / OPERATOR roles.
    IProtocolRegistry public immutable registry;

    IPyth public immutable pyth;
    uint256 public maxPriceAge;

    /// @notice Max accepted Pyth confidence interval relative to price, in BPS.
    uint256 public maxConfBps;

    /// @dev Asset ticker → session feed IDs.
    ///      Index 0 = regular, 1 = pre-market, 2 = post-market, 3 = overnight.
    ///      verifyPrice() always uses index 0 (regular). verifyPriceForSession() uses the specified index.
    mapping(bytes32 => bytes32[4]) private _feedIds;

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice No Pyth feed is configured for this asset/session.
    error FeedNotConfigured(bytes32 asset);
    /// @notice Session index is out of range (must be 0–3).
    error InvalidSessionId(uint8 sessionId);
    /// @notice Pyth returned a non-positive price.
    /// @param rawPrice Raw Pyth price (signed, feed exponent).
    error NegativePrice(bytes32 asset, int64 rawPrice);
    /// @notice Pyth confidence interval exceeds the allowed band relative to price.
    /// @param conf       Confidence interval (feed exponent units).
    /// @param price      Raw Pyth price (feed exponent units).
    /// @param maxConfBps Allowed confidence relative to price (BPS).
    error ConfidenceTooWide(bytes32 asset, uint256 conf, uint256 price, uint256 maxConfBps);
    /// @notice Max confidence band is zero (BPS).
    error InvalidMaxConfBps();

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a Pyth feed ID is set for an asset and trading session.
    /// @param asset     Asset ticker.
    /// @param sessionId Session index (0=regular, 1=pre-market, 2=post-market, 3=overnight).
    /// @param feedId    Pyth price feed ID.
    event FeedIdSet(bytes32 indexed asset, uint8 sessionId, bytes32 feedId);

    /// @notice Emitted when all session feeds for an asset are cleared (emergency kill-switch).
    /// @param asset Asset ticker disabled.
    event FeedDisabled(bytes32 indexed asset);

    /// @notice Emitted when the max accepted price age is updated.
    /// @param oldAge Previous max age (seconds).
    /// @param newAge New max age (seconds).
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @notice Emitted when the max accepted confidence band is updated.
    /// @param oldBps Previous max confidence relative to price (BPS).
    /// @param newBps New max confidence relative to price (BPS).
    event MaxConfBpsUpdated(uint256 oldBps, uint256 newBps);

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

    /// @param registry_     ProtocolRegistry address (resolves ADMIN / OPERATOR roles).
    /// @param pyth_         Pyth contract address.
    /// @param maxPriceAge_  Max accepted price age (seconds).
    /// @param maxConfBps_   Max accepted confidence interval relative to price (BPS). Non-zero.
    constructor(address registry_, address pyth_, uint256 maxPriceAge_, uint256 maxConfBps_) {
        if (registry_ == address(0)) revert ZeroAddress();
        if (maxConfBps_ == 0) revert InvalidMaxConfBps();
        registry = IProtocolRegistry(registry_);
        pyth = IPyth(pyth_);
        maxPriceAge = maxPriceAge_;
        maxConfBps = maxConfBps_;
    }

    // ──────────────────────────────────────────────────────────
    //  Push — update price feeds
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev updateData is abi.encode(bytes[]) — Pyth price update blobs.
    ///      Caller must send enough ETH to cover pyth.getUpdateFee().
    function updatePriceFeeds(
        bytes calldata updateData
    ) external payable override {
        bytes[] memory pythUpdateData = abi.decode(updateData, (bytes[]));
        uint256 updateFee = pyth.getUpdateFee(pythUpdateData);
        pyth.updatePriceFeeds{value: updateFee}(pythUpdateData);
    }

    // ──────────────────────────────────────────────────────────
    //  Read — cached prices
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function getPrice(
        bytes32 asset
    ) external view override returns (uint256 price, uint256 timestamp) {
        bytes32 feedId = _feedIds[asset][0];
        if (feedId == bytes32(0)) revert FeedNotConfigured(asset);

        PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(feedId, maxPriceAge);
        price = _normalizePythPrice(asset, pythPrice);
        timestamp = pythPrice.publishTime;
    }

    // ──────────────────────────────────────────────────────────
    //  Verify — inline proof (force execution)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev Uses index 0 (regular session) feed only. For multi-session, use verifyPriceForSession.
    ///      Caller must send ETH >= verifyFee(priceData) to cover the Pyth fee.
    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external payable override returns (uint256 price, uint256 timestamp) {
        return _verifyPriceWithFeed(asset, _feedIds[asset][0], priceData);
    }

    /// @inheritdoc IOracleVerifier
    function verifyPriceForSession(
        bytes32 asset,
        bytes calldata priceData,
        uint8 sessionId
    ) external payable override returns (uint256 price, uint256 timestamp) {
        if (sessionId >= 4) revert InvalidSessionId(sessionId);
        return _verifyPriceWithFeed(asset, _feedIds[asset][sessionId], priceData);
    }

    /// @inheritdoc IOracleVerifier
    /// @dev Decodes updateData from priceData and returns pyth.getUpdateFee(updateData).
    function verifyFee(
        bytes calldata priceData
    ) external view override returns (uint256) {
        (bytes[] memory updateData,,) = abi.decode(priceData, (bytes[], uint64, uint64));
        return pyth.getUpdateFee(updateData);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — signer management (no-op for Pyth)
    // ──────────────────────────────────────────────────────────

    function addSigner(
        address
    ) external pure override {
        revert("PythOracle: no signers");
    }

    function removeSigner(
        address
    ) external pure override {
        revert("PythOracle: no signers");
    }

    function isSigner(
        address
    ) external pure override returns (bool) {
        return false;
    }

    function setAssetOracleConfig(bytes32, uint256, uint256) external pure override {
        revert("PythOracle: use setFeedId/setMaxPriceAge");
    }

    function getAssetOracleConfig(
        bytes32
    ) external pure override returns (uint256, uint256) {
        revert("PythOracle: use getFeedId/maxPriceAge");
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — feed configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Set the Pyth feed ID for an asset and trading session.
    /// @param asset     Asset ticker.
    /// @param sessionId Session index (0=regular, 1=pre-market, 2=post-market, 3=overnight).
    /// @param feedId    Pyth price feed ID.
    function setFeedId(bytes32 asset, uint8 sessionId, bytes32 feedId) external onlyAdmin {
        if (sessionId >= 4) revert InvalidSessionId(sessionId);
        _feedIds[asset][sessionId] = feedId;
        emit FeedIdSet(asset, sessionId, feedId);
    }

    /// @notice Emergency kill-switch: clear all session feeds for an asset so reads/verifies revert
    ///         `FeedNotConfigured`. Gated by the instant PYTH_ORACLE_OPERATOR role.
    /// @param asset Asset ticker to disable.
    function disableFeed(
        bytes32 asset
    ) external onlyOperator {
        delete _feedIds[asset];
        emit FeedDisabled(asset);
    }

    function setMaxPriceAge(
        uint256 newMaxAge
    ) external onlyAdmin {
        uint256 old = maxPriceAge;
        maxPriceAge = newMaxAge;
        emit MaxPriceAgeUpdated(old, newMaxAge);
    }

    /// @notice Set the max accepted confidence interval relative to price (BPS).
    function setMaxConfBps(
        uint256 newMaxConfBps
    ) external onlyAdmin {
        if (newMaxConfBps == 0) revert InvalidMaxConfBps();
        emit MaxConfBpsUpdated(maxConfBps, newMaxConfBps);
        maxConfBps = newMaxConfBps;
    }

    /// @notice Get the Pyth feed ID for an asset and trading session.
    function getFeedId(bytes32 asset, uint8 sessionId) external view returns (bytes32) {
        return _feedIds[asset][sessionId];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Shared verification logic for both verifyPrice and verifyPriceForSession.
    function _verifyPriceWithFeed(
        bytes32 asset,
        bytes32 feedId,
        bytes calldata priceData
    ) private returns (uint256 price, uint256 timestamp) {
        if (feedId == bytes32(0)) revert FeedNotConfigured(asset);

        (bytes[] memory updateData, uint64 minPublishTime, uint64 maxPublishTime) =
            abi.decode(priceData, (bytes[], uint64, uint64));

        bytes32[] memory priceIds = new bytes32[](1);
        priceIds[0] = feedId;

        uint256 fee = pyth.getUpdateFee(updateData);
        PythStructs.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdates{value: fee}(updateData, priceIds, minPublishTime, maxPublishTime);

        PythStructs.Price memory pythPrice = feeds[0].price;
        price = _normalizePythPrice(asset, pythPrice);
        timestamp = uint256(uint64(pythPrice.publishTime));
    }

    function _normalizePythPrice(bytes32 asset, PythStructs.Price memory pythPrice) private view returns (uint256) {
        if (pythPrice.price <= 0) revert NegativePrice(asset, pythPrice.price);

        uint256 rawPrice = uint256(uint64(pythPrice.price));

        // conf shares price's exponent, so the relative test needs no rescaling.
        if (uint256(pythPrice.conf) * BPS > rawPrice * maxConfBps) {
            revert ConfidenceTooWide(asset, pythPrice.conf, rawPrice, maxConfBps);
        }

        int32 expo = pythPrice.expo;

        if (expo >= 0) {
            return rawPrice * (10 ** (18 + uint32(expo)));
        } else {
            uint32 absExpo = uint32(-expo);
            if (absExpo <= 18) {
                return rawPrice * (10 ** (18 - absExpo));
            } else {
                return rawPrice / (10 ** (absExpo - 18));
            }
        }
    }
}
