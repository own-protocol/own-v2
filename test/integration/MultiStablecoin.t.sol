// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {
    AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION, PriceType
} from "../../src/interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title MultiStablecoin Integration Test
/// @notice Tests orders placed in USDC, USDT, USDS. VM stablecoin filtering.
///         Redeem with chosen stablecoin.
contract MultiStablecoinTest is BaseTest {
    AssetRegistry public assetRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    OwnVault public usdcVault2;
    EToken public eTSLA;
    FeeCalculator public feeCalc;

    uint256 constant MINT_AMOUNT = 5000e6; // 5k (6 decimals for USDC/USDT)
    uint256 constant MINT_AMOUNT_18 = 5000e18; // 5k (18 decimals for USDS)

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        // Register infrastructure in registry
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
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

        // Each VM gets its own vault (1:1 binding)
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

        vm.stopPrank();

        // Add payment tokens at vault level (each VM adds to its own vault)
        vm.startPrank(Actors.VM1);
        usdcVault.addPaymentToken(address(usdc));
        usdcVault.addPaymentToken(address(usdt));
        usdcVault.addPaymentToken(address(usds));
        vm.stopPrank();

        vm.startPrank(Actors.VM2);
        usdcVault2.addPaymentToken(address(usdc));
        usdcVault2.addPaymentToken(address(usdt));
        usdcVault2.addPaymentToken(address(usds));
        vm.stopPrank();

        // Register VM1 — accepts USDC and USDT but NOT USDS
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setExposureCaps(10_000_000e18, 5_000_000e18);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vaultMgr.setPaymentTokenAcceptance(address(usdt), true);
        vaultMgr.setPaymentTokenAcceptance(address(usds), false);
        vm.stopPrank();

        // Register VM2 — accepts only USDS
        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault2));
        vaultMgr.setExposureCaps(10_000_000e18, 5_000_000e18);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), false);
        vaultMgr.setPaymentTokenAcceptance(address(usdt), false);
        vaultMgr.setPaymentTokenAcceptance(address(usds), true);
        vm.stopPrank();

        // LP deposits (VM must call deposit)
        _fundUSDC(Actors.VM1, 500_000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 500_000e6);
        usdcVault.deposit(500_000e6, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Mint order with USDC
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_mintWithUSDC() public {
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
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.stablecoin, address(usdc));
        assertEq(order.amount, MINT_AMOUNT);

        // VM1 claims (accepts USDC)
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Mint order with USDT
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_mintWithUSDT() public {
        _fundUSDT(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdt.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdt),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.stablecoin, address(usdt));

        // VM1 claims (accepts USDT)
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);
        assertEq(usdt.balanceOf(Actors.VM1), MINT_AMOUNT);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Mint order with USDS (18 decimals)
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_mintWithUSDS() public {
        usds.mint(Actors.MINTER1, MINT_AMOUNT_18);

        vm.startPrank(Actors.MINTER1);
        usds.approve(address(market), MINT_AMOUNT_18);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usds),
            MINT_AMOUNT_18,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.stablecoin, address(usds));
        assertEq(order.amount, MINT_AMOUNT_18);

        // VM2 claims (accepts USDS)
        vm.prank(Actors.VM2);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT_18);
        assertEq(usds.balanceOf(Actors.VM2), MINT_AMOUNT_18);

        vm.prank(Actors.VM2);
        market.confirmOrder(claimId, _emptyPriceData());
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: VM stablecoin acceptance tracking
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_vmAcceptanceConfig() public {
        // VM1 accepts USDC, USDT but not USDS
        assertTrue(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdc)));
        assertTrue(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdt)));
        assertFalse(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usds)));

        // VM2 accepts only USDS
        assertFalse(vaultMgr.isPaymentTokenAccepted(Actors.VM2, address(usdc)));
        assertFalse(vaultMgr.isPaymentTokenAccepted(Actors.VM2, address(usdt)));
        assertTrue(vaultMgr.isPaymentTokenAccepted(Actors.VM2, address(usds)));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: VM can toggle stablecoin acceptance
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_toggleAcceptance() public {
        // VM1 disables USDC
        vm.prank(Actors.VM1);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), false);
        assertFalse(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdc)));

        // VM1 re-enables USDC
        vm.prank(Actors.VM1);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        assertTrue(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdc)));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Payment token registry
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_vaultPaymentTokens() public {
        // usdcVault (VM1) accepts all three
        assertTrue(usdcVault.isPaymentTokenAccepted(address(usdc)));
        assertTrue(usdcVault.isPaymentTokenAccepted(address(usdt)));
        assertTrue(usdcVault.isPaymentTokenAccepted(address(usds)));

        address[] memory tokens = usdcVault.getPaymentTokens();
        assertEq(tokens.length, 3);

        // usdcVault2 (VM2) also has all three registered
        assertTrue(usdcVault2.isPaymentTokenAccepted(address(usdc)));
        assertTrue(usdcVault2.isPaymentTokenAccepted(address(usdt)));
        assertTrue(usdcVault2.isPaymentTokenAccepted(address(usds)));

        address[] memory tokens2 = usdcVault2.getPaymentTokens();
        assertEq(tokens2.length, 3);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Remove stablecoin from registry
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_removeFromVault() public {
        vm.prank(Actors.VM1);
        usdcVault.removePaymentToken(address(usds));

        assertFalse(usdcVault.isPaymentTokenAccepted(address(usds)));
        assertEq(usdcVault.getPaymentTokens().length, 2);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Concurrent orders in different stablecoins
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_concurrentOrders() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        _fundUSDT(Actors.MINTER2, MINT_AMOUNT);

        // MINTER1 places USDC order
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId1 = market.placeMintOrder(
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

        // MINTER2 places USDT order
        vm.startPrank(Actors.MINTER2);
        usdt.approve(address(market), MINT_AMOUNT);
        uint256 orderId2 = market.placeMintOrder(
            TSLA,
            address(usdt),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            Actors.VM1,
            _emptyPriceData()
        );
        vm.stopPrank();

        // Verify different stablecoins
        assertEq(market.getOrder(orderId1).stablecoin, address(usdc));
        assertEq(market.getOrder(orderId2).stablecoin, address(usdt));

        // VM1 claims and confirms both
        vm.startPrank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId1, MINT_AMOUNT);
        uint256 claimId2 = market.claimOrder(orderId2, MINT_AMOUNT);
        market.confirmOrder(claimId1, _emptyPriceData());
        market.confirmOrder(claimId2, _emptyPriceData());
        vm.stopPrank();

        // VM received both stablecoins
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT);
        assertEq(usdt.balanceOf(Actors.VM1), MINT_AMOUNT);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Redeem order requesting specific stablecoin
    // ══════════════════════════════════════════════════════════

    function test_multiStablecoin_redeemWithChosenStablecoin() public {
        // Mint eTokens first
        vm.prank(address(market));
        eTSLA.mint(Actors.MINTER1, 20e18);

        // Minter places redeem order requesting USDT payout
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), 20e18);
        uint256 orderId = market.placeRedeemOrder(
            TSLA,
            address(usdt),
            20e18,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            Actors.VM1,
            _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.stablecoin, address(usdt), "redeem requests USDT");
        assertEq(uint8(order.orderType), uint8(OrderType.Redeem));

        // VM claims
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, 20e18);

        // Fund VM with USDT for redeem payout
        uint256 maxPayout = Math.mulDiv(20e18, TSLA_PRICE, PRECISION * 1e12);
        _fundUSDT(Actors.VM1, maxPayout);
        vm.prank(Actors.VM1);
        usdt.approve(address(market), maxPayout);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
        assertGt(usdt.balanceOf(Actors.MINTER1), 0, "minter received USDT");
    }
}
