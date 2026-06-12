// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RedeemFlow Integration Test
/// @notice Tests the full redemption lifecycle with real contract instances.
///         TODO: Many test bodies commented out pending API alignment with new
///         OwnMarket interface (no PriceType, no partial fills, simplified claim/confirm).
contract RedeemFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT_WETH = 50_000e18;
    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant ETOKEN_AMOUNT = 40e18;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configureVault();
        _depositLPCollateral();
        _mintETokensToMinter();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        vm.stopPrank();
        // Deploy + register the VaultManager before registering the vault (admin-gated).
        _deployVaultManager();
        vm.startPrank(Actors.ADMIN);

        vault = new OwnVault(address(weth), "Own ETH Vault", "oETH", address(protocolRegistry), vm1Signer);
        vaultManager.registerVault(address(vault), ETH);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vm.stopPrank();

        _setClaimThreshold(6 hours);
        _registerSigner(vm1Signer, Actors.VM1);

        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);

        vm.label(address(assetRegistry), "AssetRegistry");
        vm.label(address(market), "OwnMarket");
        vm.label(address(vault), "USDCVault");
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        vm.label(address(eTSLA), "eTSLA");

        AssetConfig memory tslaConfig = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        bytes32 ethAsset = bytes32("ETH");
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ethAsset, address(weth), ethConfig);

        vm.stopPrank();

        _setOraclePrice(ethAsset, ETH_PRICE);
    }

    function _configureVault() private {
        _setPaymentToken(address(usdc));
    }

    function _depositLPCollateral() private {
        _fundWETH(vm1Signer, LP_DEPOSIT_WETH);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();

        _pullCollateralPrice(address(vault));
        _pullAssetPrice(TSLA);
    }

    function _mintETokensToMinter() private {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        Quote memory q = _buildQuote(0, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full redeem flow — basic
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_basic() public {
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeOrder(TSLA, OrderType.Redeem, ETOKEN_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(eTSLA.balanceOf(address(market)), ETOKEN_AMOUNT, "eTokens escrowed");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "minter eTokens drained");

        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint8(order.orderType), uint8(OrderType.Redeem));
        assertEq(order.amount, ETOKEN_AMOUNT);
        assertEq(uint8(order.status), uint8(OrderStatus.Open));

        // The signer's linked address funds the payout; the resting redeem order is filled.
        uint256 payout = Math.mulDiv(ETOKEN_AMOUNT, TSLA_PRICE, PRECISION * 10 ** (18 - 6));
        _fundUSDC(Actors.VM1, payout);
        vm.prank(Actors.VM1);
        usdc.approve(address(market), payout);

        Quote memory q = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Redeem, ETOKEN_AMOUNT, TSLA_PRICE);
        vm.prank(vm1Signer);
        market.fillOrder(q, _signQuote(market, q, vm1SignerPk));

        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Filled));
        assertEq(usdc.balanceOf(Actors.MINTER1), payout, "minter received payout");
        assertEq(eTSLA.balanceOf(address(market)), 0, "eTokens burned from escrow");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel redeem order
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_cancel() public {
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeOrder(TSLA, OrderType.Redeem, ETOKEN_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0);

        market.cancelOrder(orderId);
        vm.stopPrank();

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Cancelled));
        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned on cancel");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Redeem expiry
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_deadlineExpiry() public {
        uint256 expiry = block.timestamp + 1 hours;

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeOrder(TSLA, OrderType.Redeem, ETOKEN_AMOUNT, TSLA_PRICE, expiry);
        vm.stopPrank();

        vm.warp(expiry + 1);

        market.expireOrder(orderId);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Expired));
        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned on expiry");
    }
}
