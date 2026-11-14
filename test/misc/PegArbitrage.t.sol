// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PegArbitrage} from "../../misc/PegArbitrage.sol";
import {IPegArbitrage} from "../../misc/interfaces/IPegArbitrage.sol";
import {PoolKey} from "../../misc/interfaces/IPoolManagerSwap.sol";
import {EUSD} from "../../src/eusd/EUSD.sol";
import {EUSDPsm} from "../../src/eusd/EUSDPsm.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockPoolManagerSwap} from "./MockPoolManagerSwap.sol";
import {MockV3Pool} from "./MockV3Pool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PegArbitrageTest is BaseTest {
    EUSD internal eusd;
    EUSDPsm internal psm;
    MockERC20 internal usdg;
    MockPoolManagerSwap internal pm;
    PegArbitrage internal arb;
    PoolKey internal key; // currency0 = USDG, currency1 = eUSD (the live pool's order)

    address internal admin = Actors.ADMIN;
    address internal attacker = Actors.ATTACKER;
    address internal treasury = address(0x7ea5);
    address internal alice = address(0xa11ce);

    function setUp() public override {
        super.setUp();
        eusd = new EUSD(admin);
        EUSDPsm impl = new EUSDPsm();
        psm = EUSDPsm(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(EUSDPsm.initialize, (address(protocolRegistry), address(eusd)))
                )
            )
        );
        usdg = new MockERC20("USDG", "USDG", 6);
        pm = new MockPoolManagerSwap();
        arb = new PegArbitrage(address(protocolRegistry), address(pm), address(psm));
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(psm));
        eusd.grantRole(eusd.MINTER_ROLE(), admin);
        eusd.mint(address(pm), 1_000_000e18); // pool reserves
        protocolRegistry.setTreasury(treasury);
        psm.addAsset(address(usdg), 1_000_000e18, 0, 0);
        vm.stopPrank();
        usdg.mint(address(pm), 1_000_000e6);
        key = PoolKey(address(usdg), address(eusd), 0x800000, 1, address(0));
    }

    /// @dev Raw price of eUSD units per USDG unit for `usdPerEusd` (1e18 = $1).
    function _eusdPerUsdgRaw(
        uint256 usdPerEusd
    ) internal pure returns (uint256) {
        return 1e48 / usdPerEusd;
    }

    function _seedPsm(
        uint256 usdgAmount
    ) internal {
        usdg.mint(alice, usdgAmount);
        vm.startPrank(alice);
        usdg.approve(address(psm), usdgAmount);
        psm.mint(address(usdg), usdgAmount, 0);
        vm.stopPrank();
    }

    // ── Construction ──────────────────────────────────────────

    function test_constructor_setsState() public view {
        assertEq(address(arb.registry()), address(protocolRegistry));
        assertEq(address(arb.poolManager()), address(pm));
        assertEq(address(arb.psm()), address(psm));
        assertEq(arb.eusd(), address(eusd));
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IPegArbitrage.ZeroAddress.selector);
        new PegArbitrage(address(0), address(pm), address(psm));
        vm.expectRevert(IPegArbitrage.ZeroAddress.selector);
        new PegArbitrage(address(protocolRegistry), address(0), address(psm));
        vm.expectRevert(IPegArbitrage.ZeroAddress.selector);
        new PegArbitrage(address(protocolRegistry), address(pm), address(0));
    }

    // ── Sell eUSD (eUSD above $1) ─────────────────────────────

    function test_arbitrage_sellEusd_mintsFromPsmAndKeepsPremium() public {
        pm.setPrice(_eusdPerUsdgRaw(1.0049e18)); // 1 eUSD = 1.0049 USDG
        vm.expectEmit(true, false, false, false, address(arb));
        emit IPegArbitrage.Arbitraged(address(usdg), true, 0, 0, 0);
        vm.prank(admin);
        int256 profit = arb.arbitrage(key, true, 0, 10_000e18, 0);

        assertEq(psm.totalDebt(), 10_000e18);
        assertEq(usdg.balanceOf(address(psm)), 10_000e6);
        assertApproxEqAbs(uint256(profit), 49e6, 1);
        assertEq(usdg.balanceOf(address(arb)), uint256(profit));
        assertEq(eusd.balanceOf(address(arb)), 0);
    }

    function test_arbitrage_sellEusd_withMintFee_coversWhatThePoolIsOwed() public {
        vm.prank(admin);
        psm.setFees(address(usdg), 7, 0);
        pm.setPrice(_eusdPerUsdgRaw(1.0049e18));
        pm.setFillBps(3333); // odd amount
        vm.prank(admin);
        int256 profit = arb.arbitrage(key, true, 0, 1234.5678e18, 0);
        assertGt(profit, 0);
        // At most one asset unit of eUSD is left over from rounding up the mint.
        assertLt(eusd.balanceOf(address(arb)), 1e12);
        assertEq(eusd.totalSupply() - 1_000_000e18, psm.totalDebt());
    }

    function test_arbitrage_sellEusd_eusdIsCurrency0() public {
        PoolKey memory flipped = PoolKey(address(eusd), address(usdg), 0x800000, 1, address(0));
        pm.setPrice(1.0049e6); // USDG units per eUSD unit, 1e18 fixed point
        vm.prank(admin);
        int256 profit = arb.arbitrage(flipped, true, 0, 1000e18, 0);
        assertApproxEqAbs(uint256(profit), 4.9e6, 1);
        assertEq(psm.totalDebt(), 1000e18);
    }

    // ── Buy eUSD (eUSD below $1) ──────────────────────────────

    function test_arbitrage_buyEusd_redeemsAtPsm() public {
        _seedPsm(50_000e6);
        pm.setPrice(_eusdPerUsdgRaw(0.995e18)); // 1 eUSD = 0.995 USDG
        vm.prank(admin);
        int256 profit = arb.arbitrage(key, false, 0, 1000e6, 0);

        // 1000 USDG buys ~1005.03 eUSD, redeemed for ~1005.03 USDG.
        assertApproxEqAbs(uint256(profit), 5.025e6, 0.001e6);
        assertApproxEqAbs(psm.totalDebt(), 50_000e18 - 1005.025e18, 0.001e18);
        assertEq(eusd.balanceOf(address(arb)), 0);
    }

    function test_arbitrage_buyEusd_aboveDebt_reverts() public {
        _seedPsm(100e6);
        pm.setPrice(_eusdPerUsdgRaw(0.995e18));
        vm.prank(admin);
        vm.expectRevert();
        arb.arbitrage(key, false, 0, 1000e6, 0);
    }

    // ── Profit floor and float ────────────────────────────────

    function test_arbitrage_smallLoss_coveredByFloat() public {
        usdg.mint(address(arb), 100e6);
        pm.setPrice(_eusdPerUsdgRaw(0.9999e18)); // selling eUSD below $1 loses 0.01%
        vm.prank(admin);
        int256 profit = arb.arbitrage(key, true, 0, 10_000e18, -2e6);
        assertApproxEqAbs(profit, -1e6, 1);
        assertApproxEqAbs(usdg.balanceOf(address(arb)), 99e6, 1);
    }

    function test_arbitrage_lossBelowFloor_reverts() public {
        usdg.mint(address(arb), 100e6);
        pm.setPrice(_eusdPerUsdgRaw(0.9999e18));
        vm.prank(admin);
        vm.expectPartialRevert(IPegArbitrage.ProfitTooLow.selector);
        arb.arbitrage(key, true, 0, 10_000e18, -0.5e6);
    }

    function test_arbitrage_lossWithoutFloat_reverts() public {
        pm.setPrice(_eusdPerUsdgRaw(0.9999e18));
        vm.prank(admin);
        vm.expectRevert();
        arb.arbitrage(key, true, 0, 10_000e18, -2e6);
    }

    // ── Guards ────────────────────────────────────────────────

    function test_arbitrage_notOperator_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IPegArbitrage.OnlyOperator.selector);
        arb.arbitrage(key, true, 0, 1, 0);
    }

    function test_arbitrage_zeroMaxIn_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPegArbitrage.ZeroAmount.selector);
        arb.arbitrage(key, true, 0, 0, 0);
    }

    function test_arbitrage_notEusdPool_reverts() public {
        PoolKey memory other = PoolKey(address(usdg), address(0xbeef), 0, 1, address(0));
        vm.prank(admin);
        vm.expectRevert(IPegArbitrage.NotAnEusdPool.selector);
        arb.arbitrage(other, true, 0, 1, 0);
    }

    function test_arbitrage_nothingSwapped_reverts() public {
        pm.setFillBps(0);
        vm.prank(admin);
        vm.expectRevert(IPegArbitrage.NothingSwapped.selector);
        arb.arbitrage(key, true, 0, 1e18, 0);
    }

    function test_arbitrage_unlistedAsset_reverts() public {
        MockERC20 other = new MockERC20("X", "X", 6);
        other.mint(address(pm), 1e12);
        PoolKey memory k = PoolKey(address(other), address(eusd), 0, 1, address(0));
        vm.prank(admin);
        vm.expectRevert();
        arb.arbitrage(k, true, 0, 1e18, 0);
    }

    function test_unlockCallback_notPoolManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IPegArbitrage.UnauthorizedCallback.selector);
        arb.unlockCallback("");
    }

    function test_unlockCallback_outsideTrade_reverts() public {
        vm.expectRevert(IPegArbitrage.UnauthorizedCallback.selector);
        pm.callback(address(arb), "");
    }

    // ── v3-style pools (Uniswap v3, Aero Slipstream) ─────────

    function _v3Pool(
        bool eusdIsZero
    ) internal returns (MockV3Pool v3) {
        v3 = eusdIsZero ? new MockV3Pool(address(eusd), address(usdg)) : new MockV3Pool(address(usdg), address(eusd));
        usdg.mint(address(v3), 1_000_000e6);
        vm.prank(admin);
        eusd.mint(address(v3), 1_000_000e18);
    }

    function test_arbitrageV3_sellEusd_mintsFromPsmAndKeepsPremium() public {
        MockV3Pool v3 = _v3Pool(false);
        v3.setPrice(_eusdPerUsdgRaw(1.0049e18));
        vm.expectEmit(true, false, false, false, address(arb));
        emit IPegArbitrage.Arbitraged(address(usdg), true, 0, 0, 0);
        vm.prank(admin);
        int256 profit = arb.arbitrageV3(address(v3), true, 0, 10_000e18, 0);
        assertEq(psm.totalDebt(), 10_000e18);
        assertApproxEqAbs(uint256(profit), 49e6, 1);
        assertEq(eusd.balanceOf(address(arb)), 0);
    }

    function test_arbitrageV3_sellEusd_eusdIsToken0() public {
        MockV3Pool v3 = _v3Pool(true);
        v3.setPrice(1.0049e6);
        vm.prank(admin);
        int256 profit = arb.arbitrageV3(address(v3), true, 0, 1000e18, 0);
        assertApproxEqAbs(uint256(profit), 4.9e6, 1);
        assertEq(psm.totalDebt(), 1000e18);
    }

    function test_arbitrageV3_buyEusd_redeemsAtPsm() public {
        _seedPsm(50_000e6);
        MockV3Pool v3 = _v3Pool(false);
        v3.setPrice(_eusdPerUsdgRaw(0.995e18));
        vm.prank(admin);
        int256 profit = arb.arbitrageV3(address(v3), false, 0, 1000e6, 0);
        assertApproxEqAbs(uint256(profit), 5.025e6, 0.001e6);
        assertApproxEqAbs(psm.totalDebt(), 50_000e18 - 1005.025e18, 0.001e18);
        assertEq(eusd.balanceOf(address(arb)), 0);
    }

    function test_arbitrageV3_lossBelowFloor_reverts() public {
        usdg.mint(address(arb), 100e6);
        MockV3Pool v3 = _v3Pool(false);
        v3.setPrice(_eusdPerUsdgRaw(0.9999e18));
        vm.prank(admin);
        vm.expectPartialRevert(IPegArbitrage.ProfitTooLow.selector);
        arb.arbitrageV3(address(v3), true, 0, 10_000e18, -0.5e6);
    }

    function test_arbitrageV3_guards() public {
        MockV3Pool v3 = _v3Pool(false);
        vm.prank(attacker);
        vm.expectRevert(IPegArbitrage.OnlyOperator.selector);
        arb.arbitrageV3(address(v3), true, 0, 1, 0);

        vm.prank(admin);
        vm.expectRevert(IPegArbitrage.ZeroAmount.selector);
        arb.arbitrageV3(address(v3), true, 0, 0, 0);

        MockV3Pool other = new MockV3Pool(address(usdg), address(0xbeef));
        vm.prank(admin);
        vm.expectRevert(IPegArbitrage.NotAnEusdPool.selector);
        arb.arbitrageV3(address(other), true, 0, 1, 0);
    }

    function test_uniswapV3SwapCallback_outsideTrade_reverts() public {
        MockV3Pool v3 = _v3Pool(false);
        vm.prank(attacker);
        vm.expectRevert(IPegArbitrage.UnauthorizedCallback.selector);
        arb.uniswapV3SwapCallback(0, 1e18, abi.encode(false, address(usdg)));
        // Even the pool cannot call back when no trade is running.
        vm.expectRevert(IPegArbitrage.UnauthorizedCallback.selector);
        v3.callback(address(arb), 0, 1e18, abi.encode(false, address(usdg)));
    }

    // ── withdraw ──────────────────────────────────────────────

    function test_withdraw_sendsToTreasury() public {
        usdg.mint(address(arb), 7e6);
        vm.expectEmit(true, true, false, true, address(arb));
        emit IPegArbitrage.Withdrawn(address(usdg), treasury, 7e6);
        vm.prank(admin);
        arb.withdraw(address(usdg), 7e6);
        assertEq(usdg.balanceOf(treasury), 7e6);
    }

    function test_withdraw_notAdmin_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IPegArbitrage.OnlyAdmin.selector);
        arb.withdraw(address(usdg), 1);
    }

    function test_withdraw_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPegArbitrage.ZeroAmount.selector);
        arb.withdraw(address(usdg), 0);
    }
}
