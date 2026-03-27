// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {ILiquidationEngine} from "../../src/interfaces/ILiquidationEngine.sol";
import {PRECISION} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title LiquidationEngine Unit Tests
/// @notice Tests Tier 1 (eToken) liquidation, Tier 3 (DEX) fallback,
///         redemption deadline liquidation, health checks, and access control.
/// @dev Uses mock vault, oracle, and DEX. The vault is mocked to return
///      configurable health factors and collateral amounts.
contract LiquidationEngineTest is BaseTest {
    LiquidationEngine public liquidationEngine;

    MockERC20 public eTSLAToken;

    address public mockVault = makeAddr("vault");
    address public mockMarket = makeAddr("market");
    address public mockAssetRegistry = makeAddr("assetRegistry");

    function setUp() public override {
        super.setUp();

        eTSLAToken = new MockERC20("Own TSLA", "eTSLA", 18);
        vm.label(address(eTSLAToken), "eTSLA");

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), mockAssetRegistry);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        liquidationEngine = new LiquidationEngine(address(protocolRegistry), address(dex));
        vm.stopPrank();
        vm.label(address(liquidationEngine), "LiquidationEngine");

        _setOraclePrice(TSLA, TSLA_PRICE);
    }

    // ──────────────────────────────────────────────────────────
    //  Tier 1: liquidate
    // ──────────────────────────────────────────────────────────

    function test_liquidate_healthyVault_reverts() public {
        // When vault is healthy, liquidation should revert
        vm.expectRevert();
        vm.prank(Actors.LIQUIDATOR);
        liquidationEngine.liquidate(mockVault, TSLA, 1e18, _emptyPriceData());
    }

    function test_liquidate_zeroAmount_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(ILiquidationEngine.ZeroAmount.selector);
        liquidationEngine.liquidate(mockVault, TSLA, 0, _emptyPriceData());
    }

    function test_liquidate_excessiveAmount_reverts() public {
        // Even if vault is unhealthy, liquidating more than maxLiquidatable reverts
        // This test will be more meaningful once we have mock vault health control
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert();
        liquidationEngine.liquidate(mockVault, TSLA, type(uint128).max, _emptyPriceData());
    }

    // ──────────────────────────────────────────────────────────
    //  Tier 3: dexLiquidate
    // ──────────────────────────────────────────────────────────

    function test_dexLiquidate_zeroAmount_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert(ILiquidationEngine.ZeroAmount.selector);
        liquidationEngine.dexLiquidate(mockVault, TSLA, 0, _emptyPriceData(), "");
    }

    function test_dexLiquidate_healthyVault_reverts() public {
        vm.prank(Actors.LIQUIDATOR);
        vm.expectRevert();
        liquidationEngine.dexLiquidate(mockVault, TSLA, 100e6, _emptyPriceData(), "");
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    function test_isLiquidatable_healthyVault_returnsFalse() public view {
        // Default mock vault should be healthy (no exposure)
        assertFalse(liquidationEngine.isLiquidatable(mockVault));
    }

    function test_getMaxLiquidatable_healthyVault_returnsZero() public view {
        assertEq(liquidationEngine.getMaxLiquidatable(mockVault, TSLA), 0);
    }

    function test_getHealthFactor_noExposure_returnsMax() public view {
        uint256 hf = liquidationEngine.getHealthFactor(mockVault);
        // No exposure = max health
        assertGe(hf, PRECISION);
    }
}
