// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {BPS, VMConfig} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @title VaultManager Unit Tests
/// @notice Tests registration, spread/exposure config, delegation lifecycle,
///         payment token acceptance, off-market toggles, and access control.
contract VaultManagerTest is BaseTest {
    VaultManager public vmManager;

    address public mockVault = makeAddr("vault");
    address public mockMarket = makeAddr("market");

    uint256 constant DEFAULT_MIN_SPREAD = 30; // 0.3%

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        vmManager = new VaultManager(Actors.ADMIN, address(protocolRegistry), DEFAULT_MIN_SPREAD);
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

    // ──────────────────────────────────────────────────────────
    //  Spread
    // ──────────────────────────────────────────────────────────

    function test_setSpread_succeeds() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.expectEmit(true, false, false, true);
        emit IVaultManager.SpreadUpdated(Actors.VM1, 0, 50);

        vm.prank(Actors.VM1);
        vmManager.setSpread(50); // 0.5%

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertEq(config.spread, 50);
    }

    function test_setSpread_belowMinimum_reverts() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.SpreadBelowMinimum.selector, 10, DEFAULT_MIN_SPREAD));
        vmManager.setSpread(10); // below 30 bps min
    }

    function test_setSpread_notRegistered_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VMNotRegistered.selector, Actors.VM1));
        vmManager.setSpread(50);
    }

    function test_setSpread_exceedsBPS_reverts() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM1);
        vm.expectRevert(IVaultManager.InvalidSpread.selector);
        vmManager.setSpread(10_001); // > 100%
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
    //  Delegation
    // ──────────────────────────────────────────────────────────

    function test_delegation_fullLifecycle() public {
        // VM registers
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        // LP proposes delegation
        vm.expectEmit(true, true, false, false);
        emit IVaultManager.DelegationProposed(Actors.LP1, Actors.VM1);

        vm.prank(Actors.LP1);
        vmManager.proposeDelegation(Actors.VM1);

        // VM accepts
        vm.expectEmit(true, true, false, false);
        emit IVaultManager.DelegationAccepted(Actors.LP1, Actors.VM1);

        vm.prank(Actors.VM1);
        vmManager.acceptDelegation(Actors.LP1);

        // Verify delegation
        assertEq(vmManager.getDelegatedVM(Actors.LP1), Actors.VM1);

        address[] memory lps = vmManager.getDelegatedLPs(Actors.VM1);
        assertEq(lps.length, 1);
        assertEq(lps[0], Actors.LP1);
    }

    function test_proposeDelegation_vmNotRegistered_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.VMNotRegistered.selector, Actors.VM1));
        vmManager.proposeDelegation(Actors.VM1);
    }

    function test_proposeDelegation_alreadyDelegated_reverts() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM2);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.LP1);
        vmManager.proposeDelegation(Actors.VM1);

        vm.prank(Actors.VM1);
        vmManager.acceptDelegation(Actors.LP1);

        // LP1 tries to propose to VM2 while delegated to VM1
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.AlreadyDelegated.selector, Actors.LP1));
        vmManager.proposeDelegation(Actors.VM2);
    }

    function test_acceptDelegation_noProposal_reverts() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.DelegationNotProposed.selector, Actors.LP1, Actors.VM1));
        vmManager.acceptDelegation(Actors.LP1);
    }

    function test_removeDelegation_succeeds() public {
        // Setup delegation
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.LP1);
        vmManager.proposeDelegation(Actors.VM1);

        vm.prank(Actors.VM1);
        vmManager.acceptDelegation(Actors.LP1);

        // LP removes delegation
        vm.expectEmit(true, true, false, false);
        emit IVaultManager.DelegationRemoved(Actors.LP1, Actors.VM1);

        vm.prank(Actors.LP1);
        vmManager.removeDelegation();

        assertEq(vmManager.getDelegatedVM(Actors.LP1), address(0));
    }

    function test_removeDelegation_notDelegated_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert();
        vmManager.removeDelegation();
    }

    function test_delegation_multipleLPs() public {
        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        // LP1 delegates
        vm.prank(Actors.LP1);
        vmManager.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vmManager.acceptDelegation(Actors.LP1);

        // LP2 delegates
        vm.prank(Actors.LP2);
        vmManager.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vmManager.acceptDelegation(Actors.LP2);

        address[] memory lps = vmManager.getDelegatedLPs(Actors.VM1);
        assertEq(lps.length, 2);
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

    // ──────────────────────────────────────────────────────────
    //  Admin: minSpread
    // ──────────────────────────────────────────────────────────

    function test_setMinSpread_admin_succeeds() public {
        vm.prank(Actors.ADMIN);
        vmManager.setMinSpread(50);

        assertEq(vmManager.minSpread(), 50);
    }

    function test_setMinSpread_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vmManager.setMinSpread(50);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_setSpread_aboveMinimum(
        uint256 spread
    ) public {
        spread = bound(spread, DEFAULT_MIN_SPREAD, BPS);

        vm.prank(Actors.VM1);
        vmManager.registerVM(mockVault);

        vm.prank(Actors.VM1);
        vmManager.setSpread(spread);

        VMConfig memory config = vmManager.getVMConfig(Actors.VM1);
        assertEq(config.spread, spread);
    }
}
