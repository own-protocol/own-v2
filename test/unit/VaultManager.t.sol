// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {BPS, VMConfig} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @title VaultManager Unit Tests
/// @notice Tests registration, exposure config, 1:1 vault binding,
///         payment token acceptance, off-market toggles, and access control.
contract VaultManagerTest is BaseTest {
    VaultManager public vmManager;

    address public mockVault = makeAddr("vault");
    address public mockVault2 = makeAddr("vault2");
    address public mockMarket = makeAddr("market");

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        vmManager = new VaultManager(Actors.ADMIN, address(protocolRegistry));
        vm.stopPrank();
        vm.label(address(vmManager), "VaultManager");
    }

    // ──────────────────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────────────────

    function test_registerVM_succeeds() public {
        vm.expectEmit(true, true, false, false);
        emit IVaultManager.VaultManagerRegistered(Actors.VM1, mockVault);

        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertTrue(config.registered);
        assertEq(vmManager.getVMVault(Actors.VM1), mockVault);
    }

    function test_registerVM_alreadyRegistered_reverts() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VMAlreadyRegistered.selector, Actors.VM1));
        vmManager.registerVM(mockVault);
    }

    function test_registerVM_zeroAddress_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(IVaultManager.ZeroAddress.selector);
        vmManager.registerVM(address(0));
    }

    function test_registerVM_vaultAlreadyHasVM_reverts() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        // VM2 tries to register with the same vault
        vm.prank(Actors.VM2);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VaultAlreadyHasVM.selector, mockVault));
        vmManager.registerVM(mockVault);
    }

    function test_deregisterVM_succeeds() public {
        vm.startPrank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.expectEmit(true, true, false, false);
        emit IVaultManager.VaultManagerDeregistered(Actors.VM1, mockVault);

        vmManager.deregisterVM();
        vm.stopPrank();

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertFalse(config.registered);
    }

    function test_deregisterVM_notRegistered_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VMNotRegistered.selector, Actors.VM1));
        vmManager.deregisterVM();
    }

    function test_deregisterVM_clearsVaultVM() public {
        vm.startPrank(Actors.VM1);
        vmManager.registerVM(mockVault);
        vmManager.deregisterVM();
        vm.stopPrank();

        // Vault should no longer have a VM
        assertEq(vmManager.getVaultVM(mockVault), address(0));

        // Another VM should now be able to register with the same vault
        vm.prank(Actors.VM2);
        vmManager.registerVM(mockVault);
        assertEq(vmManager.getVaultVM(mockVault), Actors.VM2);
    }

    // ──────────────────────────────────────────────────────────
    //  Vault VM lookup
    // ──────────────────────────────────────────────────────────

    function test_getVaultVM_returnsRegisteredVM() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        assertEq(vmManager.getVaultVM(mockVault), Actors.VM1);
    }

    function test_getVaultVM_unregisteredVault_returnsZero() public view {
        assertEq(vmManager.getVaultVM(mockVault), address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Exposure caps
    // ──────────────────────────────────────────────────────────

    function test_setExposureCaps_succeeds() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.ExposureCapsUpdated(Actors.VM1, 1_000_000e18, 500_000e18);

        vm.prank(Actors.VM1);
        vmManager.setExposureCaps(1_000_000e18, 500_000e18);

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertEq(config.maxExposure, 1_000_000e18);
        assertEq(config.maxOffMarketExposure, 500_000e18);
    }

    function test_setExposureCaps_notRegistered_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VMNotRegistered.selector, Actors.VM1));
        vmManager.setExposureCaps(1_000_000e18, 500_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Payment token acceptance
    // ──────────────────────────────────────────────────────────

    function test_setPaymentTokenAcceptance_succeeds() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.expectEmit(true, true, false, true);
        emit IVaultManager.PaymentTokenAcceptanceUpdated(Actors.VM1, address(usdc), true);

        vm.prank(Actors.VM1);
        vmManager.setPaymentTokenAcceptance(address(usdc), true);

        assertTrue(vmManager.isPaymentTokenAccepted(Actors.VM1, address(usdc)));
    }

    function test_setPaymentTokenAcceptance_remove() public {
        vm.startPrank(Actors.VM1);
        vmManager.registerVM(mockVault);
        vmManager.setPaymentTokenAcceptance(address(usdc), true);
        vmManager.setPaymentTokenAcceptance(address(usdc), false);
        vm.stopPrank();

        assertFalse(vmManager.isPaymentTokenAccepted(Actors.VM1, address(usdc)));
    }

    // ──────────────────────────────────────────────────────────
    //  Off-market toggles
    // ──────────────────────────────────────────────────────────

    function test_setAssetOffMarketEnabled_succeeds() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.expectEmit(true, true, false, true);
        emit IVaultManager.AssetOffMarketToggled(Actors.VM1, TSLA, true);

        vm.prank(Actors.VM1);
        vmManager.setAssetOffMarketEnabled(TSLA, true);

        assertTrue(vmManager.isAssetOffMarketEnabled(Actors.VM1, TSLA));
    }

    // ──────────────────────────────────────────────────────────
    //  VM active status
    // ──────────────────────────────────────────────────────────

    function test_setVMActive_pause_succeeds() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.VMActiveStatusUpdated(Actors.VM1, false);

        vm.prank(Actors.VM1);
        vmManager.setVMActive(false);

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertFalse(config.active);
    }

    function test_setVMActive_resume_succeeds() public {
        vm.startPrank(Actors.VM1);
        vmManager.registerVM(mockVault);
        vmManager.setVMActive(false);
        vmManager.setVMActive(true);
        vm.stopPrank();

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertTrue(config.active);
    }

    // ──────────────────────────────────────────────────────────
    //  Exposure tracking
    // ──────────────────────────────────────────────────────────

    function test_updateExposure_market_succeeds() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM1);
        vmManager.setExposureCaps(1_000_000e18, 500_000e18);

        // Market updates exposure
        vm.expectEmit(true, false, false, true);
        emit IVaultManager.ExposureUpdated(Actors.VM1, 100_000e18);

        vm.prank(mockMarket);
        vmManager.updateExposure(Actors.VM1, int256(100_000e18));

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertEq(config.currentExposure, 100_000e18);
    }

    function test_updateExposure_decrease() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM1);
        vmManager.setExposureCaps(1_000_000e18, 500_000e18);

        vm.prank(mockMarket);
        vmManager.updateExposure(Actors.VM1, int256(100_000e18));

        vm.prank(mockMarket);
        vmManager.updateExposure(Actors.VM1, -int256(40_000e18));

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertEq(config.currentExposure, 60_000e18);
    }

    function test_updateExposure_nonMarket_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vmManager.updateExposure(Actors.VM1, int256(100_000e18));
    }
}
