// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {AssetConfig, OracleConfig} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @title AssetRegistry Unit Tests
/// @notice Tests asset whitelisting, configuration, deactivation, token migration,
///         and access control.
contract AssetRegistryTest is BaseTest {
    AssetRegistry public registry;

    address public eTSLA = makeAddr("eTSLA");
    address public eGOLD = makeAddr("eGOLD");

    function setUp() public override {
        super.setUp();

        vm.prank(Actors.ADMIN);
        registry = new AssetRegistry(Actors.ADMIN);
        vm.label(address(registry), "AssetRegistry");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _defaultConfig(
        address token
    ) internal pure returns (AssetConfig memory) {
        return AssetConfig({activeToken: token, legacyTokens: new address[](0), active: true, volatilityLevel: 2});
    }

    // ──────────────────────────────────────────────────────────
    //  addAsset
    // ──────────────────────────────────────────────────────────

    function test_addAsset_admin_succeeds() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.expectEmit(true, true, false, false);
        emit IAssetRegistry.AssetAdded(TSLA, eTSLA);

        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        assertTrue(registry.isActiveAsset(TSLA));
        assertEq(registry.getActiveToken(TSLA), eTSLA);
    }

    function test_addAsset_nonAdmin_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.addAsset(TSLA, eTSLA, config);
    }

    function test_addAsset_duplicate_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetAlreadyExists.selector, TSLA));
        registry.addAsset(TSLA, eTSLA, config);
        vm.stopPrank();
    }

    function test_addAsset_zeroAddress_reverts() public {
        AssetConfig memory config = _defaultConfig(address(0));

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.addAsset(TSLA, address(0), config);
    }

    // ──────────────────────────────────────────────────────────
    //  updateAssetConfig
    // ──────────────────────────────────────────────────────────

    function test_updateAssetConfig_admin_succeeds() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        // Update volatility level
        config.volatilityLevel = 3;
        registry.updateAssetConfig(TSLA, config);
        vm.stopPrank();

        AssetConfig memory updated = registry.getAssetConfig(TSLA);
        assertEq(updated.volatilityLevel, 3);
    }

    function test_updateAssetConfig_nonAdmin_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.updateAssetConfig(TSLA, config);
    }

    function test_updateAssetConfig_nonExistent_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.updateAssetConfig(TSLA, config);
    }

    // ──────────────────────────────────────────────────────────
    //  deactivateAsset
    // ──────────────────────────────────────────────────────────

    function test_deactivateAsset_admin_succeeds() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.expectEmit(true, false, false, false);
        emit IAssetRegistry.AssetDeactivated(TSLA);

        registry.deactivateAsset(TSLA);
        vm.stopPrank();

        assertFalse(registry.isActiveAsset(TSLA));
    }

    function test_deactivateAsset_nonAdmin_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.deactivateAsset(TSLA);
    }

    function test_deactivateAsset_nonExistent_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.deactivateAsset(TSLA);
    }

    function test_deactivateAsset_alreadyInactive_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.deactivateAsset(TSLA);

        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotActive.selector, TSLA));
        registry.deactivateAsset(TSLA);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  migrateToken (stock split)
    // ──────────────────────────────────────────────────────────

    function test_migrateToken_admin_succeeds() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address newTSLA = makeAddr("eTSLAv2");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.expectEmit(true, true, true, false);
        emit IAssetRegistry.TokenMigrated(TSLA, eTSLA, newTSLA);

        registry.migrateToken(TSLA, newTSLA);
        vm.stopPrank();

        assertEq(registry.getActiveToken(TSLA), newTSLA);

        address[] memory legacy = registry.getLegacyTokens(TSLA);
        assertEq(legacy.length, 1);
        assertEq(legacy[0], eTSLA);
    }

    function test_migrateToken_multipleMigrations() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address v2 = makeAddr("eTSLAv2");
        address v3 = makeAddr("eTSLAv3");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, v2);
        registry.migrateToken(TSLA, v3);
        vm.stopPrank();

        assertEq(registry.getActiveToken(TSLA), v3);

        address[] memory legacy = registry.getLegacyTokens(TSLA);
        assertEq(legacy.length, 2);
        assertEq(legacy[0], eTSLA);
        assertEq(legacy[1], v2);
    }

    function test_migrateToken_zeroAddress_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.migrateToken(TSLA, address(0));
        vm.stopPrank();
    }

    function test_migrateToken_nonAdmin_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.migrateToken(TSLA, makeAddr("eTSLAv2"));
    }

    // ──────────────────────────────────────────────────────────
    //  View: isValidToken
    // ──────────────────────────────────────────────────────────

    function test_isValidToken_activeToken_true() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        assertTrue(registry.isValidToken(TSLA, eTSLA));
    }

    function test_isValidToken_legacyToken_true() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address v2 = makeAddr("eTSLAv2");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, v2);
        vm.stopPrank();

        assertTrue(registry.isValidToken(TSLA, eTSLA)); // legacy
        assertTrue(registry.isValidToken(TSLA, v2)); // active
    }

    function test_isValidToken_unknownToken_false() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        assertFalse(registry.isValidToken(TSLA, makeAddr("random")));
    }

    function test_isValidToken_unregisteredAsset_false() public view {
        assertFalse(registry.isValidToken(TSLA, eTSLA));
    }

    // ──────────────────────────────────────────────────────────
    //  View: getAssetConfig
    // ──────────────────────────────────────────────────────────

    function test_getAssetConfig_returnsFullConfig() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        AssetConfig memory stored = registry.getAssetConfig(TSLA);
        assertEq(stored.activeToken, eTSLA);
        assertTrue(stored.active);
        assertEq(stored.volatilityLevel, 2);
        assertEq(stored.legacyTokens.length, 0);
    }

    function test_getAssetConfig_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.getAssetConfig(TSLA);
    }

    // ──────────────────────────────────────────────────────────
    //  switchPrimaryOracle
    // ──────────────────────────────────────────────────────────

    function test_switchPrimaryOracle_succeeds() public {
        address oracleA = makeAddr("oracleA");
        address oracleB = makeAddr("oracleB");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));
        registry.setOracleConfig(TSLA, OracleConfig(oracleA, oracleB));
        registry.switchPrimaryOracle(TSLA);
        vm.stopPrank();

        assertEq(registry.getPrimaryOracle(TSLA), oracleB);
    }

    function test_switchPrimaryOracle_noSecondary_reverts() public {
        address oracleA = makeAddr("oracleA");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));
        registry.setOracleConfig(TSLA, OracleConfig(oracleA, address(0)));

        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.switchPrimaryOracle(TSLA);
        vm.stopPrank();
    }
}
