// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {PRECISION} from "../interfaces/types/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPyth} from "@pythnetwork/IPyth.sol";
import {PythStructs} from "@pythnetwork/PythStructs.sol";

/// @title PythOracleVerifier — Pyth Network oracle with push model
/// @notice Wraps the Pyth oracle on Base to implement IOracleVerifier.
///         Prices are pushed via updatePriceFeeds() and read via getPrice().
///         verifyPrice() parses a Pyth update inline for force execution proofs.
contract PythOracleVerifier is IOracleVerifier, Ownable {
    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    IPyth public immutable pyth;
    uint256 public maxPriceAge;

    /// @dev Asset ticker → Pyth price feed ID.
    mapping(bytes32 => bytes32) private _feedIds;

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

    constructor(address admin_, address pyth_, uint256 maxPriceAge_) Ownable(admin_) {
        pyth = IPyth(pyth_);
        maxPriceAge = maxPriceAge_;
    }

    // ──────────────────────────────────────────────────────────
    //  Push — update price feeds
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev updateData is abi.encode(bytes[]) — Pyth price update blobs.
    ///      Caller must send enough ETH to cover pyth.getUpdateFee().
    function updatePriceFeeds(bytes calldata updateData) external payable override {
        bytes[] memory pythUpdateData = abi.decode(updateData, (bytes[]));
        uint256 updateFee = pyth.getUpdateFee(pythUpdateData);
        pyth.updatePriceFeeds{value: updateFee}(pythUpdateData);
    }

    // ──────────────────────────────────────────────────────────
    //  Read — cached prices
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    function getPrice(bytes32 asset) external view override returns (uint256 price, uint256 timestamp) {
        bytes32 feedId = _feedIds[asset];
        if (feedId == bytes32(0)) revert FeedNotConfigured(asset);

        PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(feedId, maxPriceAge);
        price = _normalizePythPrice(asset, pythPrice);
        timestamp = pythPrice.publishTime;
    }

    // ──────────────────────────────────────────────────────────
    //  Verify — inline proof (force execution)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOracleVerifier
    /// @dev priceData encodes (bytes[] updateData, uint64 minPublishTime, uint64 maxPublishTime).
    ///      The caller submits a Pyth VAA blob attesting to a price within [minPublishTime, maxPublishTime].
    ///      parsePriceFeedUpdates cryptographically verifies the VAA and returns the attested price.
    ///      Caller must send ETH >= verifyFee(priceData) to cover the Pyth fee.
    function verifyPrice(bytes32 asset, bytes calldata priceData)
        external
        payable
        override
        returns (uint256 price, uint256 timestamp)
    {
        bytes32 feedId = _feedIds[asset];
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

    /// @inheritdoc IOracleVerifier
    /// @dev Decodes updateData from priceData and returns pyth.getUpdateFee(updateData).
    function verifyFee(bytes calldata priceData) external view override returns (uint256) {
        (bytes[] memory updateData,,) = abi.decode(priceData, (bytes[], uint64, uint64));
        return pyth.getUpdateFee(updateData);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — signer management (no-op for Pyth)
    // ──────────────────────────────────────────────────────────

    function addSigner(address) external pure override { revert("PythOracle: no signers"); }
    function removeSigner(address) external pure override { revert("PythOracle: no signers"); }
    function isSigner(address) external pure override returns (bool) { return false; }
    function setAssetOracleConfig(bytes32, uint256, uint256) external pure override {
        revert("PythOracle: use setFeedId/setMaxPriceAge");
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — feed configuration
    // ──────────────────────────────────────────────────────────

    function setFeedId(bytes32 asset, bytes32 feedId) external onlyOwner {
        _feedIds[asset] = feedId;
        emit FeedIdSet(asset, feedId);
    }

    function setMaxPriceAge(uint256 newMaxAge) external onlyOwner {
        uint256 old = maxPriceAge;
        maxPriceAge = newMaxAge;
        emit MaxPriceAgeUpdated(old, newMaxAge);
    }

    function getFeedId(bytes32 asset) external view returns (bytes32) {
        return _feedIds[asset];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    function _normalizePythPrice(bytes32 asset, PythStructs.Price memory pythPrice) private pure returns (uint256) {
        if (pythPrice.price <= 0) revert NegativePrice(asset, pythPrice.price);

        uint256 rawPrice = uint256(uint64(pythPrice.price));
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
