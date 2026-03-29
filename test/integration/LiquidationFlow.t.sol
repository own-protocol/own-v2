// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title LiquidationFlow Integration Test
/// @notice Tests the LiquidationEngine integration with vaults and oracle.
///         Note: LiquidationEngine is currently a stub.
contract LiquidationFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
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

        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));
        liquidationEngine = new LiquidationEngine(address(protocolRegistry), address(dex));

        usdcVault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), Actors.VM1, 8000, 2000, 2000
        );

        market = new OwnMarket(address(protocolRegistry), address(usdcVault), 1 days, 6 hours);

        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));
        protocolRegistry.setAddress(protocolRegistry.LIQUIDATION_ENGINE(), address(liquidationEngine));

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        vm.stopPrank();

        // Set payment token (single token per vault)
        vm.prank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));

        vm.label(address(liquidationEngine), "LiquidationEngine");

        // LP deposits collateral (via VM1)
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    function test_liquidation_healthyVault_notLiquidatable() public view {
        assertFalse(liquidationEngine.isLiquidatable(address(usdcVault)));
    }

    function test_liquidation_healthFactor_stub() public view {
        assertEq(liquidationEngine.getHealthFactor(address(usdcVault)), type(uint256).max);
    }

    function test_liquidation_maxLiquidatable_stub() public view {
        assertEq(liquidationEngine.getMaxLiquidatable(address(usdcVault), TSLA), 0);
    }

    function test_liquidation_tier1_healthyVault_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("VaultHealthy(address,uint256)", address(usdcVault), type(uint256).max));
        liquidationEngine.liquidate(address(usdcVault), TSLA, 10e18, _emptyPriceData());
    }

    function test_liquidation_tier1_zeroAmount_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        liquidationEngine.liquidate(address(usdcVault), TSLA, 0, _emptyPriceData());
    }

    function test_liquidation_tier3_healthyVault_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("VaultHealthy(address,uint256)", address(usdcVault), type(uint256).max));
        liquidationEngine.dexLiquidate(address(usdcVault), TSLA, 100e6, _emptyPriceData(), "");
    }

    function test_liquidation_tier3_zeroAmount_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        liquidationEngine.dexLiquidate(address(usdcVault), TSLA, 0, _emptyPriceData(), "");
    }

    function test_liquidation_expiredRedemption_stub() public {
        vm.prank(Actors.LIQUIDATOR);
        uint256 payout = liquidationEngine.liquidateExpiredRedemption(1, "", "");
        assertEq(payout, 0);
    }

    function test_liquidation_vaultHealthFactor_noExposure() public view {
        assertEq(usdcVault.healthFactor(), type(uint256).max);
        assertEq(usdcVault.utilization(), 0);
    }

    function test_liquidation_contractWiring() public view {
        assertEq(address(liquidationEngine.registry()), address(protocolRegistry));
        assertEq(liquidationEngine.dex(), address(dex));
    }
}
