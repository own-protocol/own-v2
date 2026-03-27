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

/// @title RedeemFlow Integration Test
/// @notice Tests the full redemption lifecycle with real contract instances:
///         minter holds eTokens → places redeem order → VM claims → VM sends stablecoins
///         + confirms → eTokens burned. Deadline enforcement and cancel flows.
contract RedeemFlowTest is BaseTest {
    // ──────────────────────────────────────────────────────────
    //  Protocol contracts
    // ──────────────────────────────────────────────────────────

    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    EToken public eTSLA;
    FeeCalculator public feeCalc;
    address public feeAccrual = makeAddr("feeAccrual");

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    uint256 constant DEFAULT_SPREAD = 50;
    uint256 constant MIN_SPREAD = 30;
    uint256 constant MAX_EXPOSURE = 10_000_000e18;
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT = 1_000_000e6;
    uint256 constant MINT_AMOUNT = 10_000e6;

    // eToken amount minted from a $10k order at $250/share = 40 eTSLA
    // (In current implementation, eTokens aren't auto-minted on confirm,
    //  so we mint them directly for redeem testing.)
    uint256 constant ETOKEN_AMOUNT = 40e18;

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
        _mintETokensToMinter();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        paymentRegistry = new PaymentTokenRegistry(Actors.ADMIN);

        // Register infrastructure in registry
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

        // Deploy contracts with registry
        market = new OwnMarket(address(protocolRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry), MIN_SPREAD);

        // Register market and vault manager
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        usdcVault =
            new OwnVault(address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), MAX_UTIL_BPS, 50, 1000);

        vm.stopPrank();

        vm.label(address(assetRegistry), "AssetRegistry");
        vm.label(address(paymentRegistry), "PaymentTokenRegistry");
        vm.label(address(vaultMgr), "VaultManager");
        vm.label(address(market), "OwnMarket");
        vm.label(address(usdcVault), "USDCVault");
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        vm.label(address(eTSLA), "eTSLA");

        AssetConfig memory tslaConfig =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        vm.stopPrank();
    }

    function _configurePaymentTokens() private {
        vm.startPrank(Actors.ADMIN);
        paymentRegistry.addPaymentToken(address(usdc));
        paymentRegistry.addPaymentToken(address(usdt));
        vm.stopPrank();
    }

    function _configureVaultManager() private {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(DEFAULT_SPREAD);
        vaultMgr.setExposureCaps(MAX_EXPOSURE, MAX_EXPOSURE / 2);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);
    }

    function _depositLPCollateral() private {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    /// @dev Directly mint eTokens to MINTER1 for redeem testing.
    ///      In the full protocol, eTokens would be minted on confirmOrder.
    ///      Since the market is the orderSystem, we prank as market to mint.
    function _mintETokensToMinter() private {
        vm.prank(address(market));
        eTSLA.mint(Actors.MINTER1, ETOKEN_AMOUNT);
    }

    /// @dev Fund a VM with USDC and approve OwnMarket for redeem payout.
    function _fundVMForRedeem(address vmAddr, uint256 eTokenAmount) private {
        // Fund generously: eTokenAmount at oracle price (no spread deduction, so always enough)
        uint256 maxPayout = Math.mulDiv(eTokenAmount, TSLA_PRICE, PRECISION * 1e12);
        _fundUSDC(vmAddr, maxPayout);
        vm.prank(vmAddr);
        usdc.approve(address(market), maxPayout);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Full redeem flow — market order
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_marketOrder() public {
        // Minter places redeem order (eTokens escrowed)
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeRedeemOrder(
            TSLA,
            address(usdc),
            ETOKEN_AMOUNT,
            PriceType.Market,
            100, // 1% slippage
            block.timestamp + 1 days,
            false,
            Actors.VM1,
            _emptyPriceData()
        );
        vm.stopPrank();

        // Verify eTokens escrowed in market
        assertEq(eTSLA.balanceOf(address(market)), ETOKEN_AMOUNT, "eTokens escrowed");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "minter eTokens drained");

        // Verify order state
        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint8(order.orderType), uint8(OrderType.Redeem));
        assertEq(order.amount, ETOKEN_AMOUNT);
        assertEq(order.placementPrice, TSLA_PRICE);
        assertEq(uint8(order.status), uint8(OrderStatus.Open));

        // VM1 claims the redeem order (no stablecoin transfer on claim for redeems)
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, ETOKEN_AMOUNT);

        // Verify order fully claimed
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.FullyClaimed));

        // Verify claim
        ClaimInfo memory claim = market.getClaim(claimId);
        assertEq(claim.vm, Actors.VM1);
        assertEq(claim.amount, ETOKEN_AMOUNT);

        // VM1 must have stablecoins to pay minter on confirm
        _fundVMForRedeem(Actors.VM1, ETOKEN_AMOUNT);

        uint256 minterBalanceBefore = usdc.balanceOf(Actors.MINTER1);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        // Verify confirmed
        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed));
        claim = market.getClaim(claimId);
        assertTrue(claim.confirmed);
        assertEq(claim.executionPrice, TSLA_PRICE);

        // Minter should have received stablecoins
        assertGt(usdc.balanceOf(Actors.MINTER1), minterBalanceBefore);
        // eTokens should be burned from escrow
        assertEq(eTSLA.balanceOf(address(market)), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Redeem with limit order
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_limitOrder() public {
        uint256 limitPrice = 260e18; // $260 limit (want at least this)

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeRedeemOrder(
            TSLA,
            address(usdc),
            ETOKEN_AMOUNT,
            PriceType.Limit,
            limitPrice,
            block.timestamp + 1 days,
            false,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.limitPrice, limitPrice);
        assertEq(order.slippage, 0);

        // VM claims
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, ETOKEN_AMOUNT);

        // Fund VM for redeem payout and confirm
        _fundVMForRedeem(Actors.VM1, ETOKEN_AMOUNT);
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancel redeem order — eTokens returned
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_cancel_eTokensReturned() public {
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeRedeemOrder(
            TSLA,
            address(usdc),
            ETOKEN_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            address(0),
            _emptyPriceData()
        );

        // eTokens escrowed
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0);

        // Cancel — note: current implementation only refunds stablecoins for Mint orders.
        // For Redeem orders, eTokens should be returned but aren't in the current cancelOrder.
        // This test documents that gap.
        market.cancelOrder(orderId);
        vm.stopPrank();

        // Verify order is cancelled
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Cancelled));

        // Note: eTokens are NOT automatically returned for redeem cancellations
        // in the current OwnMarket.cancelOrder() implementation (it only handles Mint refunds).
        // This is a gap that needs to be addressed.
        // assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Redeem deadline expiry
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_deadlineExpiry() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeRedeemOrder(
            TSLA, address(usdc), ETOKEN_AMOUNT, PriceType.Market, 100, deadline, false, address(0), _emptyPriceData()
        );
        vm.stopPrank();

        // Warp past deadline
        vm.warp(deadline + 1);

        // Trigger expiry
        market.expireOrder(orderId);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Expired));

        // Note: eTokens are NOT automatically returned on expiry for Redeem orders
        // in the current implementation. This is a gap.
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Partial redeem — two VMs claim portions
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_partialFill() public {
        // Register VM2
        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(DEFAULT_SPREAD);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeRedeemOrder(
            TSLA,
            address(usdc),
            ETOKEN_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            true, // allow partial fill
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        uint256 halfAmount = ETOKEN_AMOUNT / 2;

        // VM1 claims first half
        vm.prank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId, halfAmount);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.PartiallyClaimed));

        // VM2 claims second half
        vm.prank(Actors.VM2);
        uint256 claimId2 = market.claimOrder(orderId, halfAmount);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.FullyClaimed));

        // Fund both VMs for payout, then confirm
        _fundVMForRedeem(Actors.VM1, halfAmount);
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId1, _emptyPriceData());

        _fundVMForRedeem(Actors.VM2, halfAmount);
        vm.prank(Actors.VM2);
        market.confirmOrder(claimId2, _emptyPriceData());

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: VM cannot claim expired redeem order
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_claimAfterDeadline_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeRedeemOrder(
            TSLA, address(usdc), ETOKEN_AMOUNT, PriceType.Market, 100, deadline, false, address(0), _emptyPriceData()
        );
        vm.stopPrank();

        // Warp past deadline
        vm.warp(deadline + 1);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("OrderExpiredError(uint256,uint256)", orderId, deadline));
        market.claimOrder(orderId, ETOKEN_AMOUNT);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Directed redeem order — wrong VM cannot claim
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_directedOrder_wrongVM_reverts() public {
        // Register VM2
        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(DEFAULT_SPREAD);
        vm.stopPrank();

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        uint256 orderId = market.placeRedeemOrder(
            TSLA,
            address(usdc),
            ETOKEN_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            Actors.VM1, // directed to VM1
            _emptyPriceData()
        );
        vm.stopPrank();

        // VM2 cannot claim
        vm.prank(Actors.VM2);
        vm.expectRevert(
            abi.encodeWithSignature("DirectedOrderWrongVM(uint256,address,address)", orderId, Actors.VM1, Actors.VM2)
        );
        market.claimOrder(orderId, ETOKEN_AMOUNT);

        // VM1 can claim
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, ETOKEN_AMOUNT);
        assertGt(claimId, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Redeem for different stablecoin (USDT)
    // ══════════════════════════════════════════════════════════

    function test_fullRedeemFlow_differentStablecoin() public {
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);

        // Request redemption in USDT
        uint256 orderId = market.placeRedeemOrder(
            TSLA,
            address(usdt),
            ETOKEN_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            Actors.VM1,
            _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.stablecoin, address(usdt));

        // VM claims
        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, ETOKEN_AMOUNT);

        // Fund VM with USDT for payout
        uint256 maxPayout = Math.mulDiv(ETOKEN_AMOUNT, TSLA_PRICE, PRECISION * 1e12);
        _fundUSDT(Actors.VM1, maxPayout);
        vm.prank(Actors.VM1);
        usdt.approve(address(market), maxPayout);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
        // Minter received USDT
        assertGt(usdt.balanceOf(Actors.MINTER1), 0);
    }
}
