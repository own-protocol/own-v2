// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDLiquidityManager} from "../../src/eusd/EUSDLiquidityManager.sol";
import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {ILiquidityVault} from "../../src/interfaces/ILiquidityVault.sol";
import {PoolKey} from "../../src/interfaces/external/IFables.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";
import {LiquidityManagerSetup} from "../helpers/LiquidityManagerSetup.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockFablesLedger} from "../helpers/MockFables.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Upgrade target with one extra view, used to prove the proxy upgraded.
contract EUSDLiquidityManagerV2 is EUSDLiquidityManager {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract EUSDLiquidityManagerTest is LiquidityManagerSetup {
    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _vault(uint256 poolId, address owner) internal view returns (FablesAdapter) {
        return FablesAdapter(manager.getPosition(poolId, owner).vault);
    }

    function _debt(uint256 poolId, address owner) internal view returns (uint256) {
        return manager.getPosition(poolId, owner).debt;
    }

    function _liquidity(uint256 poolId, address owner) internal view returns (uint128 liquidity) {
        (,, liquidity) = _vault(poolId, owner).range();
    }

    function _addParams(
        uint256 assetDeposit,
        uint256 assetMax,
        uint256 eusdMax
    ) internal pure returns (IEUSDLiquidityManager.AddLiquidityParams memory) {
        (int24 lower, int24 upper) = spyRange(595e18, 805e18);
        return IEUSDLiquidityManager.AddLiquidityParams({
            poolId: SPY_POOL,
            tickLower: lower,
            tickUpper: upper,
            assetDeposit: assetDeposit,
            assetMax: assetMax,
            eusdMax: eusdMax,
            staked: true
        });
    }

    function _repoParams(
        uint256 low,
        uint256 high,
        uint256 assetMax,
        uint256 eusdMax
    ) internal pure returns (IEUSDLiquidityManager.RepositionParams memory) {
        (int24 lower, int24 upper) = spyRange(low, high);
        return IEUSDLiquidityManager.RepositionParams({
            poolId: SPY_POOL,
            tickLower: lower,
            tickUpper: upper,
            assetMax: assetMax,
            eusdMax: eusdMax,
            assetMin: 0,
            eusdMin: 0
        });
    }

    function _assertSupplyMatchesDebt() internal view {
        assertEq(eusd.totalSupply(), manager.totalDebt(), "supply == debt");
    }

    // ──────────────────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────────────────

    function test_initialize_setsState() public view {
        assertEq(address(manager.registry()), address(registry));
        assertEq(manager.eusd(), address(eusd));
        IEUSDLiquidityManager.RiskParams memory p = manager.riskParams();
        assertEq(p.mcrBps, MCR);
        assertEq(p.stakedFeeBps, STAKED_FEE);
        assertEq(p.unstakedFeeBps, UNSTAKED_FEE);
        assertEq(p.poolPriceBandBps, BAND);
        assertEq(manager.poolCount(), 2);
    }

    function test_initialize_twice_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        manager.initialize(address(registry), address(eusd), defaultParams());
    }

    function test_initialize_implementationLocked_reverts() public {
        EUSDLiquidityManager impl = new EUSDLiquidityManager();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(registry), address(eusd), defaultParams());
    }

    function _expectInitRevert(
        address registry_,
        address eusd_,
        IEUSDLiquidityManager.RiskParams memory p,
        bytes4 err
    ) internal {
        EUSDLiquidityManager impl = new EUSDLiquidityManager();
        bytes memory initData = abi.encodeCall(EUSDLiquidityManager.initialize, (registry_, eusd_, p));
        vm.expectRevert(err);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_zeroAddress_reverts() public {
        _expectInitRevert(address(0), address(eusd), defaultParams(), IEUSDLiquidityManager.ZeroAddress.selector);
        _expectInitRevert(address(registry), address(0), defaultParams(), IEUSDLiquidityManager.ZeroAddress.selector);
    }

    function test_initialize_invalidParams_reverts() public {
        bytes4 err = IEUSDLiquidityManager.InvalidRiskParams.selector;
        IEUSDLiquidityManager.RiskParams memory p = defaultParams();
        p.mcrBps = LIQ_THRESHOLD - 1;
        _expectInitRevert(address(registry), address(eusd), p, err);

        p = defaultParams();
        p.stakedFeeBps = uint16(BPS + 1);
        _expectInitRevert(address(registry), address(eusd), p, err);

        p = defaultParams();
        p.unstakedFeeBps = uint16(BPS + 1);
        _expectInitRevert(address(registry), address(eusd), p, err);

        p = defaultParams();
        p.poolPriceBandBps = 0;
        _expectInitRevert(address(registry), address(eusd), p, err);

        p = defaultParams();
        p.poolPriceBandBps = uint16(BPS + 1);
        _expectInitRevert(address(registry), address(eusd), p, err);

        p = defaultParams();
        p.mintPriceMaxAge = 0;
        _expectInitRevert(address(registry), address(eusd), p, err);
    }

    // ──────────────────────────────────────────────────────────
    //  addPool / setPoolEnabled
    // ──────────────────────────────────────────────────────────

    function test_addPool_storesConfig() public view {
        IEUSDLiquidityManager.PoolConfig memory cfg = manager.poolConfig(SPY_POOL);
        assertEq(cfg.beacon, address(beacon));
        assertEq(cfg.asset, address(spy));
        assertEq(cfg.ticker, SPY);
        assertEq(cfg.assetDecimals, 18);
        assertTrue(cfg.enabled && cfg.exists);
        assertEq(cfg.poolData, abi.encode(spyKey));
        assertEq(manager.poolConfig(USD_POOL).assetDecimals, 6);
    }

    function test_addPool_emits() public {
        MockERC20 qqq = new MockERC20("QQQ", "QQQ", 18);
        oracle.setPrice(bytes32("QQQ"), 600e18);
        PoolKey memory key = _keyFor(address(qqq));
        ledger.setPrice(key, address(qqq), 600e18);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.PoolAdded(2, address(beacon), address(qqq), bytes32("QQQ"));
        vm.prank(admin);
        assertEq(manager.addPool(address(beacon), address(qqq), bytes32("QQQ"), abi.encode(key)), 2);
    }

    function test_addPool_notAdmin_reverts() public {
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        vm.prank(attacker);
        manager.addPool(address(beacon), address(spy), SPY, abi.encode(spyKey));
    }

    function test_addPool_zeroAddress_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(IEUSDLiquidityManager.ZeroAddress.selector);
        manager.addPool(address(0), address(spy), SPY, abi.encode(spyKey));
        vm.expectRevert(IEUSDLiquidityManager.ZeroAddress.selector);
        manager.addPool(address(beacon), address(0), SPY, abi.encode(spyKey));
        vm.stopPrank();
    }

    function test_addPool_tooManyDecimals_reverts() public {
        MockERC20 odd = new MockERC20("ODD", "ODD", 24);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.InvalidAssetDecimals.selector, uint8(24)));
        vm.prank(admin);
        manager.addPool(address(beacon), address(odd), SPY, abi.encode(spyKey));
    }

    function test_addPool_unpricedTicker_reverts() public {
        vm.expectRevert();
        vm.prank(admin);
        manager.addPool(address(beacon), address(spy), bytes32("NONE"), abi.encode(spyKey));
    }

    function test_addPool_wrongTokens_reverts() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        vm.prank(admin);
        manager.addPool(address(beacon), address(other), SPY, abi.encode(spyKey));
    }

    function test_addPool_uninitializedPool_reverts() public {
        MockERC20 qqq = new MockERC20("QQQ", "QQQ", 18);
        vm.expectRevert(ILiquidityVault.PoolNotInitialized.selector);
        vm.prank(admin);
        manager.addPool(address(beacon), address(qqq), SPY, abi.encode(_keyFor(address(qqq))));
    }

    function test_setPoolEnabled_togglesAndEmits() public {
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.PoolEnabledSet(SPY_POOL, false);
        vm.prank(admin);
        manager.setPoolEnabled(SPY_POOL, false);
        assertFalse(manager.poolConfig(SPY_POOL).enabled);
    }

    function test_setPoolEnabled_unknownPool_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.PoolNotSupported.selector, 9));
        vm.prank(admin);
        manager.setPoolEnabled(9, false);
    }

    function test_setPoolEnabled_notAdmin_reverts() public {
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        vm.prank(attacker);
        manager.setPoolEnabled(SPY_POOL, false);
    }

    function _keyFor(
        address asset
    ) internal view returns (PoolKey memory) {
        (address c0, address c1) = asset < address(eusd) ? (asset, address(eusd)) : (address(eusd), asset);
        return PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 10, hooks: address(ledger)});
    }

    // ──────────────────────────────────────────────────────────
    //  deposit / withdraw
    // ──────────────────────────────────────────────────────────

    function test_deposit_createsVaultUnstaked() public {
        vm.prank(alice);
        manager.deposit(SPY_POOL, 5e18);
        IEUSDLiquidityManager.Position memory p = manager.getPosition(SPY_POOL, alice);
        assertTrue(p.vault != address(0));
        assertFalse(p.staked);
        FablesAdapter v = FablesAdapter(p.vault);
        assertEq(v.owner(), alice);
        assertEq(v.manager(), address(manager));
        assertEq(v.asset(), address(spy));
        assertFalse(v.staked());
        assertEq(spy.balanceOf(p.vault), 5e18);
        assertEq(manager.positionCount(SPY_POOL), 1);
        assertEq(manager.positionOwnerAt(SPY_POOL, 0), alice);
    }

    function test_deposit_secondDepositReusesVault() public {
        vm.startPrank(alice);
        manager.deposit(SPY_POOL, 5e18);
        address vault = manager.getPosition(SPY_POOL, alice).vault;
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.AssetDeposited(SPY_POOL, alice, 1e18);
        manager.deposit(SPY_POOL, 1e18);
        vm.stopPrank();
        assertEq(manager.getPosition(SPY_POOL, alice).vault, vault);
        assertEq(spy.balanceOf(vault), 6e18);
        assertEq(manager.positionCount(SPY_POOL), 1);
    }

    function test_deposit_zeroAmount_reverts() public {
        vm.expectRevert(IEUSDLiquidityManager.ZeroAmount.selector);
        vm.prank(alice);
        manager.deposit(SPY_POOL, 0);
    }

    function test_deposit_unknownPool_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.PoolNotSupported.selector, 7));
        vm.prank(alice);
        manager.deposit(7, 1e18);
    }

    function test_deposit_disabledPoolWithoutDebt_reverts() public {
        vm.prank(admin);
        manager.setPoolEnabled(SPY_POOL, false);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.PoolDisabled.selector, SPY_POOL));
        vm.prank(alice);
        manager.deposit(SPY_POOL, 1e18);
    }

    function test_deposit_disabledPoolWithDebt_allowed() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(admin);
        manager.setPoolEnabled(SPY_POOL, false);
        vm.prank(alice);
        manager.deposit(SPY_POOL, 1e18);
    }

    function test_withdraw_noDebt_sendsIdle() public {
        vm.startPrank(alice);
        manager.deposit(SPY_POOL, 5e18);
        uint256 before = spy.balanceOf(alice);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.AssetWithdrawn(SPY_POOL, alice, 2e18);
        manager.withdraw(SPY_POOL, 2e18);
        vm.stopPrank();
        assertEq(spy.balanceOf(alice), before + 2e18);
    }

    function test_withdraw_withDebt_keepsMcr() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(alice);
        manager.withdraw(SPY_POOL, 1e18);
        assertGe(manager.collateralRatioBps(SPY_POOL, alice), MCR);
    }

    function test_withdraw_belowMcr_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 idle = spy.balanceOf(address(_vault(SPY_POOL, alice)));
        vm.expectRevert();
        vm.prank(alice);
        manager.withdraw(SPY_POOL, idle);
    }

    function test_withdraw_moreThanIdle_reverts() public {
        vm.startPrank(alice);
        manager.deposit(SPY_POOL, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.InsufficientIdleAsset.selector, 2e18, 1e18));
        manager.withdraw(SPY_POOL, 2e18);
        vm.stopPrank();
    }

    function test_withdraw_zero_reverts() public {
        vm.expectRevert(IEUSDLiquidityManager.ZeroAmount.selector);
        vm.prank(alice);
        manager.withdraw(SPY_POOL, 0);
    }

    function test_withdraw_noVault_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoVault.selector, SPY_POOL, alice));
        vm.prank(alice);
        manager.withdraw(SPY_POOL, 1);
    }

    function test_withdraw_withDebtWhilePaused_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(operator);
        manager.setMintPaused(true);
        vm.expectRevert(IEUSDLiquidityManager.MintingPaused.selector);
        vm.prank(alice);
        manager.withdraw(SPY_POOL, 1e18);
    }

    function test_withdraw_withDebtStalePrice_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        vm.warp(block.timestamp + PRICE_MAX_AGE + 1);
        vm.expectRevert();
        vm.prank(alice);
        manager.withdraw(SPY_POOL, 1e18);
    }

    // ──────────────────────────────────────────────────────────
    //  addLiquidity
    // ──────────────────────────────────────────────────────────

    function test_addLiquidity_mintsIntoRangeAndStakes() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        FablesAdapter v = _vault(SPY_POOL, alice);
        (int24 lower, int24 upper, uint128 held) = v.range();
        assertEq(held, liquidity);
        uint256 id = ledger.rangeId(spyKey, lower, upper);
        assertEq(ledger.balanceOf(address(v), id), liquidity);
        assertEq(ledger.stakedOf(address(v), id), liquidity);

        uint256 debt = _debt(SPY_POOL, alice);
        assertGt(debt, 3499e18);
        assertLe(debt, 3500e18);
        assertEq(eusd.balanceOf(address(v)), 0, "leftover eUSD burned");
        assertEq(eusd.balanceOf(alice), 0, "no wallet mint");
        _assertSupplyMatchesDebt();
        assertGe(manager.collateralRatioBps(SPY_POOL, alice), MCR);
    }

    function test_addLiquidity_leftoverEusdBurned() public {
        // 1 SPY cannot absorb 3,500 eUSD in this range, so most of the mint is burned back.
        vm.prank(alice);
        manager.addLiquidity(_addParams(2e18, 1e18, 3500e18));
        uint256 debt = _debt(SPY_POOL, alice);
        assertLt(debt, 1000e18);
        assertEq(eusd.balanceOf(address(_vault(SPY_POOL, alice))), 0);
        _assertSupplyMatchesDebt();
    }

    function test_addLiquidity_sameRangeAddsUp() public {
        uint128 first = openSpy(alice, 10e18, 3500e18);
        uint128 second = openSpy(alice, 10e18, 3500e18);
        assertEq(_liquidity(SPY_POOL, alice), first + second);
    }

    function test_addLiquidity_rangeAbovePrice_assetOnlyNoDebt() public {
        (int24 lower, int24 upper) = spyRange(750e18, 850e18);
        vm.prank(bob);
        uint128 liquidity = manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: SPY_POOL,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 5e18,
                assetMax: 5e18,
                eusdMax: 0,
                staked: true
            })
        );
        assertGt(liquidity, 0);
        assertEq(_debt(SPY_POOL, bob), 0);
        assertApproxEqAbs(spy.balanceOf(address(_vault(SPY_POOL, bob))), 0, 2);
    }

    function test_addLiquidity_otherRange_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        (int24 lower, int24 upper) = spyRange(595e18, 805e18);
        IEUSDLiquidityManager.AddLiquidityParams memory a = _addParams(1e18, 1e18, 100e18);
        a.tickUpper = upper + 10;
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.RangeMismatch.selector, lower, upper));
        vm.prank(alice);
        manager.addLiquidity(a);
    }

    function test_addLiquidity_invalidRange_reverts() public {
        IEUSDLiquidityManager.AddLiquidityParams memory a = _addParams(1e18, 1e18, 100e18);
        a.tickLower = a.tickUpper;
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.InvalidRange.selector, a.tickLower, a.tickUpper));
        vm.prank(alice);
        manager.addLiquidity(a);

        a = _addParams(1e18, 1e18, 100e18);
        a.tickLower += 1;
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.InvalidRange.selector, a.tickLower, a.tickUpper));
        vm.prank(alice);
        manager.addLiquidity(a);
    }

    function test_addLiquidity_zeroLiquidity_reverts() public {
        vm.expectRevert(ILiquidityVault.ZeroLiquidity.selector);
        vm.prank(alice);
        manager.addLiquidity(_addParams(0, 0, 0));
    }

    function test_addLiquidity_belowMcr_reverts() public {
        // All 10 SPY plus matching eUSD in range: ratio ~2x minus range curvature, below 200%.
        IEUSDLiquidityManager.AddLiquidityParams memory a = _addParams(10e18, 10e18, 8000e18);
        vm.expectRevert();
        vm.prank(alice);
        manager.addLiquidity(a);
    }

    function test_addLiquidity_debtCeiling_reverts() public {
        vm.prank(admin);
        manager.setDebtCeiling(1000e18);
        vm.expectRevert();
        openSpy(alice, 10e18, 3500e18);
    }

    function test_addLiquidity_belowMinDebt_reverts() public {
        vm.expectRevert();
        openSpy(alice, 10e18, 50e18);
    }

    function test_addLiquidity_paused_reverts() public {
        vm.prank(operator);
        manager.setMintPaused(true);
        vm.expectRevert(IEUSDLiquidityManager.MintingPaused.selector);
        openSpy(alice, 10e18, 3500e18);
    }

    function test_addLiquidity_stalePrice_reverts() public {
        oracle.setPrice(SPY, SPY_PRICE, block.timestamp - PRICE_MAX_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEUSDLiquidityManager.StaleMintPrice.selector, block.timestamp - PRICE_MAX_AGE - 1, PRICE_MAX_AGE
            )
        );
        openSpy(alice, 10e18, 3500e18);
    }

    function test_addLiquidity_poolOutOfBand_reverts() public {
        ledger.setPrice(spyKey, address(spy), 730e18);
        vm.expectRevert();
        openSpy(alice, 10e18, 3500e18);
    }

    function test_addLiquidity_poolInsideBand_succeeds() public {
        ledger.setPrice(spyKey, address(spy), 715e18);
        openSpy(alice, 10e18, 3500e18);
    }

    function test_addLiquidity_disabledPool_reverts() public {
        vm.prank(admin);
        manager.setPoolEnabled(SPY_POOL, false);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.PoolDisabled.selector, SPY_POOL));
        openSpy(alice, 10e18, 3500e18);
    }

    function test_addLiquidity_gaugeNotEarning_reverts_unlessUnstaked() public {
        ledger.setGaugeEarning(false);
        vm.expectRevert(MockFablesLedger.DeskRetired.selector);
        openSpy(alice, 10e18, 3500e18);

        openSpy(alice, 10e18, 3500e18, false);
        assertFalse(manager.getPosition(SPY_POOL, alice).staked);
    }

    function test_addLiquidity_unstaked_opensUnstakedAtUnstakedRate() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18, false);
        FablesAdapter v = _vault(SPY_POOL, alice);
        (int24 lower, int24 upper,) = v.range();
        IEUSDLiquidityManager.Position memory p = manager.getPosition(SPY_POOL, alice);
        assertFalse(p.staked);
        assertFalse(v.staked());
        assertEq(p.feeIndexSnapshot, manager.globalFeeIndex(false));
        assertEq(ledger.stakedOf(address(v), ledger.rangeId(spyKey, lower, upper)), 0);
        assertGt(liquidity, 0);
    }

    function test_addLiquidity_switchesOpenRangeMode() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        FablesAdapter v = _vault(SPY_POOL, alice);
        (int24 lower, int24 upper,) = v.range();
        uint256 id = ledger.rangeId(spyKey, lower, upper);
        assertEq(ledger.stakedOf(address(v), id), liquidity);

        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.StakedSet(SPY_POOL, alice, false);
        uint128 added = openSpy(alice, 1e18, 350e18, false);
        assertFalse(manager.getPosition(SPY_POOL, alice).staked);
        assertEq(ledger.stakedOf(address(v), id), 0);
        (,, uint128 held) = v.range();
        assertEq(held, liquidity + added);
    }

    function test_addLiquidity_assetAsCurrency1_sixDecimals() public {
        (int24 lower, int24 upper) = usdRange(0.99e18, 1.01e18);
        vm.prank(alice);
        uint128 liquidity = manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: USD_POOL,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 2000e6,
                assetMax: 1000e6,
                eusdMax: 1000e18,
                staked: true
            })
        );
        assertGt(liquidity, 0);
        uint256 debt = _debt(USD_POOL, alice);
        assertGt(debt, 900e18);
        // ~1,000 USDG idle + ~2,000 in value in range vs ~1,000 debt.
        uint256 ratio = manager.collateralRatioBps(USD_POOL, alice);
        assertGt(ratio, 29_000);
        assertLt(ratio, 31_000);
        _assertSupplyMatchesDebt();
    }

    // ──────────────────────────────────────────────────────────
    //  removeLiquidity
    // ──────────────────────────────────────────────────────────

    function test_removeLiquidity_burnsEusdAgainstDebt() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        vm.prank(alice);
        manager.removeLiquidity(SPY_POOL, liquidity / 2, 0, 0);
        assertApproxEqRel(_debt(SPY_POOL, alice), debt / 2, 0.001e18);
        assertEq(eusd.balanceOf(address(_vault(SPY_POOL, alice))), 0);
        _assertSupplyMatchesDebt();
    }

    function test_removeLiquidity_all_clearsDebtWhenPriceRose() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        giveEusd(address(ledger), 100_000e18);
        moveSpy(780e18);
        uint256 supplyBefore = eusd.totalSupply();
        vm.prank(alice);
        manager.removeLiquidity(SPY_POOL, liquidity, 0, 0);
        assertEq(_debt(SPY_POOL, alice), 0);
        assertGt(eusd.balanceOf(alice), 0, "surplus eUSD to owner");
        assertEq(eusd.balanceOf(address(_vault(SPY_POOL, alice))), 0);
        assertEq(manager.totalDebt(), 0);
        assertLt(eusd.totalSupply(), supplyBefore);
    }

    function test_removeLiquidity_keepsMinDebt_leavesIdleEusd() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        giveEusd(address(ledger), 100_000e18);
        // Price up: the range holds more eUSD than the debt; removing most of it hits the minDebt floor.
        moveSpy(700e18);
        vm.prank(admin);
        manager.setMinDebt(3000e18);
        vm.prank(alice);
        manager.removeLiquidity(SPY_POOL, (liquidity * 9) / 10, 0, 0);
        uint256 debt = _debt(SPY_POOL, alice);
        assertEq(debt, 3000e18);
        assertGt(eusd.balanceOf(address(_vault(SPY_POOL, alice))), 0);
    }

    function test_removeLiquidity_zero_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        vm.expectRevert(IEUSDLiquidityManager.ZeroAmount.selector);
        vm.prank(alice);
        manager.removeLiquidity(SPY_POOL, 0, 0, 0);
    }

    function test_removeLiquidity_tooMuch_reverts() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.InsufficientLiquidity.selector, liquidity + 1, liquidity)
        );
        vm.prank(alice);
        manager.removeLiquidity(SPY_POOL, liquidity + 1, 0, 0);
    }

    function test_removeLiquidity_slippage_reverts() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        vm.expectRevert();
        vm.prank(alice);
        manager.removeLiquidity(SPY_POOL, liquidity, 100e18, 0);
    }

    function test_removeLiquidity_noVault_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoVault.selector, SPY_POOL, bob));
        vm.prank(bob);
        manager.removeLiquidity(SPY_POOL, 1, 0, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  reposition
    // ──────────────────────────────────────────────────────────

    function test_reposition_movesRangeAndDebt() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debtBefore = _debt(SPY_POOL, alice);
        vm.prank(alice);
        uint128 liquidity = manager.reposition(_repoParams(650e18, 750e18, 3e18, 2000e18));
        (int24 lower, int24 upper, uint128 held) = _vault(SPY_POOL, alice).range();
        (int24 eLower, int24 eUpper) = spyRange(650e18, 750e18);
        assertEq(lower, eLower);
        assertEq(upper, eUpper);
        assertEq(held, liquidity);
        assertLt(_debt(SPY_POOL, alice), debtBefore, "debt shrank to the new eUSD leg");
        assertEq(eusd.balanceOf(address(_vault(SPY_POOL, alice))), 0);
        assertEq(ledger.stakedOf(address(_vault(SPY_POOL, alice)), ledger.rangeId(spyKey, lower, upper)), held);
        _assertSupplyMatchesDebt();
    }

    function test_reposition_canIncreaseDebt() public {
        openSpy(alice, 20e18, 3500e18);
        uint256 debtBefore = _debt(SPY_POOL, alice);
        vm.prank(alice);
        manager.reposition(_repoParams(595e18, 805e18, 10e18, 5000e18));
        assertGt(_debt(SPY_POOL, alice), debtBefore);
        assertGe(manager.collateralRatioBps(SPY_POOL, alice), MCR);
        _assertSupplyMatchesDebt();
    }

    function test_reposition_increaseBelowMcr_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        vm.expectRevert();
        vm.prank(alice);
        manager.reposition(_repoParams(595e18, 805e18, 10e18, 8000e18));
    }

    function test_reposition_belowMcrMayNotWorsen() public {
        openSpy(alice, 10e18, 3500e18);
        moveSpy(420e18);
        uint256 ratio = manager.collateralRatioBps(SPY_POOL, alice);
        assertLt(ratio, MCR);
        // Below MCR a move is allowed when it takes no new debt and the ratio does not fall.
        vm.prank(alice);
        manager.reposition(_repoParams(450e18, 600e18, 9e18, 0));
        assertGe(manager.collateralRatioBps(SPY_POOL, alice), ratio);
        assertEq(_debt(SPY_POOL, alice) <= 3500e18, true);
    }

    function test_reposition_outOfBand_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        ledger.setPrice(spyKey, address(spy), 650e18);
        vm.expectRevert();
        vm.prank(alice);
        manager.reposition(_repoParams(600e18, 700e18, 1e18, 0));
    }

    function test_reposition_noVault_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoVault.selector, SPY_POOL, bob));
        vm.prank(bob);
        manager.reposition(_repoParams(600e18, 700e18, 1e18, 0));
    }

    // ──────────────────────────────────────────────────────────
    //  setStaked / fees
    // ──────────────────────────────────────────────────────────

    function test_setStaked_unstakesAndSwitchesRate() public {
        uint128 liquidity = openSpy(alice, 10e18, 3500e18);
        FablesAdapter v = _vault(SPY_POOL, alice);
        (int24 lower, int24 upper,) = v.range();
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.StakedSet(SPY_POOL, alice, false);
        vm.prank(alice);
        manager.setStaked(SPY_POOL, false);
        assertFalse(v.staked());
        assertEq(ledger.stakedOf(address(v), ledger.rangeId(spyKey, lower, upper)), 0);

        vm.prank(alice);
        manager.setStaked(SPY_POOL, true);
        assertEq(ledger.stakedOf(address(v), ledger.rangeId(spyKey, lower, upper)), liquidity);
    }

    function test_setStaked_sameState_noop() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(alice);
        manager.setStaked(SPY_POOL, true);
        assertTrue(_vault(SPY_POOL, alice).staked());
    }

    function test_setStaked_noVault_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoVault.selector, SPY_POOL, bob));
        vm.prank(bob);
        manager.setStaked(SPY_POOL, false);
    }

    function test_fees_stakedRate() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        vm.warp(block.timestamp + 365 days);
        uint256 expected = debt + (debt * STAKED_FEE) / BPS;
        assertApproxEqAbs(manager.currentDebt(SPY_POOL, alice), expected, 1);
        oracle.setPrice(SPY, SPY_PRICE);
        manager.accrue(SPY_POOL, alice);
        assertApproxEqAbs(_debt(SPY_POOL, alice), expected, 1);
        assertApproxEqAbs(eusd.balanceOf(treasury), expected - debt, 1);
        _assertSupplyMatchesDebt();
    }

    function test_fees_unstakedRate() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(alice);
        manager.setStaked(SPY_POOL, false);
        uint256 debt = _debt(SPY_POOL, alice);
        vm.warp(block.timestamp + 365 days);
        assertApproxEqAbs(manager.currentDebt(SPY_POOL, alice), debt + (debt * UNSTAKED_FEE) / BPS, 1);
    }

    function test_fees_switchSettlesAtOldRate() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        vm.warp(block.timestamp + 182.5 days);
        vm.prank(alice);
        manager.setStaked(SPY_POOL, false);
        vm.warp(block.timestamp + 182.5 days);
        uint256 expected = debt + (debt * (STAKED_FEE + UNSTAKED_FEE)) / (2 * BPS);
        assertApproxEqAbs(manager.currentDebt(SPY_POOL, alice), expected, 2);
    }

    function test_setStabilityFees_prospective() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        vm.warp(block.timestamp + 182.5 days);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.StabilityFeesSet(0, 0);
        vm.prank(admin);
        manager.setStabilityFees(0, 0);
        vm.warp(block.timestamp + 182.5 days);
        assertApproxEqAbs(manager.currentDebt(SPY_POOL, alice), debt + (debt * STAKED_FEE) / (2 * BPS), 1);
        assertEq(manager.globalFeeIndex(true), uint256(STAKED_FEE) * 182.5 days);
        assertEq(manager.globalFeeIndex(false), uint256(UNSTAKED_FEE) * 182.5 days);
    }

    function test_accrue_noDebt_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoDebt.selector, SPY_POOL, alice));
        manager.accrue(SPY_POOL, alice);
    }

    // ──────────────────────────────────────────────────────────
    //  repay
    // ──────────────────────────────────────────────────────────

    function test_repay_partial() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(bob, 1000e18);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.DebtRepaid(SPY_POOL, alice, bob, 1000e18, debt - 1000e18);
        vm.prank(bob);
        manager.repay(SPY_POOL, alice, 1000e18);
        assertEq(_debt(SPY_POOL, alice), debt - 1000e18);
        assertEq(eusd.balanceOf(bob), 0);
    }

    function test_repay_capsAtDebt() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(bob, debt + 50e18);
        vm.prank(bob);
        manager.repay(SPY_POOL, alice, type(uint256).max);
        assertEq(_debt(SPY_POOL, alice), 0);
        assertEq(eusd.balanceOf(bob), 50e18);
    }

    function test_repay_belowMinDebt_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(bob, debt);
        vm.expectRevert();
        vm.prank(bob);
        manager.repay(SPY_POOL, alice, debt - 1e18);
    }

    function test_repay_reverts() public {
        vm.expectRevert(IEUSDLiquidityManager.ZeroAddress.selector);
        manager.repay(SPY_POOL, address(0), 1);
        vm.expectRevert(IEUSDLiquidityManager.ZeroAmount.selector);
        manager.repay(SPY_POOL, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoDebt.selector, SPY_POOL, alice));
        manager.repay(SPY_POOL, alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.PoolNotSupported.selector, 5));
        manager.repay(5, alice, 1);
    }

    // ──────────────────────────────────────────────────────────
    //  close
    // ──────────────────────────────────────────────────────────

    function test_close_atOpenPrice_userPaysOnlyFees() public {
        openSpy(alice, 10e18, 3500e18);
        vm.warp(block.timestamp + 30 days);
        uint256 debt = manager.currentDebt(SPY_POOL, alice);
        uint256 spyBefore = spy.balanceOf(alice);
        // The range still holds the minted eUSD; only the accrued fee is owed from the wallet.
        giveEusd(alice, 100e18);
        vm.prank(alice);
        manager.close(SPY_POOL, 0, 0);
        assertEq(_debt(SPY_POOL, alice), 0);
        assertEq(manager.totalDebt(), 0);
        assertApproxEqAbs(spy.balanceOf(alice) - spyBefore, 10e18, 2);
        assertApproxEqAbs(eusd.balanceOf(alice), 100e18 - (debt - 3500e18), 2e18);
        FablesAdapter v = _vault(SPY_POOL, alice);
        assertEq(spy.balanceOf(address(v)), 0);
        assertEq(eusd.balanceOf(address(v)), 0);
        (,, uint128 held) = v.range();
        assertEq(held, 0);
    }

    function test_close_afterDrop_userPaysShortfall() public {
        openSpy(alice, 10e18, 3500e18);
        moveSpy(600e18);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(alice, 4000e18);
        vm.prank(alice);
        manager.close(SPY_POOL, 0, 0);
        uint256 paid = 4000e18 - eusd.balanceOf(alice);
        assertGt(paid, 0);
        assertLt(paid, debt);
        assertEq(manager.totalDebt(), 0);
    }

    function test_close_withoutEnoughEusd_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        moveSpy(600e18);
        vm.expectRevert();
        vm.prank(alice);
        manager.close(SPY_POOL, 0, 0);
    }

    function test_close_vaultReusable() public {
        openSpy(alice, 10e18, 3500e18);
        address vault = address(_vault(SPY_POOL, alice));
        giveEusd(alice, 100e18);
        vm.prank(alice);
        manager.close(SPY_POOL, 0, 0);
        openSpy(alice, 10e18, 3500e18);
        assertEq(address(_vault(SPY_POOL, alice)), vault);
        assertEq(manager.positionCount(SPY_POOL), 1);
    }

    function test_close_empty_reverts() public {
        vm.startPrank(alice);
        manager.deposit(SPY_POOL, 1e18);
        manager.close(SPY_POOL, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.EmptyPosition.selector, SPY_POOL, alice));
        manager.close(SPY_POOL, 0, 0);
        vm.stopPrank();
    }

    function test_close_noVault_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoVault.selector, SPY_POOL, alice));
        vm.prank(alice);
        manager.close(SPY_POOL, 0, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  liquidate
    // ──────────────────────────────────────────────────────────

    function test_liquidate_healthy_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 ratio = manager.collateralRatioBps(SPY_POOL, alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEUSDLiquidityManager.PositionNotLiquidatable.selector, ratio, LIQ_THRESHOLD)
        );
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, type(uint256).max);
    }

    function test_liquidate_noDebt_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.NoDebt.selector, SPY_POOL, alice));
        manager.liquidate(SPY_POOL, alice, type(uint256).max);
    }

    function _crash(
        uint256 price
    ) internal {
        moveSpy(price);
        assertTrue(manager.isLiquidatable(SPY_POOL, alice));
    }

    function test_liquidate_paysBonusAndRefundsOwner() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(250e18);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(keeper, debt);
        uint256 keeperEusd = eusd.balanceOf(keeper);
        uint256 aliceSpy = spy.balanceOf(alice);

        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, type(uint256).max);

        uint256 repaid = keeperEusd - eusd.balanceOf(keeper);
        uint256 seized = spy.balanceOf(keeper) - 1_000_000e18;
        assertEq(seized, (repaid * (BPS + LIQ_BONUS) * 1e18) / (250e18 * BPS));
        assertGt(spy.balanceOf(alice), aliceSpy, "owner refund");
        assertEq(_debt(SPY_POOL, alice), 0);
        assertEq(manager.totalDebt(), 0);
        FablesAdapter v = _vault(SPY_POOL, alice);
        assertEq(spy.balanceOf(address(v)), 0);
        assertEq(eusd.balanceOf(address(v)), 0);
    }

    function test_liquidate_ignoresPoolBandAndPriceAge() public {
        openSpy(alice, 10e18, 3500e18);
        oracle.setPrice(SPY, 250e18, block.timestamp);
        ledger.setPrice(spyKey, address(spy), 300e18);
        vm.warp(block.timestamp + 10 days);
        assertTrue(manager.isLiquidatable(SPY_POOL, alice));
        giveEusd(keeper, 10_000e18);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, type(uint256).max);
        assertEq(_debt(SPY_POOL, alice), 0);
    }

    function test_liquidate_underwater_capsSeizure() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(100e18);
        giveEusd(keeper, 10_000e18);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, type(uint256).max);
        assertEq(spy.balanceOf(address(_vault(SPY_POOL, alice))), 0);
        assertEq(spy.balanceOf(alice), 1_000_000e18 - 10e18, "no refund when underwater");
    }

    function test_liquidate_emits() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(250e18);
        giveEusd(keeper, 10_000e18);
        vm.expectEmit(true, true, true, false, address(manager));
        emit IEUSDLiquidityManager.PositionLiquidated(SPY_POOL, alice, keeper, 0, 0, 0, 0, 0, 0);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, type(uint256).max);
    }

    function test_liquidate_zeroAmount_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(250e18);
        vm.expectRevert(IEUSDLiquidityManager.ZeroAmount.selector);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, 0);
    }

    function test_liquidate_partial_removesShareAndKeepsRange() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(250e18);
        FablesAdapter v = _vault(SPY_POOL, alice);
        (int24 lower, int24 upper, uint128 held) = v.range();
        uint256 debt = _debt(SPY_POOL, alice);
        uint256 cleared = debt / 2;
        _partialLiquidate(cleared);

        (int24 lowerAfter, int24 upperAfter, uint128 left) = v.range();
        assertEq(lowerAfter, lower);
        assertEq(upperAfter, upper);
        assertEq(left, held - uint128(Math.mulDiv(held, cleared, debt, Math.Rounding.Ceil)));
        assertEq(ledger.stakedOf(address(v), ledger.rangeId(spyKey, lower, upper)), left, "rest stays staked");
        assertLe(_debt(SPY_POOL, alice), debt - cleared);
        assertGe(_debt(SPY_POOL, alice), MIN_DEBT);
        assertEq(manager.totalDebt(), _debt(SPY_POOL, alice));
    }

    /// @dev Liquidate `cleared` as the keeper; checks the payout, no owner refund and a better ratio.
    function _partialLiquidate(
        uint256 cleared
    ) internal {
        uint256 ratioBefore = manager.collateralRatioBps(SPY_POOL, alice);
        uint256 aliceSpy = spy.balanceOf(alice);
        giveEusd(keeper, cleared);
        uint256 keeperEusd = eusd.balanceOf(keeper);
        uint256 keeperSpy = spy.balanceOf(keeper);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, cleared);
        uint256 repaid = keeperEusd - eusd.balanceOf(keeper);
        assertLe(repaid, cleared);
        assertEq(spy.balanceOf(keeper) - keeperSpy, (repaid * (BPS + LIQ_BONUS) * 1e18) / (250e18 * BPS));
        assertEq(spy.balanceOf(alice), aliceSpy, "no refund on a partial liquidation");
        assertGt(manager.collateralRatioBps(SPY_POOL, alice), ratioBefore, "ratio improves");
    }

    function test_liquidate_partial_emits() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(250e18);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(keeper, debt);
        vm.recordLogs();
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, 1000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IEUSDLiquidityManager.PositionLiquidated.selector;
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != topic) continue;
            uint256[6] memory data = abi.decode(logs[i].data, (uint256[6]));
            assertEq(data[0], 1000e18, "cleared");
            assertEq(data[3], 0, "asset refund");
            assertEq(data[4], 0, "eusd refund");
            assertEq(data[5], _debt(SPY_POOL, alice), "remaining");
            found = true;
        }
        assertTrue(found);
    }

    function test_liquidate_partial_belowMinDebt_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(250e18);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(keeper, debt);
        vm.expectRevert(abi.encodeWithSelector(IEUSDLiquidityManager.BelowMinimumDebt.selector, MIN_DEBT - 1, MIN_DEBT));
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, debt - MIN_DEBT + 1);
    }

    function test_liquidate_partialThenFull() public {
        openSpy(alice, 10e18, 3500e18);
        _crash(250e18);
        giveEusd(keeper, 10_000e18);
        vm.startPrank(keeper);
        manager.liquidate(SPY_POOL, alice, 1000e18);
        if (manager.isLiquidatable(SPY_POOL, alice)) manager.liquidate(SPY_POOL, alice, 1000e18);
        moveSpy(200e18);
        manager.liquidate(SPY_POOL, alice, type(uint256).max);
        vm.stopPrank();
        assertEq(_debt(SPY_POOL, alice), 0);
        assertEq(manager.totalDebt(), 0);
        FablesAdapter v = _vault(SPY_POOL, alice);
        (,, uint128 left) = v.range();
        assertEq(left, 0);
        assertEq(spy.balanceOf(address(v)), 0);
        assertEq(eusd.balanceOf(address(v)), 0);
    }

    /// @dev Between 1 + bonus and the threshold, any partial liquidation leaves a healthier position.
    function testFuzz_liquidate_partial_improvesRatio(uint256 priceSeed, uint256 amountSeed) public {
        openSpy(alice, 10e18, 3500e18);
        moveSpy(bound(priceSeed, 200e18, 300e18));
        uint256 ratioBefore = manager.collateralRatioBps(SPY_POOL, alice);
        vm.assume(ratioBefore < LIQ_THRESHOLD && ratioBefore > BPS + LIQ_BONUS);
        uint256 debt = _debt(SPY_POOL, alice);
        uint256 amount = bound(amountSeed, 1e18, debt - MIN_DEBT);
        giveEusd(keeper, amount);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, amount);
        assertGe(manager.collateralRatioBps(SPY_POOL, alice), ratioBefore);
        assertLe(_debt(SPY_POOL, alice), debt - amount);
        assertEq(manager.totalDebt(), _debt(SPY_POOL, alice));
    }

    /// @dev Below 1 + bonus too, and with idle asset in the vault, a partial liquidation takes only
    ///      its share of the value, so the ratio of what remains never falls.
    function testFuzz_liquidate_partial_neverLowersRatio(
        uint256 priceSeed,
        uint256 amountSeed,
        uint256 idleSeed
    ) public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(alice);
        manager.deposit(SPY_POOL, bound(idleSeed, 1, 5e18));
        moveSpy(bound(priceSeed, 120e18, 300e18));
        uint256 ratioBefore = manager.collateralRatioBps(SPY_POOL, alice);
        vm.assume(ratioBefore < LIQ_THRESHOLD && ratioBefore > BPS);
        uint256 debt = _debt(SPY_POOL, alice);
        uint256 amount = bound(amountSeed, 1e18, debt - MIN_DEBT);
        giveEusd(keeper, amount);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, amount);
        assertGe(manager.collateralRatioBps(SPY_POOL, alice), ratioBefore);
        assertEq(manager.totalDebt(), _debt(SPY_POOL, alice));
    }

    function test_liquidate_partial_belowOnePlusBonus_paysOnlyShareOfValue() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(alice);
        manager.deposit(SPY_POOL, 5e18);
        uint256 price = 175e18;
        moveSpy(price);
        uint256 debt = _debt(SPY_POOL, alice);
        uint256 value = manager.collateralValue(SPY_POOL, alice);
        uint256 ratioBefore = manager.collateralRatioBps(SPY_POOL, alice);
        assertGt(ratioBefore, BPS);
        assertLt(ratioBefore, BPS + LIQ_BONUS);

        uint256 cleared = debt / 2;
        giveEusd(keeper, cleared);
        uint256 keeperSpy = spy.balanceOf(keeper);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, cleared);
        uint256 seizedValue = ((spy.balanceOf(keeper) - keeperSpy) * price) / 1e18;
        assertLe(seizedValue, Math.mulDiv(value, cleared, debt), "at most the cleared share of the value");
        assertLt(seizedValue, (cleared * (BPS + LIQ_BONUS)) / BPS, "the full bonus does not fit");
        assertGe(manager.collateralRatioBps(SPY_POOL, alice), ratioBefore);
    }

    /// @dev The bonus is on the cleared debt, so a pool that still holds the range's eUSD pays the
    ///      liquidator the same as one pushed below the range.
    function test_liquidate_bonusOnCleared_sameWhateverThePoolSplit() public {
        uint256 lagging = _liquidationProfit(true);
        uint256 pushed = _liquidationProfit(false);
        assertApproxEqAbs(lagging, pushed, 1e6);
    }

    function _liquidationProfit(
        bool poolLags
    ) internal returns (uint256 profit) {
        uint256 snap = vm.snapshotState();
        openSpy(alice, 10e18, 3500e18);
        uint256 price = 250e18;
        oracle.setPrice(SPY, price, block.timestamp);
        ledger.setPrice(spyKey, address(spy), poolLags ? SPY_PRICE : price);
        uint256 debt = _debt(SPY_POOL, alice);
        giveEusd(keeper, debt);
        uint256 keeperEusd = eusd.balanceOf(keeper);
        uint256 keeperSpy = spy.balanceOf(keeper);
        vm.prank(keeper);
        manager.liquidate(SPY_POOL, alice, type(uint256).max);
        uint256 repaid = keeperEusd - eusd.balanceOf(keeper);
        if (poolLags) assertLt(repaid, debt, "the vault's eUSD covered part");
        else assertEq(repaid, debt);
        profit = ((spy.balanceOf(keeper) - keeperSpy) * price) / 1e18 - repaid;
        assertApproxEqAbs(profit, (debt * LIQ_BONUS) / BPS, 1e6, "bonus on the cleared debt");
        vm.revertToState(snap);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    function test_collateralValue_matchesHoldings() public {
        openSpy(alice, 10e18, 3500e18);
        (uint256 a, uint256 e) = _vault(SPY_POOL, alice).holdings(SPY_PRICE);
        assertEq(manager.collateralValue(SPY_POOL, alice), (a * SPY_PRICE) / 1e18 + e);
        assertApproxEqRel(manager.collateralValue(SPY_POOL, alice), 10e18 * 700 + 3500e18, 0.001e18);
    }

    function test_views_noPosition() public view {
        assertEq(manager.collateralValue(SPY_POOL, alice), 0);
        assertEq(manager.collateralRatioBps(SPY_POOL, alice), type(uint256).max);
        assertFalse(manager.isLiquidatable(SPY_POOL, alice));
        assertEq(manager.currentDebt(SPY_POOL, alice), 0);
    }

    function test_poolPrice_bothOrientations() public view {
        FablesAdapter impl = adapterImpl;
        impl; // the views below run on vaults; this checks the math via a fresh vault's pool
        assertApproxEqRel(_priceOf(spyKey, address(spy)), SPY_PRICE, 1e9);
        assertApproxEqRel(_priceOf(usdKey, address(usdg)), 1e18, 1e9);
    }

    function _priceOf(PoolKey memory key, address asset) internal view returns (uint256) {
        uint256 sqrtP = ledger.sqrtPriceOf(key);
        uint256 scale = 10 ** MockERC20(asset).decimals();
        bool zero = key.currency0 == asset;
        if (zero) return Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 2 ** 96), scale, 2 ** 96);
        return Math.mulDiv(Math.mulDiv(2 ** 96, scale, sqrtP), 2 ** 96, sqrtP);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin setters
    // ──────────────────────────────────────────────────────────

    function test_setRiskParams() public {
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.RiskParamsSet(21_000, 14_000, 400);
        vm.prank(admin);
        manager.setRiskParams(21_000, 14_000, 400);
        assertEq(manager.riskParams().liquidationThresholdBps, 14_000);
    }

    function test_setRiskParams_invalid_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setRiskParams(11_000, 12_000, 500);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setRiskParams(20_000, 10_400, 500);
        vm.stopPrank();
    }

    function test_setStabilityFees_invalid_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setStabilityFees(uint16(BPS + 1), 0);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setStabilityFees(0, uint16(BPS + 1));
        vm.stopPrank();
    }

    function test_setPoolPriceBand() public {
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.PoolPriceBandSet(500);
        vm.prank(admin);
        manager.setPoolPriceBand(500);
        assertEq(manager.riskParams().poolPriceBandBps, 500);
        vm.startPrank(admin);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setPoolPriceBand(0);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setPoolPriceBand(uint16(BPS + 1));
        vm.stopPrank();
    }

    function test_setDebtCeiling_setMinDebt_setMintPriceMaxAge() public {
        vm.startPrank(admin);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.DebtCeilingSet(5e24);
        manager.setDebtCeiling(5e24);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.MinDebtSet(50e18);
        manager.setMinDebt(50e18);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.MintPriceMaxAgeSet(600);
        manager.setMintPriceMaxAge(600);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setMintPriceMaxAge(0);
        vm.stopPrank();
        IEUSDLiquidityManager.RiskParams memory p = manager.riskParams();
        assertEq(p.debtCeiling, 5e24);
        assertEq(p.minDebt, 50e18);
        assertEq(p.mintPriceMaxAge, 600);
    }

    function test_adminSetters_notAdmin_revert() public {
        vm.startPrank(attacker);
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        manager.setRiskParams(MCR, LIQ_THRESHOLD, LIQ_BONUS);
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        manager.setStabilityFees(0, 0);
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        manager.setPoolPriceBand(100);
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        manager.setDebtCeiling(0);
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        manager.setMinDebt(0);
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        manager.setMintPriceMaxAge(1);
        vm.expectRevert(IEUSDLiquidityManager.OnlyOperator.selector);
        manager.setMintPaused(true);
        vm.stopPrank();
    }

    function test_setMintPaused_emits() public {
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.MintPausedSet(true);
        vm.prank(operator);
        manager.setMintPaused(true);
        assertTrue(manager.mintPaused());
    }

    // ──────────────────────────────────────────────────────────
    //  Upgrades
    // ──────────────────────────────────────────────────────────

    function test_upgrade_adminKeepsState() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 debt = _debt(SPY_POOL, alice);
        EUSDLiquidityManagerV2 v2 = new EUSDLiquidityManagerV2();
        vm.prank(admin);
        manager.upgradeToAndCall(address(v2), "");
        assertEq(EUSDLiquidityManagerV2(address(manager)).version(), 2);
        assertEq(_debt(SPY_POOL, alice), debt);
    }

    function test_upgrade_notAdmin_reverts() public {
        EUSDLiquidityManagerV2 v2 = new EUSDLiquidityManagerV2();
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        vm.prank(attacker);
        manager.upgradeToAndCall(address(v2), "");
    }

    function test_upgrade_implementationDirectCall_reverts() public {
        EUSDLiquidityManager impl = new EUSDLiquidityManager();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(address(impl), "");
    }
}
