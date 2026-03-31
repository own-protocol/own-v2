// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, OrderStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title VMLifecycle Integration Test
/// @notice Tests VM binding to vault, order claiming, and VM identity verification.
///         VaultManager no longer exists — VM identity is checked via vault.vm().
contract VMLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
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

        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        usdcVault = OwnVault(factory.createVault(address(usdc), Actors.VM1, "Own USDC Vault", "oUSDC", 8000, 2000));
        usdcVault2 = OwnVault(factory.createVault(address(usdc), Actors.VM2, "Own USDC Vault 2", "oUSDC2", 8000, 2000));

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        usdcVault.setGracePeriod(1 days);
        usdcVault.setClaimThreshold(6 hours);

        vm.stopPrank();

        // Set payment tokens and enable assets
        vm.startPrank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));
        usdcVault.enableAsset(TSLA);
        vm.stopPrank();

        vm.startPrank(Actors.VM2);
        usdcVault2.setPaymentToken(address(usdc));
        usdcVault2.enableAsset(TSLA);
        vm.stopPrank();

        // LP deposits collateral (VM1 must call deposit on behalf of LP)
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  VM binding — vault.vm() returns correct VM
    // ══════════════════════════════════════════════════════════

    function test_vmBinding() public view {
        assertEq(usdcVault.vm(), Actors.VM1);
        assertEq(usdcVault2.vm(), Actors.VM2);
    }

    // ══════════════════════════════════════════════════════════
    //  VM identity — only bound VM can claim orders
    // ══════════════════════════════════════════════════════════

    function test_vmClaimOrder_boundVM_succeeds() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Claimed));
        assertEq(market.getOrder(orderId).vm, Actors.VM1);
    }

    function test_vmClaimOrder_wrongVM_reverts() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // VM2 is bound to usdcVault2, not usdcVault (which is the registered vault)
        vm.prank(Actors.VM2);
        vm.expectRevert(abi.encodeWithSignature("OnlyVM()"));
        market.claimOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Full lifecycle
    // ══════════════════════════════════════════════════════════

    function test_fullVMLifecycle() public {
        // 1. Minter places order
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // 2. VM claims and confirms
        vm.startPrank(Actors.VM1);
        market.claimOrder(orderId);
        market.confirmOrder(orderId);
        vm.stopPrank();

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  VM-only vault operations
    // ══════════════════════════════════════════════════════════

    function test_vmOnlyDeposit() public {
        _fundUSDC(Actors.LP1, 1000e6);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), 1000e6);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        usdcVault.deposit(1000e6, Actors.LP1);
        vm.stopPrank();
    }

    function test_vmSetPaymentToken() public view {
        assertEq(usdcVault.paymentToken(), address(usdc));
        assertEq(usdcVault2.paymentToken(), address(usdc));
    }
}
