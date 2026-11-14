// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEUSDPsm} from "../src/interfaces/IEUSDPsm.sol";
import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";
import {BPS} from "../src/interfaces/types/Types.sol";
import {IPegArbitrage} from "./interfaces/IPegArbitrage.sol";
import {IPoolManagerSwap, PoolKey, SwapParams} from "./interfaces/IPoolManagerSwap.sol";
import {IUniswapV3PoolSwap} from "./interfaces/IUniswapV3PoolSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PegArbitrage — keeper tool that moves an eUSD pool to a target price through the PSM
/// @notice See {IPegArbitrage}.
contract PegArbitrage is IPegArbitrage, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev ProtocolRegistry role for withdrawals.
    bytes32 private constant ADMIN = keccak256("ADMIN");

    /// @dev ProtocolRegistry role for trades.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @notice ProtocolRegistry used to resolve the ADMIN and OPERATOR roles and the treasury.
    IProtocolRegistry public immutable registry;

    /// @notice Uniswap v4 PoolManager the pools live in.
    IPoolManagerSwap public immutable poolManager;

    /// @notice The PSM trades settle against.
    IEUSDPsm public immutable psm;

    /// @notice The eUSD token.
    address public immutable eusd;

    /// @dev True only while {arbitrage} has the PoolManager unlocked.
    bool private _trading;

    /// @dev The v3-style pool {arbitrageV3} is trading, only while it trades.
    address private _v3Pool;

    /// @dev Reverts unless the caller holds ADMIN in the registry.
    modifier onlyAdmin() {
        if (!registry.hasRole(ADMIN, msg.sender)) revert OnlyAdmin();
        _;
    }

    /// @dev Reverts unless the caller holds OPERATOR in the registry.
    modifier onlyOperator() {
        if (!registry.hasRole(OPERATOR, msg.sender)) revert OnlyOperator();
        _;
    }

    /// @param registry_    ProtocolRegistry address.
    /// @param poolManager_ Uniswap v4 PoolManager address.
    /// @param psm_         EUSDPsm address.
    constructor(address registry_, address poolManager_, address psm_) {
        if (registry_ == address(0) || poolManager_ == address(0) || psm_ == address(0)) revert ZeroAddress();
        registry = IProtocolRegistry(registry_);
        poolManager = IPoolManagerSwap(poolManager_);
        psm = IEUSDPsm(psm_);
        eusd = IEUSDPsm(psm_).eusd();
    }

    /// @inheritdoc IPegArbitrage
    function arbitrage(
        PoolKey calldata key,
        bool sellEusd,
        uint160 sqrtPriceLimitX96,
        uint256 maxIn,
        int256 minProfit
    ) external override onlyOperator nonReentrant returns (int256 profit) {
        if (maxIn == 0) revert ZeroAmount();
        bool eusdIsZero = key.currency0 == eusd;
        if (!eusdIsZero && key.currency1 != eusd) revert NotAnEusdPool();
        address asset = eusdIsZero ? key.currency1 : key.currency0;

        uint256 before = IERC20(asset).balanceOf(address(this));
        _trading = true;
        bytes memory result = poolManager.unlock(abi.encode(key, sellEusd, sqrtPriceLimitX96, maxIn, eusdIsZero, asset));
        _trading = false;
        (uint256 eusdAmt, uint256 assetAmt) = abi.decode(result, (uint256, uint256));

        profit = IERC20(asset).balanceOf(address(this)).toInt256() - before.toInt256();
        if (profit < minProfit) revert ProfitTooLow(profit, minProfit);
        emit Arbitraged(asset, sellEusd, eusdAmt, assetAmt, profit);
    }

    /// @inheritdoc IPegArbitrage
    function arbitrageV3(
        address pool,
        bool sellEusd,
        uint160 sqrtPriceLimitX96,
        uint256 maxIn,
        int256 minProfit
    ) external override onlyOperator nonReentrant returns (int256 profit) {
        if (maxIn == 0) revert ZeroAmount();
        address token0 = IUniswapV3PoolSwap(pool).token0();
        address token1 = IUniswapV3PoolSwap(pool).token1();
        bool eusdIsZero = token0 == eusd;
        if (!eusdIsZero && token1 != eusd) revert NotAnEusdPool();
        address asset = eusdIsZero ? token1 : token0;

        uint256 before = IERC20(asset).balanceOf(address(this));
        (uint256 eusdAmt, uint256 assetAmt) = _swapV3(pool, sellEusd, sqrtPriceLimitX96, maxIn, eusdIsZero, asset);
        profit = IERC20(asset).balanceOf(address(this)).toInt256() - before.toInt256();
        if (profit < minProfit) revert ProfitTooLow(profit, minProfit);
        emit Arbitraged(asset, sellEusd, eusdAmt, assetAmt, profit);
    }

    /// @inheritdoc IPegArbitrage
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        address pool = _v3Pool;
        if (pool == address(0) || msg.sender != pool) revert UnauthorizedCallback();
        (bool eusdIsZero, address asset) = abi.decode(data, (bool, address));
        // Positive = owed to the pool; the pool has already sent what it owes.
        (int256 eusdDelta, int256 assetDelta) = eusdIsZero ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (eusdDelta > 0) {
            uint256 eusdOwed = uint256(eusdDelta);
            _mintFromPsm(asset, eusdOwed);
            IERC20(eusd).safeTransfer(pool, eusdOwed);
        } else if (eusdDelta < 0) {
            psm.redeem(asset, uint256(-eusdDelta), 0);
            if (assetDelta > 0) IERC20(asset).safeTransfer(pool, uint256(assetDelta));
        } else {
            revert NothingSwapped();
        }
    }

    /// @inheritdoc IPegArbitrage
    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_trading) revert UnauthorizedCallback();
        (PoolKey memory key, bool sellEusd, uint160 limit, uint256 maxIn, bool eusdIsZero, address asset) =
            abi.decode(data, (PoolKey, bool, uint160, uint256, bool, address));

        // Selling eUSD sells currency0 exactly when eUSD is currency0.
        int256 delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: sellEusd == eusdIsZero,
                amountSpecified: -maxIn.toInt256(),
                sqrtPriceLimitX96: limit
            }),
            ""
        );
        int256 eusdDelta = eusdIsZero ? int256(int128(delta >> 128)) : int256(int128(delta));
        int256 assetDelta = eusdIsZero ? int256(int128(delta)) : int256(int128(delta >> 128));

        uint256 eusdAmt;
        uint256 assetAmt;
        if (sellEusd) {
            eusdAmt = (-eusdDelta).toUint256();
            assetAmt = assetDelta.toUint256();
            if (eusdAmt == 0) revert NothingSwapped();
            poolManager.take(asset, address(this), assetAmt);
            _mintFromPsm(asset, eusdAmt);
            _pay(eusd, eusdAmt);
        } else {
            eusdAmt = eusdDelta.toUint256();
            assetAmt = (-assetDelta).toUint256();
            if (eusdAmt == 0) revert NothingSwapped();
            poolManager.take(eusd, address(this), eusdAmt);
            psm.redeem(asset, eusdAmt, 0);
            _pay(asset, assetAmt);
        }
        return abi.encode(eusdAmt, assetAmt);
    }

    /// @inheritdoc IPegArbitrage
    function withdraw(address token, uint256 amount) external override onlyAdmin nonReentrant {
        if (amount == 0) revert ZeroAmount();
        address to = registry.treasury();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @dev Mint at least `eusdOwed` from the PSM with the least asset that covers it.
    /// @param asset    The stablecoin.
    /// @param eusdOwed eUSD needed (18 decimals).
    function _mintFromPsm(address asset, uint256 eusdOwed) private {
        IEUSDPsm.AssetConfig memory cfg = psm.assetConfig(asset);
        uint256 scale = 10 ** (18 - cfg.decimals);
        // Rounded up so the eUSD out covers what the pool is owed; any excess stays here.
        uint256 assetIn = Math.mulDiv(eusdOwed, BPS, (BPS - cfg.mintFeeBps) * scale, Math.Rounding.Ceil);
        (uint256 out,) = psm.previewMint(asset, assetIn);
        if (out < eusdOwed) ++assetIn;
        IERC20(asset).forceApprove(address(psm), assetIn);
        psm.mint(asset, assetIn, eusdOwed);
    }

    /// @dev Exact-input swap in a v3-style pool; the pool calls back {uniswapV3SwapCallback}.
    /// @return eusdAmt  eUSD sold or bought (18 decimals).
    /// @return assetAmt Stablecoin received or paid (asset units).
    function _swapV3(
        address pool,
        bool sellEusd,
        uint160 limit,
        uint256 maxIn,
        bool eusdIsZero,
        address asset
    ) private returns (uint256 eusdAmt, uint256 assetAmt) {
        _v3Pool = pool;
        (int256 amount0, int256 amount1) = IUniswapV3PoolSwap(pool).swap(
            address(this), sellEusd == eusdIsZero, maxIn.toInt256(), limit, abi.encode(eusdIsZero, asset)
        );
        _v3Pool = address(0);
        (int256 eusdDelta, int256 assetDelta) = eusdIsZero ? (amount0, amount1) : (amount1, amount0);
        eusdAmt = (eusdDelta < 0 ? -eusdDelta : eusdDelta).toUint256();
        assetAmt = (assetDelta < 0 ? -assetDelta : assetDelta).toUint256();
    }

    /// @dev Pay the PoolManager `amount` of `token` owed from the swap.
    /// @param token  The token.
    /// @param amount Amount owed.
    function _pay(address token, uint256 amount) private {
        poolManager.sync(token);
        IERC20(token).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }
}
