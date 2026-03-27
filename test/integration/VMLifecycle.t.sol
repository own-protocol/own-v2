// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, OrderStatus, PriceType, VMConfig} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title VMLifecycle Integration Test
/// @notice Tests VM registration, configuration, order claiming,
///         and multi-VM competition with real contract instances.
contract VMLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
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
        paymentRegistry = new PaymentTokenRegistry(Actors.ADMIN);

        // Register infrastructure in registry
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.PAYMENT_TOKEN_REGISTRY(), address(paymentRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        // Deploy FeeCalculator with zero fees
        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));
        // Deploy contracts with registry
        market = new OwnMarket(address(protocolRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));

        // Register market and vault manager
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        usdcVault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), Actors.VM1, 8000, 0, 2000, 2000
        );
        usdcVault2 = new OwnVault(
            address(usdc), "Own USDC Vault 2", "oUSDC2", address(protocolRegistry), Actors.VM2, 8000, 0, 2000, 2000
        );

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);
        paymentRegistry.addPaymentToken(address(usdc));

        vm.stopPrank();

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
        vaultMgr.setExposureCaps(5_000_000e18, 2_000_000e18);
        vm.stopPrank();

        VMConfig memory cfg = vaultMgr.getVMConfig(Actors.VM1);
        assertEq(cfg.maxExposure, 5_000_000e18);
        assertEq(cfg.maxOffMarketExposure, 2_000_000e18);
    }

    function test_vmPaymentTokenAcceptance() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vaultMgr.setPaymentTokenAcceptance(address(usdt), false);
        vm.stopPrank();

        assertTrue(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdc)));
        assertFalse(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdt)));
    }

    function test_vmAssetOffMarketToggle() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setAssetOffMarketEnabled(TSLA, true);
        vm.stopPrank();

        assertTrue(vaultMgr.isAssetOffMarketEnabled(Actors.VM1, TSLA));

        vm.prank(Actors.VM1);
        vaultMgr.setAssetOffMarketEnabled(TSLA, false);

        assertFalse(vaultMgr.isAssetOffMarketEnabled(Actors.VM1, TSLA));
    }

    function test_vmActiveToggle() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        // Deactivate
        vaultMgr.setVMActive(false);
        assertFalse(vaultMgr.getVMConfig(Actors.VM1).active);

        // Reactivate
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

        // VM2 tries to register with same vault
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
    //  Multi-VM competition for orders
    // ══════════════════════════════════════════════════════════

    function test_multiVM_competitionForOpenOrder() public {
        // Register both VMs with separate vaults (1:1 binding)
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault2));
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        // Minter places open order with partial fills
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            true, // partial fill
            address(0), // open
            _emptyPriceData()
        );
        vm.stopPrank();

        // VM2 claims half first
        vm.prank(Actors.VM2);
        uint256 claimId2 = market.claimOrder(orderId, MINT_AMOUNT / 2);

        // VM1 claims other half
        vm.prank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId, MINT_AMOUNT / 2);

        // Both confirm
        vm.prank(Actors.VM2);
        market.confirmOrder(claimId2, _emptyPriceData());
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId1, _emptyPriceData());

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT / 2);
        assertEq(usdc.balanceOf(Actors.VM2), MINT_AMOUNT / 2);
    }

    // ══════════════════════════════════════════════════════════
    //  Config only if registered
    // ══════════════════════════════════════════════════════════

    function test_configOnlyRegistered() public {
        // Unregistered VM cannot set exposure caps
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("VMNotRegistered(address)", Actors.VM1));
        vaultMgr.setExposureCaps(1_000_000e18, 500_000e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Full lifecycle
    // ══════════════════════════════════════════════════════════

    function test_fullVMLifecycle() public {
        // 1. Register
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setExposureCaps(10_000_000e18, 5_000_000e18);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        // 2. Minter places order
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            Actors.VM1,
            _emptyPriceData()
        );
        vm.stopPrank();

        // 3. VM claims and confirms
        vm.startPrank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);
        market.confirmOrder(claimId, _emptyPriceData());
        vm.stopPrank();

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT);

        // 4. Deregister
        vm.prank(Actors.VM1);
        vaultMgr.deregisterVM();

        assertFalse(vaultMgr.getVMConfig(Actors.VM1).registered);
    }
}
