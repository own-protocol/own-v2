// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "../../src/interfaces/external/IFables.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockFablesLedger — Fables ledger hook and v4 PoolManager slot0 in one contract
/// @notice Holds deposited tokens itself and pays withdrawals at the price set for the pool, using
///         the same concentrated-liquidity math as the vault. Deposits charge 1 wei over the
///         rounded-down quote per token (like v4's round-up), so callers must leave headroom.
///         Tests mint extra tokens to this contract to cover withdrawals after price moves.
contract MockFablesLedger {
    using SafeERC20 for IERC20;

    error PrincipalAboveMax(uint256 paid, uint256 max);
    error PrincipalBelowMin(uint256 received, uint256 min);
    error DeadlineExpired();
    error DeskRetired();
    error InsufficientUnstakedShares();
    error NothingToClaim();
    error ClaimFeeAboveMax();

    /// @dev PoolManager-style storage of slot0 per state slot (extsload).
    mapping(bytes32 => bytes32) public slots;

    /// @notice Shares per owner per range id.
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    /// @notice Staked shares per owner per range id.
    mapping(address => mapping(uint256 => uint128)) public stakedOf;

    /// @notice Whether staking is accepted.
    bool public gaugeEarning = true;

    /// @notice Claim fee charged on swap fees (BPS).
    uint16 public claimFeeBps;

    /// @notice Swap fees owed per owner (currency0, currency1).
    mapping(address => uint256[2]) public feesOwed;

    function poolId(
        PoolKey memory key
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function rangeId(PoolKey memory key, int24 tickLower, int24 tickUpper) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId(key), tickLower, tickUpper)));
    }

    function setSqrtPrice(PoolKey memory key, uint160 sqrtPriceX96) public {
        bytes32 slot = keccak256(abi.encodePacked(poolId(key), bytes32(uint256(6))));
        slots[slot] = bytes32(uint256(sqrtPriceX96));
    }

    /// @notice Set the pool price from an asset price (18 decimals, eUSD per whole asset).
    function setPrice(PoolKey memory key, address asset, uint256 price) external {
        uint256 scale = 10 ** MockERC20(asset).decimals();
        setSqrtPrice(key, uint160(LiquidityMath.sqrtPriceFromOracle(price, scale, key.currency0 == asset)));
    }

    function setGaugeEarning(
        bool earning
    ) external {
        gaugeEarning = earning;
    }

    function setClaimFeeBps(
        uint16 bps
    ) external {
        claimFeeBps = bps;
    }

    function setFeesOwed(address owner, uint256 fee0, uint256 fee1) external {
        feesOwed[owner] = [fee0, fee1];
    }

    function extsload(
        bytes32 slot
    ) external view returns (bytes32) {
        return slots[slot];
    }

    function sqrtPriceOf(
        PoolKey memory key
    ) public view returns (uint256) {
        return uint256(slots[keccak256(abi.encodePacked(poolId(key), bytes32(uint256(6))))]);
    }

    function _amounts(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256, uint256) {
        return LiquidityMath.getAmountsForLiquidity(
            sqrtPriceOf(key),
            LiquidityMath.getSqrtPriceAtTick(tickLower),
            LiquidityMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
    }

    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external payable {
        if (block.timestamp > deadline) revert DeadlineExpired();
        (uint256 a0, uint256 a1) = _amounts(key, tickLower, tickUpper, liquidity);
        if (a0 > 0) a0 += 1;
        if (a1 > 0) a1 += 1;
        if (a0 > amount0Max) revert PrincipalAboveMax(a0, amount0Max);
        if (a1 > amount1Max) revert PrincipalAboveMax(a1, amount1Max);
        balanceOf[msg.sender][rangeId(key, tickLower, tickUpper)] += liquidity;
        if (a0 > 0) IERC20(key.currency0).safeTransferFrom(msg.sender, address(this), a0);
        if (a1 > 0) IERC20(key.currency1).safeTransferFrom(msg.sender, address(this), a1);
    }

    function withdraw(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external {
        if (block.timestamp > deadline) revert DeadlineExpired();
        uint256 id = rangeId(key, tickLower, tickUpper);
        uint256 unstaked = balanceOf[msg.sender][id] - stakedOf[msg.sender][id];
        if (unstaked < liquidity) stakedOf[msg.sender][id] -= uint128(liquidity - unstaked);
        balanceOf[msg.sender][id] -= liquidity;
        (uint256 a0, uint256 a1) = _amounts(key, tickLower, tickUpper, liquidity);
        if (a0 < amount0Min) revert PrincipalBelowMin(a0, amount0Min);
        if (a1 < amount1Min) revert PrincipalBelowMin(a1, amount1Min);
        if (a0 > 0) IERC20(key.currency0).safeTransfer(to, a0);
        if (a1 > 0) IERC20(key.currency1).safeTransfer(to, a1);
    }

    function claimFees(PoolKey calldata key, int24, int24, address to, uint16 maxFeeBps) external {
        if (claimFeeBps > maxFeeBps) revert ClaimFeeAboveMax();
        uint256[2] memory owed = feesOwed[msg.sender];
        if (owed[0] == 0 && owed[1] == 0) revert NothingToClaim();
        delete feesOwed[msg.sender];
        if (owed[0] > 0) IERC20(key.currency0).safeTransfer(to, owed[0]);
        if (owed[1] > 0) IERC20(key.currency1).safeTransfer(to, owed[1]);
    }

    function stake(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 shares, uint256) external {
        if (!gaugeEarning) revert DeskRetired();
        uint256 id = rangeId(key, tickLower, tickUpper);
        if (balanceOf[msg.sender][id] - stakedOf[msg.sender][id] < shares) revert InsufficientUnstakedShares();
        stakedOf[msg.sender][id] += shares;
    }

    function unstake(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 shares) external {
        stakedOf[msg.sender][rangeId(key, tickLower, tickUpper)] -= shares;
    }
}

/// @title MockEmissionStream — pays a cumulative FABLES amount per account, no proof check
contract MockEmissionStream {
    error NothingToClaim();
    error InvalidKind();

    MockERC20 public immutable ff;
    mapping(uint256 => uint256) public claimed;

    constructor() {
        ff = new MockERC20("Fables", "FABLES", 18);
    }

    function claim(uint8 kind, uint256 id, uint256 cumulative, bytes32[] calldata) external returns (uint256 amount) {
        if (kind != 0) revert InvalidKind();
        if (cumulative <= claimed[id]) revert NothingToClaim();
        amount = cumulative - claimed[id];
        claimed[id] = cumulative;
        ff.mint(address(uint160(id)), amount);
    }
}
