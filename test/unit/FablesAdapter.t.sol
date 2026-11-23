// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {ILiquidityVault} from "../../src/interfaces/ILiquidityVault.sol";
import {PoolKey} from "../../src/interfaces/external/IFables.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";
import {LiquidityManagerSetup} from "../helpers/LiquidityManagerSetup.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockFablesLedger} from "../helpers/MockFables.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Stand-in for the Fables pool registry.
contract MockPoolRegistry {
    mapping(bytes32 => bool) public isRegistered;

    function register(
        PoolKey memory key
    ) external {
        isRegistered[keccak256(abi.encode(key))] = true;
    }
}

/// @dev Upgrade target with one extra view, used to prove the beacon upgraded every vault.
contract FablesAdapterV2 is FablesAdapter {
    constructor(
        address poolManager_,
        address emissionStream_
    ) FablesAdapter(poolManager_, emissionStream_, address(0)) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract FablesAdapterTest is LiquidityManagerSetup {
    FablesAdapter internal vault;

    function setUp() public override {
        super.setUp();
        openSpy(alice, 10e18, 3500e18);
        vault = FablesAdapter(manager.getPosition(SPY_POOL, alice).vault);
    }

    // ──────────────────────────────────────────────────────────
    //  Construction / initialization
    // ──────────────────────────────────────────────────────────

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        new FablesAdapter(address(0), address(stream), address(0));
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        new FablesAdapter(address(ledger), address(0), address(0));
    }

    function test_initialize_setsState() public view {
        assertEq(vault.manager(), address(manager));
        assertEq(vault.owner(), alice);
        assertEq(vault.asset(), address(spy));
        assertEq(address(vault.poolManager()), address(ledger));
        assertEq(address(vault.emissionStream()), address(stream));
        PoolKey memory key = vault.poolKey();
        assertEq(key.currency0, spyKey.currency0);
        assertEq(key.hooks, spyKey.hooks);
    }

    function test_initialize_twice_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(attacker, address(spy), address(eusd), abi.encode(spyKey));
    }

    function test_initialize_implementation_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapterImpl.initialize(attacker, address(spy), address(eusd), abi.encode(spyKey));
    }

    function test_checkPool_rejectsBadKeys() public {
        PoolKey memory key = spyKey;
        key.hooks = address(0);
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        adapterImpl.checkPool(address(spy), address(eusd), abi.encode(key));

        key = spyKey;
        key.tickSpacing = 0;
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        adapterImpl.checkPool(address(spy), address(eusd), abi.encode(key));

        key = spyKey;
        (key.currency0, key.currency1) = (key.currency1, key.currency0);
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        adapterImpl.checkPool(address(spy), address(eusd), abi.encode(key));

        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        adapterImpl.checkPool(address(spy), address(spy), abi.encode(spyKey));

        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        adapterImpl.checkPool(address(0), address(eusd), abi.encode(spyKey));

        // eUSD on the wrong side for an asset that is currency1.
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        adapterImpl.checkPool(address(usdg), address(spy), abi.encode(usdKey));
    }

    function test_checkPool_rejectsTooManyDecimals() public {
        address odd = address(0x2000);
        deployCodeTo("test/helpers/MockERC20.sol:MockERC20", abi.encode("ODD", "ODD", uint8(24)), odd);
        PoolKey memory key =
            PoolKey({currency0: odd, currency1: address(eusd), fee: 0x800000, tickSpacing: 10, hooks: address(ledger)});
        ledger.setSqrtPrice(key, uint160(1 << 96));
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        adapterImpl.checkPool(odd, address(eusd), abi.encode(key));
    }

    // ──────────────────────────────────────────────────────────
    //  Access control
    // ──────────────────────────────────────────────────────────

    function test_managerFunctions_onlyManager() public {
        vm.startPrank(alice);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        vault.addLiquidity(0, 10, 1, 1);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        vault.removeLiquidity(1, 0, 0);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        vault.setStaked(false);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        vault.transferToken(address(spy), alice, 1);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        vault.swap(true, 1, 0, "");
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        vault.chargeDelegateLoss(1, 0);
        vm.stopPrank();
    }

    function test_ownerFunctions_onlyOwner() public {
        bytes32[] memory proof;
        address ff = address(stream.ff());
        vm.startPrank(attacker);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.sweep(ff);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.claimFees(0, 10, 0);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.setDelegate(attacker, 100);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Fables, true);
        vm.stopPrank();
    }

    function test_delegateCannotUseOwnerFunctions() public {
        vm.prank(alice);
        vault.setDelegate(keeper, 100);
        bytes32[] memory proof;
        address ff = address(stream.ff());
        vm.startPrank(keeper);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.sweep(ff);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.setDelegate(keeper, 100);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Fables, true);
        vm.expectRevert(ILiquidityVault.OnlyManager.selector);
        vault.transferToken(address(spy), keeper, 1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────

    function test_permissionlessStreamClaim_thenSweep() public {
        bytes32[] memory proof;
        vm.prank(attacker);
        stream.claim(0, uint256(uint160(address(vault))), 50e18, proof);
        address ff = address(stream.ff());
        assertEq(stream.ff().balanceOf(address(vault)), 50e18);
        vm.expectEmit(address(vault));
        emit ILiquidityVault.Swept(ff, 50e18);
        vm.prank(alice);
        vault.sweep(ff);
        assertEq(stream.ff().balanceOf(alice), 50e18);
    }

    function test_sweep_protectedTokens_revert() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.ProtectedToken.selector, address(spy)));
        vault.sweep(address(spy));
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.ProtectedToken.selector, address(eusd)));
        vault.sweep(address(eusd));
        vm.stopPrank();
    }

    function test_claimFees_paysOwner() public {
        (int24 lower, int24 upper,) = vault.range();
        ledger.setFeesOwed(address(vault), 1e18, 50e18);
        giveEusd(address(ledger), 50e18);
        uint256 spyBefore = spy.balanceOf(alice);
        vm.prank(alice);
        vault.claimFees(lower, upper, 0);
        assertEq(spy.balanceOf(alice), spyBefore + 1e18);
        assertEq(eusd.balanceOf(alice), 50e18);
    }

    function test_claimFees_aboveMaxFee_reverts() public {
        (int24 lower, int24 upper,) = vault.range();
        ledger.setFeesOwed(address(vault), 1e18, 0);
        ledger.setClaimFeeBps(100);
        vm.expectRevert(MockFablesLedger.ClaimFeeAboveMax.selector);
        vm.prank(alice);
        vault.claimFees(lower, upper, 50);
    }

    // ──────────────────────────────────────────────────────────
    //  Delegate and harvest
    // ──────────────────────────────────────────────────────────

    uint256 internal constant FABLES_PRICE = 0.5e18;

    function _fablesKey(
        address other
    ) internal returns (PoolKey memory key) {
        address ff = address(stream.ff());
        (address c0, address c1) = ff < other ? (ff, other) : (other, ff);
        key = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: address(ledger)});
        ledger.setPrice(key, ff, other == address(spy) ? FABLES_PRICE / 700 : FABLES_PRICE);
    }

    function _route(
        PoolKey memory a
    ) internal pure returns (bytes memory) {
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = a;
        return abi.encode(hops);
    }

    function _proof() internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
    }

    function _eusdRoute() internal returns (bytes memory route) {
        route = _route(_fablesKey(address(eusd)));
        giveEusd(address(ledger), 1_000_000e18);
    }

    function test_setDelegate_setsAndClears() public {
        vm.expectEmit(address(vault));
        emit ILiquidityVault.DelegateSet(keeper, 100);
        vm.prank(alice);
        vault.setDelegate(keeper, 100);
        assertEq(vault.delegate(), keeper);
        vm.prank(alice);
        vault.setDelegate(address(0), 100);
        assertEq(vault.delegate(), address(0));
    }

    function test_setDelegate_lossBudget() public {
        vm.prank(alice);
        vault.setDelegate(keeper, 250);
        (uint16 budget, uint64 start, uint32 used) = vault.delegateLossBudget();
        assertEq(budget, 250);
        assertEq(start, 0);
        assertEq(used, 0);
        vm.prank(alice);
        vault.setDelegate(keeper, uint16(BPS));
        vm.expectRevert(ILiquidityVault.InvalidLossBudget.selector);
        vm.prank(alice);
        vault.setDelegate(keeper, uint16(BPS + 1));
    }

    function test_chargeDelegateLoss_countsLossesPerWindow() public {
        vm.prank(alice);
        vault.setDelegate(keeper, 100);
        vm.startPrank(address(manager));
        vault.chargeDelegateLoss(1000e18, 1001e18);
        (, uint64 start, uint32 used) = vault.delegateLossBudget();
        assertEq(start, 0, "gains open no window");
        vault.chargeDelegateLoss(1000e18, 996e18);
        (, start, used) = vault.delegateLossBudget();
        assertEq(start, block.timestamp);
        assertEq(used, 40);
        vault.chargeDelegateLoss(1000e18, 1000e18 - 1);
        (,, used) = vault.delegateLossBudget();
        assertEq(used, 41, "any loss costs at least 1 bps");
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.DelegateLossBudgetExceeded.selector, 101, 100));
        vault.chargeDelegateLoss(1000e18, 994e18);
        vault.chargeDelegateLoss(1000e18, 994.1e18);
        (,, used) = vault.delegateLossBudget();
        assertEq(used, 100);
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectPartialRevert(ILiquidityVault.DelegateLossBudgetExceeded.selector);
        vault.chargeDelegateLoss(1000e18, 1000e18 - 1);
        vm.warp(block.timestamp + 1);
        vault.chargeDelegateLoss(1000e18, 1000e18 - 1);
        (, start, used) = vault.delegateLossBudget();
        assertEq(start, block.timestamp);
        assertEq(used, 1);
        vm.expectPartialRevert(ILiquidityVault.DelegateLossBudgetExceeded.selector);
        vault.chargeDelegateLoss(1e18, 0);
        vm.stopPrank();
    }

    function test_harvestConfig_defaultsToEusdInVault() public view {
        assertEq(uint8(vault.harvestOut()), uint8(FablesAdapter.HarvestOut.Eusd));
        assertFalse(vault.harvestToOwner());
    }

    function test_setHarvestConfig_setsAndEmits() public {
        vm.expectEmit(address(vault));
        emit FablesAdapter.HarvestConfigSet(FablesAdapter.HarvestOut.Asset, true);
        vm.prank(alice);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Asset, true);
        assertEq(uint8(vault.harvestOut()), uint8(FablesAdapter.HarvestOut.Asset));
        assertTrue(vault.harvestToOwner());
    }

    function test_harvest_default_claimsSwapsAndKeepsEusd() public {
        bytes memory route = _eusdRoute();
        bytes32[] memory proof = _proof();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 expected = vault.harvest(100e18, proof, route, 0);
        vm.revertToState(snap);
        assertApproxEqAbs(expected, 50e18, 1e9);

        vm.expectEmit(address(vault));
        emit ILiquidityVault.Swapped(address(stream.ff()), address(eusd), 100e18, expected);
        vm.expectEmit(address(vault));
        emit FablesAdapter.EmissionsHarvested(alice, 100e18, address(eusd), expected, false);
        vm.prank(alice);
        uint256 out = vault.harvest(100e18, proof, route, expected);
        assertEq(out, expected);
        assertEq(eusd.balanceOf(address(vault)), expected, "eUSD kept in the vault");
        assertEq(stream.ff().balanceOf(address(vault)), 0);
        assertEq(eusd.balanceOf(alice), 0);
    }

    function test_harvest_byDelegate() public {
        bytes memory route = _eusdRoute();
        vm.prank(alice);
        vault.setDelegate(keeper, 100);
        vm.prank(keeper);
        uint256 out = vault.harvest(100e18, _proof(), route, 0);
        assertEq(eusd.balanceOf(address(vault)), out);
        assertEq(eusd.balanceOf(keeper), 0, "delegate receives nothing");
    }

    function test_harvest_stranger_reverts() public {
        bytes memory route = _eusdRoute();
        bytes32[] memory proof = _proof();
        vm.expectRevert(FablesAdapter.OnlyOwnerOrDelegate.selector);
        vm.prank(attacker);
        vault.harvest(100e18, proof, route, 0);
    }

    function test_harvest_clearedDelegate_reverts() public {
        bytes memory route = _eusdRoute();
        bytes32[] memory proof = _proof();
        vm.startPrank(alice);
        vault.setDelegate(keeper, 100);
        vault.setDelegate(address(0), 100);
        vm.stopPrank();
        vm.expectRevert(FablesAdapter.OnlyOwnerOrDelegate.selector);
        vm.prank(keeper);
        vault.harvest(100e18, proof, route, 0);
    }

    function test_harvest_eusdToOwner_sendsOnlyTheSwapOutput() public {
        bytes memory route = _eusdRoute();
        // eUSD already in the vault (e.g. returned by the range) must not leave with a harvest.
        giveEusd(address(vault), 40e18);
        vm.prank(alice);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Eusd, true);
        vm.prank(alice);
        uint256 out = vault.harvest(100e18, _proof(), route, 0);
        assertEq(eusd.balanceOf(alice), out);
        assertEq(eusd.balanceOf(address(vault)), 40e18, "vault eUSD untouched");
    }

    function test_harvest_assetKeptInVault() public {
        bytes memory route = _route(_fablesKey(address(spy)));
        uint256 spyBefore = spy.balanceOf(address(vault));
        vm.prank(alice);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Asset, false);
        vm.expectEmit(true, true, false, false, address(vault));
        emit FablesAdapter.EmissionsHarvested(alice, 700e18, address(spy), 0, false);
        vm.prank(alice);
        uint256 out = vault.harvest(700e18, _proof(), route, 0);
        assertApproxEqAbs(out, 0.5e18, 1e9);
        assertEq(spy.balanceOf(address(vault)), spyBefore + out);
    }

    function test_harvest_assetToOwner() public {
        bytes memory route = _route(_fablesKey(address(spy)));
        uint256 vaultSpy = spy.balanceOf(address(vault));
        uint256 aliceSpy = spy.balanceOf(alice);
        vm.prank(alice);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Asset, true);
        vm.prank(alice);
        uint256 out = vault.harvest(700e18, _proof(), route, 0);
        assertEq(spy.balanceOf(alice), aliceSpy + out);
        assertEq(spy.balanceOf(address(vault)), vaultSpy, "vault asset untouched");
    }

    function test_harvest_fablesKept() public {
        vm.prank(alice);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Fables, false);
        vm.prank(alice);
        uint256 out = vault.harvest(100e18, _proof(), "", 0);
        assertEq(out, 100e18);
        assertEq(stream.ff().balanceOf(address(vault)), 100e18);
    }

    function test_harvest_fablesToOwner() public {
        vm.prank(alice);
        vault.setHarvestConfig(FablesAdapter.HarvestOut.Fables, true);
        vm.prank(alice);
        uint256 out = vault.harvest(100e18, _proof(), "", 0);
        assertEq(out, 100e18);
        assertEq(stream.ff().balanceOf(alice), 100e18);
        assertEq(stream.ff().balanceOf(address(vault)), 0);
    }

    function test_harvest_emptyProof_usesFablesAlreadyInVault() public {
        bytes memory route = _eusdRoute();
        bytes32[] memory empty;
        stream.claim(0, uint256(uint160(address(vault))), 30e18, empty);
        vm.prank(alice);
        uint256 out = vault.harvest(0, empty, route, 0);
        assertApproxEqAbs(out, 15e18, 1e9);
    }

    function test_harvest_nothing_reverts() public {
        bytes32[] memory empty;
        vm.expectRevert(FablesAdapter.NothingToHarvest.selector);
        vm.prank(alice);
        vault.harvest(0, empty, "", 0);
    }

    function test_harvest_belowMinOut_reverts() public {
        bytes memory route = _eusdRoute();
        bytes32[] memory proof = _proof();
        vm.expectPartialRevert(ILiquidityVault.InsufficientOutput.selector);
        vm.prank(alice);
        vault.harvest(100e18, proof, route, 50e18 + 1);
    }

    function test_harvest_swapWithoutRoute_reverts() public {
        bytes32[] memory proof = _proof();
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vm.prank(alice);
        vault.harvest(100e18, proof, "", 0);
    }

    function test_harvest_badRoutes_revert() public {
        PoolKey memory good = _fablesKey(address(eusd));
        bytes memory toSpy = _route(_fablesKey(address(spy)));
        giveEusd(address(ledger), 1_000_000e18);
        bytes32[] memory proof = _proof();
        vm.startPrank(alice);

        PoolKey memory foreignHook = good;
        foreignHook.hooks = address(0xBEEF);
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vault.harvest(100e18, proof, _route(foreignHook), 0);

        // An unset route hook does not open hookless pools.
        foreignHook.hooks = address(0);
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vault.harvest(100e18, proof, _route(foreignHook), 0);

        // Leads from FABLES to SPY, not to eUSD.
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vault.harvest(100e18, proof, toSpy, 0);

        // First hop does not hold FABLES.
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vault.harvest(100e18, proof, _route(usdKey), 0);

        PoolKey[] memory none = new PoolKey[](0);
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vault.harvest(100e18, proof, abi.encode(none), 0);

        // Four hops is over the limit, whatever the tokens.
        PoolKey[] memory long = new PoolKey[](4);
        (long[0], long[1], long[2], long[3]) = (good, usdKey, usdKey, usdKey);
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vault.harvest(100e18, proof, abi.encode(long), 0);
        vm.stopPrank();
    }

    function test_harvest_fablesIsAsset_reverts() public {
        MockERC20 ff = MockERC20(address(stream.ff()));
        (address c0, address c1) =
            address(ff) < address(eusd) ? (address(ff), address(eusd)) : (address(eusd), address(ff));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: address(ledger)});
        ledger.setPrice(key, address(ff), FABLES_PRICE);
        oracle.setPrice(bytes32("FABLES"), FABLES_PRICE);
        vm.prank(admin);
        uint256 poolId = manager.addPool(address(beacon), address(ff), bytes32("FABLES"), abi.encode(key));
        ff.mint(bob, 10e18);
        vm.startPrank(bob);
        ff.approve(address(manager), 10e18);
        manager.deposit(poolId, 10e18);
        FablesAdapter v = FablesAdapter(manager.getPosition(poolId, bob).vault);
        v.setHarvestConfig(FablesAdapter.HarvestOut.Fables, true);
        bytes32[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.ProtectedToken.selector, address(ff)));
        v.harvest(0, empty, "", 0);
        vm.stopPrank();
        assertEq(ff.balanceOf(address(v)), 10e18, "collateral stays");
    }

    function test_harvest_fablesIsEusd_reverts() public {
        vm.mockCall(address(stream), abi.encodeWithSignature("ff()"), abi.encode(address(eusd)));
        bytes32[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.ProtectedToken.selector, address(eusd)));
        vm.prank(alice);
        vault.harvest(0, empty, "", 0);
    }

    function test_harvest_throughRegisteredPool() public {
        MockPoolRegistry registry = new MockPoolRegistry();
        FablesAdapter impl = new FablesAdapter(address(ledger), address(stream), address(registry));
        vm.prank(admin);
        beacon.upgradeTo(address(impl));
        assertEq(address(vault.poolRegistry()), address(registry));

        // FABLES -> eUSD on the vault hook, then eUSD -> USDG -> eUSD through a pool on another hook.
        PoolKey memory other = usdKey;
        other.hooks = makeAddr("otherHook");
        ledger.setPrice(other, address(usdg), 1e18);
        PoolKey[] memory hops = new PoolKey[](3);
        (hops[0], hops[1], hops[2]) = (_fablesKey(address(eusd)), other, usdKey);
        giveEusd(address(ledger), 1_000_000e18);
        usdg.mint(address(ledger), 1_000_000e6);
        bytes32[] memory proof = _proof();
        bytes memory route = abi.encode(hops);

        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vm.prank(alice);
        vault.harvest(100e18, proof, route, 1);

        registry.register(other);
        vm.prank(alice);
        uint256 out = vault.harvest(100e18, proof, route, 1);
        assertApproxEqRel(out, 50e18, 1e15);
        assertEq(eusd.balanceOf(address(vault)), out);
    }

    function test_harvest_partialFill_reverts() public {
        bytes memory route = _eusdRoute();
        bytes32[] memory proof = _proof();
        ledger.setFillBps(5000);
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vm.prank(alice);
        vault.harvest(100e18, proof, route, 0);
    }

    function test_harvest_twoHops() public {
        // FABLES -> eUSD -> USDG -> eUSD: the longest route allowed.
        PoolKey[] memory hops = new PoolKey[](3);
        (hops[0], hops[1], hops[2]) = (_fablesKey(address(eusd)), usdKey, usdKey);
        giveEusd(address(ledger), 1_000_000e18);
        vm.prank(alice);
        uint256 out = vault.harvest(100e18, _proof(), abi.encode(hops), 0);
        assertApproxEqAbs(out, 50e18, 1e12);
        assertEq(eusd.balanceOf(address(vault)), out);
    }

    // ──────────────────────────────────────────────────────────
    //  Swap
    // ──────────────────────────────────────────────────────────

    function test_swap_assetToEusd_ownPool() public {
        giveEusd(address(ledger), 1_000_000e18);
        uint256 spyBefore = spy.balanceOf(address(vault));
        vm.prank(alice);
        manager.deposit(SPY_POOL, 1e18);
        vm.expectEmit(true, true, false, false, address(vault));
        emit ILiquidityVault.Swapped(address(spy), address(eusd), 1e18, 0);
        vm.prank(address(manager));
        uint256 out = vault.swap(true, 1e18, 699e18, "");
        assertApproxEqAbs(out, 700e18, 1e9);
        assertEq(spy.balanceOf(address(vault)), spyBefore);
        assertEq(eusd.balanceOf(address(vault)), out);
    }

    function test_swap_eusdToAsset_ownPool() public {
        giveEusd(address(vault), 700e18);
        uint256 spyBefore = spy.balanceOf(address(vault));
        vm.prank(address(manager));
        uint256 out = vault.swap(false, 700e18, 0, "");
        assertApproxEqAbs(out, 1e18, 1e6);
        assertEq(spy.balanceOf(address(vault)), spyBefore + out);
        assertEq(eusd.balanceOf(address(vault)), 0);
    }

    function test_swap_belowMinOut_reverts() public {
        giveEusd(address(ledger), 1_000_000e18);
        vm.prank(alice);
        manager.deposit(SPY_POOL, 1e18);
        ledger.setSwapFeeBps(100);
        vm.expectPartialRevert(ILiquidityVault.InsufficientOutput.selector);
        vm.prank(address(manager));
        vault.swap(true, 1e18, 694e18, "");
    }

    function test_swap_zeroAmount_reverts() public {
        vm.expectRevert(ILiquidityVault.InvalidRoute.selector);
        vm.prank(address(manager));
        vault.swap(true, 0, 0, "");
    }

    function test_unlockCallback_notPoolManager_reverts() public {
        vm.expectRevert(FablesAdapter.OnlyPoolManager.selector);
        vm.prank(attacker);
        vault.unlockCallback("");
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    function test_holdings_includesIdle() public {
        (uint256 a0, uint256 e0) = vault.holdings(SPY_PRICE);
        vm.prank(alice);
        manager.deposit(SPY_POOL, 1e18);
        (uint256 a1, uint256 e1) = vault.holdings(SPY_PRICE);
        assertEq(a1, a0 + 1e18);
        assertEq(e1, e0);
    }

    function test_holdings_rangeAboveAndBelowPrice() public view {
        (uint256 aLow, uint256 eLow) = vault.holdings(500e18);
        (uint256 aHigh, uint256 eHigh) = vault.holdings(900e18);
        uint256 idle = spy.balanceOf(address(vault));
        assertGt(aLow, idle);
        assertEq(eLow, 0, "below the range: all asset");
        assertEq(aHigh, idle, "above the range: all eUSD");
        assertGt(eHigh, 0);
    }

    function test_holdings_isLowerBoundWhenPoolIsOff() public {
        // Valued at the oracle, the amounts the range actually holds at an off-oracle pool price
        // are worth at least the amounts it would hold at the oracle price.
        (uint256 aFair, uint256 eFair) = vault.holdings(SPY_PRICE);
        uint256 fair = aFair * 700 + eFair;
        uint128 liquidity;
        (,, liquidity) = vault.range();
        giveEusd(address(ledger), 10_000e18);
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            ledger.setPrice(spyKey, address(spy), i == 0 ? 640e18 : 760e18);
            uint256 idle = spy.balanceOf(address(vault));
            vm.prank(address(manager));
            (uint256 aOut, uint256 eOut) = vault.removeLiquidity(liquidity, 0, 0);
            assertGe((aOut + idle) * 700 + eOut, fair);
            vm.revertToState(snap);
        }
    }

    function test_poolPrice_matchesOracle() public view {
        assertApproxEqRel(vault.poolPrice(), SPY_PRICE, 1e9);
    }

    // ──────────────────────────────────────────────────────────
    //  Manager paths on the vault
    // ──────────────────────────────────────────────────────────

    function test_removeLiquidity_zero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.InsufficientLiquidity.selector, 0, _held()));
        vm.prank(address(manager));
        vault.removeLiquidity(0, 0, 0);
    }

    function test_removeLiquidity_all_clearsRange() public {
        uint128 held = _held();
        vm.prank(address(manager));
        vault.removeLiquidity(held, 0, 0);
        (int24 lower, int24 upper, uint128 liquidity) = vault.range();
        assertEq(lower, 0);
        assertEq(upper, 0);
        assertEq(liquidity, 0);
    }

    function test_transferToken_emits() public {
        vm.expectEmit(address(vault));
        emit ILiquidityVault.TokenTransferred(address(spy), bob, 1e18);
        vm.prank(address(manager));
        vault.transferToken(address(spy), bob, 1e18);
    }

    function test_addLiquidity_poolUninitialized_reverts() public {
        ledger.setSqrtPrice(spyKey, 0);
        (int24 lower, int24 upper,) = vault.range();
        vm.expectRevert(ILiquidityVault.PoolNotInitialized.selector);
        vm.prank(address(manager));
        vault.addLiquidity(lower, upper, 1e18, 0);
    }

    function test_addLiquidity_noApprovalLeft() public view {
        assertEq(spy.allowance(address(vault), address(ledger)), 0);
        assertEq(eusd.allowance(address(vault), address(ledger)), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Beacon upgrades
    // ──────────────────────────────────────────────────────────

    function test_beaconUpgrade_upgradesEveryVault() public {
        openSpy(bob, 10e18, 3500e18);
        FablesAdapter bobVault = FablesAdapter(manager.getPosition(SPY_POOL, bob).vault);
        FablesAdapterV2 v2 = new FablesAdapterV2(address(ledger), address(stream));
        vm.prank(admin);
        beacon.upgradeTo(address(v2));
        assertEq(FablesAdapterV2(address(vault)).version(), 2);
        assertEq(FablesAdapterV2(address(bobVault)).version(), 2);
        assertEq(vault.owner(), alice, "state kept");
        assertEq(_held(), _heldOf(vault));
    }

    function test_beaconUpgrade_notOwner_reverts() public {
        FablesAdapterV2 v2 = new FablesAdapterV2(address(ledger), address(stream));
        vm.expectRevert();
        vm.prank(attacker);
        beacon.upgradeTo(address(v2));
    }

    function test_vaultIsBeaconProxy() public view {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1);
        assertEq(address(uint160(uint256(vm.load(address(vault), slot)))), address(beacon));
    }

    function _held() internal view returns (uint128 liquidity) {
        (,, liquidity) = vault.range();
    }

    function _heldOf(
        FablesAdapter v
    ) internal view returns (uint128 liquidity) {
        (,, liquidity) = v.range();
    }
}
