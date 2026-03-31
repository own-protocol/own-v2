// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MintFlow Integration Test
/// @notice Tests the full minting lifecycle with real contract instances.
///         TODO: Most test bodies commented out pending API alignment with new
///         OwnMarket interface (no PriceType, no partial fills, simplified claim/confirm).
contract MintFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public usdcVault;
    EToken public eTSLA;
    EToken public eGOLD;
    FeeCalculator public feeCalc;

    uint256 constant MAX_EXPOSURE = 10_000_000e18;
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT = 1_000_000e6;
    uint256 constant MINT_AMOUNT = 10_000e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configureVault();
        _depositLPCollateral();
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

        usdcVault =
            OwnVault(factory.createVault(address(usdc), Actors.VM1, "Own USDC Vault", "oUSDC", MAX_UTIL_BPS, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        usdcVault.setGracePeriod(1 days);
        usdcVault.setClaimThreshold(6 hours);

        vm.stopPrank();

        vm.label(address(assetRegistry), "AssetRegistry");
        vm.label(address(market), "OwnMarket");
        vm.label(address(usdcVault), "USDCVault");
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        vm.label(address(eTSLA), "eTSLA");

        eGOLD = new EToken("Own Gold", "eGOLD", GOLD, address(protocolRegistry), address(usdc));
        vm.label(address(eGOLD), "eGOLD");

        AssetConfig memory tslaConfig =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        AssetConfig memory goldConfig =
            AssetConfig({activeToken: address(eGOLD), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(GOLD, address(eGOLD), goldConfig);

        vm.stopPrank();
    }

    function _configureVault() private {
        vm.startPrank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));
        usdcVault.enableAsset(TSLA);
        usdcVault.enableAsset(GOLD);
        vm.stopPrank();
    }

    function _depositLPCollateral() private {
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full mint flow — place, claim, confirm
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_basic() public {
        // TODO: Rewrite once OwnMarket integration is finalised
        // The new API: placeMintOrder(asset, amount, price, expiry)
        // claimOrder(orderId), confirmOrder(orderId)
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(market)), MINT_AMOUNT, "stablecoins escrowed");

        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint8(order.orderType), uint8(OrderType.Mint));
        assertEq(order.amount, MINT_AMOUNT);
        assertEq(uint8(order.status), uint8(OrderStatus.Open));

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Claimed));

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed));

        // Verify eTokens minted to user
        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter received eTokens");
        assertGt(expectedETokens, 0, "non-zero eTokens minted");

        // Verify market escrow is cleared
        assertEq(usdc.balanceOf(address(market)), 0, "market escrow cleared");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel before claim
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_cancelBeforeClaim() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);

        assertEq(usdc.balanceOf(Actors.MINTER1), 0);
        assertEq(usdc.balanceOf(address(market)), MINT_AMOUNT);

        market.cancelOrder(orderId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "stablecoins refunded");
        assertEq(usdc.balanceOf(address(market)), 0, "market drained");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Cancelled));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Deadline expiry
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_deadlineExpiry() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        uint256 expiry = block.timestamp + 1 hours;

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, expiry);
        vm.stopPrank();

        vm.warp(expiry + 1);

        market.expireOrder(orderId);

        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "stablecoins refunded on expiry");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Expired));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cannot cancel other user's order
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_cancelOtherUsersOrder_reverts() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(Actors.MINTER2);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId));
        market.cancelOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Place order with zero amount reverts
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_placeZeroAmount_reverts() public {
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        market.placeMintOrder(address(usdcVault), TSLA, 0, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Place order with expired expiry reverts
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_expiredExpiry_reverts() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("InvalidExpiry()"));
        market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Open orders tracking
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_openOrdersTracking() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

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
    //  Test: Multiple assets minted through same vault
    // ══════════════════════════════════════════════════════════

    function test_mintFlow_multipleAssets_sameVault() public {
        uint256 goldAmount = 5000e6;

        // Place TSLA order
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 tslaOrderId =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // Place GOLD order
        _fundUSDC(Actors.MINTER2, goldAmount);
        vm.startPrank(Actors.MINTER2);
        usdc.approve(address(market), goldAmount);
        uint256 goldOrderId =
            market.placeMintOrder(address(usdcVault), GOLD, goldAmount, GOLD_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // VM claims and confirms both
        vm.startPrank(Actors.VM1);
        market.claimOrder(tslaOrderId);
        market.claimOrder(goldOrderId);
        market.confirmOrder(tslaOrderId);
        market.confirmOrder(goldOrderId);
        vm.stopPrank();

        // Verify independent eToken balances
        uint256 expectedTSLA = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        uint256 expectedGOLD = Math.mulDiv(goldAmount * 1e12, PRECISION, GOLD_PRICE);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedTSLA, "MINTER1 got eTSLA");
        assertEq(eGOLD.balanceOf(Actors.MINTER2), expectedGOLD, "MINTER2 got eGOLD");
        assertGt(expectedTSLA, 0, "non-zero eTSLA");
        assertGt(expectedGOLD, 0, "non-zero eGOLD");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple orders from same user
    // ══════════════════════════════════════════════════════════

    function test_mintFlow_multipleOrders_sameUser() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT * 2);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT * 2);
        uint256 orderId1 =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        uint256 orderId2 =
            market.placeMintOrder(address(usdcVault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertTrue(orderId1 != orderId2, "distinct order IDs");

        // Claim and confirm both
        vm.startPrank(Actors.VM1);
        market.claimOrder(orderId1);
        market.claimOrder(orderId2);
        market.confirmOrder(orderId1);
        market.confirmOrder(orderId2);
        vm.stopPrank();

        uint256 expectedPerOrder = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedPerOrder * 2, "minter got eTokens from both orders");
    }
}
