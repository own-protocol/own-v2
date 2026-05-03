// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultBorrowCoordinator} from "../../src/core/VaultBorrowCoordinator.sol";
import {IBorrowDebt} from "../../src/interfaces/IBorrowDebt.sol";
import {IVaultBorrowCoordinator} from "../../src/interfaces/IVaultBorrowCoordinator.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";

/// @dev Stub manager that returns a settable USD debt figure to the coordinator.
contract StubBorrowManager is IBorrowDebt {
    uint256 public override totalDebtUSD;

    function setDebt(
        uint256 d
    ) external {
        totalDebtUSD = d;
    }
}

/// @dev Stub vault that returns a settable USD collateral value.
contract StubVault {
    uint256 public collateralValueUSD;

    function setCollateral(
        uint256 v
    ) external {
        collateralValueUSD = v;
    }
}

contract VaultBorrowCoordinatorTest is BaseTest {
    VaultBorrowCoordinator public coord;
    MockAaveV3Pool public aavePool;
    StubVault public vault;
    StubBorrowManager public m1;
    StubBorrowManager public m2;

    uint256 constant DEFAULT_LTV = 3500; // 35%

    function setUp() public override {
        super.setUp();

        aavePool = new MockAaveV3Pool();
        // Register USDC as a reserve so getReserveData is non-empty.
        aavePool.registerReserve(address(usdc), "Aave USDC", "aUSDC", 6);

        vault = new StubVault();
        vault.setCollateral(1_000_000e18); // $1M.

        vm.prank(Actors.ADMIN);
        coord = new VaultBorrowCoordinator(
            address(vault), address(aavePool), address(protocolRegistry), address(usdc), DEFAULT_LTV
        );

        m1 = new StubBorrowManager();
        m2 = new StubBorrowManager();
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(coord.vault(), address(vault));
        assertEq(coord.aavePool(), address(aavePool));
        assertEq(coord.stablecoin(), address(usdc));
        assertEq(coord.targetLtvBps(), DEFAULT_LTV);
    }

    function test_constructor_zeroAddresses_revert() public {
        vm.expectRevert(IVaultBorrowCoordinator.ZeroAddress.selector);
        new VaultBorrowCoordinator(address(0), address(aavePool), address(protocolRegistry), address(usdc), DEFAULT_LTV);
    }

    function test_constructor_invalidLtv_reverts() public {
        vm.expectRevert(IVaultBorrowCoordinator.InvalidLtv.selector);
        new VaultBorrowCoordinator(address(vault), address(aavePool), address(protocolRegistry), address(usdc), 0);
        vm.expectRevert(IVaultBorrowCoordinator.InvalidLtv.selector);
        new VaultBorrowCoordinator(address(vault), address(aavePool), address(protocolRegistry), address(usdc), BPS);
    }

    // ──────────────────────────────────────────────────────────
    //  Manager registration
    // ──────────────────────────────────────────────────────────

    function test_registerManager_addsToList() public {
        vm.prank(Actors.ADMIN);
        coord.registerManager(address(m1));
        assertTrue(coord.isManager(address(m1)));
        address[] memory list = coord.managers();
        assertEq(list.length, 1);
        assertEq(list[0], address(m1));
    }

    function test_registerManager_emits() public {
        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, false, false, false);
        emit IVaultBorrowCoordinator.ManagerRegistered(address(m1));
        coord.registerManager(address(m1));
    }

    function test_registerManager_alreadyRegistered_reverts() public {
        vm.startPrank(Actors.ADMIN);
        coord.registerManager(address(m1));
        vm.expectRevert(abi.encodeWithSelector(IVaultBorrowCoordinator.ManagerAlreadyRegistered.selector, address(m1)));
        coord.registerManager(address(m1));
        vm.stopPrank();
    }

    function test_registerManager_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IVaultBorrowCoordinator.OnlyAdmin.selector);
        coord.registerManager(address(m1));
    }

    function test_deregisterManager_removesAndCompacts() public {
        vm.startPrank(Actors.ADMIN);
        coord.registerManager(address(m1));
        coord.registerManager(address(m2));

        coord.deregisterManager(address(m1));
        assertFalse(coord.isManager(address(m1)));
        assertTrue(coord.isManager(address(m2)));
        address[] memory list = coord.managers();
        assertEq(list.length, 1);
        assertEq(list[0], address(m2));
        vm.stopPrank();
    }

    function test_deregisterManager_unknown_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IVaultBorrowCoordinator.ManagerNotRegistered.selector, address(m1)));
        coord.deregisterManager(address(m1));
    }

    // ──────────────────────────────────────────────────────────
    //  Total debt + utilization
    // ──────────────────────────────────────────────────────────

    function test_totalDebtUSD_sumsAcrossManagers() public {
        vm.startPrank(Actors.ADMIN);
        coord.registerManager(address(m1));
        coord.registerManager(address(m2));
        vm.stopPrank();

        m1.setDebt(100_000e18);
        m2.setDebt(50_000e18);

        assertEq(coord.totalDebtUSD(), 150_000e18);
    }

    function test_maxDebtUSD_isCollateralXLtv() public view {
        // $1M × 35% = $350k.
        assertEq(coord.maxDebtUSD(), 350_000e18);
    }

    function test_utilizationBps_zeroWhenNoDebt() public view {
        assertEq(coord.utilizationBps(), 0);
    }

    function test_utilizationBps_zeroWhenCapZero() public {
        vault.setCollateral(0);
        assertEq(coord.utilizationBps(), 0);
    }

    function test_utilizationBps_proportional() public {
        vm.prank(Actors.ADMIN);
        coord.registerManager(address(m1));
        m1.setDebt(175_000e18); // 50% of cap.
        assertEq(coord.utilizationBps(), 5000);
    }

    function test_utilizationBps_clampsTo100() public {
        vm.prank(Actors.ADMIN);
        coord.registerManager(address(m1));
        m1.setDebt(1_000_000e18); // way over cap.
        assertEq(coord.utilizationBps(), BPS);
    }

    // ──────────────────────────────────────────────────────────
    //  preBorrowCheck (hard cap)
    // ──────────────────────────────────────────────────────────

    function test_preBorrowCheck_passesUnderCap() public {
        vm.prank(Actors.ADMIN);
        coord.registerManager(address(m1));
        m1.setDebt(100_000e18);
        coord.preBorrowCheck(50_000e18); // 150k < 350k.
    }

    function test_preBorrowCheck_revertsOverCap() public {
        vm.prank(Actors.ADMIN);
        coord.registerManager(address(m1));
        m1.setDebt(300_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultBorrowCoordinator.BorrowExceedsCap.selector, 360_000e18, 350_000e18)
        );
        coord.preBorrowCheck(60_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Live Aave rate
    // ──────────────────────────────────────────────────────────

    function test_liveAaveRateBps_readsFromPool() public {
        // 5% APR in RAY.
        aavePool.setCurrentVariableBorrowRate(address(usdc), uint128(5 * 1e25));
        assertEq(coord.liveAaveRateBps(), 500);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin setters
    // ──────────────────────────────────────────────────────────

    function test_setTargetLtvBps_updates() public {
        vm.prank(Actors.ADMIN);
        coord.setTargetLtvBps(5000);
        assertEq(coord.targetLtvBps(), 5000);
    }

    function test_setTargetLtvBps_invalid_reverts() public {
        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(IVaultBorrowCoordinator.InvalidLtv.selector);
        coord.setTargetLtvBps(0);
        vm.expectRevert(IVaultBorrowCoordinator.InvalidLtv.selector);
        coord.setTargetLtvBps(BPS);
        vm.stopPrank();
    }

    function test_setStablecoin_updates() public {
        address newStable = makeAddr("newStable");
        vm.prank(Actors.ADMIN);
        coord.setStablecoin(newStable);
        assertEq(coord.stablecoin(), newStable);
    }

    function test_setStablecoin_zero_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IVaultBorrowCoordinator.ZeroAddress.selector);
        coord.setStablecoin(address(0));
    }

    function test_adminFunctions_onlyAdmin() public {
        vm.startPrank(Actors.ATTACKER);
        vm.expectRevert(IVaultBorrowCoordinator.OnlyAdmin.selector);
        coord.setTargetLtvBps(4000);
        vm.expectRevert(IVaultBorrowCoordinator.OnlyAdmin.selector);
        coord.setStablecoin(makeAddr("x"));
        vm.expectRevert(IVaultBorrowCoordinator.OnlyAdmin.selector);
        coord.deregisterManager(address(m1));
        vm.stopPrank();
    }
}
