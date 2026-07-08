// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {ReserveVault} from "../../src/core/ReserveVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {IReserveVault} from "../../src/interfaces/IReserveVault.sol";
import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Minimal asset registry stub: every ticker resolves to the in-house oracle; maker
///      allowlist is a plain mapping (default-deny, mirroring the real registry).
contract PsmStubAssetRegistry {
    mapping(bytes32 => mapping(address => bool)) public makerAllowed;

    function getOracleType(
        bytes32
    ) external pure returns (uint8) {
        return 1;
    }

    function setMakerAllowed(bytes32 ticker, address signer, bool allowed) external {
        makerAllowed[ticker][signer] = allowed;
    }

    function isMakerAllowed(bytes32 ticker, address signer) external view returns (bool) {
        return makerAllowed[ticker][signer];
    }
}

/// @title ReserveVault Unit Tests
/// @notice Custody, market-only release with mark sync, and the operator surplus skim guard.
///         Uses a real VaultManager so the netted-books interactions are exercised for real.
contract ReserveVaultTest is Test {
    ProtocolRegistry internal registry;
    VaultManager internal manager;
    PsmStubAssetRegistry internal assetRegistry;
    MockOracleVerifier internal oracle;
    MockERC20 internal ondo;
    ReserveVault internal reserve;

    address internal admin = Actors.ADMIN;
    address internal market = makeAddr("market");
    address internal treasury = makeAddr("treasury");
    address internal user = makeAddr("user");

    bytes32 internal constant TSLA = bytes32("TSLA");
    bytes32 internal constant ONDO_TSLA = bytes32("ONDO.TSLA");
    uint256 internal constant TSLA_MARK = 100e18;

    function setUp() public {
        registry = new ProtocolRegistry(admin, 0, 2 minutes);
        oracle = new MockOracleVerifier();
        ondo = new MockERC20("Ondo Tesla", "ondoTSLA", 18);

        vm.startPrank(admin);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);
        registry.setAddress(registry.MARKET(), market);
        assetRegistry = new PsmStubAssetRegistry();
        registry.setAddress(registry.ASSET_REGISTRY(), address(assetRegistry));
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracle));
        registry.setAddress(registry.PYTH_ORACLE(), address(oracle));
        vm.stopPrank();

        manager = new VaultManager(IProtocolRegistry(address(registry)));
        vm.startPrank(admin);
        registry.setAddress(registry.VAULT_MANAGER(), address(manager));
        manager.setGlobalMaxUtilizationBps(8000);
        manager.setMaxMarkAge(365 days);
        manager.setAssetCapUSD(TSLA, type(uint128).max);
        vm.stopPrank();

        oracle.setPrice(TSLA, TSLA_MARK);
        oracle.setPrice(ONDO_TSLA, TSLA_MARK);
        manager.pullAssetPrice(TSLA);

        reserve = new ReserveVault(address(ondo), address(registry));
        vm.prank(admin);
        manager.registerVault(address(reserve), ONDO_TSLA, TSLA);
    }

    /// @dev Seed `units` of wrapper into the reserve and mark it.
    function _seed(
        uint256 units
    ) internal {
        ondo.mint(address(reserve), units);
        manager.pullCollateralPrice(address(reserve));
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor & views
    // ──────────────────────────────────────────────────────────

    function test_constructor_zeroAddresses_revert() public {
        vm.expectRevert(IReserveVault.ZeroAddress.selector);
        new ReserveVault(address(0), address(registry));
        vm.expectRevert(IReserveVault.ZeroAddress.selector);
        new ReserveVault(address(ondo), address(0));
    }

    function test_constructor_decimalsTooHigh_reverts() public {
        MockERC20 weird = new MockERC20("Weird", "WRD", 19);
        vm.expectRevert(abi.encodeWithSelector(IReserveVault.DecimalsTooHigh.selector, 19));
        new ReserveVault(address(weird), address(registry));
    }

    function test_views_assetAndTotalAssets() public {
        assertEq(reserve.asset(), address(ondo));
        assertEq(reserve.totalAssets(), 0);
        ondo.mint(address(reserve), 5e18);
        assertEq(reserve.totalAssets(), 5e18, "balance-based");
    }

    // ──────────────────────────────────────────────────────────
    //  deposit
    // ──────────────────────────────────────────────────────────

    function test_deposit_zeroAmount_reverts() public {
        vm.expectRevert(IReserveVault.ZeroAmount.selector);
        vm.prank(user);
        reserve.deposit(0);
    }

    function test_deposit_succeeds_andSyncsMark() public {
        ondo.mint(user, 10e18);
        vm.startPrank(user);
        ondo.approve(address(reserve), 10e18);
        vm.expectEmit(true, false, false, true);
        emit IReserveVault.ReserveDeposited(user, 10e18);
        reserve.deposit(10e18);
        vm.stopPrank();

        assertEq(reserve.totalAssets(), 10e18);
        assertEq(manager.assetRwaCollateralUSD(TSLA), 1000e18, "mark synced on deposit");
    }

    function test_deposit_unregisteredVault_reverts() public {
        // pullCollateralPrice reverts for an unregistered vault — deposits fail closed.
        ReserveVault orphan = new ReserveVault(address(ondo), address(registry));
        ondo.mint(user, 1e18);
        vm.startPrank(user);
        ondo.approve(address(orphan), 1e18);
        vm.expectRevert();
        orphan.deposit(1e18);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  releaseCollateral
    // ──────────────────────────────────────────────────────────

    function test_releaseCollateral_onlyMarket_reverts() public {
        _seed(10e18);
        vm.expectRevert(IReserveVault.OnlyMarket.selector);
        vm.prank(user);
        reserve.releaseCollateral(user, 1e18);
    }

    function test_releaseCollateral_zeroChecks_revert() public {
        _seed(10e18);
        vm.startPrank(market);
        vm.expectRevert(IReserveVault.ZeroAddress.selector);
        reserve.releaseCollateral(address(0), 1e18);
        vm.expectRevert(IReserveVault.ZeroAmount.selector);
        reserve.releaseCollateral(user, 0);
        vm.stopPrank();
    }

    function test_releaseCollateral_exceedsReserve_reverts() public {
        _seed(10e18);
        vm.expectRevert(IReserveVault.AmountExceedsReserve.selector);
        vm.prank(market);
        reserve.releaseCollateral(user, 11e18);
    }

    function test_releaseCollateral_succeeds_andSyncsMark() public {
        _seed(10e18); // R = $1000
        assertEq(manager.assetRwaCollateralUSD(TSLA), 1000e18);

        vm.expectEmit(true, false, false, true);
        emit IReserveVault.CollateralReleased(user, 4e18);
        vm.prank(market);
        reserve.releaseCollateral(user, 4e18);

        assertEq(ondo.balanceOf(user), 4e18);
        assertEq(reserve.totalAssets(), 6e18);
        assertEq(manager.assetRwaCollateralUSD(TSLA), 600e18, "mark reduced proportionally");
    }

    // ──────────────────────────────────────────────────────────
    //  skimExcess
    // ──────────────────────────────────────────────────────────

    function test_skimExcess_onlyOperator_reverts() public {
        _seed(10e18);
        vm.expectRevert(IReserveVault.OnlyOperator.selector);
        vm.prank(user);
        reserve.skimExcess(1e18);
    }

    function test_skimExcess_zeroAndExceeds_revert() public {
        _seed(10e18);
        vm.startPrank(admin);
        registry.setAddress(registry.TREASURY(), treasury);
        vm.expectRevert(IReserveVault.ZeroAmount.selector);
        reserve.skimExcess(0);
        vm.expectRevert(IReserveVault.AmountExceedsReserve.selector);
        reserve.skimExcess(11e18);
        vm.stopPrank();
    }

    function test_skimExcess_treasuryNotSet_reverts() public {
        _seed(10e18);
        vm.prank(admin);
        vm.expectRevert(IReserveVault.TreasuryNotSet.selector);
        reserve.skimExcess(1e18);
    }

    function test_skimExcess_notRwaRegistered_reverts() public {
        // A reserve vault that was never registered (or registered generic) has no backed asset.
        ReserveVault orphan = new ReserveVault(address(ondo), address(registry));
        ondo.mint(address(orphan), 5e18);
        vm.startPrank(admin);
        registry.setAddress(registry.TREASURY(), treasury);
        vm.expectRevert(IReserveVault.VaultNotRwaRegistered.selector);
        orphan.skimExcess(1e18);
        vm.stopPrank();
    }

    function test_skimExcess_blockedWhenReserveMatchesExposure() public {
        _seed(10e18); // R = $1000
        vm.prank(market);
        manager.openExposure(TSLA, 10e18); // E = $1000 — zero surplus

        vm.startPrank(admin);
        registry.setAddress(registry.TREASURY(), treasury);
        vm.expectRevert(IReserveVault.SkimExceedsSurplus.selector);
        reserve.skimExcess(1e18);
        vm.stopPrank();
    }

    function test_skimExcess_spendsOnlyClampedSurplus() public {
        _seed(10e18); // R = $1000
        vm.prank(market);
        manager.openExposure(TSLA, 6e18); // E = $600 → surplus = 4 ondo

        vm.startPrank(admin);
        registry.setAddress(registry.TREASURY(), treasury);
        vm.expectRevert(IReserveVault.SkimExceedsSurplus.selector);
        reserve.skimExcess(5e18); // one wrapper too many

        vm.expectEmit(true, false, false, true);
        emit IReserveVault.ExcessSkimmed(treasury, 4e18);
        reserve.skimExcess(4e18); // exactly the surplus
        vm.stopPrank();

        assertEq(ondo.balanceOf(treasury), 4e18);
        assertEq(reserve.totalAssets(), 6e18);
        assertEq(manager.assetRwaCollateralUSD(TSLA), 600e18, "remaining reserve still covers E");
        assertEq(manager.globalNetExposureUSD(), 0, "skim never re-loads the buffer");
    }

    // ──────────────────────────────────────────────────────────
    //  withdraw (maker recovery)
    // ──────────────────────────────────────────────────────────

    function test_withdraw_onlyRegisteredSigner_reverts() public {
        _seed(10e18);
        vm.expectRevert(IReserveVault.OnlyMaker.selector);
        vm.prank(user);
        reserve.withdraw(1e18);
    }

    function test_withdraw_makerNotAllowedForAsset_reverts() public {
        // Registered signer without a maker-allowlist entry for the backed asset is rejected.
        address signer = makeAddr("signer");
        vm.prank(admin);
        manager.registerSigner(signer, makeAddr("linked"));

        _seed(10e18);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IReserveVault.MakerNotAllowed.selector, TSLA, signer));
        reserve.withdraw(1e18);
    }

    function test_withdraw_paysLinkedAddress_notSigner() public {
        address signer = makeAddr("signer");
        address linked = makeAddr("linked");
        vm.prank(admin);
        manager.registerSigner(signer, linked);
        assetRegistry.setMakerAllowed(TSLA, signer, true);

        _seed(10e18);
        vm.prank(market);
        manager.openExposure(TSLA, 6e18); // E = $600 → surplus = 4 ondo

        vm.expectEmit(true, true, false, true);
        emit IReserveVault.SurplusWithdrawn(signer, linked, 4e18);
        vm.prank(signer);
        reserve.withdraw(4e18);

        assertEq(ondo.balanceOf(linked), 4e18, "funds land at the linked settlement address");
        assertEq(ondo.balanceOf(signer), 0, "never at the hot key");
        assertEq(manager.assetRwaCollateralUSD(TSLA), 600e18, "remaining reserve still covers E");
        assertEq(manager.globalNetExposureUSD(), 0, "withdrawal never re-loads the buffer");
    }

    function test_withdraw_clampedToSurplus_reverts() public {
        address signer = makeAddr("signer");
        vm.prank(admin);
        manager.registerSigner(signer, makeAddr("linked"));
        assetRegistry.setMakerAllowed(TSLA, signer, true);

        _seed(10e18);
        vm.prank(market);
        manager.openExposure(TSLA, 6e18); // surplus = 4 ondo

        vm.prank(signer);
        vm.expectRevert(IReserveVault.SkimExceedsSurplus.selector);
        reserve.withdraw(5e18); // one wrapper into matched backing
    }

    function test_skimExcess_remarksBeforeGuard() public {
        // Donation arrives without a keeper pull: skim must still see it (inline re-mark).
        _seed(10e18);
        vm.prank(market);
        manager.openExposure(TSLA, 10e18); // matched
        ondo.mint(address(reserve), 3e18); // unmarked donation

        vm.startPrank(admin);
        registry.setAddress(registry.TREASURY(), treasury);
        reserve.skimExcess(3e18); // re-mark makes the donation skimmable
        vm.stopPrank();
        assertEq(ondo.balanceOf(treasury), 3e18);
    }
}
