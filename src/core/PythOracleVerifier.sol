// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {PRECISION} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPyth} from "@pythnetwork/IPyth.sol";
import {PythStructs} from "@pythnetwork/PythStructs.sol";

/// @title PythOracleVerifier — Pyth Network price verification
/// @notice Wraps the Pyth oracle on Base to implement IOracleVerifier.
///         Normalizes Pyth prices (int64 with variable exponent) to 18-decimal uint256.
contract PythOracleVerifier is IOracleVerifier, Ownable {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    /// @notice The Pyth oracle contract on Base.
    IPyth public immutable pyth;

    /// @notice Maximum acceptable price age in seconds for spot reads.
    uint256 public maxPriceAge;

    /// @dev Asset ticker → Pyth price feed ID.
    mapping(bytes32 => bytes32) private _feedIds;

    /// @dev Per-asset last verified price (for deviation checks and getLastPrice).
    mapping(bytes32 => LastPrice) private _lastPrices;

    struct LastPrice {
        uint256 price;
        uint256 timestamp;
    }

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    error FeedNotConfigured(bytes32 asset);
    error NegativePrice(bytes32 asset, int64 rawPrice);

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    event FeedIdSet(bytes32 indexed asset, bytes32 feedId);
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param admin_      Protocol admin.
    /// @param pyth_       Pyth contract address on Base.
    /// @param maxPriceAge_ Maximum acceptable price age in seconds.
    constructor(address admin_, address pyth_, uint256 maxPriceAge_) Ownable(admin_) {
        pyth = IPyth(pyth_);
        maxPriceAge = maxPriceAge_;
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — core
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev `priceData` is encoded as `bytes[] updateData` for Pyth.
    ///      Caller must send enough ETH to cover `pyth.getUpdateFee()`.
    ///      After updating, reads the price with staleness check.
    function verifyPrice(
        bytes32 asset,
        bytes calldata priceData
    ) external payable override returns (uint256 price, uint256 timestamp, bool marketOpen) {
        bytes32 feedId = _feedIds[asset];
        if (feedId == bytes32(0)) revert FeedNotConfigured(asset);

        // Decode and update Pyth price feeds
        bytes[] memory updateData = abi.decode(priceData, (bytes[]));
        uint256 updateFee = pyth.getUpdateFee(updateData);
        pyth.updatePriceFeeds{value: updateFee}(updateData);

        // Read the price with staleness check
        PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(feedId, maxPriceAge);

        price = _normalizePythPrice(asset, pythPrice);
        timestamp = pythPrice.publishTime;
        marketOpen = true; // Pyth doesn't provide market-open status

        _lastPrices[asset] = LastPrice(price, timestamp);

        emit PriceVerified(asset, price, timestamp, marketOpen);
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — signer management (no-op for Pyth)
    // ──────────────────────────────────────────────────────────

    /// @dev Not applicable for Pyth. Reverts.
    function addSigner(address) external pure override {
        revert("PythOracle: no signers");
    }

    /// @dev Not applicable for Pyth. Reverts.
    function removeSigner(address) external pure override {
        revert("PythOracle: no signers");
    }

    /// @dev Always returns false — Pyth doesn't use signers.
    function isSigner(address) external pure override returns (bool) {
        return false;
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — per-asset config (no-op for Pyth)
    // ──────────────────────────────────────────────────────────

    /// @dev Not used for Pyth. Staleness is handled via maxPriceAge.
    function setAssetOracleConfig(bytes32, uint256, uint256) external pure override {
        revert("PythOracle: use setFeedId");
    }

    // ──────────────────────────────────────────────────────────
    //  IOracleVerifier — view
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function getLastPrice(bytes32 asset) external view override returns (uint256 price, uint256 timestamp) {
        LastPrice storage lp = _lastPrices[asset];
        return (lp.price, lp.timestamp);
    }

    /// @dev Not applicable for Pyth.
    function getSequenceNumber(bytes32) external pure override returns (uint256) {
        return 0;
    }

    // ──────────────────────────────────────────────────────────
    //  Pyth-specific: parse price updates within a time window
    // ──────────────────────────────────────────────────────────

    /// @notice Parse Pyth price updates and return a verified price within a time window.
    ///         Used by OwnMarket for force execution price range proofs.
    /// @param asset         Asset ticker.
    /// @param updateData    Pyth price update blob.
    /// @param minPublishTime Earliest acceptable publish time.
    /// @param maxPublishTime Latest acceptable publish time.
    /// @return price        Verified price in 18 decimals.
    /// @return timestamp    Price publish time.
    function parsePriceInWindow(
        bytes32 asset,
        bytes[] calldata updateData,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (uint256 price, uint256 timestamp) {
        bytes32 feedId = _feedIds[asset];
        if (feedId == bytes32(0)) revert FeedNotConfigured(asset);

        bytes32[] memory priceIds = new bytes32[](1);
        priceIds[0] = feedId;

        uint256 updateFee = pyth.getUpdateFee(updateData);
        PythStructs.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdates{value: updateFee}(updateData, priceIds, minPublishTime, maxPublishTime);

        price = _normalizePythPrice(asset, feeds[0].price);
        timestamp = feeds[0].price.publishTime;
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — feed configuration
    // ──────────────────────────────────────────────────────────

    /// @notice Set the Pyth price feed ID for an asset.
    function setFeedId(bytes32 asset, bytes32 feedId) external onlyOwner {
        _feedIds[asset] = feedId;
        emit FeedIdSet(asset, feedId);
    }

    /// @notice Update the maximum acceptable price age.
    function setMaxPriceAge(uint256 newMaxAge) external onlyOwner {
        uint256 old = maxPriceAge;
        maxPriceAge = newMaxAge;
        emit MaxPriceAgeUpdated(old, newMaxAge);
    }

    /// @notice Return the Pyth feed ID for an asset.
    function getFeedId(bytes32 asset) external view returns (bytes32) {
        return _feedIds[asset];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    /// @dev Convert a Pyth Price (int64 + int32 expo) to uint256 with 18 decimals.
    ///      Pyth prices are `price * 10^expo`. We normalize to `price * 10^18`.
    function _normalizePythPrice(bytes32 asset, PythStructs.Price memory pythPrice) private pure returns (uint256) {
        if (pythPrice.price <= 0) revert NegativePrice(asset, pythPrice.price);

        uint256 rawPrice = uint256(uint64(pythPrice.price));
        int32 expo = pythPrice.expo;

        // Target: rawPrice * 10^expo → normalized * 10^(-18)
        // normalized = rawPrice * 10^(18 + expo)
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
