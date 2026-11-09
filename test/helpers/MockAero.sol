// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title MockCLPool — Slipstream pool state: tokens, spacing, price and gauge
contract MockCLPool {
    address public immutable token0;
    address public immutable token1;
    int24 public immutable tickSpacing;
    uint160 public sqrtPriceX96;
    address public gauge;

    constructor(address tokenA, address tokenB, int24 spacing) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        tickSpacing = spacing;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, true);
    }

    function setSqrtPrice(
        uint160 price
    ) external {
        sqrtPriceX96 = price;
    }

    /// @notice Set the pool price from an asset price (18 decimals, eUSD per whole asset).
    function setPrice(address asset, uint256 price) external {
        uint256 scale = 10 ** MockERC20(asset).decimals();
        sqrtPriceX96 = uint160(LiquidityMath.sqrtPriceFromOracle(price, scale, token0 == asset));
    }

    function setGauge(
        address gauge_
    ) external {
        gauge = gauge_;
    }
}

/// @title MockCLFactory — canonical pool per (pair, spacing)
contract MockCLFactory {
    mapping(address => mapping(address => mapping(int24 => address))) public pools;

    function createPool(address tokenA, address tokenB, int24 spacing) external returns (MockCLPool pool) {
        pool = new MockCLPool(tokenA, tokenB, spacing);
        pools[tokenA][tokenB][spacing] = address(pool);
        pools[tokenB][tokenA][spacing] = address(pool);
    }

    function getPool(address tokenA, address tokenB, int24 spacing) external view returns (address) {
        return pools[tokenA][tokenB][spacing];
    }
}

