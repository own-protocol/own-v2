// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title VMLifecycle Integration Test
/// @notice Tests manager binding to vault, order filling, and signer identity verification.
///         The vault operator is now `vault.manager()`; quote signers are a global registry
///         on the VaultManager (mint proceeds / redeem payouts flow to each signer's linked address).
contract VMLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    OwnVault public vault2;
    EToken public eTSLA;

    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant LP_DEPOSIT = 100 ether;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(address(protocolRegistry));

        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        vm.stopPrank();
        // Deploy + register the VaultManager before registering the vault (admin-gated).
        _deployVaultManager();
        vm.startPrank(Actors.ADMIN);

        vault = new OwnVault(address(weth), "Own WETH Vault", "oWETH", address(protocolRegistry), vm1Signer);
        vaultManager.registerVault(address(vault), ETH);
        vault2 = new OwnVault(address(weth), "Own WETH Vault 2", "oWETH2", address(protocolRegistry), vm2Signer);
        vaultManager.registerVault(address(vault2), ETH);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        // Register the WETH collateral ticker so the VaultManager can resolve its oracle.
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ETH, address(weth), ethConfig);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vm.stopPrank();

        // Global controls now live on the VaultManager.
        _setClaimThreshold(6 hours);
        // vm2Signer is intentionally NOT registered, so its quotes are rejected (wrong-VM test).
        _registerSigner(vm1Signer, Actors.VM1);
        // Scope the maker to its quoted assets (default-deny since Phase 4b).
        vm.prank(Actors.ADMIN);
        assetRegistry.setMakerAllowed(TSLA, vm1Signer, true);

        // Per-asset issuance ceiling (global util default is set by _deployVaultManager).
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);

        // Global payment token for all vaults.
        _setPaymentToken(address(usdc));

        // LP deposits collateral (VM1 must call deposit on behalf of LP)
        _fundWETH(vm1Signer, LP_DEPOSIT);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        // Seed the manager's marks: collateral for both vaults and asset price.
        _pullCollateralPrice(address(vault));
        _pullCollateralPrice(address(vault2));
        _pullAssetPrice(TSLA);
    }

    // ══════════════════════════════════════════════════════════
    //  Manager binding — vault.manager() returns correct operator
    // ══════════════════════════════════════════════════════════

    function test_vmBinding() public view {
        assertEq(vault.manager(), vm1Signer);
        assertEq(vault2.manager(), vm2Signer);
    }

    // ══════════════════════════════════════════════════════════
    //  VM identity — only the bound VM can sign a fillable quote
    // ══════════════════════════════════════════════════════════

    function test_vmFillOrder_boundVM_succeeds() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Quote memory q = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
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
        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // vm2Signer is not a registered global signer — its signature is rejected.
        Quote memory q = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
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

        Quote memory q = _buildQuote(0, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter received eTokens");
        // Mint proceeds flow to the signer's linked settlement address (Actors.VM1).
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT, "linked address received stablecoins");
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
        // Payment token is now a single global setting on the VaultManager.
        assertEq(vaultManager.paymentToken(), address(usdc));
    }
}
