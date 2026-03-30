// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, OrderStatus, VMConfig} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title VMLifecycle Integration Test
/// @notice Tests VM registration, configuration, order claiming,
///         and multi-VM competition with real contract instances.
contract VMLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    OwnVault public usdcVault2;
    EToken public eTSLA;
    FeeCalculator public feeCalc;

    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant LP_DEPOSIT = 500_000e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));

        usdcVault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), Actors.VM1, 8000, 2000, 2000
        );
        usdcVault2 = new OwnVault(
            address(usdc), "Own USDC Vault 2", "oUSDC2", address(protocolRegistry), Actors.VM2, 8000, 2000, 2000
        );

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        protocolRegistry.setAddress(protocolRegistry.VAULT(), address(usdcVault));
        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        usdcVault.setGracePeriod(1 days);
        usdcVault.setClaimThreshold(6 hours);
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        vm.stopPrank();

        // Set payment tokens (single token per vault)
        vm.prank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));

        vm.prank(Actors.VM2);
        usdcVault2.setPaymentToken(address(usdc));

        // LP deposits collateral (VM1 must call deposit on behalf of LP)
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Registration
    // ══════════════════════════════════════════════════════════

    function test_vmRegistration() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        VMConfig memory cfg = vaultMgr.getVMConfig(Actors.VM1);
        assertTrue(cfg.registered);
        assertTrue(cfg.active);
        assertEq(vaultMgr.getVMVault(Actors.VM1), address(usdcVault));
    }

    function test_vmRegistration_alreadyRegistered_reverts() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        vm.expectRevert(abi.encodeWithSignature("VMAlreadyRegistered(address)", Actors.VM1));
        vaultMgr.registerVM(address(usdcVault));
        vm.stopPrank();
    }

    function test_vmRegistration_zeroVault_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vaultMgr.registerVM(address(0));
    }

    function test_vmDeregistration() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.deregisterVM();
        vm.stopPrank();

        VMConfig memory cfg = vaultMgr.getVMConfig(Actors.VM1);
        assertFalse(cfg.registered);
        assertFalse(cfg.active);
        assertEq(vaultMgr.getVMVault(Actors.VM1), address(0));
    }

    function test_vmDeregistration_notRegistered_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("VMNotRegistered(address)", Actors.VM1));
        vaultMgr.deregisterVM();
    }

    // ══════════════════════════════════════════════════════════
    //  Configuration
    // ══════════════════════════════════════════════════════════

    function test_vmSetExposureCaps() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setExposureCaps(5_000_000e18);
        vm.stopPrank();

        VMConfig memory cfg = vaultMgr.getVMConfig(Actors.VM1);
        assertEq(cfg.maxExposure, 5_000_000e18);
    }

    function test_vmActiveToggle() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        vaultMgr.setVMActive(false);
        assertFalse(vaultMgr.getVMConfig(Actors.VM1).active);

        vaultMgr.setVMActive(true);
        assertTrue(vaultMgr.getVMConfig(Actors.VM1).active);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  1:1 vault binding
    // ══════════════════════════════════════════════════════════

    function test_vaultAlreadyHasVM_reverts() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        vm.prank(Actors.VM2);
        vm.expectRevert(abi.encodeWithSignature("VaultAlreadyHasVM(address)", address(usdcVault)));
        vaultMgr.registerVM(address(usdcVault));
    }

    function test_getVaultVM_returnsVM() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        assertEq(vaultMgr.getVaultVM(address(usdcVault)), Actors.VM1);
    }

    function test_deregisterVM_clearsVaultVM() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.deregisterVM();
        vm.stopPrank();

        assertEq(vaultMgr.getVaultVM(address(usdcVault)), address(0));
    }

    // ══════════════════════════════════════════════════════════
    //  Config only if registered
    // ══════════════════════════════════════════════════════════

    function test_configOnlyRegistered() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("VMNotRegistered(address)", Actors.VM1));
        vaultMgr.setExposureCaps(1_000_000e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Full lifecycle
    // ══════════════════════════════════════════════════════════

    function test_fullVMLifecycle() public {
        // 1. Register
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setExposureCaps(10_000_000e18);
        vm.stopPrank();

        // 2. Minter places order
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days
        );
        vm.stopPrank();

        // 3. VM claims and confirms
        vm.startPrank(Actors.VM1);
        market.claimOrder(orderId);
        market.confirmOrder(orderId);
        vm.stopPrank();

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));

        // 4. Deregister
        vm.prank(Actors.VM1);
        vaultMgr.deregisterVM();

        assertFalse(vaultMgr.getVMConfig(Actors.VM1).registered);
    }
}
