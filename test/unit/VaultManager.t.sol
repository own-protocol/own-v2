// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Minimal asset registry stub exposing only getOracleType (all assets use the in-house oracle).
contract StubAssetRegistry {
    function getOracleType(
        bytes32
    ) external pure returns (uint8) {
        return 1; // in-house
    }
}

/// @dev Minimal ERC-4626 stub exposing only asset() and a settable totalAssets().
contract StubVault {
    address public asset;
    uint256 public totalAssets;

    constructor(
        address asset_
    ) {
        asset = asset_;
    }

    function setTotalAssets(
        uint256 ta
    ) external {
        totalAssets = ta;
    }
}

contract VaultManagerTest is Test {
    VaultManager internal manager;
    ProtocolRegistry internal registry;
    StubAssetRegistry internal assetRegistry;
    MockOracleVerifier internal oracle;
    MockERC20 internal usdc;
    MockERC20 internal ondo;
    StubVault internal vault;
    StubVault internal rwaVault;
    StubVault internal rwaVault2;

    address internal admin = Actors.ADMIN;
    address internal market = makeAddr("market");
    address internal nonAdmin = makeAddr("nonAdmin");

    bytes32 internal constant TSLA = bytes32("TSLA");
    bytes32 internal constant USDC_TICKER = bytes32("USDC");
    bytes32 internal constant ONDO_TSLA = bytes32("ONDO.TSLA");
    bytes32 internal constant XS_TSLA = bytes32("XS.TSLA");

    uint256 internal constant TSLA_MARK = 100e18; // $100 per eTSLA
    uint256 internal constant USDC_MARK = 1e18; //   $1 per USDC
    uint256 internal constant MAX_UTIL_BPS = 8000; // 80%
    uint256 internal constant ASSET_CAP = 1_000_000e18; // $1M
    uint256 internal constant MARK_MAX_AGE = 365 days; // wide default so non-staleness tests pass

    function setUp() public {
        registry = new ProtocolRegistry(admin, 0, 2 minutes);
        assetRegistry = new StubAssetRegistry();
        oracle = new MockOracleVerifier();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        ondo = new MockERC20("Ondo Tesla", "ondoTSLA", 18);
        vault = new StubVault(address(usdc));
        rwaVault = new StubVault(address(ondo));
        rwaVault2 = new StubVault(address(ondo));

        vm.startPrank(admin);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);
        registry.setAddress(registry.MARKET(), market);
        registry.setAddress(registry.ASSET_REGISTRY(), address(assetRegistry));
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracle));
        registry.setAddress(registry.PYTH_ORACLE(), address(oracle));
        vm.stopPrank();

        manager = new VaultManager(IProtocolRegistry(address(registry)));

        oracle.setPrice(TSLA, TSLA_MARK);
        oracle.setPrice(USDC_TICKER, USDC_MARK);
        // Wrapper token feeds: token price = underlying × sValue (= 1 at launch).
        oracle.setPrice(ONDO_TSLA, TSLA_MARK);
        oracle.setPrice(XS_TSLA, TSLA_MARK);

        vm.startPrank(admin);
        manager.setGlobalMaxUtilizationBps(MAX_UTIL_BPS);
        manager.setMaxMarkAge(MARK_MAX_AGE);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Register the vault, seed collateral, and pull both marks. $1M collateral.
    function _bootstrap() internal {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);

        vault.setTotalAssets(1_000_000e6); // 1M USDC
        manager.pullCollateralPrice(address(vault));
        manager.pullAssetPrice(TSLA);

        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
    }

    /// @dev Register the RWA reserve vault backing TSLA and mark `wrapperUnits` of reserve
    ///      (18-dec wrapper units at $100 each).
    function _bootstrapRwa(
        uint256 wrapperUnits
    ) internal {
        vm.prank(admin);
        manager.registerVault(address(rwaVault), ONDO_TSLA, TSLA);
        rwaVault.setTotalAssets(wrapperUnits);
        manager.pullCollateralPrice(address(rwaVault));
    }

    function _open(
        uint256 units
    ) internal {
        vm.prank(market);
        manager.openExposure(TSLA, units);
    }

    function _close(
        uint256 units
    ) internal {
        vm.prank(market);
        manager.closeExposure(TSLA, units);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_zeroRegistry_reverts() public {
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        new VaultManager(IProtocolRegistry(address(0)));
    }

    // ──────────────────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────────────────

    function test_registerVault_setsStateAndScale() public {
        vm.expectEmit(true, true, false, true);
        emit IVaultManager.VaultRegistered(address(vault), USDC_TICKER, bytes32(0));
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);

        assertTrue(manager.isRegisteredVault(address(vault)));
    }

    function test_registerVault_zeroCollateralAsset_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IVaultManager.InvalidCollateralAsset.selector);
        manager.registerVault(address(vault), bytes32(0));
    }

    function test_registerVault_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(nonAdmin);
        manager.registerVault(address(vault), USDC_TICKER);
    }

    function test_registerVault_zeroVault_reverts() public {
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        vm.prank(admin);
        manager.registerVault(address(0), USDC_TICKER);
    }

    function test_registerVault_alreadyRegistered_reverts() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VaultAlreadyRegistered.selector, address(vault)));
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
    }

    function test_getAllVaults_returnsRegisteredVaults() public {
        assertEq(manager.getAllVaults().length, 0);
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);

        address[] memory all = manager.getAllVaults();
        assertEq(all.length, 1);
        assertEq(all[0], address(vault));
    }

    // ──────────────────────────────────────────────────────────
    //  Price pull — collateral
    // ──────────────────────────────────────────────────────────

    function test_pullCollateralPrice_setsMarkAndGlobal() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(1_000_000e6);

        manager.pullCollateralPrice(address(vault));

        assertEq(manager.collateralMark(address(vault)), 1_000_000e18);
        assertEq(manager.globalCollateralUSD(), 1_000_000e18);
    }

    function test_pullCollateralPrice_secondPullReplacesContribution() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);

        vault.setTotalAssets(1_000_000e6);
        manager.pullCollateralPrice(address(vault));
        vault.setTotalAssets(500_000e6);
        manager.pullCollateralPrice(address(vault));

        assertEq(manager.globalCollateralUSD(), 500_000e18);
    }

    function test_pullCollateralPrice_notRegistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VaultNotRegistered.selector, address(vault)));
        manager.pullCollateralPrice(address(vault));
    }

    // ──────────────────────────────────────────────────────────
    //  Collateral concentration cap
    // ──────────────────────────────────────────────────────────

    /// @dev Register a USDC vault (uncapped) with `usdc6` collateral and pull its mark.
    function _registerAndPull(StubVault v, uint256 usdc6) internal {
        vm.prank(admin);
        manager.registerVault(address(v), USDC_TICKER);
        v.setTotalAssets(usdc6);
        manager.pullCollateralPrice(address(v));
    }

    /// @dev Register a USDC vault with a concentration cap and `usdc6` collateral, then pull.
    function _registerCappedAndPull(StubVault v, uint256 usdc6, uint256 capBps) internal {
        vm.startPrank(admin);
        manager.registerVault(address(v), USDC_TICKER);
        manager.setCollateralCapBps(address(v), capBps);
        vm.stopPrank();
        v.setTotalAssets(usdc6);
        manager.pullCollateralPrice(address(v));
    }

    function test_setCollateralCapBps_emits() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.CollateralCapUpdated(address(vault), 0, 2500);
        vm.prank(admin);
        manager.setCollateralCapBps(address(vault), 2500);
        assertEq(manager.collateralCapBps(address(vault)), 2500);
    }

    function test_setCollateralCapBps_atOrAboveBps_reverts() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vm.expectRevert(IVaultManager.InvalidCollateralCap.selector);
        vm.prank(admin);
        manager.setCollateralCapBps(address(vault), BPS);
    }

    function test_setCollateralCapBps_notRegistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VaultNotRegistered.selector, address(vault)));
        vm.prank(admin);
        manager.setCollateralCapBps(address(vault), 2500);
    }

    function test_setCollateralCapBps_onlyAdmin_reverts() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setCollateralCapBps(address(vault), 2500);
    }

    function test_collateralCap_uncapped_countsFull() public {
        _registerAndPull(vault, 3_000_000e6); // cap 0 → uncapped
        assertEq(manager.collateralMark(address(vault)), 3_000_000e18);
        assertEq(manager.globalCollateralUSD(), 3_000_000e18);
    }

    function test_collateralCap_underCap_countsFull() public {
        _registerAndPull(vault, 3_000_000e6); // base, uncapped
        StubVault vaultB = new StubVault(address(usdc));
        _registerCappedAndPull(vaultB, 500_000e6, 2500); // $0.5M, 25% cap

        // maxCounted = 3M × 2500/7500 = $1M; raw $0.5M < $1M → counts full.
        assertEq(manager.collateralMark(address(vaultB)), 500_000e18);
        assertEq(manager.globalCollateralUSD(), 3_500_000e18);
    }

    function test_collateralCap_overCap_capsContribution() public {
        _registerAndPull(vault, 3_000_000e6); // base $3M, uncapped
        StubVault vaultB = new StubVault(address(usdc));
        _registerCappedAndPull(vaultB, 3_000_000e6, 2500); // $3M raw, 25% cap

        // others = $3M; maxCounted = 3M × 2500/7500 = $1M; raw $3M → counted $1M (25% of $4M).
        assertEq(manager.collateralMark(address(vaultB)), 1_000_000e18, "capped to 25% share");
        assertEq(manager.globalCollateralUSD(), 4_000_000e18, "global = base 3M + capped 1M");
    }

    function test_collateralCap_emitsCapApplied() public {
        _registerAndPull(vault, 3_000_000e6);
        StubVault vaultB = new StubVault(address(usdc));
        vm.startPrank(admin);
        manager.registerVault(address(vaultB), USDC_TICKER);
        manager.setCollateralCapBps(address(vaultB), 2500);
        vm.stopPrank();
        vaultB.setTotalAssets(3_000_000e6);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.CollateralCapApplied(address(vaultB), 3_000_000e18, 1_000_000e18);
        manager.pullCollateralPrice(address(vaultB));
    }

    function test_collateralCap_reappliesAsOthersGrow() public {
        _registerAndPull(vault, 3_000_000e6); // base $3M
        StubVault vaultB = new StubVault(address(usdc));
        _registerCappedAndPull(vaultB, 3_000_000e6, 2500);
        assertEq(manager.collateralMark(address(vaultB)), 1_000_000e18, "initially capped at $1M");

        // Base grows to $9M; re-pull base then the capped vault.
        vault.setTotalAssets(9_000_000e6);
        manager.pullCollateralPrice(address(vault));
        manager.pullCollateralPrice(address(vaultB));

        // others = $9M; maxCounted = 9M × 2500/7500 = $3M; raw $3M → now fully counted.
        assertEq(manager.collateralMark(address(vaultB)), 3_000_000e18, "cap relaxes as base grows");
        assertEq(manager.globalCollateralUSD(), 12_000_000e18);
    }

    function test_collateralCap_onVaultUnhalted_appliesCap() public {
        _registerAndPull(vault, 3_000_000e6); // base $3M, uncapped
        StubVault vaultB = new StubVault(address(usdc));
        _registerCappedAndPull(vaultB, 3_000_000e6, 2500);
        assertEq(manager.collateralMark(address(vaultB)), 1_000_000e18);

        // Halt then unhalt vaultB — re-inclusion must re-apply the cap, not count raw $3M.
        vm.prank(address(vaultB));
        manager.onVaultHalted();
        vm.prank(address(vaultB));
        manager.onVaultUnhalted();

        assertEq(manager.collateralMark(address(vaultB)), 1_000_000e18, "cap re-applied on unhalt");
        assertEq(manager.globalCollateralUSD(), 4_000_000e18);
    }

    function test_collateralCap_clearedOnDeregister() public {
        vm.startPrank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        manager.setCollateralCapBps(address(vault), 2500);
        assertEq(manager.collateralCapBps(address(vault)), 2500);
        manager.deregisterVault(address(vault));
        manager.registerVault(address(vault), USDC_TICKER); // re-register
        vm.stopPrank();
        assertEq(manager.collateralCapBps(address(vault)), 0, "cap cleared on deregister");
    }

    // ──────────────────────────────────────────────────────────
    //  Price pull — asset price
    // ──────────────────────────────────────────────────────────

    function test_pullAssetPricePrice_setsMark() public {
        manager.pullAssetPrice(TSLA);
        assertEq(manager.assetMark(TSLA), TSLA_MARK);
    }

    function test_pullAssetPricePrice_remarksExposure() public {
        _bootstrap();
        _open(1000e18); // $100k exposure
        assertEq(manager.globalNetExposureUSD(), 100_000e18);

        oracle.setPrice(TSLA, 200e18); // price doubles
        manager.pullAssetPrice(TSLA);

        assertEq(manager.assetMark(TSLA), 200e18);
        assertEq(manager.globalNetExposureUSD(), 200_000e18);
    }

    function test_pullAssetPricePrice_unavailable_reverts() public {
        // Asset has no oracle price → oracle's getPrice reverts.
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.PriceNotAvailable.selector, bytes32("GOLD")));
        manager.pullAssetPrice(bytes32("GOLD"));
    }

    // ──────────────────────────────────────────────────────────
    //  Open exposure
    // ──────────────────────────────────────────────────────────

    function test_openExposure_happy() public {
        _bootstrap();

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.ExposureOpened(TSLA, 1000e18, TSLA_MARK);
        _open(1000e18);

        assertEq(manager.globalAssetUnits(TSLA), 1000e18);
        assertEq(manager.globalNetExposureUSD(), 100_000e18);
        assertEq(manager.globalUtilizationBps(), 1000); // 100k / 1M = 10%
    }

    // ──────────────────────────────────────────────────────────
    //  applySplit
    // ──────────────────────────────────────────────────────────

    function test_applySplit_redenominatesUnitsAndMark_usdInvariant() public {
        _bootstrap();
        _open(1000e18);
        uint256 usdBefore = manager.globalNetExposureUSD();

        vm.prank(address(assetRegistry));
        manager.applySplit(TSLA, 3e18); // 3:1 split — now driven by the AssetRegistry

        assertEq(manager.globalAssetUnits(TSLA), 3000e18, "units x3");
        assertEq(manager.assetMark(TSLA), TSLA_MARK / 3, "mark /3");
        assertEq(manager.globalNetExposureUSD(), usdBefore, "USD exposure invariant across split");
    }

    function test_applySplit_onlyAssetRegistry_reverts() public {
        _bootstrap();
        _open(1000e18);
        // applySplit is locked to the AssetRegistry (driven atomically by migrateToken).
        vm.expectRevert(IVaultManager.OnlyAssetRegistry.selector);
        vm.prank(market);
        manager.applySplit(TSLA, 3e18);
    }

    function test_applySplit_zeroRatio_reverts() public {
        _bootstrap();
        vm.expectRevert(IVaultManager.InvalidRatio.selector);
        vm.prank(address(assetRegistry));
        manager.applySplit(TSLA, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  onCollateralReleased (H-03: bad-debt mark sync)
    // ──────────────────────────────────────────────────────────

    function test_onCollateralReleased_reducesMarkProportionally() public {
        _bootstrap(); // mark = $1,000,000; totalAssets = 1,000,000 USDC
        uint256 markBefore = manager.collateralMark(address(vault));
        uint256 globalBefore = manager.globalCollateralUSD();

        // Release 200k USDC (20% of the vault) — proportional 20% of the mark.
        vm.prank(address(vault));
        manager.onCollateralReleased(200_000e6);

        assertEq(manager.collateralMark(address(vault)), markBefore - 200_000e18, "mark -20%");
        assertEq(manager.globalCollateralUSD(), globalBefore - 200_000e18, "global collateral -20%");
    }

    function test_onCollateralReleased_onlyRegisteredVault_reverts() public {
        _bootstrap();
        vm.expectRevert(IVaultManager.OnlyRegisteredVault.selector);
        vm.prank(admin);
        manager.onCollateralReleased(1e6);
    }

    /// @dev H-03: after a bad-debt release, the withdrawal gate blocks an exit it would have allowed
    ///      with a stale (un-synced) collateral mark.
    function test_badDebtRelease_tightensWithdrawalGate() public {
        _bootstrap();
        _open(7000e18); // $700k exposure vs $1M collateral → 70% util (cap 80%)

        // Before the release, a tiny withdrawal is allowed (70% util).
        assertFalse(manager.withdrawalBreachesUtil(address(vault), 1e6), "allowed pre-release");

        // Bad debt: the vault releases 200k USDC. Mark syncs here; the real transfer drops totalAssets.
        vm.prank(address(vault));
        manager.onCollateralReleased(200_000e6);
        vault.setTotalAssets(800_000e6);

        // True util is now 700k / 800k = 87.5% > 80% → the gate blocks (would have been stale-allowed).
        assertTrue(manager.withdrawalBreachesUtil(address(vault), 1e6), "blocked post-release");
    }

    function test_openExposure_onlyMarket_reverts() public {
        _bootstrap();
        vm.expectRevert(IVaultManager.OnlyMarket.selector);
        vm.prank(admin);
        manager.openExposure(TSLA, 1000e18);
    }

    function test_openExposure_zeroUnits_reverts() public {
        _bootstrap();
        vm.expectRevert(IVaultManager.ZeroAmount.selector);
        vm.prank(market);
        manager.openExposure(TSLA, 0);
    }

    function test_openExposure_priceUnavailable_reverts() public {
        // Registered + collateral pulled, but asset price never pulled → mark == 0.
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(1_000_000e6);
        manager.pullCollateralPrice(address(vault));

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.PriceUnavailable.selector, TSLA));
        vm.prank(market);
        manager.openExposure(TSLA, 1000e18);
    }

    function test_openExposure_collateralNotInitialized_reverts() public {
        // Asset price pulled, but no collateral pulled → global collateral == 0.
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);

        vm.expectRevert(IVaultManager.CollateralNotInitialized.selector);
        vm.prank(market);
        manager.openExposure(TSLA, 1000e18);
    }

    function test_openExposure_assetCapZero_blocksMinting() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(1_000_000e6);
        manager.pullCollateralPrice(address(vault));
        manager.pullAssetPrice(TSLA);
        // assetCapUSD left at 0 (default).

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.AssetCapBreached.selector, TSLA, 100_000e18, 0));
        vm.prank(market);
        manager.openExposure(TSLA, 1000e18);
    }

    function test_openExposure_assetCapBreached_reverts() public {
        _bootstrap();
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, 50_000e18); // $50k cap

        // 600 units * $100 = $60k > $50k cap.
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.AssetCapBreached.selector, TSLA, 60_000e18, 50_000e18));
        vm.prank(market);
        manager.openExposure(TSLA, 600e18);
    }

    function test_openExposure_globalUtilizationBreached_reverts() public {
        _bootstrap();
        // collateral $1M, max util 80% → ceiling $800k. 9000 units * $100 = $900k → 9000 bps.
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.GlobalUtilizationBreached.selector, 9000, MAX_UTIL_BPS));
        vm.prank(market);
        manager.openExposure(TSLA, 9000e18);
    }

    function test_openExposure_atUtilizationBoundary_succeeds() public {
        _bootstrap();
        // Exactly 80%: 8000 units * $100 = $800k / $1M = 8000 bps.
        _open(8000e18);
        assertEq(manager.globalUtilizationBps(), MAX_UTIL_BPS);
    }

    // ──────────────────────────────────────────────────────────
    //  Open exposure — mark staleness guard
    // ──────────────────────────────────────────────────────────

    function test_openExposure_staleMark_reverts() public {
        _bootstrap(); // pulls the TSLA mark at the current timestamp
        vm.prank(admin);
        manager.setMaxMarkAge(15 minutes);

        uint256 pulledAt = manager.assetMarkUpdatedAt(TSLA);
        vm.warp(block.timestamp + 15 minutes + 1); // 1s past the freshness bound

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.StaleAssetMark.selector, TSLA, pulledAt, 15 minutes));
        vm.prank(market);
        manager.openExposure(TSLA, 1000e18);
    }

    function test_openExposure_atMarkAgeBoundary_succeeds() public {
        _bootstrap();
        vm.prank(admin);
        manager.setMaxMarkAge(15 minutes);

        vm.warp(block.timestamp + 15 minutes); // exactly at the bound — inclusive
        _open(1000e18);
        assertEq(manager.globalAssetUnits(TSLA), 1000e18);
    }

    function test_openExposure_freshAfterRepull_succeeds() public {
        _bootstrap();
        vm.prank(admin);
        manager.setMaxMarkAge(15 minutes);

        vm.warp(block.timestamp + 1 hours); // mark now stale
        manager.pullAssetPrice(TSLA); // keeper refreshes the mark
        _open(1000e18); // fresh again
        assertEq(manager.globalAssetUnits(TSLA), 1000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Close exposure
    // ──────────────────────────────────────────────────────────

    function test_closeExposure_happy() public {
        _bootstrap();
        _open(1000e18);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.ExposureClosed(TSLA, 400e18, TSLA_MARK);
        _close(400e18);

        assertEq(manager.globalAssetUnits(TSLA), 600e18);
        assertEq(manager.globalNetExposureUSD(), 60_000e18);
    }

    function test_closeExposure_onlyMarket_reverts() public {
        _bootstrap();
        _open(1000e18);
        vm.expectRevert(IVaultManager.OnlyMarket.selector);
        vm.prank(admin);
        manager.closeExposure(TSLA, 100e18);
    }

    function test_closeExposure_zeroUnits_reverts() public {
        _bootstrap();
        _open(1000e18);
        vm.expectRevert(IVaultManager.ZeroAmount.selector);
        vm.prank(market);
        manager.closeExposure(TSLA, 0);
    }

    function test_closeExposure_insufficient_reverts() public {
        _bootstrap();
        _open(100e18);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.InsufficientExposure.selector, TSLA, 100e18, 200e18));
        vm.prank(market);
        manager.closeExposure(TSLA, 200e18);
    }

    function test_openThenClose_roundTrips() public {
        _bootstrap();
        _open(1000e18);
        _close(1000e18);
        assertEq(manager.globalAssetUnits(TSLA), 0);
        assertEq(manager.globalNetExposureUSD(), 0);
    }

    /// @dev closeExposure (risk-reducing) is exempt from the mark-staleness guard: a redeem must
    ///      still go through even when the keeper mark has gone stale.
    function test_closeExposure_staleMark_exempt() public {
        _bootstrap();
        _open(1000e18); // opened while fresh (wide default)
        vm.prank(admin);
        manager.setMaxMarkAge(15 minutes);

        vm.warp(block.timestamp + 1 hours); // mark now stale
        _close(1000e18); // still succeeds — no freshness gate on the redeem path
        assertEq(manager.globalAssetUnits(TSLA), 0);
    }

    /// @dev A zero mark must fail loud (mirrors openExposure) instead of silently zeroing
    ///      the asset's USD exposure. Reachable via an extreme applySplit ratio flooring the mark.
    function test_closeExposure_zeroMark_reverts() public {
        _bootstrap();
        _open(1000e18);

        vm.prank(address(assetRegistry));
        manager.applySplit(TSLA, 1e57); // mark = 100e18 × 1e18 / 1e57 → floors to 0

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.PriceUnavailable.selector, TSLA));
        vm.prank(market);
        manager.closeExposure(TSLA, 1);
    }

    /// @dev Regression: with a sub-$1 mark, dust opens floor their USD contribution to 0, so a
    ///      naive running-sum total would underflow when a differently-grouped close (or a price
    ///      pull) subtracts the bulk term. The stored per-asset USD makes every subtraction exact.
    function test_closeExposure_dustRoundingNoUnderflow() public {
        _bootstrap();
        oracle.setPrice(TSLA, 4e17); // $0.40 → floor(1 wei * 0.4e18 / 1e18) == 0
        manager.pullAssetPrice(TSLA);

        _open(1);
        _open(1);
        _open(1);
        assertEq(manager.globalAssetUnits(TSLA), 3);

        // Closing all three at once subtracts the bulk floor(3 * 0.4) = 1; must not underflow.
        _close(3);
        assertEq(manager.globalAssetUnits(TSLA), 0);
        assertEq(manager.globalNetExposureUSD(), 0);

        // A price pull on the now-empty book is also safe.
        manager.pullAssetPrice(TSLA);
        assertEq(manager.globalNetExposureUSD(), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Deregister
    // ──────────────────────────────────────────────────────────

    function test_deregisterVault_noExposure_succeeds() public {
        _bootstrap();
        vm.prank(admin);
        manager.deregisterVault(address(vault));

        assertFalse(manager.isRegisteredVault(address(vault)));
        assertEq(manager.globalCollateralUSD(), 0);
        assertEq(manager.collateralMark(address(vault)), 0);
    }

    function test_deregisterVault_onlyAdmin_reverts() public {
        _bootstrap();
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(nonAdmin);
        manager.deregisterVault(address(vault));
    }

    function test_deregisterVault_notRegistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VaultNotRegistered.selector, address(vault)));
        vm.prank(admin);
        manager.deregisterVault(address(vault));
    }

    function test_deregisterVault_wouldBreachUtil_reverts() public {
        _bootstrap();
        _open(7000e18); // $700k exposure, $1M collateral → 70%

        // Removing the only collateral source leaves projCollateral == 0 with live exposure.
        vm.expectRevert(IVaultManager.DeregisterWouldBreachUtilization.selector);
        vm.prank(admin);
        manager.deregisterVault(address(vault));
    }

    // ──────────────────────────────────────────────────────────
    //  withdrawalBreachesUtil
    // ──────────────────────────────────────────────────────────

    function test_withdrawalBreachesUtil_smallWithdrawal_false() public {
        _bootstrap();
        _open(1000e18); // 10% util
        // Withdraw 10% of collateral → util becomes ~11.1%, still under 80%.
        assertFalse(manager.withdrawalBreachesUtil(address(vault), 100_000e6));
    }

    function test_withdrawalBreachesUtil_largeWithdrawal_true() public {
        _bootstrap();
        _open(7000e18); // $700k exposure, 70% util
        // Withdraw 90% of collateral → projected $100k collateral → 700% util.
        assertTrue(manager.withdrawalBreachesUtil(address(vault), 900_000e6));
    }

    function test_withdrawalBreachesUtil_zeroTotalAssets_true() public {
        _bootstrap();
        vault.setTotalAssets(0);
        assertTrue(manager.withdrawalBreachesUtil(address(vault), 1));
    }

    function test_withdrawalBreachesUtil_fullWithdrawalNoExposure_false() public {
        _bootstrap();
        // No exposure; withdrawing everything is fine.
        assertFalse(manager.withdrawalBreachesUtil(address(vault), 1_000_000e6));
    }

    // ──────────────────────────────────────────────────────────
    //  onVaultHalted / onVaultUnhalted — collateral exclusion
    // ──────────────────────────────────────────────────────────

    function test_onVaultHalted_excludesCollateral() public {
        _bootstrap(); // $1M collateral pooled.

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.VaultCollateralExcluded(address(vault), 1_000_000e18);
        vm.prank(address(vault));
        manager.onVaultHalted();

        assertTrue(manager.isVaultExcluded(address(vault)));
        assertEq(manager.globalCollateralUSD(), 0, "collateral dropped from pool");
        assertEq(manager.collateralMark(address(vault)), 0);
    }

    function test_onVaultHalted_onlyRegisteredVault_reverts() public {
        _bootstrap();
        vm.expectRevert(IVaultManager.OnlyRegisteredVault.selector);
        vm.prank(admin);
        manager.onVaultHalted();
    }

    function test_onVaultHalted_alreadyExcluded_reverts() public {
        _bootstrap();
        vm.prank(address(vault));
        manager.onVaultHalted();

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VaultAlreadyExcluded.selector, address(vault)));
        vm.prank(address(vault));
        manager.onVaultHalted();
    }

    function test_onVaultUnhalted_reincludesCollateral() public {
        _bootstrap();
        vm.prank(address(vault));
        manager.onVaultHalted();
        assertEq(manager.globalCollateralUSD(), 0);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.VaultCollateralReincluded(address(vault), 1_000_000e18);
        vm.prank(address(vault));
        manager.onVaultUnhalted();

        assertFalse(manager.isVaultExcluded(address(vault)));
        assertEq(manager.globalCollateralUSD(), 1_000_000e18, "collateral re-pooled");
    }

    function test_pullCollateralPrice_whileExcluded_reverts() public {
        _bootstrap();
        vm.prank(address(vault));
        manager.onVaultHalted();

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VaultAlreadyExcluded.selector, address(vault)));
        manager.pullCollateralPrice(address(vault));
    }

    // ──────────────────────────────────────────────────────────
    //  Admin setters — risk params
    // ──────────────────────────────────────────────────────────

    function test_setAssetCapUSD_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
    }

    function test_setAssetCapUSD_emits() public {
        vm.expectEmit(true, false, false, true);
        emit IVaultManager.AssetCapUpdated(TSLA, ASSET_CAP);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
        assertEq(manager.assetCapUSD(TSLA), ASSET_CAP);
    }

    function test_setGlobalMaxUtilizationBps_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setGlobalMaxUtilizationBps(5000);
    }

    function test_setGlobalMaxUtilizationBps_emits() public {
        vm.expectEmit(false, false, false, true);
        emit IVaultManager.GlobalMaxUtilizationUpdated(MAX_UTIL_BPS, 5000);
        vm.prank(admin);
        manager.setGlobalMaxUtilizationBps(5000);
        assertEq(manager.globalMaxUtilizationBps(), 5000);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — settle-price band
    // ──────────────────────────────────────────────────────────

    function test_settleBandBps_defaultsToZero() public view {
        // Fail-safe: unconfigured band blocks settlement until an admin sets it. setUp does not.
        assertEq(manager.settleBandBps(), 0);
    }

    function test_setSettleBandBps_emits() public {
        vm.expectEmit(false, false, false, true);
        emit IVaultManager.SettleBandUpdated(0, 500);
        vm.prank(admin);
        manager.setSettleBandBps(500);
        assertEq(manager.settleBandBps(), 500);
    }

    function test_setSettleBandBps_atMaxBps_succeeds() public {
        vm.prank(admin);
        manager.setSettleBandBps(BPS);
        assertEq(manager.settleBandBps(), BPS);
    }

    function test_setSettleBandBps_zero_reverts() public {
        vm.expectRevert(IVaultManager.InvalidSettleBand.selector);
        vm.prank(admin);
        manager.setSettleBandBps(0);
    }

    function test_setSettleBandBps_aboveMaxBps_reverts() public {
        vm.expectRevert(IVaultManager.InvalidSettleBand.selector);
        vm.prank(admin);
        manager.setSettleBandBps(BPS + 1);
    }

    function test_setSettleBandBps_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setSettleBandBps(500);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — max mark age
    // ──────────────────────────────────────────────────────────

    function test_setMaxMarkAge_emits() public {
        vm.expectEmit(false, false, false, true);
        emit IVaultManager.MaxMarkAgeUpdated(MARK_MAX_AGE, 15 minutes);
        vm.prank(admin);
        manager.setMaxMarkAge(15 minutes);
        assertEq(manager.maxMarkAge(), 15 minutes);
    }

    function test_setMaxMarkAge_zero_reverts() public {
        vm.expectRevert(IVaultManager.InvalidMaxMarkAge.selector);
        vm.prank(admin);
        manager.setMaxMarkAge(0);
    }

    function test_setMaxMarkAge_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setMaxMarkAge(15 minutes);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — signer registry
    // ──────────────────────────────────────────────────────────

    function test_registerSigner_setsLinkedAddress() public {
        address signer = makeAddr("signer");
        address linked = makeAddr("linked");

        vm.expectEmit(true, true, false, false);
        emit IVaultManager.SignerRegistered(signer, linked);
        vm.prank(admin);
        manager.registerSigner(signer, linked);

        assertTrue(manager.isSigner(signer));
        assertEq(manager.signerLinkedAddress(signer), linked);
    }

    function test_registerSigner_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.registerSigner(makeAddr("signer"), makeAddr("linked"));
    }

    function test_registerSigner_zeroAddress_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        manager.registerSigner(address(0), makeAddr("linked"));
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        manager.registerSigner(makeAddr("signer"), address(0));
        vm.stopPrank();
    }

    function test_registerSigner_alreadySigner_reverts() public {
        address signer = makeAddr("signer");
        vm.startPrank(admin);
        manager.registerSigner(signer, makeAddr("linked"));
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.AlreadySigner.selector, signer));
        manager.registerSigner(signer, makeAddr("linked2"));
        vm.stopPrank();
    }

    function test_updateSignerLinkedAddress_succeeds() public {
        address signer = makeAddr("signer");
        address linked2 = makeAddr("linked2");
        vm.startPrank(admin);
        manager.registerSigner(signer, makeAddr("linked"));

        vm.expectEmit(true, true, false, false);
        emit IVaultManager.SignerLinkedAddressUpdated(signer, linked2);
        manager.updateSignerLinkedAddress(signer, linked2);
        vm.stopPrank();

        assertEq(manager.signerLinkedAddress(signer), linked2);
    }

    function test_updateSignerLinkedAddress_notSigner_reverts() public {
        address signer = makeAddr("signer");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.NotSigner.selector, signer));
        manager.updateSignerLinkedAddress(signer, makeAddr("linked"));
    }

    function test_removeSigner_succeeds() public {
        address signer = makeAddr("signer");
        vm.startPrank(admin);
        manager.registerSigner(signer, makeAddr("linked"));

        vm.expectEmit(true, false, false, false);
        emit IVaultManager.SignerRemoved(signer);
        manager.removeSigner(signer);
        vm.stopPrank();

        assertFalse(manager.isSigner(signer));
        assertEq(manager.signerLinkedAddress(signer), address(0));
    }

    function test_removeSigner_notSigner_reverts() public {
        address signer = makeAddr("signer");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.NotSigner.selector, signer));
        manager.removeSigner(signer);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — payment token
    // ──────────────────────────────────────────────────────────

    function test_setPaymentToken_succeeds() public {
        vm.expectEmit(true, true, false, false);
        emit IVaultManager.PaymentTokenUpdated(address(0), address(usdc));
        vm.prank(admin);
        manager.setPaymentToken(address(usdc));
        assertEq(manager.paymentToken(), address(usdc));
    }

    function test_setPaymentToken_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setPaymentToken(address(usdc));
    }

    function test_setPaymentToken_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        manager.setPaymentToken(address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — trading pause
    // ──────────────────────────────────────────────────────────

    function test_setTradingPaused_global() public {
        vm.expectEmit(false, false, false, true);
        emit IVaultManager.TradingPausedUpdated(true);
        vm.prank(admin);
        manager.setTradingPaused(true);
        assertTrue(manager.isTradingPaused(TSLA));

        vm.prank(admin);
        manager.setTradingPaused(false);
        assertFalse(manager.isTradingPaused(TSLA));
    }

    function test_setTradingPaused_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyOperator.selector);
        vm.prank(market);
        manager.setTradingPaused(true);
    }

    function test_setAssetTradingPaused_perAsset() public {
        vm.expectEmit(true, false, false, true);
        emit IVaultManager.AssetTradingPausedUpdated(TSLA, true);
        vm.prank(admin);
        manager.setAssetTradingPaused(TSLA, true);
        assertTrue(manager.isTradingPaused(TSLA));
        // Other assets remain unpaused.
        assertFalse(manager.isTradingPaused(bytes32("GOLD")));
    }

    function test_setAssetTradingPaused_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyOperator.selector);
        vm.prank(market);
        manager.setAssetTradingPaused(TSLA, true);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — asset halt (permanent)
    // ──────────────────────────────────────────────────────────

    function test_haltAsset_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit IVaultManager.AssetHalted(TSLA, TSLA_MARK);
        vm.prank(admin);
        manager.haltAsset(TSLA, TSLA_MARK);

        assertTrue(manager.isAssetHalted(TSLA));
        assertEq(manager.assetHaltPrice(TSLA), TSLA_MARK);
        // Halt re-marks the asset price to the fixed halt price.
        assertEq(manager.assetMark(TSLA), TSLA_MARK);
    }

    function test_haltAsset_remarksExposureAtHaltPrice() public {
        _bootstrap();
        _open(1000e18); // $100k at $100 mark

        // Halt at $200 → exposure re-marks to $200k.
        vm.prank(admin);
        manager.haltAsset(TSLA, 200e18);
        assertEq(manager.globalNetExposureUSD(), 200_000e18);
    }

    function test_haltAsset_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyOperator.selector);
        vm.prank(market);
        manager.haltAsset(TSLA, TSLA_MARK);
    }

    function test_haltAsset_zeroPrice_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IVaultManager.InvalidHaltPrice.selector);
        manager.haltAsset(TSLA, 0);
    }

    function test_haltAsset_alreadyHalted_reverts() public {
        vm.startPrank(admin);
        manager.haltAsset(TSLA, TSLA_MARK);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.AssetAlreadyHalted.selector, TSLA));
        manager.haltAsset(TSLA, TSLA_MARK);
        vm.stopPrank();
    }

    function test_setHaltRedeemAddress_succeeds() public {
        address addr = makeAddr("haltFund");
        vm.expectEmit(true, true, false, false);
        emit IVaultManager.HaltRedeemAddressUpdated(address(0), addr);
        vm.prank(admin);
        manager.setHaltRedeemAddress(addr);
        assertEq(manager.haltRedeemAddress(), addr);
    }

    function test_setHaltRedeemAddress_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setHaltRedeemAddress(makeAddr("haltFund"));
    }

    function test_setHaltRedeemAddress_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        manager.setHaltRedeemAddress(address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Admin — claim threshold
    // ──────────────────────────────────────────────────────────

    function test_setClaimThreshold_succeeds() public {
        vm.expectEmit(false, false, false, true);
        emit IVaultManager.ClaimThresholdUpdated(0, 6 hours);
        vm.prank(admin);
        manager.setClaimThreshold(6 hours);
        assertEq(manager.claimThreshold(), 6 hours);
    }

    function test_setClaimThreshold_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setClaimThreshold(6 hours);
    }

    function test_claimThreshold_defaultsToZero() public view {
        // Pre-deploy default; OwnMarket.forceExecuteOrder treats this as force-disabled.
        assertEq(manager.claimThreshold(), 0);
    }

    function test_setClaimThreshold_zero_reverts() public {
        vm.expectRevert(IVaultManager.InvalidClaimThreshold.selector);
        vm.prank(admin);
        manager.setClaimThreshold(0);
    }

    function test_setClaimThreshold_cannotResetToZeroAfterSet() public {
        vm.prank(admin);
        manager.setClaimThreshold(6 hours);
        // Once configured, it can never be reset to zero (force can't be silently disabled).
        vm.expectRevert(IVaultManager.InvalidClaimThreshold.selector);
        vm.prank(admin);
        manager.setClaimThreshold(0);
        assertEq(manager.claimThreshold(), 6 hours, "threshold unchanged");
    }

    // ──────────────────────────────────────────────────────────
    //  Views — utilisation edge cases
    // ──────────────────────────────────────────────────────────

    function test_globalUtilizationBps_zeroCollateralZeroExposure_isZero() public view {
        assertEq(manager.globalUtilizationBps(), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  pullAssetPrice — halted asset (fixed-mark path)
    // ──────────────────────────────────────────────────────────

    /// @dev A halted asset's mark is pinned at the halt price; a keeper pull is a no-op when the
    ///      stored mark already equals the halt price (the common case).
    function test_pullAssetPrice_haltedAsset_noOpWhenMarkMatches() public {
        _bootstrap();
        _open(1000e18);
        vm.prank(admin);
        manager.haltAsset(TSLA, 200e18); // sets _assetMark == haltPrice == 200e18

        manager.pullAssetPrice(TSLA); // halted branch, hp == old → returns without re-marking
        assertEq(manager.assetMark(TSLA), 200e18);
        assertEq(manager.globalNetExposureUSD(), 200_000e18);
    }

    /// @dev Defensive re-mark: if a halted asset's stored mark ever drifts from the fixed halt price
    ///      (here forced via a direct applySplit), the keeper pull re-pins it to the halt price.
    function test_pullAssetPrice_haltedAsset_remarksOnDrift() public {
        _bootstrap();
        _open(1000e18);
        vm.prank(admin);
        manager.haltAsset(TSLA, 200e18); // _assetMark = 200e18

        // Desync the stored mark from the halt price (applySplit only checks the caller, not halt state).
        vm.prank(address(assetRegistry));
        manager.applySplit(TSLA, 2e18); // _assetMark = 100e18, units x2 → 2000e18; haltPrice still 200e18

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.AssetPricePulled(TSLA, 100e18, 200e18);
        manager.pullAssetPrice(TSLA); // hp(200) != old(100) → re-pin to halt price

        assertEq(manager.assetMark(TSLA), 200e18, "re-pinned to fixed halt price");
        assertEq(manager.globalNetExposureUSD(), 400_000e18, "2000 units * $200");
    }

    // ──────────────────────────────────────────────────────────
    //  Zero resolved price guards (Pyth normalises to 0)
    // ──────────────────────────────────────────────────────────

    function test_pullAssetPrice_zeroResolvedPrice_reverts() public {
        oracle.setForceZeroPrice(true);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.PriceUnavailable.selector, TSLA));
        manager.pullAssetPrice(TSLA);
    }

    function test_pullCollateralPrice_zeroResolvedPrice_reverts() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        oracle.setForceZeroPrice(true);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.PriceUnavailable.selector, USDC_TICKER));
        manager.pullCollateralPrice(address(vault));
    }

    function test_onVaultUnhalted_zeroResolvedPrice_reverts() public {
        _bootstrap();
        vm.prank(address(vault));
        manager.onVaultHalted();

        oracle.setForceZeroPrice(true);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.PriceUnavailable.selector, USDC_TICKER));
        manager.onVaultUnhalted();
    }

    // ──────────────────────────────────────────────────────────
    //  Remaining branch coverage
    // ──────────────────────────────────────────────────────────

    /// @dev Deregistering a non-last vault exercises the O(1) swap-remove (idx != lastIdx).
    function test_deregisterVault_swapRemoveNonLast() public {
        vm.startPrank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        StubVault vaultB = new StubVault(address(usdc));
        manager.registerVault(address(vaultB), USDC_TICKER);
        manager.deregisterVault(address(vault)); // idx 1 of 2 → swap last into the freed slot
        vm.stopPrank();

        address[] memory all = manager.getAllVaults();
        assertEq(all.length, 1);
        assertEq(all[0], address(vaultB), "last vault swapped into freed slot");
        assertFalse(manager.isRegisteredVault(address(vault)));
        assertTrue(manager.isRegisteredVault(address(vaultB)));
    }

    /// @dev Releasing more than the vault holds clamps the removed USD to the stored mark (no underflow).
    function test_onCollateralReleased_clampsToMark() public {
        _bootstrap(); // mark $1M, totalAssets 1M USDC
        vm.prank(address(vault));
        manager.onCollateralReleased(2_000_000e6); // assets > totalAssets → removedUSD would exceed mark

        assertEq(manager.collateralMark(address(vault)), 0, "mark fully cleared, clamped not underflowed");
        assertEq(manager.globalCollateralUSD(), 0);
    }

    function test_updateSignerLinkedAddress_zeroAddress_reverts() public {
        address signer = makeAddr("signer");
        vm.startPrank(admin);
        manager.registerSigner(signer, makeAddr("linked"));
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        manager.updateSignerLinkedAddress(signer, address(0));
        vm.stopPrank();
    }

    function test_setPaymentToken_decimalsAbove18_reverts() public {
        MockERC20 weird = new MockERC20("Weird", "WRD", 19);
        vm.prank(admin);
        vm.expectRevert(IVaultManager.ZeroAddress.selector); // contract rejects >18-decimal tokens via ZeroAddress
        manager.setPaymentToken(address(weird));
    }

    // ──────────────────────────────────────────────────────────
    //  RWA reserve vaults — registration & class
    // ──────────────────────────────────────────────────────────

    function test_registerVault_backedAsset_setsClass() public {
        vm.expectEmit(true, true, true, true);
        emit IVaultManager.VaultRegistered(address(rwaVault), ONDO_TSLA, TSLA);
        vm.prank(admin);
        manager.registerVault(address(rwaVault), ONDO_TSLA, TSLA);

        assertEq(manager.vaultBackedAsset(address(rwaVault)), TSLA);
        assertEq(manager.vaultCollateralAsset(address(rwaVault)), ONDO_TSLA);
        assertTrue(manager.isRegisteredVault(address(rwaVault)));
    }

    function test_registerVault_twoArg_defaultsGeneric() public {
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        assertEq(manager.vaultBackedAsset(address(vault)), bytes32(0));
    }

    function test_setCollateralCapBps_rwaVault_reverts() public {
        vm.prank(admin);
        manager.registerVault(address(rwaVault), ONDO_TSLA, TSLA);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.RwaVaultNotEligible.selector, address(rwaVault)));
        vm.prank(admin);
        manager.setCollateralCapBps(address(rwaVault), 5000);
    }

    // ──────────────────────────────────────────────────────────
    //  RWA reserve vaults — netting math
    // ──────────────────────────────────────────────────────────

    function test_pullCollateralPrice_rwaVault_updatesReserveNotGlobalPool() public {
        _bootstrap(); // $1M generic collateral
        uint256 genericCollateral = manager.globalCollateralUSD();

        _bootstrapRwa(400e18); // 400 wrappers × $100 = $40k reserve

        assertEq(manager.assetRwaCollateralUSD(TSLA), 40_000e18, "reserve marked");
        assertEq(manager.collateralMark(address(rwaVault)), 40_000e18, "vault mark stored");
        assertEq(manager.globalCollateralUSD(), genericCollateral, "generic pool untouched");
    }

    function test_netting_partialCoverage() public {
        _bootstrap();
        _open(1000e18); // E = $100k
        assertEq(manager.globalNetExposureUSD(), 100_000e18);

        _bootstrapRwa(400e18); // R = $40k
        assertEq(manager.assetExposureUSD(TSLA), 100_000e18, "gross unchanged");
        assertEq(manager.globalNetExposureUSD(), 60_000e18, "net = E - R");
    }

    function test_netting_exactCoverage() public {
        _bootstrap();
        _open(1000e18);
        _bootstrapRwa(1000e18); // R = $100k = E
        assertEq(manager.globalNetExposureUSD(), 0, "fully netted");
        assertEq(manager.globalUtilizationBps(), 0);
    }

    function test_netting_excessReserveClamped() public {
        _bootstrap();
        _open(1000e18); // E(TSLA) = $100k
        _bootstrapRwa(5000e18); // R = $500k > E

        // Clamped at zero: excess reserve must not go negative or credit other assets.
        assertEq(manager.globalNetExposureUSD(), 0, "clamped, not negative");

        // A second asset's exposure is NOT offset by TSLA's excess reserve.
        bytes32 gold = bytes32("GOLD");
        oracle.setPrice(gold, 2000e18);
        manager.pullAssetPrice(gold);
        vm.prank(admin);
        manager.setAssetCapUSD(gold, ASSET_CAP);
        vm.prank(market);
        manager.openExposure(gold, 10e18); // $20k GOLD
        assertEq(manager.globalNetExposureUSD(), 20_000e18, "GOLD unhedged; TSLA excess gives no credit");
    }

    function test_openExposure_matchedByReserve_needsNoGenericCollateral() public {
        // No generic vault at all: reserve-covered mint must still clear.
        _bootstrapRwa(1000e18); // R = $100k
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);

        _open(1000e18); // E = $100k, fully netted
        assertEq(manager.globalNetExposureUSD(), 0);
        assertEq(manager.globalCollateralUSD(), 0);

        // The next unit is an unhedged residual — with zero generic collateral it must revert.
        vm.expectRevert(IVaultManager.CollateralNotInitialized.selector);
        vm.prank(market);
        manager.openExposure(TSLA, 1e18);
    }

    function test_openExposure_residualBreachesUtil_reverts() public {
        // Small generic pool: $10k × 80% cap = $8k residual headroom.
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(10_000e6);
        manager.pullCollateralPrice(address(vault));
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);

        _bootstrapRwa(1000e18); // R = $100k

        _open(1080e18); // E = $108k → residual $8k = exactly at the 80% cap
        assertEq(manager.globalNetExposureUSD(), 8000e18);

        vm.expectRevert(abi.encodeWithSelector(IVaultManager.GlobalUtilizationBreached.selector, 9000, MAX_UTIL_BPS));
        vm.prank(market);
        manager.openExposure(TSLA, 10e18); // +$1k residual → $9k on $10k pool = 9000 bps
    }

    function test_closeExposure_renets() public {
        _bootstrap();
        _open(1000e18); // E = $100k
        _bootstrapRwa(400e18); // R = $40k → net $60k

        _close(500e18); // E → $50k
        assertEq(manager.assetExposureUSD(TSLA), 50_000e18);
        assertEq(manager.globalNetExposureUSD(), 10_000e18, "net = 50k - 40k");

        _close(500e18); // E → 0; net clamps at 0 (R now exceeds E)
        assertEq(manager.globalNetExposureUSD(), 0);
    }

    function test_pullAssetPrice_renets_withReserve() public {
        _bootstrap();
        _open(1000e18); // E = $100k @ $100
        _bootstrapRwa(400e18); // R = $40k → net $60k

        oracle.setPrice(TSLA, 2 * TSLA_MARK); // TSLA doubles
        manager.pullAssetPrice(TSLA);
        assertEq(manager.assetExposureUSD(TSLA), 200_000e18);
        assertEq(manager.globalNetExposureUSD(), 160_000e18, "net = 200k - 40k");

        // Wrapper feed catches up (delta-1 collateral): reserve doubles too, net back to 2×60k.
        oracle.setPrice(ONDO_TSLA, 2 * TSLA_MARK);
        manager.pullCollateralPrice(address(rwaVault));
        assertEq(manager.assetRwaCollateralUSD(TSLA), 80_000e18);
        assertEq(manager.globalNetExposureUSD(), 120_000e18, "net = 200k - 80k");
    }

    function test_netting_multiWrapper_sums() public {
        _bootstrap();
        _open(1000e18); // E = $100k

        _bootstrapRwa(400e18); // ondo reserve $40k
        vm.prank(admin);
        manager.registerVault(address(rwaVault2), XS_TSLA, TSLA);
        rwaVault2.setTotalAssets(300e18); // xstock reserve $30k
        manager.pullCollateralPrice(address(rwaVault2));

        assertEq(manager.assetRwaCollateralUSD(TSLA), 70_000e18, "wrappers sum");
        assertEq(manager.globalNetExposureUSD(), 30_000e18, "net = 100k - 70k");
    }

    // ──────────────────────────────────────────────────────────
    //  RWA reserve vaults — release / halt / deregister branches
    // ──────────────────────────────────────────────────────────

    function test_onCollateralReleased_rwaVault_reducesReserve() public {
        _bootstrap();
        _open(1000e18); // E = $100k
        _bootstrapRwa(1000e18); // R = $100k → net 0

        // Release half the reserve (mark reduced proportionally; called before assets leave).
        vm.prank(address(rwaVault));
        manager.onCollateralReleased(500e18);

        assertEq(manager.assetRwaCollateralUSD(TSLA), 50_000e18, "reserve halved");
        assertEq(manager.globalNetExposureUSD(), 50_000e18, "net exposure rises");
        uint256 generic = manager.globalCollateralUSD();
        assertEq(generic, 1_000_000e18, "generic pool untouched");
    }

    function test_onVaultHalted_rwaVault_removesReserve_andUnhaltRestores() public {
        _bootstrap();
        _open(1000e18); // E = $100k
        _bootstrapRwa(400e18); // net $60k

        vm.prank(address(rwaVault));
        manager.onVaultHalted();
        assertEq(manager.assetRwaCollateralUSD(TSLA), 0, "reserve excluded");
        assertEq(manager.globalNetExposureUSD(), 100_000e18, "net back to gross");
        assertEq(manager.collateralMark(address(rwaVault)), 0);
        assertTrue(manager.isVaultExcluded(address(rwaVault)));

        vm.prank(address(rwaVault));
        manager.onVaultUnhalted();
        assertEq(manager.assetRwaCollateralUSD(TSLA), 40_000e18, "reserve re-included");
        assertEq(manager.globalNetExposureUSD(), 60_000e18, "net restored");
    }

    function test_deregisterVault_rwaVault_zeroGenericCollateral_reverts() public {
        // E = R = $100k with NO generic pool: removing the reserve leaves a residual no
        // collateral can absorb — fail closed.
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
        _bootstrapRwa(1000e18);
        _open(1000e18);

        vm.expectRevert(IVaultManager.DeregisterWouldBreachUtilization.selector);
        vm.prank(admin);
        manager.deregisterVault(address(rwaVault));
    }

    function test_deregisterVault_rwaVault_residualUnderCap_succeeds() public {
        // Generic pool $1M; E = $100k fully netted by R. Removing the reserve leaves a $100k
        // residual at 10% utilization — under the cap, so the reserve may exit.
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(1_000_000e6);
        manager.pullCollateralPrice(address(vault));
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
        _bootstrapRwa(1000e18);
        _open(1000e18);
        assertEq(manager.globalNetExposureUSD(), 0, "fully netted before exit");

        vm.prank(admin);
        manager.deregisterVault(address(rwaVault));

        assertEq(manager.assetRwaCollateralUSD(TSLA), 0, "reserve removed");
        assertEq(manager.globalNetExposureUSD(), 100_000e18, "residual re-loads the generic pool");
    }

    function test_deregisterVault_rwaVault_breachesUtil_reverts() public {
        // Generic pool $10k; E = $100k fully netted by R = $100k.
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(10_000e6);
        manager.pullCollateralPrice(address(vault));
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
        _bootstrapRwa(1000e18);
        _open(1000e18);

        // Removing the reserve would leave a $100k residual on a $10k pool.
        vm.expectRevert(IVaultManager.DeregisterWouldBreachUtilization.selector);
        vm.prank(admin);
        manager.deregisterVault(address(rwaVault));

        // Wind the exposure down; now the reserve can leave.
        _close(1000e18);
        vm.prank(admin);
        manager.deregisterVault(address(rwaVault));
        assertEq(manager.assetRwaCollateralUSD(TSLA), 0);
        assertEq(manager.vaultBackedAsset(address(rwaVault)), bytes32(0), "class cleared");
    }

    function test_withdrawalBreachesUtil_rwaVault_checksResidual() public {
        // Same construction: $10k generic, E = R = $100k.
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(10_000e6);
        manager.pullCollateralPrice(address(vault));
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
        _bootstrapRwa(1000e18);
        _open(1000e18);

        // Releasing 80 wrappers ($8k) leaves an $8k residual = exactly the 80% cap → not a breach.
        assertFalse(manager.withdrawalBreachesUtil(address(rwaVault), 80e18));
        // 90 wrappers → $9k residual > $8k headroom → breach.
        assertTrue(manager.withdrawalBreachesUtil(address(rwaVault), 90e18));
    }
}
