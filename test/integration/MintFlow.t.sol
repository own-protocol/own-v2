// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

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
    OwnVault public vault;
    EToken public eTSLA;
    EToken public eGOLD;
    FeeCalculator public feeCalc;

    uint256 constant MAX_EXPOSURE = 10_000_000e18;
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT = 500 ether;
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

        vault = OwnVault(factory.createVault(address(weth), vm1Signer, "Own WETH Vault", "oWETH", MAX_UTIL_BPS, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        vault.setClaimThreshold(6 hours);
        vault.addQuoteSigner(vm1Signer);

        vm.stopPrank();

        vm.label(address(assetRegistry), "AssetRegistry");
        vm.label(address(market), "OwnMarket");
        vm.label(address(vault), "USDCVault");
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        vm.label(address(eTSLA), "eTSLA");

        eGOLD = new EToken("Own Gold", "eGOLD", GOLD, address(protocolRegistry), address(usdc));
        vm.label(address(eGOLD), "eGOLD");

        AssetConfig memory tslaConfig = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        AssetConfig memory goldConfig = AssetConfig({
            activeToken: address(eGOLD),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(GOLD, address(eGOLD), goldConfig);

        vm.stopPrank();
    }

    function _configureVault() private {
        vm.startPrank(vm1Signer);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vault.enableAsset(GOLD);
        vm.stopPrank();
    }

    function _depositLPCollateral() private {
        _fundWETH(vm1Signer, LP_DEPOSIT);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    /// @dev Execute a market mint for `minter` against a VM-signed quote (1 tx).
    function _marketMint(address minter, bytes32 asset, uint256 amount, uint256 price) internal {
        _fundUSDC(minter, amount);
        vm.prank(minter);
        usdc.approve(address(market), amount);
        Quote memory q = _buildQuote(0, minter, address(vault), asset, OrderType.Mint, amount, price);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(minter);
        market.executeOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full mint flow — place, claim, confirm
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_basic() public {
        // Happy-path mint now settles atomically against a VM-signed market quote.
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        Quote memory q = _buildQuote(0, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        // Verify eTokens minted to user, net stablecoins to VM
        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter received eTokens");
        assertGt(expectedETokens, 0, "non-zero eTokens minted");
        assertEq(usdc.balanceOf(vm1Signer), MINT_AMOUNT, "VM received stablecoins");
        assertEq(usdc.balanceOf(address(market)), 0, "no escrow for market order");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Limit mint flow — place (escrow), then VM fills
    // ══════════════════════════════════════════════════════════

    function test_limitMintFlow_placeThenFill() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(market)), MINT_AMOUNT, "stablecoins escrowed");

        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint8(order.orderType), uint8(OrderType.Mint));
        assertEq(order.amount, MINT_AMOUNT);
        assertEq(uint8(order.status), uint8(OrderStatus.Open));

        Quote memory q =
            _buildQuote(orderId, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        vm.prank(vm1Signer);
        market.fillOrder(q, _signQuote(market, q, vm1SignerPk));

        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Filled));

        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "minter received eTokens");
        assertEq(usdc.balanceOf(vm1Signer), MINT_AMOUNT, "VM received escrowed stablecoins");
        assertEq(usdc.balanceOf(address(market)), 0, "market escrow cleared");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel before claim
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_cancelBeforeFill() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);

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
        uint256 orderId = market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, expiry);
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
            market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
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
        market.placeOrder(address(vault), TSLA, OrderType.Mint, 0, TSLA_PRICE, block.timestamp + 1 days);
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
        market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: User orders tracking
    // ══════════════════════════════════════════════════════════

    function test_fullMintFlow_userOrdersTracking() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId =
            market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256[] memory userOrders = market.getUserOrders(Actors.MINTER1);
        bool found;
        for (uint256 i; i < userOrders.length; i++) {
            if (userOrders[i] == orderId) {
                found = true;
                break;
            }
        }
        assertTrue(found, "order in user orders list");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple assets minted through same vault
    // ══════════════════════════════════════════════════════════

    function test_mintFlow_multipleAssets_sameVault() public {
        uint256 goldAmount = 5000e6;

        // Market mint TSLA for MINTER1 and GOLD for MINTER2
        _marketMint(Actors.MINTER1, TSLA, MINT_AMOUNT, TSLA_PRICE);
        _marketMint(Actors.MINTER2, GOLD, goldAmount, GOLD_PRICE);

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
        // Two separate market mints accumulate eTokens for the same user.
        _marketMint(Actors.MINTER1, TSLA, MINT_AMOUNT, TSLA_PRICE);
        _marketMint(Actors.MINTER1, TSLA, MINT_AMOUNT, TSLA_PRICE);

        uint256 expectedPerOrder = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedPerOrder * 2, "minter got eTokens from both orders");
    }
}
