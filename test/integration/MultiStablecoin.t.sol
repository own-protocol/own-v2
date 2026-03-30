// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION} from "../../src/interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title MultiStablecoin Integration Test
/// @notice Tests orders placed in different stablecoins.
///         TODO: Many tests commented out — the new OwnMarket no longer has
///         per-VM payment token acceptance, addPaymentToken/removePaymentToken,
///         isPaymentTokenAccepted, or getPaymentTokens. The vault now has a
///         single paymentToken set via setPaymentToken/paymentToken.
contract MultiStablecoinTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public usdcVault;
    OwnVault public usdcVault2;
    EToken public eTSLA;
    FeeCalculator public feeCalc;

    uint256 constant MINT_AMOUNT = 5000e6;
    uint256 constant MINT_AMOUNT_18 = 5000e18;

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
        protocolRegistry.setProtocolShareBps(2000);

        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        // Deploy factory and create vaults through it
        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        usdcVault = OwnVault(factory.createVault(address(usdc), Actors.VM1, "Own USDC Vault", "oUSDC", 8000, 2000, 900));
        usdcVault2 =
            OwnVault(factory.createVault(address(usdc), Actors.VM2, "Own USDC Vault 2", "oUSDC2", 8000, 2000, 900));

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

        // LP deposits (VM must call deposit)
        _fundUSDC(Actors.VM1, 500_000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 500_000e6);
        usdcVault.deposit(500_000e6, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Mint order with USDC — basic flow
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_mintWithUSDC() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.amount, MINT_AMOUNT);

        // VM1 claims
        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Payment token is set correctly
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_vaultPaymentToken() public view {
        assertEq(usdcVault.paymentToken(), address(usdc));
        assertEq(usdcVault2.paymentToken(), address(usdc));
    }

    // TODO: Tests for multi-stablecoin VM acceptance, addPaymentToken,
    // removePaymentToken, getPaymentTokens, isPaymentTokenAccepted, and
    // setPaymentTokenAcceptance have been removed. The new model uses a
    // single payment token per vault (setPaymentToken/paymentToken).
}
