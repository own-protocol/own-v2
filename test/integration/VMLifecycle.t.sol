// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, OracleConfig, OrderStatus} from "../../src/interfaces/types/Types.sol";

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
    OwnVault public vault;
    OwnVault public vault2;
    EToken public eTSLA;
    FeeCalculator public feeCalc;

    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant LP_DEPOSIT = 100 ether;

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

        vault = OwnVault(factory.createVault(address(weth), Actors.VM1, "Own WETH Vault", "oWETH", 8000, 2000));
        vault2 = OwnVault(factory.createVault(address(weth), Actors.VM2, "Own WETH Vault 2", "oWETH2", 8000, 2000));

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        OracleConfig memory tslaOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(TSLA, tslaOracleConfig);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vault.setGracePeriod(1 days);
        vault.setClaimThreshold(6 hours);

        vm.stopPrank();

        // Set payment tokens and enable assets
        vm.startPrank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();

        vm.startPrank(Actors.VM2);
        vault2.setPaymentToken(address(usdc));
        vault2.enableAsset(TSLA);
        vm.stopPrank();

        // LP deposits collateral (VM1 must call deposit on behalf of LP)
        _fundWETH(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  VM binding — vault.vm() returns correct VM
    // ══════════════════════════════════════════════════════════

    function test_vmBinding() public view {
        assertEq(vault.vm(), Actors.VM1);
        assertEq(vault2.vm(), Actors.VM2);
    }

    // ══════════════════════════════════════════════════════════
    //  VM identity — only bound VM can claim orders
    // ══════════════════════════════════════════════════════════

    function test_vmClaimOrder_boundVM_succeeds() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
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
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // VM2 is bound to vault2, not vault (which is the registered vault)
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
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // 2. VM claims and confirms
        vm.startPrank(Actors.VM1);
        market.claimOrder(orderId);
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));
        vm.stopPrank();

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  VM-only vault operations
    // ══════════════════════════════════════════════════════════

    function test_vmOnlyDeposit_whenApprovalRequired() public {
        // Enable deposit approval — non-VM deposit should revert
        vm.prank(Actors.ADMIN);
        vault.setRequireDepositApproval(true);

        _fundWETH(Actors.LP1, 10 ether);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), 10 ether);
        vm.expectRevert(IOwnVault.DepositApprovalRequired.selector);
        vault.deposit(1000e6, Actors.LP1);
        vm.stopPrank();
    }

    function test_vmSetPaymentToken() public view {
        assertEq(vault.paymentToken(), address(usdc));
        assertEq(vault2.paymentToken(), address(usdc));
    }
}
