// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title LiquidationFlow Integration Test
/// @notice Tests the LiquidationEngine integration with vaults and oracle.
///         Note: LiquidationEngine is currently a stub. These tests verify current
///         behavior (always-healthy vaults) and document expected future behavior.
contract LiquidationFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    LiquidationEngine public liquidationEngine;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 500_000e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        paymentRegistry = new PaymentTokenRegistry(Actors.ADMIN);

        // Register infrastructure in registry
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.PAYMENT_TOKEN_REGISTRY(), address(paymentRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        // Deploy contracts with registry
        market = new OwnMarket(address(protocolRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));
        liquidationEngine = new LiquidationEngine(address(protocolRegistry), address(dex));

        // Register market, vault manager, and liquidation engine
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));
        protocolRegistry.setAddress(protocolRegistry.LIQUIDATION_ENGINE(), address(liquidationEngine));

        usdcVault =
            new OwnVault(address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), Actors.VM1, 8000, 0);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);
        paymentRegistry.addPaymentToken(address(usdc));

        vm.stopPrank();

        vm.label(address(liquidationEngine), "LiquidationEngine");

        // LP deposits collateral (via VM1)
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Vault is healthy — not liquidatable (stub behavior)
    // ══════════════════════════════════════════════════════════

    function test_liquidation_healthyVault_notLiquidatable() public view {
        // Current stub always returns false for isLiquidatable
        assertFalse(liquidationEngine.isLiquidatable(address(usdcVault)));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Health factor view (stub returns max)
    // ══════════════════════════════════════════════════════════

    function test_liquidation_healthFactor_stub() public view {
        // Stub always returns max uint256
        assertEq(liquidationEngine.getHealthFactor(address(usdcVault)), type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Max liquidatable (stub returns 0)
    // ══════════════════════════════════════════════════════════

    function test_liquidation_maxLiquidatable_stub() public view {
        assertEq(liquidationEngine.getMaxLiquidatable(address(usdcVault), TSLA), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Tier 1 liquidation — reverts when vault is healthy
    // ══════════════════════════════════════════════════════════

    function test_liquidation_tier1_healthyVault_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("VaultHealthy(address,uint256)", address(usdcVault), type(uint256).max));
        liquidationEngine.liquidate(address(usdcVault), TSLA, 10e18, _emptyPriceData());
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Tier 1 liquidation — zero amount reverts
    // ══════════════════════════════════════════════════════════

    function test_liquidation_tier1_zeroAmount_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        liquidationEngine.liquidate(address(usdcVault), TSLA, 0, _emptyPriceData());
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Tier 3 DEX liquidation — reverts when healthy
    // ══════════════════════════════════════════════════════════

    function test_liquidation_tier3_healthyVault_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("VaultHealthy(address,uint256)", address(usdcVault), type(uint256).max));
        liquidationEngine.dexLiquidate(address(usdcVault), TSLA, 100e6, _emptyPriceData(), "");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Tier 3 DEX liquidation — zero amount reverts
    // ══════════════════════════════════════════════════════════

    function test_liquidation_tier3_zeroAmount_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        liquidationEngine.dexLiquidate(address(usdcVault), TSLA, 0, _emptyPriceData(), "");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Expired redemption liquidation (stub)
    // ══════════════════════════════════════════════════════════

    function test_liquidation_expiredRedemption_stub() public {
        // Stub returns 0 payout, emits event
        vm.prank(Actors.LIQUIDATOR);
        uint256 payout = liquidationEngine.liquidateExpiredRedemption(1, "", "");
        assertEq(payout, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Vault health factor via OwnVault (real contract)
    // ══════════════════════════════════════════════════════════

    function test_liquidation_vaultHealthFactor_noExposure() public view {
        // OwnVault with 0 exposure returns max health
        assertEq(usdcVault.healthFactor(), type(uint256).max);
        assertEq(usdcVault.utilization(), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: LiquidationEngine wiring
    // ══════════════════════════════════════════════════════════

    function test_liquidation_contractWiring() public view {
        assertEq(address(liquidationEngine.registry()), address(protocolRegistry));
        assertEq(liquidationEngine.dex(), address(dex));
    }
}
