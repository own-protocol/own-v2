// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPyth} from "@pythnetwork/IPyth.sol";

import {IPythEvents} from "@pythnetwork/IPythEvents.sol";
import {PythStructs} from "@pythnetwork/PythStructs.sol";

/// @title MockPyth — Minimal Pyth mock for unit testing PythOracleVerifier.
/// @dev Supports getPriceNoOlderThan, updatePriceFeeds, parsePriceFeedUpdates, and getUpdateFee.
contract MockPyth is IPyth {
    uint256 public constant UPDATE_FEE_PER_FEED = 1; // 1 wei per feed

    mapping(bytes32 => PythStructs.Price) private _prices;

    // ── Admin helpers (test-only) ────────────────────────────

    /// @dev Directly set a cached price for a feed ID (bypasses update flow).
    function setPrice(bytes32 feedId, int64 price, int32 expo, uint256 publishTime) external {
        _prices[feedId] = PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }

    // ── IPyth implementation ─────────────────────────────────

    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view override returns (PythStructs.Price memory price) {
        price = _prices[id];
        require(price.publishTime > 0, "MockPyth: no price");
        require(block.timestamp - price.publishTime <= age, "MockPyth: price too old");
    }

    function getUpdateFee(
        bytes[] calldata updateData
    ) external pure override returns (uint256 feeAmount) {
        return updateData.length * UPDATE_FEE_PER_FEED;
    }

    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable override {
        uint256 fee = updateData.length * UPDATE_FEE_PER_FEED;
        require(msg.value >= fee, "MockPyth: insufficient fee");
        for (uint256 i; i < updateData.length; i++) {
            (bytes32 feedId, int64 price, int32 expo, uint256 publishTime) =
                abi.decode(updateData[i], (bytes32, int64, int32, uint256));
            _prices[feedId] = PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
        }
    }

    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable override returns (PythStructs.PriceFeed[] memory priceFeeds) {
        uint256 fee = updateData.length * UPDATE_FEE_PER_FEED;
        require(msg.value >= fee, "MockPyth: insufficient fee");

        priceFeeds = new PythStructs.PriceFeed[](priceIds.length);
        for (uint256 i; i < updateData.length; i++) {
            (bytes32 feedId, int64 price, int32 expo, uint256 publishTime) =
                abi.decode(updateData[i], (bytes32, int64, int32, uint256));
            require(publishTime >= minPublishTime && publishTime <= maxPublishTime, "MockPyth: out of range");
            for (uint256 j; j < priceIds.length; j++) {
                if (priceIds[j] == feedId) {
                    priceFeeds[j] = PythStructs.PriceFeed({
                        id: feedId,
                        price: PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime}),
                        emaPrice: PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime})
                    });
                }
            }
        }
    }

    // ── Unused IPyth methods (revert) ────────────────────────

    function getValidTimePeriod() external pure override returns (uint256) {
        return 120;
    }

    function getPrice(
        bytes32
    ) external pure override returns (PythStructs.Price memory) {
        revert("MockPyth: use getPriceNoOlderThan");
    }

    function getEmaPrice(
        bytes32
    ) external pure override returns (PythStructs.Price memory) {
        revert("MockPyth: not implemented");
    }

    function getPriceUnsafe(
        bytes32
    ) external pure override returns (PythStructs.Price memory) {
        revert("MockPyth: not implemented");
    }

    function getEmaPriceUnsafe(
        bytes32
    ) external pure override returns (PythStructs.Price memory) {
        revert("MockPyth: not implemented");
    }

    function getEmaPriceNoOlderThan(bytes32, uint256) external pure override returns (PythStructs.Price memory) {
        revert("MockPyth: not implemented");
    }

    function updatePriceFeedsIfNecessary(
        bytes[] calldata,
        bytes32[] calldata,
        uint64[] calldata
    ) external payable override {
        revert("MockPyth: not implemented");
    }
}
