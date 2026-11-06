// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDLiquidityManager} from "../../src/eusd/EUSDLiquidityManager.sol";
import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {IExtsload, PoolKey} from "../../src/interfaces/external/IFables.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {deployEUSDLiquidityManager} from "../helpers/LiquidityManagerSetup.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Fables ledger views used to check what the vault holds on the real ledger.
interface IFablesLedgerView {
    struct UserPosition {
        uint128 staked;
        uint128 owed0;
        uint128 owed1;
        uint256 checkpoint0X128;
        uint256 checkpoint1X128;
        uint256 stakedCheckpoint0X128;
        uint256 stakedCheckpoint1X128;
        uint256 forgone0;
        uint256 forgone1;
    }

    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function rangeId(bytes32 poolId, int24 tickLower, int24 tickUpper) external pure returns (uint256);
    function userPosition(uint256 id, address owner) external view returns (UserPosition memory);
}

/// @title EUSDLiquidityManagerRobinhoodFork — the manager against live Fables pools
/// @notice Skipped if `ROBINHOOD_RPC` is not set. Runs the manager and FablesAdapter against the
///         live Fables ledger, Uniswap v4 PoolManager and eUSD on Robinhood Chain, with a mock
///         oracle pinned to each pool's price so the band check is deterministic.
contract EUSDLiquidityManagerRobinhoodFork is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    address internal constant EUSD = 0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7;
    address internal constant GOV_SAFE = 0x470f35a7e5d4Cd490D74799AC01E7bEea7F478e2;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant EMISSION_STREAM = 0x498506256215702f0DA01c0f9Ab0C765488acd07;
    address internal constant FABLES_RAMP = 0x08E52564Bad99E05a694b4809F397edcA417A080;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    bytes32 internal constant SPY_TICKER = bytes32("R.SPY");
    bytes32 internal constant USDG_TICKER = bytes32("USDG");

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    EUSDLiquidityManager internal manager;
    MockOracleVerifier internal oracle;
    UpgradeableBeacon internal beacon;
    PoolKey internal spyKey;
    PoolKey internal usdKey;
    bool internal _forkActive;

    modifier requiresFork() {
        if (!_forkActive) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "not Robinhood Chain");
        _forkActive = true;

        spyKey = PoolKey({currency0: SPY, currency1: EUSD, fee: 0x800000, tickSpacing: 10, hooks: FABLES_RAMP});
        usdKey = PoolKey({currency0: USDG, currency1: EUSD, fee: 0x800000, tickSpacing: 1, hooks: FABLES_RAMP});

        oracle = new MockOracleVerifier();
        oracle.setPrice(SPY_TICKER, _poolPrice(spyKey, 1e18));
        oracle.setPrice(USDG_TICKER, _poolPrice(usdKey, 1e6));

        vm.startPrank(admin);
        ProtocolRegistry registry = new ProtocolRegistry(admin, 2 days);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);
        registry.setOracle(address(oracle));
        registry.setTreasury(treasury);
        vm.stopPrank();

        manager = deployEUSDLiquidityManager(
            address(registry),
            EUSD,
            IEUSDLiquidityManager.RiskParams({
                mcrBps: 19_000,
                liquidationThresholdBps: 12_500,
                liquidationBonusBps: 500,
                stakedFeeBps: 700,
                unstakedFeeBps: 200,
                poolPriceBandBps: 250,
                debtCeiling: 1_000_000e18,
                minDebt: 10e18,
                mintPriceMaxAge: 1 days
            })
        );
        bytes32 minterRole = keccak256("MINTER_ROLE");
        vm.prank(GOV_SAFE);
        IAccessControl(EUSD).grantRole(minterRole, address(manager));

        FablesAdapter impl = new FablesAdapter(POOL_MANAGER, EMISSION_STREAM);
        beacon = new UpgradeableBeacon(address(impl), admin);
        vm.startPrank(admin);
        manager.addPool(address(beacon), SPY, SPY_TICKER, abi.encode(spyKey));
        manager.addPool(address(beacon), USDG, USDG_TICKER, abi.encode(usdKey));
        vm.stopPrank();

        deal(SPY, alice, 100e18);
        deal(USDG, alice, 100_000e6);
        vm.startPrank(alice);
        IERC20(SPY).approve(address(manager), type(uint256).max);
        IERC20(USDG).approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _sqrtPrice(
        PoolKey memory key
    ) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encodePacked(keccak256(abi.encode(key)), bytes32(uint256(6))));
        return uint256(IExtsload(POOL_MANAGER).extsload(slot)) & type(uint160).max;
    }

    function _poolPrice(PoolKey memory key, uint256 scale) internal view returns (uint256) {
        return LiquidityMath.priceFromSqrtPrice(_sqrtPrice(key), scale, true);
    }

    /// @dev Range of ±`bps` around the pool price, on the spacing (asset is currency0 in both pools).
    function _rangeAround(PoolKey memory key, uint256 bps) internal view returns (int24 lower, int24 upper) {
        uint256 sqrtP = _sqrtPrice(key);
        int24 tick = _tickAtOrBelow(sqrtP);
        // ln(1.0001) ≈ 1e-4, so ±bps of price is about ±bps ticks.
        int24 spacing = key.tickSpacing;
        lower = _floor(tick - int24(int256(bps)), spacing);
        upper = _floor(tick + int24(int256(bps)), spacing) + spacing;
    }

    function _tickAtOrBelow(
        uint256 sqrtP
    ) internal pure returns (int24) {
        int24 lo = LiquidityMath.MIN_TICK;
        int24 hi = LiquidityMath.MAX_TICK;
        while (hi - lo > 1) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            if (LiquidityMath.getSqrtPriceAtTick(mid) <= sqrtP) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }

    function _vault(
        uint256 poolId
    ) internal view returns (FablesAdapter) {
        return FablesAdapter(manager.getPosition(poolId, alice).vault);
    }

    function _openSpy() internal returns (uint128 liquidity, int24 lower, int24 upper) {
        (lower, upper) = _rangeAround(spyKey, 1000);
        (uint256 price,) = oracle.getPrice(SPY_TICKER);
        vm.prank(alice);
        liquidity = manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: 0,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 10e18,
                assetMax: 5e18,
                eusdMax: 5 * price,
                staked: true
            })
        );
    }

    // ──────────────────────────────────────────────────────────
    //  Tests
    // ──────────────────────────────────────────────────────────

    function test_fork_spy_addStakesOnLiveLedger() public requiresFork {
        uint256 supplyBefore = IERC20(EUSD).totalSupply();
        (uint128 liquidity, int24 lower, int24 upper) = _openSpy();
        FablesAdapter v = _vault(0);
        uint256 id = IFablesLedgerView(FABLES_RAMP).rangeId(keccak256(abi.encode(spyKey)), lower, upper);
        assertEq(IFablesLedgerView(FABLES_RAMP).balanceOf(address(v), id), liquidity, "shares");
        assertEq(IFablesLedgerView(FABLES_RAMP).userPosition(id, address(v)).staked, liquidity, "staked");

        uint256 debt = manager.getPosition(0, alice).debt;
        assertGt(debt, 0);
        assertEq(IERC20(EUSD).totalSupply() - supplyBefore, debt, "supply grows by the debt");
        assertEq(IERC20(EUSD).balanceOf(address(v)), 0);
        assertGe(manager.collateralRatioBps(0, alice), manager.riskParams().mcrBps);
        assertApproxEqRel(v.poolPrice(), _poolPrice(spyKey, 1e18), 1e12);
    }

    function test_fork_spy_valuationMatchesWithdrawal() public requiresFork {
        (uint128 liquidity,,) = _openSpy();
        FablesAdapter v = _vault(0);
        (uint256 price,) = oracle.getPrice(SPY_TICKER);
        uint256 idle = IERC20(SPY).balanceOf(address(v));
        (uint256 assetHeld, uint256 eusdHeld) = v.holdings(price);

        vm.prank(address(manager));
        (uint256 assetOut, uint256 eusdOut) = v.removeLiquidity(liquidity, 0, 0);
        // The oracle is pinned to the pool, so the valuation is what the pool pays, to rounding.
        assertApproxEqAbs(assetOut, assetHeld - idle, 1e6, "asset");
        assertApproxEqAbs(eusdOut, eusdHeld, 1e6, "eUSD");
    }

    function test_fork_spy_repositionRemoveClose() public requiresFork {
        _openSpy();
        (int24 lower, int24 upper) = _rangeAround(spyKey, 500);
        uint256 eusdMax = 3 * _poolPrice(spyKey, 1e18);
        vm.prank(alice);
        manager.reposition(
            IEUSDLiquidityManager.RepositionParams({
                poolId: 0,
                tickLower: lower,
                tickUpper: upper,
                assetMax: 3e18,
                eusdMax: eusdMax,
                assetMin: 0,
                eusdMin: 0
            })
        );
        (int24 l, int24 u, uint128 held) = _vault(0).range();
        assertEq(l, lower);
        assertEq(u, upper);
        assertGt(held, 0);
        assertGe(manager.collateralRatioBps(0, alice), manager.riskParams().mcrBps);

        vm.prank(alice);
        manager.removeLiquidity(0, held / 2, 0, 0);

        deal(EUSD, alice, 100e18);
        uint256 spyBefore = IERC20(SPY).balanceOf(alice);
        vm.prank(alice);
        manager.close(0, 0, 0);
        assertEq(manager.getPosition(0, alice).debt, 0);
        assertEq(manager.totalDebt(), 0);
        assertApproxEqRel(IERC20(SPY).balanceOf(alice) - spyBefore, 10e18, 0.01e18);
        assertEq(IERC20(SPY).balanceOf(address(_vault(0))), 0);
    }

    function test_fork_spy_unstakeAndLiquidate() public requiresFork {
        (uint128 liquidity, int24 lower, int24 upper) = _openSpy();
        vm.prank(alice);
        manager.setStaked(0, false);
        uint256 id = IFablesLedgerView(FABLES_RAMP).rangeId(keccak256(abi.encode(spyKey)), lower, upper);
        assertEq(IFablesLedgerView(FABLES_RAMP).userPosition(id, address(_vault(0))).staked, 0);
        assertEq(IFablesLedgerView(FABLES_RAMP).balanceOf(address(_vault(0)), id), liquidity);

        // The oracle drops while the pool lags: the unwind returns enough eUSD to clear the debt,
        // so the keeper pays nothing and the owner gets the rest.
        (uint256 price,) = oracle.getPrice(SPY_TICKER);
        oracle.setPrice(SPY_TICKER, price / 3);
        assertTrue(manager.isLiquidatable(0, alice));
        deal(EUSD, keeper, 10_000e18);
        uint256 aliceSpy = IERC20(SPY).balanceOf(alice);
        vm.prank(keeper);
        manager.liquidate(0, alice, type(uint256).max);
        assertEq(manager.getPosition(0, alice).debt, 0);
        assertEq(manager.totalDebt(), 0);
        assertEq(IFablesLedgerView(FABLES_RAMP).balanceOf(address(_vault(0)), id), 0);
        assertEq(IERC20(SPY).balanceOf(address(_vault(0))), 0);
        assertGt(IERC20(SPY).balanceOf(alice), aliceSpy);
    }

    function test_fork_spy_partialLiquidationStaysStaked() public requiresFork {
        (uint128 liquidity, int24 lower, int24 upper) = _openSpy();
        uint256 id = IFablesLedgerView(FABLES_RAMP).rangeId(keccak256(abi.encode(spyKey)), lower, upper);
        (uint256 price,) = oracle.getPrice(SPY_TICKER);
        // Below the threshold but above 1 + bonus, where a partial liquidation helps.
        oracle.setPrice(SPY_TICKER, (price * 38) / 100);
        assertTrue(manager.isLiquidatable(0, alice));
        uint256 ratioBefore = manager.collateralRatioBps(0, alice);
        assertGt(ratioBefore, 10_500);

        uint256 debt = manager.getPosition(0, alice).debt;
        deal(EUSD, keeper, debt);
        vm.prank(keeper);
        manager.liquidate(0, alice, debt / 2);

        (,, uint128 left) = _vault(0).range();
        assertGt(left, 0);
        assertLt(left, liquidity);
        assertEq(IFablesLedgerView(FABLES_RAMP).balanceOf(address(_vault(0)), id), left, "shares");
        assertEq(IFablesLedgerView(FABLES_RAMP).userPosition(id, address(_vault(0))).staked, left, "staked");
        assertLe(manager.getPosition(0, alice).debt, debt - debt / 2);
        assertEq(manager.totalDebt(), manager.getPosition(0, alice).debt);
        // The pool lags the oracle, so the unwound share returns about the eUSD cleared (the pool
        // rounds withdrawals down by a wei or two).
        assertApproxEqAbs(IERC20(EUSD).balanceOf(keeper), debt, 2, "keeper pays ~nothing");
        assertGt(manager.collateralRatioBps(0, alice), ratioBefore, "ratio improves");

        // The rest of the position stays open and can be liquidated in full later.
        oracle.setPrice(SPY_TICKER, price / 5);
        vm.prank(keeper);
        manager.liquidate(0, alice, type(uint256).max);
        assertEq(manager.getPosition(0, alice).debt, 0);
        assertEq(IFablesLedgerView(FABLES_RAMP).balanceOf(address(_vault(0)), id), 0);
    }

    function test_fork_usdg_sixDecimalAsset() public requiresFork {
        (int24 lower, int24 upper) = _rangeAround(usdKey, 50);
        vm.prank(alice);
        uint128 liquidity = manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: 1,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 2000e6,
                assetMax: 1000e6,
                eusdMax: 1000e18,
                staked: true
            })
        );
        assertGt(liquidity, 0);
        uint256 debt = manager.getPosition(1, alice).debt;
        assertGt(debt, 0);
        assertGe(manager.collateralRatioBps(1, alice), manager.riskParams().mcrBps);
        assertApproxEqRel(_vault(1).poolPrice(), _poolPrice(usdKey, 1e6), 1e12);

        deal(EUSD, alice, 10e18);
        uint256 usdgBefore = IERC20(USDG).balanceOf(alice);
        vm.prank(alice);
        manager.close(1, 0, 0);
        assertEq(manager.totalDebt(), 0);
        assertApproxEqRel(IERC20(USDG).balanceOf(alice) - usdgBefore, 2000e6, 0.01e18);
    }
}
