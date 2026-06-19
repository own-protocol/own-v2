// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
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
}

/// @dev Records the applySplit call migrateToken now makes (L-07 atomic coupling), without
///      standing up a real VaultManager.
contract RecordingVaultManagerForRegistry {
    bytes32 public lastAsset;
    uint256 public lastRatio;
    uint256 public calls;
    bool public assetHalted;

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
