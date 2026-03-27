// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {
    AssetConfig,
    BPS,
    ClaimInfo,
    Order,
    OrderStatus,
    OrderType,
    PRECISION,
    PriceType
} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MintFlow Integration Test
/// @notice Tests the full minting lifecycle with real contract instances:
///         minter places order → VM claims → VM confirms → eTokens minted.
///         Covers market & limit orders, directed & open orders, partial fills.
contract MintFlowTest is BaseTest {
    // ──────────────────────────────────────────────────────────
    //  Protocol contracts (real instances)
    // ──────────────────────────────────────────────────────────

    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    EToken public eTSLA;
    EToken public eGOLD;
    FeeCalculator public feeCalc;
    address public feeAccrual = makeAddr("feeAccrual");

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    uint256 constant MAX_EXPOSURE = 10_000_000e18; // $10M
    uint256 constant MAX_UTIL_BPS = 8000; // 80%
    uint256 constant AUM_FEE_BPS = 50; // 0.5%
    uint256 constant LP_DEPOSIT = 1_000_000e6; // 1M USDC
    uint256 constant MINT_AMOUNT = 10_000e6; // 10k USDC

    // ──────────────────────────────────────────────────────────
    //  Setup
    // ──────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configurePaymentTokens();
        _configureVaultManager();
        _depositLPCollateral();
    }

    /// @dev Deploy all protocol contracts with correct wiring.
    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        // 1. Deploy registries
        assetRegistry = new AssetRegistry(Actors.ADMIN);
        paymentRegistry = new PaymentTokenRegistry(Actors.ADMIN);

        // 2. Register infrastructure in registry
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
        protocolRegistry.setAddress(keccak256("FEE_ACCRUAL"), feeAccrual);

        // 3. Deploy contracts with registry
        market = new OwnMarket(address(protocolRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));

        // 4. Register market and vault manager
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        // 5. Deploy USDC vault (bound to VM1)
        usdcVault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), Actors.VM1, MAX_UTIL_BPS, AUM_FEE_BPS
        );

        vm.stopPrank();

        // Label deployed contracts
        vm.label(address(assetRegistry), "AssetRegistry");
        vm.label(address(paymentRegistry), "PaymentTokenRegistry");
        vm.label(address(vaultMgr), "VaultManager");
        vm.label(address(market), "OwnMarket");
        vm.label(address(usdcVault), "USDCVault");
    }

    /// @dev Register assets and deploy eTokens.
    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        // Deploy eTSLA token
        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        vm.label(address(eTSLA), "eTSLA");

        // Deploy eGOLD token
        eGOLD = new EToken("Own Gold", "eGOLD", GOLD, address(protocolRegistry), address(usdc));
        vm.label(address(eGOLD), "eGOLD");

        // Register TSLA in asset registry
        AssetConfig memory tslaConfig =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        // Register GOLD in asset registry
        AssetConfig memory goldConfig =
            AssetConfig({activeToken: address(eGOLD), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(GOLD, address(eGOLD), goldConfig);

        vm.stopPrank();
    }

    /// @dev Whitelist payment tokens (stablecoins).
    function _configurePaymentTokens() private {
        vm.startPrank(Actors.ADMIN);
        paymentRegistry.addPaymentToken(address(usdc));
        paymentRegistry.addPaymentToken(address(usdt));
        vm.stopPrank();
    }

    /// @dev Register VM1, set exposure, accept payment tokens.
    function _configureVaultManager() private {
        // VM1 registers with USDC vault
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setExposureCaps(MAX_EXPOSURE, MAX_EXPOSURE / 2);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vaultMgr.setPaymentTokenAcceptance(address(usdt), true);
        vm.stopPrank();
    }

    /// @dev LP1 deposits collateral into the USDC vault via VM (onlyVM).
    function _depositLPCollateral() private {
        _fundUSDC(Actors.VM1, LP_DEPOSIT);

        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full mint flow — market order, directed to VM1
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_marketOrder_directed() public {
        // Fund minter with USDC
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        // Step 1: Minter places a directed market mint order
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100, // 1% slippage
            block.timestamp + 1 days,
            false, // no partial fill
            Actors.VM1, // directed to VM1
            _emptyPriceData()
        );
        vm.stopPrank();

        // Verify: stablecoins escrowed in market
        assertEq(usdc.balanceOf(address(market)), MINT_AMOUNT, "stablecoins escrowed");
        assertEq(usdc.balanceOf(Actors.MINTER1), 0, "minter balance drained");

        // Verify order state
        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint8(order.orderType), uint8(OrderType.Mint));
        assertEq(uint8(order.priceType), uint8(PriceType.Market));
        assertEq(order.asset, TSLA);
        assertEq(order.amount, MINT_AMOUNT);
        assertEq(order.placementPrice, TSLA_PRICE);
        assertEq(uint8(order.status), uint8(OrderStatus.Open));
        assertEq(order.preferredVM, Actors.VM1);

        // Step 2: VM1 claims the order
        uint256 vm1BalanceBefore = usdc.balanceOf(Actors.VM1);

        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);

        // Verify: stablecoins transferred from market to VM1
        assertEq(usdc.balanceOf(Actors.VM1), vm1BalanceBefore + MINT_AMOUNT, "VM received stablecoins");
        assertEq(usdc.balanceOf(address(market)), 0, "market released escrow");

        // Verify order is fully claimed
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.FullyClaimed));
        assertEq(order.filledAmount, MINT_AMOUNT);

        // Verify claim info
        ClaimInfo memory claim = market.getClaim(claimId);
        assertEq(claim.orderId, orderId);
        assertEq(claim.vm, Actors.VM1);
        assertEq(claim.amount, MINT_AMOUNT);
        assertFalse(claim.confirmed);

        // Step 3: VM1 confirms with oracle price
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "minter has no eTokens before confirm");

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        // Verify claim is confirmed
        claim = market.getClaim(claimId);
        assertTrue(claim.confirmed);
        assertEq(claim.executionPrice, TSLA_PRICE);

        // Verify order status is Confirmed
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed));

        // Verify minter received eTokens at oracle price (no spread)
        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter received correct eTokens");
        assertGt(expectedETokens, 0, "eToken amount is non-zero");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full mint flow — limit order, open to any VM
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_limitOrder_open() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        uint256 limitPrice = 240e18; // $240 limit price

        // Minter places open limit order
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Limit,
            limitPrice,
            block.timestamp + 1 days,
            false,
            address(0), // open to any VM
            _emptyPriceData()
        );
        vm.stopPrank();

        // Verify limit price recorded
        Order memory order = market.getOrder(orderId);
        assertEq(order.limitPrice, limitPrice);
        assertEq(order.slippage, 0); // no slippage for limit orders
        assertEq(order.preferredVM, address(0)); // open order

        // Any registered VM can claim — VM1 claims
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);

        // VM1 confirms
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        // Verify final state
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed));

        ClaimInfo memory claim = market.getClaim(claimId);
        assertTrue(claim.confirmed);

        // Verify minter received eTokens at oracle price (no spread)
        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter received eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Partial fill — VM claims portions
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_partialFill() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        // Minter places open order allowing partial fills
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100, // 1% slippage
            block.timestamp + 1 days,
            true, // allow partial fill
            address(0), // open
            _emptyPriceData()
        );
        vm.stopPrank();

        uint256 halfAmount = MINT_AMOUNT / 2;

        // VM1 claims first half
        vm.prank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId, halfAmount);

        // Verify partially claimed
        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.PartiallyClaimed));
        assertEq(order.filledAmount, halfAmount);

        // VM1 received half the stablecoins
        assertEq(usdc.balanceOf(Actors.VM1), halfAmount);

        // VM1 claims second half
        vm.prank(Actors.VM1);
        uint256 claimId2 = market.claimOrder(orderId, halfAmount);

        // Verify fully claimed
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.FullyClaimed));
        assertEq(order.filledAmount, MINT_AMOUNT);
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT);

        // VM1 confirms both claims
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId1, _emptyPriceData());

        // After first confirm, status should be PartiallyConfirmed
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.PartiallyConfirmed));

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId2, _emptyPriceData());

        // After both confirm, status should be Confirmed
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed));

        // Verify claims
        uint256[] memory claimIds = market.getOrderClaims(orderId);
        assertEq(claimIds.length, 2);

        // Verify minter received eTokens from both partial fills (no spread)
        uint256 expectedPerHalf = Math.mulDiv(halfAmount * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedPerHalf * 2, "minter received eTokens from both fills");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel before claim
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_cancelBeforeClaim() public {
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

        // Verify stablecoins escrowed
        assertEq(usdc.balanceOf(Actors.MINTER1), 0);
        assertEq(usdc.balanceOf(address(market)), MINT_AMOUNT);

        // Minter cancels
        market.cancelOrder(orderId);
        vm.stopPrank();

        // Verify stablecoins refunded
        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "stablecoins refunded");
        assertEq(usdc.balanceOf(address(market)), 0, "market drained");

        // Verify order cancelled
        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Cancelled));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel after partial claim — only unclaimed refunded
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_cancelAfterPartialClaim() public {
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
            true, // allow partial fill
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        uint256 halfAmount = MINT_AMOUNT / 2;

        // VM1 claims half
        vm.prank(Actors.VM1);
        market.claimOrder(orderId, halfAmount);

        // Minter cancels remaining
        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        // Verify: minter got back only the unclaimed portion
        assertEq(usdc.balanceOf(Actors.MINTER1), halfAmount, "unclaimed portion refunded");
        // VM1 keeps the claimed stablecoins
        assertEq(usdc.balanceOf(Actors.VM1), halfAmount, "VM keeps claimed portion");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Deadline expiry
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_deadlineExpiry() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        uint256 orderId = market.placeMintOrder(
            TSLA, address(usdc), MINT_AMOUNT, PriceType.Market, 100, deadline, false, address(0), _emptyPriceData()
        );
        vm.stopPrank();

        // Warp past deadline
        vm.warp(deadline + 1);

        // VM1 cannot claim expired order
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("OrderExpiredError(uint256,uint256)", orderId, deadline));
        market.claimOrder(orderId, MINT_AMOUNT);

        // Anyone can trigger expiry to refund minter
        market.expireOrder(orderId);

        // Verify stablecoins refunded
        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "stablecoins refunded on expiry");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Expired));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Directed order — wrong VM cannot claim
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_directedOrder_wrongVM_reverts() public {
        // Register VM2 with a separate vault
        vm.prank(Actors.ADMIN);
        OwnVault usdcVault2 = new OwnVault(
            address(usdc),
            "Own USDC Vault 2",
            "oUSDC2",
            address(protocolRegistry),
            Actors.VM2,
            MAX_UTIL_BPS,
            AUM_FEE_BPS
        );
        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault2));
        vm.stopPrank();

        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        // Place order directed to VM1
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

        // VM2 cannot claim a directed order meant for VM1
        vm.prank(Actors.VM2);
        vm.expectRevert(
            abi.encodeWithSignature("DirectedOrderWrongVM(uint256,address,address)", orderId, Actors.VM1, Actors.VM2)
        );
        market.claimOrder(orderId, MINT_AMOUNT);

        // VM1 can claim
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);
        assertGt(claimId, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Partial fill not allowed — revert on partial claim
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_partialFillNotAllowed_reverts() public {
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
            false, // no partial fill
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        // Attempting a partial claim should revert
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("PartialFillNotAllowed(uint256)", orderId));
        market.claimOrder(orderId, MINT_AMOUNT / 2);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: LP collateral in vault while orders are active
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_vaultHasCollateral() public {
        // Verify vault holds LP collateral
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT, "vault holds LP deposit");
        assertGt(usdcVault.balanceOf(Actors.LP1), 0, "LP1 has vault shares");

        // Run a full mint flow
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

        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        // Vault collateral is still intact (stablecoins went to VM, not from vault)
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT, "vault collateral unchanged");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple orders for different assets
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_multipleAssets() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT * 2);

        // Place TSLA order
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT * 2);

        uint256 tslaOrderId = market.placeMintOrder(
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

        uint256 goldOrderId = market.placeMintOrder(
            GOLD,
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

        // VM claims and confirms both
        vm.startPrank(Actors.VM1);
        uint256 tslaClaimId = market.claimOrder(tslaOrderId, MINT_AMOUNT);
        uint256 goldClaimId = market.claimOrder(goldOrderId, MINT_AMOUNT);
        market.confirmOrder(tslaClaimId, _emptyPriceData());
        market.confirmOrder(goldClaimId, _emptyPriceData());
        vm.stopPrank();

        // Both orders confirmed
        assertEq(uint8(market.getOrder(tslaOrderId).status), uint8(OrderStatus.Confirmed));
        assertEq(uint8(market.getOrder(goldOrderId).status), uint8(OrderStatus.Confirmed));

        // Verify minter received eTokens for both assets
        assertGt(eTSLA.balanceOf(Actors.MINTER1), 0, "minter received eTSLA");
        assertGt(eGOLD.balanceOf(Actors.MINTER1), 0, "minter received eGOLD");

        // Verify user orders list
        uint256[] memory userOrders = market.getUserOrders(Actors.MINTER1);
        assertEq(userOrders.length, 2);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Open orders appear in asset order list
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_openOrdersTracking() public {
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

        // Verify order appears in open orders for TSLA
        uint256[] memory openOrders = market.getOpenOrders(TSLA);
        bool found;
        for (uint256 i; i < openOrders.length; i++) {
            if (openOrders[i] == orderId) {
                found = true;
                break;
            }
        }
        assertTrue(found, "order in open orders list");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: VM confirms with different execution price
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_priceMovesBeforeConfirm() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100, // 1% slippage
            block.timestamp + 1 days,
            false,
            Actors.VM1,
            _emptyPriceData()
        );
        vm.stopPrank();

        // Placement price is TSLA_PRICE (250e18)
        Order memory order = market.getOrder(orderId);
        assertEq(order.placementPrice, TSLA_PRICE);

        // VM claims
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);

        // Price moves to $252 before confirmation
        uint256 newPrice = 252e18;
        _setOraclePrice(TSLA, newPrice);

        // VM confirms with the new price
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        // Verify execution price reflects the new oracle price
        ClaimInfo memory claim = market.getClaim(claimId);
        assertEq(claim.executionPrice, newPrice, "execution price reflects oracle at confirmation");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple minters, concurrent orders
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_multipleMinters() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        _fundUSDC(Actors.MINTER2, MINT_AMOUNT);

        // MINTER1 places order
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

        // MINTER2 places order
        vm.startPrank(Actors.MINTER2);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId2 = market.placeMintOrder(
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

        // VM1 claims both
        vm.startPrank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId1, MINT_AMOUNT);
        uint256 claimId2 = market.claimOrder(orderId2, MINT_AMOUNT);
        market.confirmOrder(claimId1, _emptyPriceData());
        market.confirmOrder(claimId2, _emptyPriceData());
        vm.stopPrank();

        // Verify both confirmed
        assertEq(uint8(market.getOrder(orderId1).status), uint8(OrderStatus.Confirmed));
        assertEq(uint8(market.getOrder(orderId2).status), uint8(OrderStatus.Confirmed));

        // VM received all stablecoins
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT * 2);

        // Both minters received eTokens at oracle price (no spread)
        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter1 received eTokens");
        assertEq(eTSLA.balanceOf(Actors.MINTER2), expectedETokens, "minter2 received eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Only claim VM can confirm
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_onlyClaimVMCanConfirm() public {
        // Register VM2 with a separate vault
        vm.prank(Actors.ADMIN);
        OwnVault usdcVault2 = new OwnVault(
            address(usdc),
            "Own USDC Vault 2",
            "oUSDC2",
            address(protocolRegistry),
            Actors.VM2,
            MAX_UTIL_BPS,
            AUM_FEE_BPS
        );
        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault2));
        vm.stopPrank();

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

        // VM1 claims
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);

        // VM2 cannot confirm VM1's claim
        vm.prank(Actors.VM2);
        vm.expectRevert("OwnMarket: not claim VM");
        market.confirmOrder(claimId, _emptyPriceData());

        // VM1 can confirm
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());
        assertTrue(market.getClaim(claimId).confirmed);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot claim zero amount
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_claimZeroAmount_reverts() public {
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
            true,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        market.claimOrder(orderId, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot claim more than remaining
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_claimExceedsRemaining_reverts() public {
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
            true,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        vm.prank(Actors.VM1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AmountExceedsRemaining(uint256,uint256,uint256)", orderId, MINT_AMOUNT + 1, MINT_AMOUNT
            )
        );
        market.claimOrder(orderId, MINT_AMOUNT + 1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot double-confirm a claim
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_doubleConfirm_reverts() public {
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

        vm.startPrank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);
        market.confirmOrder(claimId, _emptyPriceData());

        // Double confirm reverts
        vm.expectRevert(abi.encodeWithSignature("ClaimAlreadyConfirmed(uint256)", claimId));
        market.confirmOrder(claimId, _emptyPriceData());
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot cancel other user's order
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_cancelOtherUsersOrder_reverts() public {
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

        // MINTER2 cannot cancel MINTER1's order
        vm.prank(Actors.MINTER2);
        vm.expectRevert(abi.encodeWithSignature("OnlyOrderOwner(uint256,address)", orderId, Actors.MINTER2));
        market.cancelOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot claim already fully claimed order
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_claimFullyClaimed_reverts() public {
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

        // VM1 claims entire order
        vm.prank(Actors.VM1);
        market.claimOrder(orderId, MINT_AMOUNT);

        // Another claim attempt should fail
        vm.prank(Actors.VM1);
        vm.expectRevert(
            abi.encodeWithSignature("OrderNotOpen(uint256,uint8)", orderId, uint8(OrderStatus.FullyClaimed))
        );
        market.claimOrder(orderId, 1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Place order with zero amount reverts
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_placeZeroAmount_reverts() public {
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        market.placeMintOrder(
            TSLA,
            address(usdc),
            0,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Place order with expired deadline reverts
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_expiredDeadline_reverts() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("InvalidDeadline()"));
        market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp, // deadline = now (must be > block.timestamp)
            false,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();
    }
}
