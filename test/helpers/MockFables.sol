// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey, SwapParams} from "../../src/interfaces/external/IFables.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IUnlockCallback {
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory);
}

/// @title MockFablesLedger — Fables ledger hook and v4 PoolManager in one contract
/// @notice Holds deposited tokens itself and pays withdrawals at the price set for the pool, using
///         the same concentrated-liquidity math as the vault. Swaps (inside `unlock`) fill at the
///         pool's set price less `swapFeeBps`, filling `fillBps` of the input, with v4-style delta
///         accounting that must net to zero by the end of the unlock. Deposits charge 1 wei over the
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
    error NotUnlocked();
    error CurrencyNotSettled();

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

    /// @notice Fee taken from every swap's output (BPS).
    uint16 public swapFeeBps;

    /// @notice Share of a swap's input that fills (BPS).
    uint16 public fillBps = 10_000;

    bool internal _unlocked;
    mapping(address => int256) internal _deltas;
    address[] internal _touched;
    address internal _synced;
    uint256 internal _syncedBalance;

    function poolId(
        PoolKey memory key
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function rangeId(PoolKey memory key, int24 tickLower, int24 tickUpper) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId(key), tickLower, tickUpper)));
    }

    /// @dev Stores slot0 as v4 packs it: sqrt price in the low 160 bits, the tick in the next 24.
    function setSqrtPrice(PoolKey memory key, uint160 sqrtPriceX96) public {
        bytes32 slot = keccak256(abi.encodePacked(poolId(key), bytes32(uint256(6))));
        uint256 tickBits = sqrtPriceX96 == 0 ? 0 : uint256(uint24(tickAtSqrtPrice(sqrtPriceX96))) << 160;
        slots[slot] = bytes32(tickBits | uint256(sqrtPriceX96));
    }

    /// @dev Greatest tick whose sqrt price is at or below `sqrtPriceX96` (the v4 slot0 tick).
    function tickAtSqrtPrice(
        uint160 sqrtPriceX96
    ) public pure returns (int24) {
        int24 lo = LiquidityMath.MIN_TICK;
        int24 hi = LiquidityMath.MAX_TICK;
        while (hi - lo > 1) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            if (LiquidityMath.getSqrtPriceAtTick(mid) <= sqrtPriceX96) lo = mid;
            else hi = mid;
        }
        return lo;
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

    function setSwapFeeBps(
        uint16 bps
    ) external {
        swapFeeBps = bps;
    }

    function setFillBps(
        uint16 bps
    ) external {
        fillBps = bps;
    }

    function unlock(
        bytes calldata data
    ) external returns (bytes memory result) {
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint256 i; i < _touched.length; ++i) {
            if (_deltas[_touched[i]] != 0) revert CurrencyNotSettled();
        }
        delete _touched;
        _unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256) {
        if (!_unlocked) revert NotUnlocked();
        uint256 amountIn = Math.mulDiv(uint256(-params.amountSpecified), fillBps, 10_000);
        uint256 sqrtP = sqrtPriceOf(key);
        uint256 q96 = 1 << 96;
        uint256 out = params.zeroForOne
            ? Math.mulDiv(Math.mulDiv(amountIn, sqrtP, q96), sqrtP, q96)
            : Math.mulDiv(Math.mulDiv(amountIn, q96, sqrtP), q96, sqrtP);
        out = Math.mulDiv(out, 10_000 - swapFeeBps, 10_000);
        (int128 a0, int128 a1) = params.zeroForOne
            ? (-int128(int256(amountIn)), int128(int256(out)))
            : (int128(int256(out)), -int128(int256(amountIn)));
        _account(key.currency0, a0);
        _account(key.currency1, a1);
        return int256(uint256(int256(a0)) << 128 | uint256(uint128(a1)));
    }

    function sync(
        address currency
    ) external {
        _synced = currency;
        _syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedBalance;
        _account(_synced, int256(paid));
    }

    function take(address currency, address to, uint256 amount) external {
        _account(currency, -int256(amount));
        IERC20(currency).safeTransfer(to, amount);
    }

    function _account(address currency, int256 delta) internal {
        if (_deltas[currency] == 0) _touched.push(currency);
        _deltas[currency] += delta;
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
        return uint256(slots[keccak256(abi.encodePacked(poolId(key), bytes32(uint256(6))))]) & type(uint160).max;
    }

    function tickOf(
        PoolKey memory key
    ) public view returns (int24) {
        return int24(uint24(uint256(slots[keccak256(abi.encodePacked(poolId(key), bytes32(uint256(6))))]) >> 160));
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
