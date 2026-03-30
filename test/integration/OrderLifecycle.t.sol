// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {
    AssetConfig,
    BPS,
    OracleConfig,
    Order,
    OrderStatus,
    OrderType,
    PRECISION
} from "../../src/interfaces/types/Types.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OrderLifecycle Integration Test
/// @notice End-to-end tests with real contracts: close, force-execute (with collateral
///         release verification), fees, payment token swap, withdrawal wait period,
///         and edge cases (double-claim, double-confirm, etc.).
contract OrderLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;
    FeeCalculator public feeCalc;

    uint256 constant MAX_EXPOSURE = 10_000_000e18;
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT_WETH = 50_000e18;
    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant ETOKEN_AMOUNT = 40e18;
    uint256 constant GRACE_PERIOD = 1 days;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    uint256 constant MINT_FEE_BPS = 100;
    uint256 constant REDEEM_FEE_BPS = 50;

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
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(2, MINT_FEE_BPS);
        feeCalc.setRedeemFee(2, REDEEM_FEE_BPS);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        vault = new OwnVault(
            address(weth), "Own ETH Vault", "oETH",
            address(protocolRegistry), Actors.VM1, MAX_UTIL_BPS, 2000, 2000
        );

        protocolRegistry.setAddress(protocolRegistry.VAULT(), address(vault));
        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vault.setGracePeriod(GRACE_PERIOD);
        vault.setClaimThreshold(CLAIM_THRESHOLD);

        vm.stopPrank();
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaConfig =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        bytes32 ethAsset = bytes32("ETH");
        AssetConfig memory ethConfig =
            AssetConfig({activeToken: address(weth), legacyTokens: new address[](0), active: true, volatilityLevel: 1});
        assetRegistry.addAsset(ethAsset, address(weth), ethConfig);
        OracleConfig memory ethOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0), pythPriceFeedId: bytes32(0)});
        assetRegistry.setOracleConfig(ethAsset, ethOracleConfig);
        vault.setCollateralOracleAsset(ethAsset);

        vm.stopPrank();

        _setOraclePrice(ethAsset, ETH_PRICE);
    }

    function _configureVault() private {
        vm.prank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
    }

    function _depositLPCollateral() private {
        _fundWETH(Actors.VM1, LP_DEPOSIT_WETH);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();
    }

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeMintOrder(TSLA, amount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _placeRedeem(address minter, uint256 eAmount, uint256 expiry) internal returns (uint256) {
        vm.startPrank(minter);
        eTSLA.approve(address(market), eAmount);
        uint256 orderId = market.placeRedeemOrder(TSLA, eAmount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _mintETokens(address to, uint256 amount) internal {
        vm.prank(address(market));
        eTSLA.mint(to, amount);
    }

    function _mintFee(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, MINT_FEE_BPS, BPS, Math.Rounding.Ceil);
    }

    function _redeemGrossPayout(uint256 eAmount) internal pure returns (uint256) {
        return Math.mulDiv(eAmount, TSLA_PRICE, PRECISION * 1e12);
    }

    // ══════════════════════════════════════════════════════════
    //  Close order — mint (VM returns stablecoins after expiry)
    // ══════════════════════════════════════════════════════════

    function test_closeOrder_mint_fullFlow() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        assertEq(usdc.balanceOf(address(market)), MINT_AMOUNT, "USDC escrowed in market");
        assertEq(usdc.balanceOf(Actors.MINTER1), 0, "minter drained");

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 fee = _mintFee(MINT_AMOUNT);
        uint256 netToVM = MINT_AMOUNT - fee;

        // Verify claim state
        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Claimed));
        assertEq(order.vm, Actors.VM1);
        assertEq(order.vault, address(vault));
        assertGt(order.claimedAt, 0, "claimedAt set");

        assertEq(usdc.balanceOf(Actors.VM1), netToVM, "VM received net stablecoins");
        assertEq(usdc.balanceOf(address(market)), fee, "fee escrowed in market");

        vm.warp(expiry + 1);

        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), netToVM);
        market.closeOrder(orderId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "user refunded fully");
        assertEq(usdc.balanceOf(address(market)), 0, "market escrow cleared");

        order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Closed));
    }

    // ══════════════════════════════════════════════════════════
    //  Close order — redeem (eTokens returned after expiry)
    // ══════════════════════════════════════════════════════════

    function test_closeOrder_redeem_fullFlow() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, expiry);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "minter eTokens escrowed");
        assertEq(eTSLA.balanceOf(address(market)), ETOKEN_AMOUNT, "eTokens in market");

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        assertEq(eTSLA.balanceOf(address(market)), ETOKEN_AMOUNT, "eTokens still in escrow after claim");

        vm.warp(expiry + 1);

        vm.prank(Actors.VM1);
        market.closeOrder(orderId);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned");
        assertEq(eTSLA.balanceOf(address(market)), 0, "market escrow cleared");
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — claimed mint, price NOT reachable
    //  User gets WETH collateral from vault + escrowed fee returned
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_claimedMint_priceNotReachable() public {
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 fee = _mintFee(MINT_AMOUNT);

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 userWethBefore = weth.balanceOf(Actors.MINTER1);

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", "");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.ForceExecuted));

        // Calculate expected collateral: usdValue (18 decimals) / ethPrice
        uint256 usdValue = MINT_AMOUNT * 1e12; // scale 6-decimal USDC to 18
        uint256 expectedCollateral = Math.mulDiv(usdValue, PRECISION, ETH_PRICE);

        // User receives WETH collateral from vault
        assertEq(weth.balanceOf(Actors.MINTER1), userWethBefore + expectedCollateral, "user received WETH collateral");
        assertEq(weth.balanceOf(address(vault)), vaultWethBefore - expectedCollateral, "vault released WETH");

        // Escrowed fee returned as USDC
        assertEq(usdc.balanceOf(Actors.MINTER1), fee, "escrowed fee returned");
        assertEq(usdc.balanceOf(address(market)), 0, "market escrow cleared");
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — claimed redeem, price NOT reachable
    //  eTokens returned to user
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_claimedRedeem_priceNotReachable() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "eTokens escrowed");

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", "");

        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned");
        assertEq(eTSLA.balanceOf(address(market)), 0, "market escrow cleared");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.ForceExecuted));
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — unclaimed redeem (claim threshold)
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_unclaimedRedeem() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, expiry);

        assertEq(eTSLA.balanceOf(address(market)), ETOKEN_AMOUNT, "eTokens escrowed");

        vm.warp(block.timestamp + CLAIM_THRESHOLD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", "");

        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned");
        assertEq(eTSLA.balanceOf(address(market)), 0, "market escrow cleared");

        // Verify no exposure was tracked (order was never claimed)
        assertEq(vault.totalExposure(), 0, "no exposure for unclaimed");
    }

    // ══════════════════════════════════════════════════════════
    //  Fee flow — mint (exact 3-way split + claim all)
    // ══════════════════════════════════════════════════════════

    function test_feeFlow_mint_threWaySplit() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        uint256 totalFee = _mintFee(MINT_AMOUNT);

        // Exact 3-way split
        uint256 protocolAmount = Math.mulDiv(totalFee, 2000, BPS, Math.Rounding.Ceil);
        uint256 remainder = totalFee - protocolAmount;
        uint256 vmAmount = Math.mulDiv(remainder, 2000, BPS);
        uint256 lpAmount = remainder - vmAmount;

        assertEq(vault.accruedProtocolFees(), protocolAmount, "protocol fees exact");
        assertEq(vault.accruedVMFees(), vmAmount, "VM fees exact");
        assertEq(vault.claimableLPRewards(Actors.LP1), lpAmount, "LP rewards exact");

        // Verify total adds up
        assertEq(protocolAmount + vmAmount + lpAmount, totalFee, "fee split sums to total");

        // Claim and verify balances
        uint256 treasuryBefore = usdc.balanceOf(Actors.FEE_RECIPIENT);
        vault.claimProtocolFees();
        assertEq(usdc.balanceOf(Actors.FEE_RECIPIENT), treasuryBefore + protocolAmount, "treasury received");

        uint256 vmBefore = usdc.balanceOf(Actors.VM1);
        vm.prank(Actors.VM1);
        vault.claimVMFees();
        assertEq(usdc.balanceOf(Actors.VM1), vmBefore + vmAmount, "VM received");

        vm.prank(Actors.LP1);
        vault.claimLPRewards();
        assertEq(usdc.balanceOf(Actors.LP1), lpAmount, "LP received");
    }

    // ══════════════════════════════════════════════════════════
    //  Fee flow — redeem (exact split)
    // ══════════════════════════════════════════════════════════

    function test_feeFlow_redeem_threWaySplit() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 grossPayout = _redeemGrossPayout(ETOKEN_AMOUNT);
        _fundUSDC(Actors.VM1, grossPayout);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), grossPayout);
        market.confirmOrder(orderId);
        vm.stopPrank();

        uint256 totalFee = Math.mulDiv(grossPayout, REDEEM_FEE_BPS, BPS, Math.Rounding.Ceil);

        // Exact split verification
        uint256 protocolAmount = Math.mulDiv(totalFee, 2000, BPS, Math.Rounding.Ceil);
        uint256 remainder = totalFee - protocolAmount;
        uint256 vmAmount = Math.mulDiv(remainder, 2000, BPS);
        uint256 lpAmount = remainder - vmAmount;

        assertEq(vault.accruedProtocolFees(), protocolAmount, "protocol fees exact");
        assertEq(vault.accruedVMFees(), vmAmount, "VM fees exact");
        assertEq(vault.claimableLPRewards(Actors.LP1), lpAmount, "LP rewards exact");
        assertEq(protocolAmount + vmAmount + lpAmount, totalFee, "fee split sums to total");

        // User received net payout
        assertEq(usdc.balanceOf(Actors.MINTER1), grossPayout - totalFee, "user received net payout");
    }

    // ══════════════════════════════════════════════════════════
    //  Payment token swap
    // ══════════════════════════════════════════════════════════

    function test_paymentTokenSwap_fullFlow() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);
        vm.prank(Actors.VM1);
        market.claimOrder(orderId);
        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        vm.prank(Actors.VM1);
        vm.expectRevert(IOwnVault.OutstandingFeesExist.selector);
        vault.setPaymentToken(address(usdt));

        vault.claimProtocolFees();
        vm.prank(Actors.VM1);
        vault.claimVMFees();

        vm.prank(Actors.VM1);
        vault.setPaymentToken(address(usdt));
        assertEq(vault.paymentToken(), address(usdt));
    }

    // ══════════════════════════════════════════════════════════
    //  Withdrawal wait period
    // ══════════════════════════════════════════════════════════

    function test_withdrawalWaitPeriod_integration() public {
        vm.prank(Actors.ADMIN);
        vault.setWithdrawalWaitPeriod(2 days);

        uint256 shares = vault.balanceOf(Actors.LP1);
        assertGt(shares, 0, "LP has shares");

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        uint256 readyAt = block.timestamp + 2 days;
        vm.expectRevert(
            abi.encodeWithSelector(IOwnVault.WithdrawalWaitPeriodNotElapsed.selector, requestId, readyAt)
        );
        vault.fulfillWithdrawal(requestId);

        vm.warp(block.timestamp + 2 days + 1);
        uint256 wethBefore = weth.balanceOf(Actors.LP1);
        uint256 assets = vault.fulfillWithdrawal(requestId);

        assertEq(assets, LP_DEPOSIT_WETH, "correct withdrawal amount");
        assertEq(weth.balanceOf(Actors.LP1), wethBefore + LP_DEPOSIT_WETH, "LP received WETH");
        assertEq(vault.balanceOf(Actors.LP1), 0, "LP shares burned");
    }

    // ══════════════════════════════════════════════════════════
    //  Exact eToken minting math
    // ══════════════════════════════════════════════════════════

    function test_mint_eTokenAmount_correctAtSetPrice() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        uint256 fee = _mintFee(MINT_AMOUNT);
        uint256 net = MINT_AMOUNT - fee;
        uint256 expectedETokens = Math.mulDiv(net * 1e12, PRECISION, TSLA_PRICE);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "exact eToken amount");
        assertGt(expectedETokens, 0, "non-zero eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  Exact redeem payout math
    // ══════════════════════════════════════════════════════════

    function test_redeem_stablecoinAmount_correctAtSetPrice() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 grossPayout = _redeemGrossPayout(ETOKEN_AMOUNT);
        uint256 fee = Math.mulDiv(grossPayout, REDEEM_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 netToUser = grossPayout - fee;

        _fundUSDC(Actors.VM1, grossPayout);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), grossPayout);
        market.confirmOrder(orderId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.MINTER1), netToUser, "exact stablecoin payout");
        assertEq(eTSLA.balanceOf(address(market)), 0, "eTokens burned");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "minter has no eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  Exposure tracking — claim + confirm
    // ══════════════════════════════════════════════════════════

    function test_exposureTracking_claimConfirm() public {
        assertEq(vault.totalExposure(), 0, "initial exposure = 0");

        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 expectedExposure = MINT_AMOUNT; // mint exposure = stablecoin amount
        assertEq(vault.totalExposure(), expectedExposure, "exposure = mint amount");

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        assertEq(vault.totalExposure(), 0, "exposure back to 0");
    }

    // ══════════════════════════════════════════════════════════
    //  Exposure tracking — claim + close
    // ══════════════════════════════════════════════════════════

    function test_exposureTracking_claimClose() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        assertEq(vault.totalExposure(), MINT_AMOUNT, "exposure after claim");

        vm.warp(expiry + 1);

        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), MINT_AMOUNT);
        market.closeOrder(orderId);
        vm.stopPrank();

        assertEq(vault.totalExposure(), 0, "exposure back to 0 after close");
    }

    // ══════════════════════════════════════════════════════════
    //  Exposure tracking — claim + force execute
    // ══════════════════════════════════════════════════════════

    function test_exposureTracking_claimForceExecute() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 7 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        assertEq(vault.totalExposure(), MINT_AMOUNT, "exposure after claim");

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", "");

        assertEq(vault.totalExposure(), 0, "exposure back to 0 after force");
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: double-claim reverts
    // ══════════════════════════════════════════════════════════

    function test_doubleClaim_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Claimed));
        market.claimOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: double-confirm reverts
    // ══════════════════════════════════════════════════════════

    function test_doubleConfirm_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        vm.prank(Actors.VM1);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Confirmed)
        );
        market.confirmOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: force execute on already closed order
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_closedOrder_reverts() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.warp(expiry + 1);

        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), MINT_AMOUNT);
        market.closeOrder(orderId);
        vm.stopPrank();

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Closed));
        market.forceExecute(orderId, "", "");
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: force execute on expired (unclaimed) order
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_expiredOrder_reverts() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.warp(expiry + 1);
        market.expireOrder(orderId);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Expired));
        market.forceExecute(orderId, "", "");
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: cancel after claim reverts
    // ══════════════════════════════════════════════════════════

    function test_cancelAfterClaim_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Claimed));
        market.cancelOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: expire claimed order reverts (must use close)
    // ══════════════════════════════════════════════════════════

    function test_expireClaimed_reverts() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.warp(expiry + 1);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Claimed));
        market.expireOrder(orderId);
    }
}
