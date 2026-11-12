// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSD} from "../../../src/eusd/EUSD.sol";
import {EUSDLiquidityManager} from "../../../src/eusd/EUSDLiquidityManager.sol";
import {IEUSDLiquidityManager} from "../../../src/interfaces/IEUSDLiquidityManager.sol";
import {ILiquidityVault} from "../../../src/interfaces/ILiquidityVault.sol";
import {PoolKey} from "../../../src/interfaces/external/IFables.sol";
import {LiquidityMath} from "../../../src/libraries/LiquidityMath.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockFablesLedger} from "../../helpers/MockFables.sol";
import {MockOracleVerifier} from "../../helpers/MockOracleVerifier.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title LiquidityManagerHandler — stateful fuzz handler for EUSDLiquidityManager invariants
/// @notice Exercises add, remove, rebalance, stake toggles, withdraw, repay, close (both kinds), partial and
///         full liquidation, redemption, price moves (oracle and pool together) and time warps on the SPY pool.
///         The handler holds eUSD MINTER_ROLE to fund wallets and the mock pool's reserves, tracked
///         in `ghost_outsideMinted`, so supply == totalDebt + ghost_outsideMinted.
contract LiquidityManagerHandler is CommonBase, StdCheats, StdUtils {
    EUSDLiquidityManager public immutable manager;
    EUSD public immutable eusd;
    MockOracleVerifier public immutable oracle;
    MockFablesLedger public immutable ledger;
    MockERC20 public immutable asset;
    bytes32 public immutable ticker;
    uint256 public immutable poolId;

    PoolKey internal _key;
    address[] internal _actors;
    address public immutable keeper;
    uint256 public price;

    /// @notice eUSD minted by this handler outside the manager (wallet and pool-reserve funding).
    uint256 public ghost_outsideMinted;

    /// @notice Successful calls per action, to check the campaign reaches each path.
    mapping(bytes32 => uint256) public ghost_calls;

    constructor(
        EUSDLiquidityManager manager_,
        EUSD eusd_,
        MockOracleVerifier oracle_,
        MockFablesLedger ledger_,
        MockERC20 asset_,
        bytes32 ticker_,
        uint256 poolId_,
        PoolKey memory key_,
        uint256 startPrice,
        address[] memory actors_,
        address keeper_
    ) {
        manager = manager_;
        eusd = eusd_;
        oracle = oracle_;
        ledger = ledger_;
        asset = asset_;
        ticker = ticker_;
        poolId = poolId_;
        _key = key_;
        price = startPrice;
        _actors = actors_;
        keeper = keeper_;
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    // ──────────────────────────────────────────────────────────
    //  Actions
    // ──────────────────────────────────────────────────────────

    function addLiquidity(
        uint256 actorSeed,
        uint256 rangeSeed,
        uint256 assetIn,
        uint256 leverageBps,
        bool staked
    ) external {
        address actor = _actor(actorSeed);
        assetIn = bound(assetIn, 0.1e18, 50e18);
        leverageBps = bound(leverageBps, 2000, 9500);
        (int24 lower, int24 upper) = _range(actor, rangeSeed);
        uint256 eusdMax = (assetIn * price * leverageBps) / 1e18 / 10_000;
        vm.prank(actor);
        try manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: poolId,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: assetIn,
                assetMax: assetIn / 2,
                eusdMax: eusdMax,
                staked: staked
            })
        ) {
            ghost_calls["add"]++;
        } catch {}
    }

    function removeLiquidity(uint256 actorSeed, uint256 fractionBps) external {
        address actor = _actor(actorSeed);
        uint128 held = _held(actor);
        if (held == 0) return;
        uint128 liquidity = uint128((uint256(held) * bound(fractionBps, 1, 10_000)) / 10_000);
        if (liquidity == 0) return;
        vm.prank(actor);
        try manager.removeLiquidity(poolId, liquidity, 0, 0) {
            ghost_calls["remove"]++;
        } catch {}
    }

    function rebalance(
        uint256 actorSeed,
        uint256 rangeSeed,
        uint256 assetMax,
        uint256 eusdMax,
        uint256 swapAmount,
        bool assetToEusd,
        bool viaDelegate
    ) external {
        address actor = _actor(actorSeed);
        address vault = manager.getPosition(poolId, actor).vault;
        if (vault == address(0)) return;
        IEUSDLiquidityManager.RebalanceParams memory params;
        params.poolId = poolId;
        params.owner = actor;
        (params.tickLower, params.tickUpper) = _presetRange(rangeSeed);
        params.assetMax = bound(assetMax, 0, 50e18);
        params.eusdMax = bound(eusdMax, 0, 20_000e18);
        params.swapAmount = assetToEusd ? bound(swapAmount, 0, 5e18) : bound(swapAmount, 0, 3000e18);
        params.assetToEusd = assetToEusd;
        params.staked = manager.getPosition(poolId, actor).staked;
        address caller = actor;
        if (viaDelegate) {
            vm.prank(actor);
            ILiquidityVault(vault).setDelegate(keeper, 100);
            caller = keeper;
        }
        vm.prank(caller);
        try manager.rebalance(params) {
            ghost_calls[params.swapAmount > 0 ? bytes32("rebalanceSwap") : bytes32("rebalance")]++;
        } catch {}
    }

    function setStaked(uint256 actorSeed, bool staked) external {
        address actor = _actor(actorSeed);
        if (manager.getPosition(poolId, actor).vault == address(0)) return;
        vm.prank(actor);
        manager.setStaked(poolId, staked);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        address vault = manager.getPosition(poolId, actor).vault;
        if (vault == address(0)) return;
        uint256 idle = asset.balanceOf(vault);
        if (idle == 0) return;
        vm.prank(actor);
        try manager.withdraw(poolId, bound(amount, 1, idle)) {
            ghost_calls["withdraw"]++;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 debt = manager.getPosition(poolId, actor).debt;
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        _fund(actor, amount);
        vm.prank(actor);
        try manager.repay(poolId, actor, amount) {
            ghost_calls["repay"]++;
        } catch {}
    }

    function close(
        uint256 actorSeed
    ) external {
        address actor = _actor(actorSeed);
        if (manager.getPosition(poolId, actor).vault == address(0)) return;
        _fund(actor, manager.currentDebt(poolId, actor));
        vm.prank(actor);
        try manager.close(poolId, 0, 0) {
            ghost_calls["close"]++;
        } catch {}
    }

    function closePrincipalOnly(
        uint256 actorSeed
    ) external {
        address actor = _actor(actorSeed);
        if (manager.getPosition(poolId, actor).vault == address(0)) return;
        _fund(actor, manager.currentDebt(poolId, actor));
        vm.prank(actor);
        try manager.closePrincipalOnly(poolId, 0, 0) {
            ghost_calls["closePrincipalOnly"]++;
        } catch {}
    }

    function liquidate(uint256 actorSeed, uint256 fractionBps) external {
        address actor = _actor(actorSeed);
        if (!manager.isLiquidatable(poolId, actor)) return;
        uint256 debt = manager.currentDebt(poolId, actor);
        // Half the calls clear everything, half a random share.
        fractionBps = bound(fractionBps, 1, 20_000);
        uint256 amount = fractionBps > 10_000 ? debt : (debt * fractionBps) / 10_000;
        uint256 minDebt = manager.riskParams().minDebt;
        bool partial_ = amount < debt && amount > 0 && debt - amount >= minDebt;
        if (!partial_) amount = type(uint256).max;
        _fund(keeper, debt);
        vm.prank(keeper);
        manager.liquidate(poolId, actor, amount);
        ghost_calls[partial_ ? bytes32("liquidatePartial") : bytes32("liquidate")]++;
    }

    function redeem(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 debt = manager.getPosition(poolId, actor).debt;
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        oracle.setPrice(ticker, price);
        _fund(keeper, amount);
        address[] memory owners = new address[](1);
        owners[0] = actor;
        vm.prank(keeper);
        try manager.redeem(poolId, owners, amount, 0) {
            ghost_calls["redeem"]++;
        } catch {}
    }

    function movePrice(
        uint256 moveBps
    ) external {
        moveBps = bound(moveBps, 5000, 15_000);
        uint256 next = (price * moveBps) / 10_000;
        if (next < 100e18 || next > 3000e18) return;
        price = next;
        oracle.setPrice(ticker, next);
        ledger.setPrice(_key, address(asset), next);
    }

    function warp(
        uint256 secs
    ) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        oracle.setPrice(ticker, price);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    function _actor(
        uint256 seed
    ) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _held(
        address actor
    ) internal view returns (uint128 liquidity) {
        address vault = manager.getPosition(poolId, actor).vault;
        if (vault == address(0)) return 0;
        (,, liquidity) = ILiquidityVault(vault).range();
    }

    /// @dev The actor's open range if it has one, else a preset.
    function _range(address actor, uint256 seed) internal view returns (int24, int24) {
        address vault = manager.getPosition(poolId, actor).vault;
        if (vault != address(0)) {
            (int24 lower, int24 upper, uint128 liquidity) = ILiquidityVault(vault).range();
            if (liquidity > 0) return (lower, upper);
        }
        return _presetRange(seed);
    }

    /// @dev Tight, moderate, wide or full-ish ranges around the current price.
    function _presetRange(
        uint256 seed
    ) internal view returns (int24, int24) {
        uint256 widthBps = [uint256(500), 1500, 3000, 9000][seed % 4];
        int24 tick = _tick(price);
        int24 width = int24(int256(widthBps));
        return (_floor(tick - width), _floor(tick + width) + 10);
    }

    function _tick(
        uint256 p
    ) internal pure returns (int24) {
        uint256 target = LiquidityMath.sqrtPriceFromOracle(p, 1e18, true);
        int24 lo = LiquidityMath.MIN_TICK;
        int24 hi = LiquidityMath.MAX_TICK;
        while (hi - lo > 1) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            if (LiquidityMath.getSqrtPriceAtTick(mid) <= target) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _floor(
        int24 t
    ) internal pure returns (int24) {
        int24 r = t % 10;
        if (r < 0) r += 10;
        return t - r;
    }

    /// @dev Mint eUSD outside the manager (wallets, and the mock pool's reserves for price moves).
    function _fund(address to, uint256 amount) internal {
        if (amount == 0) return;
        eusd.mint(to, amount);
        ghost_outsideMinted += amount;
    }

    /// @notice Keep the mock pool able to pay eUSD after price rises.
    function fundPool() external {
        _fund(address(ledger), 100_000e18);
    }
}
