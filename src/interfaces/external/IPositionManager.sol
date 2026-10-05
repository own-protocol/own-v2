// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title IPositionManager — the parts of the Uniswap v4 PositionManager (v4-periphery) the fund
///        platform uses
/// @notice Positions are ERC-721 tokens. Only the owner or an approved address can change a
///         position's liquidity or collect its fees.
interface IPositionManager {
    /// @notice Run a batch of position actions inside a pool manager unlock.
    /// @param unlockData `abi.encode(bytes actions, bytes[] params)`, one byte per action.
    /// @param deadline   Latest timestamp the batch may run.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice A position's pool and packed info (tick upper at bits 32-55, tick lower at bits 8-31).
    /// @param tokenId The position.
    /// @return poolKey The pool.
    /// @return info    Packed position info.
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory poolKey, uint256 info);

    /// @notice A position's liquidity.
    /// @param tokenId The position.
    /// @return liquidity The liquidity.
    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128 liquidity);

    /// @notice ERC-721 transfer without a receiver check.
    /// @param from    Owner.
    /// @param to      Receiver.
    /// @param tokenId The position.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice ERC-721 transfer that calls `onERC721Received` on a contract receiver.
    /// @param from    Owner.
    /// @param to      Receiver.
    /// @param tokenId The position.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice ERC-721 owner.
    /// @param tokenId The position.
    /// @return The owner.
    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
}
