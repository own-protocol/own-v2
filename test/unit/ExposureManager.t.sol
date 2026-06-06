// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExposureManager} from "../../src/core/ExposureManager.sol";

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IExposureManager} from "../../src/interfaces/IExposureManager.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
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

contract ExposureManagerTest is Test {
    ExposureManager internal manager;
    ProtocolRegistry internal registry;
    StubAssetRegistry internal assetRegistry;
    MockOracleVerifier internal oracle;
    MockERC20 internal usdc;
    StubVault internal vault;

    address internal admin = Actors.ADMIN;
    address internal market = makeAddr("market");
    address internal factory = makeAddr("factory");

    bytes32 internal constant TSLA = bytes32("TSLA");
    bytes32 internal constant USDC_TICKER = bytes32("USDC");

    uint256 internal constant TSLA_MARK = 100e18; // $100 per eTSLA
    uint256 internal constant USDC_MARK = 1e18; //   $1 per USDC
    uint256 internal constant MAX_UTIL_BPS = 8000; // 80%
    uint256 internal constant ASSET_CAP = 1_000_000e18; // $1M

    function setUp() public {
        registry = new ProtocolRegistry(admin, 0);
        assetRegistry = new StubAssetRegistry();
        oracle = new MockOracleVerifier();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new StubVault(address(usdc));

        vm.startPrank(admin);
        registry.setAddress(registry.MARKET(), market);
        registry.setAddress(registry.VAULT_FACTORY(), factory);
        registry.setAddress(registry.ASSET_REGISTRY(), address(assetRegistry));
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracle));
        registry.setAddress(registry.PYTH_ORACLE(), address(oracle));
        vm.stopPrank();

        manager = new ExposureManager(IProtocolRegistry(address(registry)));

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
        vm.prank(factory);
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
        manager.openExposure(address(vault), TSLA, units);
    }

    function _close(
        uint256 units
    ) internal {
        vm.prank(market);
        manager.closeExposure(address(vault), TSLA, units);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_zeroRegistry_reverts() public {
        vm.expectRevert(IExposureManager.ZeroAddress.selector);
        new ExposureManager(IProtocolRegistry(address(0)));
    }

    // ──────────────────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────────────────

    function test_registerVault_setsStateAndScale() public {
        vm.expectEmit(true, true, false, true);
        emit IExposureManager.VaultRegistered(address(vault), USDC_TICKER);
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);

        assertTrue(manager.isRegisteredVault(address(vault)));
    }

    function test_registerVault_onlyFactory_reverts() public {
        vm.expectRevert(IExposureManager.OnlyFactory.selector);
        vm.prank(admin);
        manager.registerVault(address(vault), USDC_TICKER);
    }

    function test_registerVault_zeroVault_reverts() public {
        vm.expectRevert(IExposureManager.ZeroAddress.selector);
        vm.prank(factory);
        manager.registerVault(address(0), USDC_TICKER);
    }

    function test_registerVault_alreadyRegistered_reverts() public {
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);

        vm.expectRevert(abi.encodeWithSelector(IExposureManager.VaultAlreadyRegistered.selector, address(vault)));
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);
    }

    // ──────────────────────────────────────────────────────────
    //  Price pull — collateral
    // ──────────────────────────────────────────────────────────

    function test_pullCollateralPrice_setsMarkAndGlobal() public {
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(1_000_000e6);

        manager.pullCollateralPrice(address(vault));

        assertEq(manager.collateralMark(address(vault)), 1_000_000e18);
        assertEq(manager.globalCollateralUSD(), 1_000_000e18);
    }

    function test_pullCollateralPrice_secondPullReplacesContribution() public {
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);

        vault.setTotalAssets(1_000_000e6);
        manager.pullCollateralPrice(address(vault));
        vault.setTotalAssets(500_000e6);
        manager.pullCollateralPrice(address(vault));

        assertEq(manager.globalCollateralUSD(), 500_000e18);
    }

    function test_pullCollateralPrice_notRegistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IExposureManager.VaultNotRegistered.selector, address(vault)));
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

        vm.expectEmit(true, true, false, true);
        emit IExposureManager.ExposureOpened(address(vault), TSLA, 1000e18, TSLA_MARK);
        _open(1000e18);

        assertEq(manager.globalAssetUnits(TSLA), 1000e18);
        assertEq(manager.globalExposureUSD(), 100_000e18);
        assertEq(manager.globalUtilizationBps(), 1000); // 100k / 1M = 10%
    }

    function test_openExposure_onlyMarket_reverts() public {
        _bootstrap();
        vm.expectRevert(IExposureManager.OnlyMarket.selector);
        vm.prank(admin);
        manager.openExposure(address(vault), TSLA, 1000e18);
    }

    function test_openExposure_notRegistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IExposureManager.VaultNotRegistered.selector, address(vault)));
        vm.prank(market);
        manager.openExposure(address(vault), TSLA, 1000e18);
    }

    function test_openExposure_zeroUnits_reverts() public {
        _bootstrap();
        vm.expectRevert(IExposureManager.ZeroAmount.selector);
        vm.prank(market);
        manager.openExposure(address(vault), TSLA, 0);
    }

    function test_openExposure_priceUnavailable_reverts() public {
        // Registered + collateral pulled, but asset price never pulled → mark == 0.
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(1_000_000e6);
        manager.pullCollateralPrice(address(vault));

        vm.expectRevert(abi.encodeWithSelector(IExposureManager.PriceUnavailable.selector, TSLA));
        vm.prank(market);
        manager.openExposure(address(vault), TSLA, 1000e18);
    }

    function test_openExposure_collateralNotInitialized_reverts() public {
        // Registered + price pulled, but no collateral pulled → global collateral == 0.
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);
        manager.pullAssetPrice(TSLA);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);

        vm.expectRevert(IExposureManager.CollateralNotInitialized.selector);
        vm.prank(market);
        manager.openExposure(address(vault), TSLA, 1000e18);
    }

    function test_openExposure_assetCapZero_blocksMinting() public {
        vm.prank(factory);
        manager.registerVault(address(vault), USDC_TICKER);
        vault.setTotalAssets(1_000_000e6);
        manager.pullCollateralPrice(address(vault));
        manager.pullAssetPrice(TSLA);
        // assetCapUSD left at 0 (default).

        vm.expectRevert(abi.encodeWithSelector(IExposureManager.AssetCapBreached.selector, TSLA, 100_000e18, 0));
        vm.prank(market);
        manager.openExposure(address(vault), TSLA, 1000e18);
    }

    function test_openExposure_assetCapBreached_reverts() public {
        _bootstrap();
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, 50_000e18); // $50k cap

        // 600 units * $100 = $60k > $50k cap.
        vm.expectRevert(abi.encodeWithSelector(IExposureManager.AssetCapBreached.selector, TSLA, 60_000e18, 50_000e18));
        vm.prank(market);
        manager.openExposure(address(vault), TSLA, 600e18);
    }

    function test_openExposure_globalUtilizationBreached_reverts() public {
        _bootstrap();
        // collateral $1M, max util 80% → ceiling $800k. 9000 units * $100 = $900k → 9000 bps.
        vm.expectRevert(abi.encodeWithSelector(IExposureManager.GlobalUtilizationBreached.selector, 9000, MAX_UTIL_BPS));
        vm.prank(market);
        manager.openExposure(address(vault), TSLA, 9000e18);
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

        vm.expectEmit(true, true, false, true);
        emit IExposureManager.ExposureClosed(address(vault), TSLA, 400e18, TSLA_MARK);
        _close(400e18);

        assertEq(manager.globalAssetUnits(TSLA), 600e18);
        assertEq(manager.globalExposureUSD(), 60_000e18);
    }

    function test_closeExposure_onlyMarket_reverts() public {
        _bootstrap();
        _open(1000e18);
        vm.expectRevert(IExposureManager.OnlyMarket.selector);
        vm.prank(admin);
        manager.closeExposure(address(vault), TSLA, 100e18);
    }

    function test_closeExposure_zeroUnits_reverts() public {
        _bootstrap();
        _open(1000e18);
        vm.expectRevert(IExposureManager.ZeroAmount.selector);
        vm.prank(market);
        manager.closeExposure(address(vault), TSLA, 0);
    }

    function test_closeExposure_insufficient_reverts() public {
        _bootstrap();
        _open(100e18);
        vm.expectRevert(abi.encodeWithSelector(IExposureManager.InsufficientExposure.selector, TSLA, 100e18, 200e18));
        vm.prank(market);
        manager.closeExposure(address(vault), TSLA, 200e18);
    }

    function test_openThenClose_roundTrips() public {
        _bootstrap();
        _open(1000e18);
        _close(1000e18);
        assertEq(manager.globalAssetUnits(TSLA), 0);
        assertEq(manager.globalExposureUSD(), 0);
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
        vm.prank(factory);
        manager.deregisterVault(address(vault));

        assertFalse(manager.isRegisteredVault(address(vault)));
        assertEq(manager.globalCollateralUSD(), 0);
        assertEq(manager.collateralMark(address(vault)), 0);
    }

    function test_deregisterVault_onlyFactory_reverts() public {
        _bootstrap();
        vm.expectRevert(IExposureManager.OnlyFactory.selector);
        vm.prank(admin);
        manager.deregisterVault(address(vault));
    }

    function test_deregisterVault_notRegistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IExposureManager.VaultNotRegistered.selector, address(vault)));
        vm.prank(factory);
        manager.deregisterVault(address(vault));
    }

    function test_deregisterVault_wouldBreachUtil_reverts() public {
        _bootstrap();
        _open(7000e18); // $700k exposure, $1M collateral → 70%

        // Removing the only collateral source leaves projCollateral == 0 with live exposure.
        vm.expectRevert(IExposureManager.DeregisterWouldBreachUtilization.selector);
        vm.prank(factory);
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
    //  Admin setters
    // ──────────────────────────────────────────────────────────

    function test_setAssetCapUSD_onlyAdmin_reverts() public {
        vm.expectRevert(IExposureManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
    }

    function test_setAssetCapUSD_emits() public {
        vm.expectEmit(true, false, false, true);
        emit IExposureManager.AssetCapUpdated(TSLA, ASSET_CAP);
        vm.prank(admin);
        manager.setAssetCapUSD(TSLA, ASSET_CAP);
        assertEq(manager.assetCapUSD(TSLA), ASSET_CAP);
    }

    function test_setGlobalMaxUtilizationBps_onlyAdmin_reverts() public {
        vm.expectRevert(IExposureManager.OnlyAdmin.selector);
        vm.prank(market);
        manager.setGlobalMaxUtilizationBps(5000);
    }

    function test_setGlobalMaxUtilizationBps_emits() public {
        vm.expectEmit(false, false, false, true);
        emit IExposureManager.GlobalMaxUtilizationUpdated(MAX_UTIL_BPS, 5000);
        vm.prank(admin);
        manager.setGlobalMaxUtilizationBps(5000);
        assertEq(manager.globalMaxUtilizationBps(), 5000);
    }

    // ──────────────────────────────────────────────────────────
    //  Views — utilisation edge cases
    // ──────────────────────────────────────────────────────────

    function test_globalUtilizationBps_zeroCollateralZeroExposure_isZero() public view {
        assertEq(manager.globalUtilizationBps(), 0);
    }
}
