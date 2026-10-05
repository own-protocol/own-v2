// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title MockPositionManager — Uniswap v4 position NFTs with recorded (not pooled) liquidity
/// @notice Positions are bookkeeping only. Fee collection accepts exactly the
///         DECREASE_LIQUIDITY(0) + TAKE_PAIR batch and pays fees the test funded with {setFees}.
contract MockPositionManager is ERC721 {
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 fees0;
        uint256 fees1;
    }

    uint256 public nextTokenId = 1;
    mapping(uint256 => Position) internal _positions;

    constructor() ERC721("Uniswap v4 Positions NFT", "UNI-V4-POSM") {}

    function mint(
        address to,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _positions[tokenId] = Position(key, tickLower, tickUpper, liquidity, 0, 0);
        _mint(to, tokenId);
    }

    /// @dev The caller must have sent this contract the fee tokens.
    function setFees(uint256 tokenId, uint256 fees0, uint256 fees1) external {
        _positions[tokenId].fees0 = fees0;
        _positions[tokenId].fees1 = fees1;
    }

    function setLiquidity(uint256 tokenId, uint128 liquidity) external {
        _positions[tokenId].liquidity = liquidity;
    }

    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory key, uint256 info) {
        Position storage p = _positions[tokenId];
        key = p.key;
        info = (uint256(uint24(p.tickUpper)) << 32) | (uint256(uint24(p.tickLower)) << 8);
    }

    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        require(deadline >= block.timestamp, "deadline");
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(keccak256(actions) == keccak256(hex"0111"), "actions");
        (uint256 tokenId, uint256 liquidity,,,) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
        require(liquidity == 0, "liquidity");
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "NotApproved");
        (Currency c0, Currency c1, address to) = abi.decode(params[1], (Currency, Currency, address));
        Position storage p = _positions[tokenId];
        require(Currency.unwrap(c0) == Currency.unwrap(p.key.currency0), "currency0");
        require(Currency.unwrap(c1) == Currency.unwrap(p.key.currency1), "currency1");
        (uint256 f0, uint256 f1) = (p.fees0, p.fees1);
        (p.fees0, p.fees1) = (0, 0);
        if (f0 != 0) IERC20(Currency.unwrap(c0)).transfer(to, f0);
        if (f1 != 0) IERC20(Currency.unwrap(c1)).transfer(to, f1);
    }
}
