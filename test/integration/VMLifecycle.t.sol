// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

        vault = OwnVault(factory.createVault(address(weth), vm1Signer, "Own WETH Vault", "oWETH", 8000, 2000));
        vault2 = OwnVault(factory.createVault(address(weth), vm2Signer, "Own WETH Vault 2", "oWETH2", 8000, 2000));
        vault.addQuoteSigner(vm1Signer);
        vault2.addQuoteSigner(vm2Signer);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        vault.setClaimThreshold(6 hours);

        vm.stopPrank();

        // Set payment tokens and enable assets
        vm.startPrank(vm1Signer);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();

        vm.startPrank(vm2Signer);
        vault2.setPaymentToken(address(usdc));
        vault2.enableAsset(TSLA);
        vm.stopPrank();

        // LP deposits collateral (VM1 must call deposit on behalf of LP)
        _fundWETH(vm1Signer, LP_DEPOSIT);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  VM binding — vault.vm() returns correct VM
    // ══════════════════════════════════════════════════════════

    function test_vmBinding() public view {
        assertEq(vault.vm(), vm1Signer);
        assertEq(vault2.vm(), vm2Signer);
    }

    // ══════════════════════════════════════════════════════════
    //  VM identity — only the bound VM can sign a fillable quote
    // ══════════════════════════════════════════════════════════

    function test_vmFillOrder_boundVM_succeeds() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Quote memory q =
            _buildQuote(orderId, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(vm1Signer);
        market.fillOrder(q, sig);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Filled));
        assertGt(eTSLA.balanceOf(Actors.MINTER1), 0, "minter received eTokens");
    }

    function test_vmFillOrder_wrongVM_reverts() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // vm2Signer is bound to vault2, not vault — its signature is not vault's VM.
        Quote memory q =
            _buildQuote(orderId, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm2SignerPk);

        vm.prank(vm2Signer);
        vm.expectRevert(IOwnMarket.InvalidQuoteSigner.selector);
        market.fillOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Full lifecycle — market mint against a VM-signed quote
    // ══════════════════════════════════════════════════════════

    function test_fullVMLifecycle() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        Quote memory q = _buildQuote(0, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter received eTokens");
        assertEq(usdc.balanceOf(vm1Signer), MINT_AMOUNT, "VM received stablecoins");
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
