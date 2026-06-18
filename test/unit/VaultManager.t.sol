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
    StubVault internal vault;

    address internal admin = Actors.ADMIN;
    address internal market = makeAddr("market");
    address internal nonAdmin = makeAddr("nonAdmin");

    bytes32 internal constant TSLA = bytes32("TSLA");
    bytes32 internal constant USDC_TICKER = bytes32("USDC");

    uint256 internal constant TSLA_MARK = 100e18; // $100 per eTSLA
    uint256 internal constant USDC_MARK = 1e18; //   $1 per USDC
    uint256 internal constant MAX_UTIL_BPS = 8000; // 80%
    uint256 internal constant ASSET_CAP = 1_000_000e18; // $1M

    function setUp() public {
        registry = new ProtocolRegistry(admin, 0, 2 minutes);
        assetRegistry = new StubAssetRegistry();
        oracle = new MockOracleVerifier();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new StubVault(address(usdc));

        vm.startPrank(admin);
        registry.setAddress(registry.MARKET(), market);
        registry.setAddress(registry.ASSET_REGISTRY(), address(assetRegistry));
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracle));
        registry.setAddress(registry.PYTH_ORACLE(), address(oracle));
        vm.stopPrank();

        manager = new VaultManager(IProtocolRegistry(address(registry)));

        oracle.setPrice(TSLA, TSLA_MARK);
        oracle.setPrice(USDC_TICKER, USDC_MARK);

        vm.prank(admin);
        manager.setGlobalMaxUtilizationBps(MAX_UTIL_BPS);
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
        emit IVaultManager.VaultRegistered(address(vault), USDC_TICKER);
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
    //  Price pull — asset price
    // ──────────────────────────────────────────────────────────

    function test_pullAssetPricePrice_setsMark() public {
        manager.pullAssetPrice(TSLA);
        assertEq(manager.assetMark(TSLA), TSLA_MARK);
    }

    function test_pullAssetPricePrice_remarksExposure() public {
        _bootstrap();
        _open(1000e18); // $100k exposure
        assertEq(manager.globalExposureUSD(), 100_000e18);

        oracle.setPrice(TSLA, 200e18); // price doubles
        manager.pullAssetPrice(TSLA);

        assertEq(manager.assetMark(TSLA), 200e18);
        assertEq(manager.globalExposureUSD(), 200_000e18);
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
        assertEq(manager.globalExposureUSD(), 100_000e18);
        assertEq(manager.globalUtilizationBps(), 1000); // 100k / 1M = 10%
    }

    // ──────────────────────────────────────────────────────────
    //  applySplit
    // ──────────────────────────────────────────────────────────

    function test_applySplit_redenominatesUnitsAndMark_usdInvariant() public {
        _bootstrap();
        _open(1000e18);
        uint256 usdBefore = manager.globalExposureUSD();

        vm.prank(admin);
        manager.applySplit(TSLA, 3e18); // 3:1 split

        assertEq(manager.globalAssetUnits(TSLA), 3000e18, "units x3");
        assertEq(manager.assetMark(TSLA), TSLA_MARK / 3, "mark /3");
        assertEq(manager.globalExposureUSD(), usdBefore, "USD exposure invariant across split");
    }

    function test_applySplit_onlyAdmin_reverts() public {
        _bootstrap();
        _open(1000e18);
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.applySplit(TSLA, 3e18);
    }

    function test_applySplit_zeroRatio_reverts() public {
        _bootstrap();
        vm.expectRevert(IVaultManager.InvalidRatio.selector);
        vm.prank(admin);
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
    //  Close exposure
    // ──────────────────────────────────────────────────────────

    function test_closeExposure_happy() public {
        _bootstrap();
        _open(1000e18);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.ExposureClosed(TSLA, 400e18, TSLA_MARK);
        _close(400e18);

        assertEq(manager.globalAssetUnits(TSLA), 600e18);
        assertEq(manager.globalExposureUSD(), 60_000e18);
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
        assertEq(manager.globalExposureUSD(), 0);
    }

    /// @dev A zero mark must fail loud (mirrors openExposure) instead of silently zeroing
    ///      the asset's USD exposure. Reachable via an extreme applySplit ratio flooring the mark.
    function test_closeExposure_zeroMark_reverts() public {
        _bootstrap();
        _open(1000e18);

        vm.prank(admin);
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
        assertEq(manager.globalExposureUSD(), 0);

        // A price pull on the now-empty book is also safe.
        manager.pullAssetPrice(TSLA);
        assertEq(manager.globalExposureUSD(), 0);
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
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
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
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
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
        assertEq(manager.globalExposureUSD(), 200_000e18);
    }

    function test_haltAsset_onlyAdmin_reverts() public {
        vm.expectRevert(IVaultManager.OnlyAdmin.selector);
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
}