/// @title MockPositionManager — Slipstream position NFTs priced with the vault's own math
/// @notice Holds principal itself and pays removals at the pool price. Mint and increase charge
///         1 wei over the rounded-down quote per token, like the pool's round-up. Tests mint extra
///         tokens to this contract to cover removals after price moves and set swap fees owed.
contract MockPositionManager is ERC721 {
    using SafeERC20 for IERC20;

    error NotApproved();
    error NotEmpty();
    error ZeroLiquidity();
    error PriceSlippage();

    struct Position {
        MockCLPool pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 owed0;
        uint256 owed1;
    }

    MockCLFactory public immutable factory;
    uint256 public nextId = 1;
    mapping(uint256 => Position) internal _pos;

    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    constructor(
        MockCLFactory factory_
    ) ERC721("Slipstream Positions", "SLIP") {
        factory = factory_;
    }

    modifier authorized(
        uint256 tokenId
    ) {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) revert NotApproved();
        _;
    }

    function setFeesOwed(uint256 tokenId, uint256 fee0, uint256 fee1) external {
        _pos[tokenId].owed0 += fee0;
        _pos[tokenId].owed1 += fee1;
    }

    function mint(
        MintParams calldata p
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        MockCLPool pool = MockCLPool(factory.getPool(p.token0, p.token1, p.tickSpacing));
        tokenId = nextId++;
        _pos[tokenId] = Position(pool, p.tickLower, p.tickUpper, 0, 0, 0);
        (liquidity, amount0, amount1) = _add(tokenId, p.amount0Desired, p.amount1Desired);
        _mint(p.recipient, tokenId);
    }

    /// @dev Like Slipstream: anyone may add to a position unless it sits in the pool's gauge.
    function increaseLiquidity(
        IncreaseLiquidityParams calldata p
    ) external returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        address gauge = _pos[p.tokenId].pool.gauge();
        if (gauge != address(0) && _ownerOf(p.tokenId) == gauge && msg.sender != gauge) revert NotApproved();
        return _add(p.tokenId, p.amount0Desired, p.amount1Desired);
    }

    function positions(
        uint256 tokenId
    )
        external
        view
        returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Position storage pos = _pos[tokenId];
        return (
            0,
            address(0),
            address(0),
            address(0),
            0,
            pos.tickLower,
            pos.tickUpper,
            pos.liquidity,
            0,
            0,
            uint128(pos.owed0),
            uint128(pos.owed1)
        );
    }

    function decreaseLiquidity(
        DecreaseLiquidityParams calldata p
    ) external authorized(p.tokenId) returns (uint256 amount0, uint256 amount1) {
        Position storage pos = _pos[p.tokenId];
        (amount0, amount1) = _amounts(pos, p.liquidity);
        if (amount0 < p.amount0Min || amount1 < p.amount1Min) revert PriceSlippage();
        pos.liquidity -= p.liquidity;
        pos.owed0 += amount0;
        pos.owed1 += amount1;
    }

    function collect(
        CollectParams calldata p
    ) external authorized(p.tokenId) returns (uint256 amount0, uint256 amount1) {
        Position storage pos = _pos[p.tokenId];
        amount0 = pos.owed0 < p.amount0Max ? pos.owed0 : p.amount0Max;
        amount1 = pos.owed1 < p.amount1Max ? pos.owed1 : p.amount1Max;
        pos.owed0 -= amount0;
        pos.owed1 -= amount1;
        if (amount0 > 0) IERC20(pos.pool.token0()).safeTransfer(p.recipient, amount0);
        if (amount1 > 0) IERC20(pos.pool.token1()).safeTransfer(p.recipient, amount1);
    }

    function burn(
        uint256 tokenId
    ) external authorized(tokenId) {
        Position storage pos = _pos[tokenId];
        if (pos.liquidity != 0 || pos.owed0 != 0 || pos.owed1 != 0) revert NotEmpty();
        delete _pos[tokenId];
        _burn(tokenId);
    }

    function _add(
        uint256 tokenId,
        uint256 desired0,
        uint256 desired1
    ) internal returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        Position storage pos = _pos[tokenId];
        liquidity = LiquidityMath.getLiquidityForAmounts(
            pos.pool.sqrtPriceX96(),
            LiquidityMath.getSqrtPriceAtTick(pos.tickLower),
            LiquidityMath.getSqrtPriceAtTick(pos.tickUpper),
            desired0,
            desired1
        );
        if (liquidity == 0) revert ZeroLiquidity();
        (amount0, amount1) = _amounts(pos, liquidity);
        if (amount0 > 0) amount0 += 1;
        if (amount1 > 0) amount1 += 1;
        pos.liquidity += liquidity;
        if (amount0 > 0) IERC20(pos.pool.token0()).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(pos.pool.token1()).safeTransferFrom(msg.sender, address(this), amount1);
    }

    function _amounts(Position storage pos, uint128 liquidity) internal view returns (uint256, uint256) {
        return LiquidityMath.getAmountsForLiquidity(
            pos.pool.sqrtPriceX96(),
            LiquidityMath.getSqrtPriceAtTick(pos.tickLower),
            LiquidityMath.getSqrtPriceAtTick(pos.tickUpper),
            liquidity
        );
    }
}

/// @title MockCLGauge — holds staked NFTs and pays a fixed emission per unstake or claim
contract MockCLGauge is IERC721Receiver {
    error NotStaker();

    MockPositionManager public immutable nft;
    MockERC20 public immutable rewardToken;
    mapping(uint256 => address) public stakerOf;
    mapping(address => uint256) public earned;

    constructor(
        MockPositionManager nft_
    ) {
        nft = nft_;
        rewardToken = new MockERC20("xAERO", "xAERO", 18);
    }

    function setEarned(address account, uint256 amount) external {
        earned[account] = amount;
    }

    function deposit(
        uint256 tokenId
    ) external {
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        stakerOf[tokenId] = msg.sender;
    }

    function withdraw(
        uint256 tokenId
    ) external {
        if (stakerOf[tokenId] != msg.sender) revert NotStaker();
        delete stakerOf[tokenId];
        _pay(msg.sender, msg.sender);
        nft.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    function claimEmissions(address account, address recipient) external {
        if (msg.sender != account) revert NotStaker();
        _pay(account, recipient);
    }

    function _pay(address account, address recipient) internal {
        uint256 amount = earned[account];
        if (amount > 0) {
            earned[account] = 0;
            rewardToken.mint(recipient, amount);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
