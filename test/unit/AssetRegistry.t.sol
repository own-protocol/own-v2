// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {AssetConfig, PsmConfig} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @title AssetRegistry Unit Tests
/// @notice Tests asset whitelisting, configuration, deactivation, token migration,
///         and access control.
contract AssetRegistryTest is BaseTest {
    AssetRegistry public registry;
    RecordingVaultManagerForRegistry public stubVM;

    address public eTSLA = makeAddr("eTSLA");
    address public eGOLD = makeAddr("eGOLD");

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        registry = new AssetRegistry(address(protocolRegistry));
        // migrateToken now drives VaultManager.applySplit atomically (L-07); a recording stub lets the
        // unit tests exercise that call without standing up a full VaultManager.
        stubVM = new RecordingVaultManagerForRegistry();
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(stubVM));
        vm.stopPrank();
        vm.label(address(registry), "AssetRegistry");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _defaultConfig(
        address token
    ) internal pure returns (AssetConfig memory) {
        return AssetConfig({
            activeToken: token,
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
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
    //  setAssetActive
    // ──────────────────────────────────────────────────────────

    function test_setAssetActive_deactivate_succeeds() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.expectEmit(true, false, false, true);
        emit IAssetRegistry.AssetActiveUpdated(TSLA, false);

        registry.setAssetActive(TSLA, false);
        vm.stopPrank();

        assertFalse(registry.isActiveAsset(TSLA));
    }

    function test_setAssetActive_reactivate_roundTrips() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        assertTrue(registry.isActiveAsset(TSLA));

        registry.setAssetActive(TSLA, false);
        assertFalse(registry.isActiveAsset(TSLA), "deactivated");

        vm.expectEmit(true, false, false, true);
        emit IAssetRegistry.AssetActiveUpdated(TSLA, true);
        registry.setAssetActive(TSLA, true);
        vm.stopPrank();

        assertTrue(registry.isActiveAsset(TSLA), "reactivated");
    }

    function test_setAssetActive_idempotent_allowed() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.setAssetActive(TSLA, false);
        registry.setAssetActive(TSLA, false); // no-op set is allowed (no revert)
        vm.stopPrank();

        assertFalse(registry.isActiveAsset(TSLA));
    }

    function test_setAssetActive_nonAdmin_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.setAssetActive(TSLA, false);
    }

    function test_setAssetActive_nonExistent_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.setAssetActive(TSLA, false);
    }

    // ──────────────────────────────────────────────────────────
    //  migrateToken (stock split)
    // ──────────────────────────────────────────────────────────

    function test_migrateToken_admin_succeeds() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address newTSLA = makeAddr("eTSLAv2");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.TokenMigrated(TSLA, eTSLA, newTSLA, 3e18);

        registry.migrateToken(TSLA, newTSLA, 3e18);
        vm.stopPrank();

        assertEq(registry.getActiveToken(TSLA), newTSLA);

        address[] memory legacy = registry.getLegacyTokens(TSLA);
        assertEq(legacy.length, 1);
        assertEq(legacy[0], eTSLA);
    }

    /// @dev L-07: migrateToken must drive VaultManager.applySplit in the SAME tx — closing the window
    ///      where the new legacy ratio is live (convertLegacy mintable) but exposure is un-rescaled.
    function test_migrateToken_appliesSplitAtomically() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, makeAddr("eTSLAv2"), 3e18);
        vm.stopPrank();

        assertEq(stubVM.calls(), 1, "applySplit invoked once, atomically");
        assertEq(stubVM.lastAsset(), TSLA, "same ticker");
        assertEq(stubVM.lastRatio(), 3e18, "same ratio");
    }

    /// @dev #4 (A2-M-02): migrating a halted asset would desync its frozen halt price; block it.
    function test_migrateToken_haltedAsset_reverts() public {
        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));
        stubVM.setAssetHalted(true);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetHalted.selector, TSLA));
        registry.migrateToken(TSLA, makeAddr("eTSLAv2"), 3e18);
        vm.stopPrank();
    }

    /// @dev Migrating to the current active token or to an existing legacy token would
    ///      corrupt the ratio bookkeeping (self-legacy / duplicate legacy entry).
    function test_migrateToken_toActiveOrLegacyToken_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address v2 = makeAddr("eTSLAv2");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, v2, 3e18);

        // Active token (v2) as the migration target.
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.InvalidNewToken.selector, v2));
        registry.migrateToken(TSLA, v2, 3e18);

        // Existing legacy token (the original eTSLA) as the migration target.
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.InvalidNewToken.selector, eTSLA));
        registry.migrateToken(TSLA, eTSLA, 3e18);
        vm.stopPrank();
    }

    function test_migrateToken_multipleMigrations() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address v2 = makeAddr("eTSLAv2");
        address v3 = makeAddr("eTSLAv3");

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, v2, 3e18);
        registry.migrateToken(TSLA, v3, 3e18);
        vm.stopPrank();

        assertEq(registry.getActiveToken(TSLA), v3);

        address[] memory legacy = registry.getLegacyTokens(TSLA);
        assertEq(legacy.length, 2);
        assertEq(legacy[0], eTSLA);
        assertEq(legacy[1], v2);
    }

    function test_migrateToken_setsLegacyRatio() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address v2 = makeAddr("eTSLAv2");
        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, v2, 3e18);
        vm.stopPrank();
        assertEq(registry.legacyRatioToActive(eTSLA), 3e18, "old -> active = ratio");
        assertEq(registry.legacyRatioToActive(v2), 0, "active token has no legacy ratio");
    }

    function test_migrateToken_legacyRatioCompoundsAcrossSplits() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address v2 = makeAddr("eTSLAv2");
        address v3 = makeAddr("eTSLAv3");
        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, v2, 3e18); // eTSLA -> v2 (3x)
        registry.migrateToken(TSLA, v3, 2e18); // v2 -> v3 (2x)
        vm.stopPrank();
        // Original token now converts directly to the active token at 3 * 2 = 6x.
        assertEq(registry.legacyRatioToActive(eTSLA), 6e18, "compounded ratio");
        assertEq(registry.legacyRatioToActive(v2), 2e18, "newer legacy ratio");
    }

    function test_migrateToken_zeroRatio_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        vm.expectRevert(IAssetRegistry.InvalidRatio.selector);
        registry.migrateToken(TSLA, makeAddr("eTSLAv2"), 0);
        vm.stopPrank();
    }

    function test_migrateToken_zeroAddress_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);

        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.migrateToken(TSLA, address(0), 3e18);
        vm.stopPrank();
    }

    function test_migrateToken_nonAdmin_reverts() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.migrateToken(TSLA, makeAddr("eTSLAv2"), 3e18);
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
        registry.migrateToken(TSLA, v2, 3e18);
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
    //  getOracleType
    // ──────────────────────────────────────────────────────────

    function test_getOracleType_returnsConfiguredType() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        // _defaultConfig sets oracleType = 1 (in-house)

        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);

        assertEq(registry.getOracleType(TSLA), 1);
    }

    function test_getOracleType_pythType() public {
        AssetConfig memory config = AssetConfig({
            activeToken: eGOLD,
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 0
        });

        vm.prank(Actors.ADMIN);
        registry.addAsset(GOLD, eGOLD, config);

        assertEq(registry.getOracleType(GOLD), 0);
    }

    function test_getOracleType_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.getOracleType(TSLA);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor + remaining revert / view branches
    // ──────────────────────────────────────────────────────────

    function test_constructor_zeroRegistry_reverts() public {
        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        new AssetRegistry(address(0));
    }

    function test_migrateToken_nonExistent_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.migrateToken(TSLA, makeAddr("eTSLAv2"), 3e18);
    }

    function test_getActiveToken_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.getActiveToken(TSLA);
    }

    function test_getLegacyTokens_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, TSLA));
        registry.getLegacyTokens(TSLA);
    }

    /// @dev Query a token that is neither active nor the (single) legacy entry — forces the
    ///      isValidToken loop to advance past index 0 (covers the loop-increment path).
    function test_isValidToken_legacyMiss_iteratesLoop() public {
        AssetConfig memory config = _defaultConfig(eTSLA);
        address v2 = makeAddr("eTSLAv2");
        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, config);
        registry.migrateToken(TSLA, v2, 3e18); // eTSLA becomes legacy[0], v2 active
        vm.stopPrank();

        // Neither active (v2) nor legacy (eTSLA): loop checks legacy[0], misses, increments, exits.
        assertFalse(registry.isValidToken(TSLA, makeAddr("unrelated")));
    }

    // ──────────────────────────────────────────────────────────
    //  PSM configuration
    // ──────────────────────────────────────────────────────────

    function _psmSetup() internal returns (address wrapper, address reserveVault) {
        StubReserveVaultForRegistry stub = new StubReserveVaultForRegistry(makeAddr("ondoTSLA"));
        wrapper = stub.asset();
        reserveVault = address(stub);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));
        stubVM.setVaultBackedAsset(reserveVault, TSLA);
    }

    function test_setPsmConfig_succeeds() public {
        (address wrapper, address reserveVault) = _psmSetup();

        vm.expectEmit(true, true, true, false);
        emit IAssetRegistry.PsmConfigUpdated(TSLA, wrapper, reserveVault);
        vm.prank(Actors.ADMIN);
        registry.setPsmConfig(TSLA, wrapper, reserveVault);

        PsmConfig memory cfg = registry.getPsmConfig(TSLA, wrapper);
        assertEq(cfg.reserveVault, reserveVault);
        assertEq(cfg.lastUsedRatio, 0, "guard unarmed");
        assertFalse(cfg.paused);
        address[] memory wrappers = registry.getPsmWrappers(TSLA);
        assertEq(wrappers.length, 1);
        assertEq(wrappers[0], wrapper);
    }

    function test_setPsmConfig_reconfigure_noDuplicateWrapper_resetsGuard() public {
        (address wrapper, address reserveVault) = _psmSetup();
        vm.prank(Actors.ADMIN);
        registry.setPsmConfig(TSLA, wrapper, reserveVault);

        // Arm the guard, then reconfigure with a replacement vault for the same wrapper.
        address marketAddr = makeAddr("market");
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), marketAddr);
        vm.stopPrank();
        vm.prank(marketAddr);
        registry.notePsmRatio(TSLA, wrapper, 1e18);

        StubReserveVaultForRegistry stub2 = new StubReserveVaultForRegistry(wrapper);
        stubVM.setVaultBackedAsset(address(stub2), TSLA);
        vm.prank(Actors.ADMIN);
        registry.setPsmConfig(TSLA, wrapper, address(stub2));

        PsmConfig memory cfg = registry.getPsmConfig(TSLA, wrapper);
        assertEq(cfg.reserveVault, address(stub2));
        assertEq(cfg.lastUsedRatio, 0, "reconfiguration disarms the guard");
        assertEq(registry.getPsmWrappers(TSLA).length, 1, "no duplicate list entry");
    }

    function test_setPsmConfig_validation_reverts() public {
        (address wrapper, address reserveVault) = _psmSetup();

        vm.startPrank(Actors.ADMIN);
        // Unknown asset.
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, GOLD));
        registry.setPsmConfig(GOLD, wrapper, reserveVault);
        // Zero addresses.
        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.setPsmConfig(TSLA, address(0), reserveVault);
        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.setPsmConfig(TSLA, wrapper, address(0));
        // Vault not registered as RWA backing this ticker.
        StubReserveVaultForRegistry unregistered = new StubReserveVaultForRegistry(wrapper);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetRegistry.ReserveVaultMismatch.selector, address(unregistered), TSLA)
        );
        registry.setPsmConfig(TSLA, wrapper, address(unregistered));
        // Vault holds a different token than the wrapper being configured.
        address otherToken = makeAddr("otherToken");
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.WrapperMismatch.selector, otherToken, wrapper));
        registry.setPsmConfig(TSLA, otherToken, reserveVault);
        vm.stopPrank();

        // Non-admin.
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAssetRegistry.OnlyAdmin.selector);
        registry.setPsmConfig(TSLA, wrapper, reserveVault);
    }

    function test_setPsmPaused_andReverts() public {
        (address wrapper, address reserveVault) = _psmSetup();

        // Not configured yet.
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.PsmNotConfigured.selector, TSLA, wrapper));
        registry.setPsmPaused(TSLA, wrapper, true);

        vm.startPrank(Actors.ADMIN);
        registry.setPsmConfig(TSLA, wrapper, reserveVault);
        vm.expectEmit(true, true, false, true);
        emit IAssetRegistry.PsmPausedUpdated(TSLA, wrapper, true);
        registry.setPsmPaused(TSLA, wrapper, true);
        vm.stopPrank();
        assertTrue(registry.getPsmConfig(TSLA, wrapper).paused);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAssetRegistry.OnlyOperator.selector);
        registry.setPsmPaused(TSLA, wrapper, false);
    }

    function test_setRatioJumpBoundBps_boundsAndAuth() public {
        vm.startPrank(Actors.ADMIN);
        vm.expectEmit(false, false, false, true);
        emit IAssetRegistry.RatioJumpBoundUpdated(0, 200);
        registry.setRatioJumpBoundBps(200);
        assertEq(registry.ratioJumpBoundBps(), 200);

        vm.expectRevert(IAssetRegistry.InvalidRatioJumpBound.selector);
        registry.setRatioJumpBoundBps(10_001);
        // Fail-closed: zero is the reserved pre-deploy default and can never be set again.
        vm.expectRevert(IAssetRegistry.InvalidRatioJumpBound.selector);
        registry.setRatioJumpBoundBps(0);
        vm.stopPrank();

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAssetRegistry.OnlyAdmin.selector);
        registry.setRatioJumpBoundBps(100);
    }

    function test_resetRatioGuard_andNotePsmRatio_auth() public {
        (address wrapper, address reserveVault) = _psmSetup();
        vm.prank(Actors.ADMIN);
        registry.setPsmConfig(TSLA, wrapper, reserveVault);

        // notePsmRatio is market-only.
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAssetRegistry.OnlyMarket.selector);
        registry.notePsmRatio(TSLA, wrapper, 1e18);

        address marketAddr = makeAddr("market");
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), marketAddr);
        vm.stopPrank();
        vm.prank(marketAddr);
        vm.expectEmit(true, true, false, true);
        emit IAssetRegistry.PsmRatioNoted(TSLA, wrapper, 1.05e18);
        registry.notePsmRatio(TSLA, wrapper, 1.05e18);
        assertEq(registry.getPsmConfig(TSLA, wrapper).lastUsedRatio, 1.05e18);

        // Operator reset disarms.
        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, true, false, false);
        emit IAssetRegistry.RatioGuardReset(TSLA, wrapper);
        registry.resetRatioGuard(TSLA, wrapper);
        assertEq(registry.getPsmConfig(TSLA, wrapper).lastUsedRatio, 0);

        // Reset on an unconfigured wrapper reverts; non-operator reverts.
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.PsmNotConfigured.selector, TSLA, makeAddr("unknown")));
        registry.resetRatioGuard(TSLA, makeAddr("unknown"));
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAssetRegistry.OnlyOperator.selector);
        registry.resetRatioGuard(TSLA, wrapper);
    }

    function test_getPsmConfig_notConfigured_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.PsmNotConfigured.selector, TSLA, makeAddr("wrapper")));
        registry.getPsmConfig(TSLA, makeAddr("wrapper"));
    }

    // ──────────────────────────────────────────────────────────
    //  Lending allowlist
    // ──────────────────────────────────────────────────────────

    function test_setLendingVaultAllowed_togglesAndEmits() public {
        address lendingVault = makeAddr("lendingVault");
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));

        assertFalse(registry.isLendingVaultAllowed(TSLA, lendingVault), "default-deny");

        vm.expectEmit(true, true, false, true);
        emit IAssetRegistry.LendingVaultAllowedUpdated(TSLA, lendingVault, true);
        vm.prank(Actors.ADMIN);
        registry.setLendingVaultAllowed(TSLA, lendingVault, true);
        assertTrue(registry.isLendingVaultAllowed(TSLA, lendingVault));

        // Keyed per (asset, vault): no bleed across tickers or vaults.
        assertFalse(registry.isLendingVaultAllowed(GOLD, lendingVault));
        assertFalse(registry.isLendingVaultAllowed(TSLA, makeAddr("otherVault")));

        vm.prank(Actors.ADMIN);
        registry.setLendingVaultAllowed(TSLA, lendingVault, false);
        assertFalse(registry.isLendingVaultAllowed(TSLA, lendingVault));
    }

    function test_setLendingVaultAllowed_validation_reverts() public {
        address lendingVault = makeAddr("lendingVault");
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));

        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, GOLD));
        registry.setLendingVaultAllowed(GOLD, lendingVault, true);
        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.setLendingVaultAllowed(TSLA, address(0), true);
        vm.stopPrank();

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAssetRegistry.OnlyAdmin.selector);
        registry.setLendingVaultAllowed(TSLA, lendingVault, true);
    }

    // ──────────────────────────────────────────────────────────
    //  Maker allowlist
    // ──────────────────────────────────────────────────────────

    function test_setMakerAllowed_togglesAndEmits() public {
        address signer = makeAddr("makerSigner");
        stubVM.setSigner(signer, true);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));

        assertFalse(registry.isMakerAllowed(TSLA, signer), "default-deny");

        vm.expectEmit(true, true, false, true);
        emit IAssetRegistry.MakerAllowedUpdated(TSLA, signer, true);
        vm.prank(Actors.ADMIN);
        registry.setMakerAllowed(TSLA, signer, true);
        assertTrue(registry.isMakerAllowed(TSLA, signer));

        // Keyed per (asset, signer): no bleed across tickers or signers.
        assertFalse(registry.isMakerAllowed(GOLD, signer));
        assertFalse(registry.isMakerAllowed(TSLA, makeAddr("otherSigner")));

        vm.prank(Actors.ADMIN);
        registry.setMakerAllowed(TSLA, signer, false);
        assertFalse(registry.isMakerAllowed(TSLA, signer));
    }

    function test_setMakerAllowed_validation_reverts() public {
        address signer = makeAddr("makerSigner");
        stubVM.setSigner(signer, true);
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));

        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotFound.selector, GOLD));
        registry.setMakerAllowed(GOLD, signer, true);
        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.setMakerAllowed(TSLA, address(0), true);
        // Grants require a registered signer on the VaultManager.
        address unregistered = makeAddr("unregisteredSigner");
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.SignerNotRegistered.selector, unregistered));
        registry.setMakerAllowed(TSLA, unregistered, true);
        vm.stopPrank();

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAssetRegistry.OnlyAdmin.selector);
        registry.setMakerAllowed(TSLA, signer, true);
    }

    function test_setMakerAllowed_revokeAfterSignerRemoved_works() public {
        address signer = makeAddr("makerSigner");
        stubVM.setSigner(signer, true);
        vm.startPrank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));
        registry.setMakerAllowed(TSLA, signer, true);
        vm.stopPrank();

        // Signer removed from the VaultManager: re-granting reverts, revoking still works.
        stubVM.setSigner(signer, false);
        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.SignerNotRegistered.selector, signer));
        registry.setMakerAllowed(TSLA, signer, true);
        registry.setMakerAllowed(TSLA, signer, false);
        vm.stopPrank();
        assertFalse(registry.isMakerAllowed(TSLA, signer));
    }

    function test_setLendingVaultAllowed_rwaVaultBlocked_revokeStillWorks() public {
        address reserveVault = makeAddr("reserveVault");
        vm.prank(Actors.ADMIN);
        registry.addAsset(TSLA, eTSLA, _defaultConfig(eTSLA));

        // Allow while generic, then reclassify as RWA: re-allowing reverts, revoking still works.
        vm.prank(Actors.ADMIN);
        registry.setLendingVaultAllowed(TSLA, reserveVault, true);
        stubVM.setVaultBackedAsset(reserveVault, TSLA);

        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.RwaVaultNotEligible.selector, reserveVault));
        registry.setLendingVaultAllowed(TSLA, reserveVault, true);
        registry.setLendingVaultAllowed(TSLA, reserveVault, false);
        vm.stopPrank();
        assertFalse(registry.isLendingVaultAllowed(TSLA, reserveVault));
    }
}

