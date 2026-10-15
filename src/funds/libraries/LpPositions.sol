// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFundStaking} from "../../interfaces/IFundStaking.sol";
import {IFundVenue} from "../../interfaces/IFundVenue.sol";
import {IPositionManager} from "../../interfaces/external/IPositionManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title LpPositions — the staking module's Uniswap v4 position checks and fee collection
/// @notice External library, linked at deployment and run in the staking module's context
///         (delegatecall), so the module stays under the contract size limit.
library LpPositions {
    using PoolIdLibrary for PoolKey;

    // v4-periphery Actions.
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant TAKE_PAIR = 0x11;

    /// @notice Liquidity of a full-range position in the pool the fund trades in now; reverts for
    ///         any other position or an empty one.
    /// @param positionManager The PositionManager.
    /// @param venue           The fund's venue.
    /// @param tokenId         The position.
    /// @return liquidity The position's liquidity.
    function fundLiquidity(
        IPositionManager positionManager,
        address venue,
        uint256 tokenId
    ) public view returns (uint128 liquidity) {
        (PoolKey memory key, uint256 info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolKey memory fundKey = IFundVenue(venue).poolKey();
        if (fundKey.tickSpacing == 0 || PoolId.unwrap(key.toId()) != PoolId.unwrap(fundKey.toId())) {
            revert IFundStaking.NotFundPosition();
        }
        // PositionInfo packs tick lower at bits 8-31 and tick upper at bits 32-55.
        if (
            int24(uint24(info >> 8)) != TickMath.minUsableTick(key.tickSpacing)
                || int24(uint24(info >> 32)) != TickMath.maxUsableTick(key.tickSpacing)
        ) revert IFundStaking.NotFullRange();
        liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert IFundStaking.ZeroAmount();
    }

    /// @notice Sends a position's accrued fees in both currencies to `to`, leaving its liquidity
    ///         as it is. The caller must own or be approved for the position.
    /// @param positionManager The PositionManager.
    /// @param tokenId         The position.
    /// @param to              Receiver of the fees.
    function collectFees(IPositionManager positionManager, uint256 tokenId, address to) public {
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
