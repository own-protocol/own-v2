// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPositionManager} from "../../interfaces/external/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title PositionFees — collects a Uniswap v4 position's swap fees through the PositionManager
library PositionFees {
    // v4-periphery Actions.
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant TAKE_PAIR = 0x11;

    /// @notice Sends a position's accrued fees in both currencies to `to`, leaving its liquidity
    ///         as it is. The caller must own or be approved for the position.
    /// @param positionManager The PositionManager.
    /// @param tokenId         The position.
    /// @param to              Receiver of the fees.
    function collect(IPositionManager positionManager, uint256 tokenId, address to) internal {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        bytes[] memory params = new bytes[](2);
        // Removing zero liquidity settles the fees into the caller's deltas.
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), block.timestamp
        );
    }
}