/// @dev Minimal IReserveVault surface for PSM config validation.
contract StubReserveVaultForRegistry {
    address public asset;

    constructor(
        address asset_
    ) {
        asset = asset_;
    }
}

/// @dev Records the applySplit call migrateToken now makes (L-07 atomic coupling), without
///      standing up a real VaultManager.
contract RecordingVaultManagerForRegistry {
    bytes32 public lastAsset;
    uint256 public lastRatio;
    uint256 public calls;
    bool public assetHalted;

    mapping(address => bytes32) public backedAssets;
    mapping(address => bool) public signers;

    function setVaultBackedAsset(address vault, bytes32 ticker) external {
        backedAssets[vault] = ticker;
    }

    function setSigner(address signer, bool registered) external {
        signers[signer] = registered;
    }

    function isSigner(
        address signer
    ) external view returns (bool) {
        return signers[signer];
    }

    function vaultBackedAsset(
        address vault
    ) external view returns (bytes32) {
        return backedAssets[vault];
    }

    function applySplit(bytes32 asset, uint256 ratio) external {
        lastAsset = asset;
        lastRatio = ratio;
        ++calls;
    }

    function isAssetHalted(
        bytes32
    ) external view returns (bool) {
        return assetHalted;
    }

    function setAssetHalted(
        bool halted
    ) external {
        assetHalted = halted;
    }
}
