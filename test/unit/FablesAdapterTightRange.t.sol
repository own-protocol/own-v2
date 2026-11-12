// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {ILiquidityVault} from "../../src/interfaces/ILiquidityVault.sol";
import {PoolKey} from "../../src/interfaces/external/IFables.sol";

import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {LiquidityManagerSetup} from "../helpers/LiquidityManagerSetup.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FablesAdapterTightRangeTest is LiquidityManagerSetup {
    FablesAdapter internal vault;

    int24 internal constant HALF = 20;

    MockERC20 internal cheap;
    PoolKey internal cheapKey;
    uint256 internal cheapPrice;
    uint256 internal cheapPool;
    int24 internal cheapLower;
    int24 internal cheapUpper;

    function setUp() public override {
        super.setUp();
        openSpy(alice, 10e18, 3500e18);
        vault = FablesAdapter(manager.getPosition(SPY_POOL, alice).vault);
        // Reserve so the mock pool can pay eUSD out after price moves.
        giveEusd(address(ledger), 10_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  setTightRange
    // ──────────────────────────────────────────────────────────

    function test_setTightRange_ownerAndDelegate() public {
        vm.expectEmit(address(vault));
        emit FablesAdapter.TightRangeSet(alice, 1000, HALF);
        vm.prank(alice);
        vault.setTightRange(1000, HALF);
        assertEq(vault.tightShareBps(), 1000);
        assertEq(vault.tightHalfWidth(), HALF);

        vm.prank(alice);
        vault.setDelegate(keeper);
        vm.prank(keeper);
        vault.setTightRange(0, 0);
        assertEq(vault.tightShareBps(), 0);
    }

    function test_setTightRange_stranger_reverts() public {
        vm.expectRevert(FablesAdapter.OnlyOwnerOrDelegate.selector);
        vm.prank(attacker);
        vault.setTightRange(1000, HALF);
    }

    function test_setTightRange_invalid_reverts() public {
        uint16 tooBig = vault.MAX_TIGHT_SHARE_BPS() + 1;
        int24[3] memory widths = [int24(0), int24(-10), int24(15)];
        for (uint256 i; i < widths.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(FablesAdapter.InvalidTightRange.selector, 1000, widths[i]));
            vm.prank(alice);
            vault.setTightRange(1000, widths[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(FablesAdapter.InvalidTightRange.selector, tooBig, HALF));
        vm.prank(alice);
        vault.setTightRange(tooBig, HALF);
        vm.prank(alice);
        vault.setTightRange(0, 15); // off: width ignored
    }

    function test_setTightRange_doesNotMoveLiquidity() public {
        uint128 held = _held();
        vm.prank(alice);
        vault.setTightRange(1000, HALF);
        assertEq(_held(), held);
        (,, uint128 tight) = vault.tightRange();
        assertEq(tight, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Opening
    // ──────────────────────────────────────────────────────────

    function test_rebalance_opensTightRangeAroundPoolTick() public {
        (uint256 a0, uint256 e0) = vault.holdings(SPY_PRICE);
        _setTight(1000);
        _rebalance();

        (int24 lower, int24 upper, uint128 tight) = vault.tightRange();
        int24 centre = _nearest(ledger.tickOf(spyKey), 10);
        assertEq(lower, centre - HALF);
        assertEq(upper, centre + HALF);
        assertGt(tight, 0);
        assertEq(ledger.stakedOf(address(vault), ledger.rangeId(spyKey, lower, upper)), tight, "tight staked");
        (int24 mLower, int24 mUpper, uint128 held) = vault.range();
        assertEq(ledger.stakedOf(address(vault), ledger.rangeId(spyKey, mLower, mUpper)), held, "main staked");

        (uint256 a1, uint256 e1) = vault.holdings(SPY_PRICE);
        // Same value before and after; eUSD left over is burned against the debt.
        assertApproxEqRel(a1 * 700 + e1 + (3500e18 - _debt()), a0 * 700 + e0, 1e15);
        _assertSupplyMatchesDebt();
    }

    function test_rebalance_tightShareOfAmounts() public {
        _setTight(1000);
        _rebalance();
        (,, uint128 tight) = vault.tightRange();
        (uint256 tightAsset, uint256 tightEusd) = _tightAmounts(SPY_PRICE);
        // The tight range takes at most 10% of each token offered (6e18 asset, 2000e18 eUSD).
        assertLe(tightAsset, 0.6e18 + 1);
        assertLe(tightEusd, 200e18 + 1);
        assertGt(tightAsset * 700 + tightEusd, 0);
        assertGt(tight, 0);
    }

    function test_rebalance_tightCentredOnPoolNotOracle() public {
        // Pool 0.5% above the oracle, inside the band: the tight range follows the pool.
        ledger.setPrice(spyKey, address(spy), 703.5e18);
        _setTight(1000);
        _rebalance();
        (int24 lower, int24 upper,) = vault.tightRange();
        int24 centre = _nearest(ledger.tickOf(spyKey), 10);
        assertEq(lower, centre - HALF);
        assertEq(upper, centre + HALF);
        assertGt(lower, tickAt(SPY_PRICE, 1e18, true, 10), "oracle tick below the tight range");
    }

    function test_centre_roundsToNearestSpacing() public {
        _setTight(1000);
        uint256[4] memory prices = [uint256(700e18), 700.2e18, 700.35e18, 700.6e18];
        for (uint256 i; i < prices.length; i++) {
            uint256 snap = vm.snapshotState();
            moveSpy(prices[i]);
            _rebalance();
            int24 tick = ledger.tickOf(spyKey);
            (int24 lower, int24 upper,) = vault.tightRange();
            int24 centre = (lower + upper) / 2;
            assertEq(centre % 10, 0);
            assertLe(_abs(tick - centre), 5, "nearest multiple");
            vm.revertToState(snap);
        }
    }

    function test_centre_negativeTicks() public {
        FablesAdapter v = _openCheapPool();
        assertLt(ledger.tickOf(cheapKey), 0);
        uint256[4] memory bumps = [uint256(10_000), 10_003, 10_006, 9996];
        for (uint256 i; i < bumps.length; i++) {
            uint256 snap = vm.snapshotState();
            ledger.setPrice(cheapKey, address(cheap), cheapPrice * bumps[i] / 10_000);
            _rebalanceCheap();
            int24 tick = ledger.tickOf(cheapKey);
            (int24 tl, int24 tu, uint128 tight) = v.tightRange();
            int24 centre = (tl + tu) / 2;
            assertLt(centre, 0);
            assertEq(centre % 10, 0);
            assertLe(_abs(tick - centre), 5, "nearest multiple");
            assertEq(centre, _nearest(tick, 10));
            assertGt(tight, 0);
            vm.revertToState(snap);
        }
    }

    /// @dev A pool whose ticks are negative (price below 1 in currency1 per currency0), spacing 10,
    ///      with alice's position open and a 10% tight range set.
    function _openCheapPool() internal returns (FablesAdapter v) {
        cheap = new MockERC20("Cheap", "CHP", 18);
        bool assetIsZero = address(cheap) < address(eusd);
        cheapPrice = assetIsZero ? 0.5e18 : 2e18;
        cheapKey = PoolKey({
            currency0: assetIsZero ? address(cheap) : address(eusd),
            currency1: assetIsZero ? address(eusd) : address(cheap),
            fee: 0x800000,
            tickSpacing: 10,
            hooks: address(ledger)
        });
        oracle.setPrice(bytes32("CHP"), cheapPrice);
        ledger.setPrice(cheapKey, address(cheap), cheapPrice);
        vm.prank(admin);
        cheapPool = manager.addPool(address(beacon), address(cheap), bytes32("CHP"), abi.encode(cheapKey));
        cheap.mint(alice, 10_000e18);
        cheap.mint(address(ledger), 1_000_000e18);
        vm.prank(alice);
        cheap.approve(address(manager), type(uint256).max);
        int24 t = ledger.tickOf(cheapKey) / 10 * 10;
        (cheapLower, cheapUpper) = (t - 2000, t + 2000);
        vm.prank(alice);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: cheapPool,
                tickLower: cheapLower,
                tickUpper: cheapUpper,
                assetDeposit: 1000e18,
                assetMax: 1000e18,
                eusdMax: cheapPrice * 250,
                staked: false
            })
        );
        v = FablesAdapter(manager.getPosition(cheapPool, alice).vault);
        vm.prank(alice);
        v.setTightRange(1000, HALF);
    }

    function _rebalanceCheap() internal {
        vm.prank(alice);
        manager.rebalance(
            IEUSDLiquidityManager.RebalanceParams({
                poolId: cheapPool,
                owner: alice,
                assetMin: 0,
                eusdMin: 0,
                swapAmount: 0,
                assetToEusd: false,
                route: "",
                tickLower: cheapLower,
                tickUpper: cheapUpper,
                assetMax: 1000e18,
                eusdMax: cheapPrice * 250,
                staked: false
            })
        );
    }

    function test_open_off_noTightRange() public {
        _rebalance();
        (,, uint128 tight) = vault.tightRange();
        assertEq(tight, 0);
    }

    function test_topUp_doesNotChangeTight() public {
        _setTight(1000);
        _rebalance();
        (int24 lower, int24 upper, uint128 tight) = vault.tightRange();
        (int24 mLower, int24 mUpper, uint128 held) = vault.range();
        vm.prank(alice);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: SPY_POOL,
                tickLower: mLower,
                tickUpper: mUpper,
                assetDeposit: 1e18,
                assetMax: 1e18,
                eusdMax: 300e18,
                staked: true
            })
        );
        (int24 l2, int24 u2, uint128 t2) = vault.tightRange();
        assertEq(l2, lower);
        assertEq(u2, upper);
        assertEq(t2, tight);
        assertGt(_held(), held);
    }

    function test_turnOff_rebalanceClosesTight() public {
        _setTight(1000);
        _rebalance();
        (int24 lower, int24 upper,) = vault.tightRange();
        _setTight(0);
        _rebalance();
        (int24 l2, int24 u2, uint128 t2) = vault.tightRange();
        assertEq(t2, 0);
        assertEq(l2, 0);
        assertEq(u2, 0);
        assertEq(ledger.balanceOf(address(vault), ledger.rangeId(spyKey, lower, upper)), 0);
    }

    function test_rebalance_reCentresTight() public {
        _setTight(1000);
        _rebalance();
        (int24 lower,,) = vault.tightRange();
        moveSpy(710e18);
        _rebalance();
        (int24 l2,, uint128 t2) = vault.tightRange();
        assertGt(l2, lower);
        assertGt(t2, 0);
        assertEq(ledger.balanceOf(address(vault), ledger.rangeId(spyKey, lower, lower + 2 * HALF)), 0, "old range gone");
    }

    // ──────────────────────────────────────────────────────────
    //  Removal
    // ──────────────────────────────────────────────────────────

    function test_partialRemove_takesSameShareRoundedUp() public {
        _setTight(1000);
        _rebalance();
        (,, uint128 tight) = vault.tightRange();
        uint128 held = _held();
        uint128 part = held / 3;
        vm.prank(alice);
        manager.removeLiquidity(SPY_POOL, part, 0, 0);
        (,, uint128 t2) = vault.tightRange();
        assertEq(t2, tight - uint128(Math.mulDiv(tight, part, held, Math.Rounding.Ceil)));
        assertEq(_held(), held - part);
    }

    function test_removeAll_clearsBoth() public {
        _setTight(1000);
        _rebalance();
        (int24 lower, int24 upper,) = vault.tightRange();
        uint128 held = _held();
        vm.prank(address(manager));
        vault.removeLiquidity(held, 0, 0);
        (int24 l2, int24 u2, uint128 t2) = vault.tightRange();
        assertEq(t2, 0);
        assertEq(l2, 0);
        assertEq(u2, 0);
        assertEq(ledger.balanceOf(address(vault), ledger.rangeId(spyKey, lower, upper)), 0);
    }

    function test_removeLiquidity_minimumsCoverBothRanges() public {
        _setTight(1000);
        _rebalance();
        uint128 held = _held();
        uint256 snap = vm.snapshotState();
        vm.prank(address(manager));
        (uint256 assetOut, uint256 eusdOut) = vault.removeLiquidity(held, 0, 0);
        vm.revertToState(snap);

        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.InsufficientOutput.selector, assetOut, assetOut + 1));
        vm.prank(address(manager));
        vault.removeLiquidity(held, assetOut + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.InsufficientOutput.selector, eusdOut, eusdOut + 1));
        vm.prank(address(manager));
        vault.removeLiquidity(held, 0, eusdOut + 1);
        vm.prank(address(manager));
        vault.removeLiquidity(held, assetOut, eusdOut);
    }

    function test_close_withTight_returnsEverything() public {
        _setTight(1000);
        _rebalance();
        (int24 lower, int24 upper,) = vault.tightRange();
        giveEusd(alice, 1000e18);
        vm.prank(alice);
        eusd.approve(address(manager), type(uint256).max);
        vm.prank(alice);
        manager.close(SPY_POOL, 0, 0);
        assertEq(ledger.balanceOf(address(vault), ledger.rangeId(spyKey, lower, upper)), 0);
        assertEq(spy.balanceOf(address(vault)), 0);
        assertEq(eusd.balanceOf(address(vault)), 0);
        assertEq(_debt(), 0);
    }

    function test_liquidate_takesTightShare() public {
        _setTight(1000);
        _rebalance();
        (,, uint128 tight) = vault.tightRange();
        moveSpy(180e18);
        assertLt(manager.collateralRatioBps(SPY_POOL, alice), LIQ_THRESHOLD);
        uint256 debt = _debt();
        giveEusd(bob, debt);
        vm.prank(bob);
        eusd.approve(address(manager), type(uint256).max);
        vm.prank(bob);
        manager.liquidate(SPY_POOL, alice, debt / 2);
        (,, uint128 t2) = vault.tightRange();
        assertLt(t2, tight);
        assertApproxEqRel(t2, tight / 2, 0.01e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Staking & valuation
    // ──────────────────────────────────────────────────────────

    function test_setStaked_coversTight() public {
        _setTight(1000);
        _rebalance();
        (int24 lower, int24 upper, uint128 tight) = vault.tightRange();
        uint256 id = ledger.rangeId(spyKey, lower, upper);
        assertEq(ledger.stakedOf(address(vault), id), tight);
        vm.prank(alice);
        manager.setStaked(SPY_POOL, false);
        assertEq(ledger.stakedOf(address(vault), id), 0);
        vm.prank(alice);
        manager.setStaked(SPY_POOL, true);
        assertEq(ledger.stakedOf(address(vault), id), tight);
    }

    function test_holdings_countsTight() public {
        _setTight(1000);
        _rebalance();
        uint256 snap = vm.snapshotState();
        (uint256 a, uint256 e) = vault.holdings(SPY_PRICE);
        uint128 held = _held();
        vm.prank(address(manager));
        vault.removeLiquidity(held, 0, 0);
        assertApproxEqAbs(spy.balanceOf(address(vault)), a, 10);
        assertApproxEqAbs(eusd.balanceOf(address(vault)), e, 10);
        vm.revertToState(snap);

        // Below the tight range it holds only asset; above it, only eUSD.
        (uint256 tA,) = _tightAmounts(690e18);
        (, uint256 tE) = _tightAmounts(710e18);
        assertGt(tA, 0);
        assertGt(tE, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _setTight(
        uint16 share
    ) internal {
        vm.prank(alice);
        vault.setTightRange(share, HALF);
    }

    function _rebalance() internal {
        (int24 lower, int24 upper) = spyRange(595e18, 805e18);
        vm.prank(alice);
        manager.rebalance(
            IEUSDLiquidityManager.RebalanceParams({
                poolId: SPY_POOL,
                owner: alice,
                assetMin: 0,
                eusdMin: 0,
                swapAmount: 0,
                assetToEusd: false,
                route: "",
                tickLower: lower,
                tickUpper: upper,
                assetMax: 6e18,
                eusdMax: 2000e18,
                staked: true
            })
        );
    }

    function _tightAmounts(
        uint256 price
    ) internal view returns (uint256, uint256) {
        (int24 lower, int24 upper, uint128 tight) = vault.tightRange();
        return LiquidityMath.getAmountsForLiquidity(
            LiquidityMath.sqrtPriceFromOracle(price, 1e18, true),
            LiquidityMath.getSqrtPriceAtTick(lower),
            LiquidityMath.getSqrtPriceAtTick(upper),
            tight
        );
    }

    function _held() internal view returns (uint128 liquidity) {
        (,, liquidity) = vault.range();
    }

    function _debt() internal view returns (uint256) {
        return manager.getPosition(SPY_POOL, alice).debt;
    }

    function _nearest(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing * spacing;
        int24 r = tick - c;
        if (2 * r >= spacing) c += spacing;
        else if (2 * r < -spacing) c -= spacing;
        return c;
    }

    function _abs(
        int24 x
    ) internal pure returns (int24) {
        return x < 0 ? -x : x;
    }

    function _assertSupplyMatchesDebt() internal view {
        assertEq(eusd.totalSupply() - 10_000e18, manager.totalDebt(), "supply == debt (less the mock reserve)");
    }
}
