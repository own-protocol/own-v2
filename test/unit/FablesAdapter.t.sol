// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FablesAdapter} from "../../src/eusd/adapters/FablesAdapter.sol";
import {ILiquidityVault} from "../../src/interfaces/ILiquidityVault.sol";
import {PoolKey} from "../../src/interfaces/external/IFables.sol";
import {LiquidityManagerSetup} from "../helpers/LiquidityManagerSetup.sol";
import {MockFablesLedger} from "../helpers/MockFables.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Upgrade target with one extra view, used to prove the beacon upgraded every vault.
contract FablesAdapterV2 is FablesAdapter {
    constructor(address poolManager_, address emissionStream_) FablesAdapter(poolManager_, emissionStream_) {}

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
        new FablesAdapter(address(0), address(stream));
        vm.expectRevert(ILiquidityVault.InvalidPool.selector);
        new FablesAdapter(address(ledger), address(0));
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
        vm.stopPrank();
    }

    function test_ownerFunctions_onlyOwner() public {
        bytes32[] memory proof;
        address ff = address(stream.ff());
        vm.startPrank(attacker);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.sweep(ff);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.claimEmissions(1, proof);
        vm.expectRevert(ILiquidityVault.OnlyOwner.selector);
        vault.claimFees(0, 10, 0);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────

    function test_claimEmissions_forwardsToOwner() public {
        bytes32[] memory proof;
        vm.prank(alice);
        vault.claimEmissions(123e18, proof);
        assertEq(stream.ff().balanceOf(alice), 123e18);
        assertEq(stream.ff().balanceOf(address(vault)), 0);
    }

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
