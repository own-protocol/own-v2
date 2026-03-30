// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {
    AssetConfig,
    BPS,
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
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OrderLifecycle Integration Test
/// @notice Tests all order paths end-to-end with real contracts:
///         close, force-execute, fees, payment token swap, withdrawal wait period.
contract OrderLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;
    FeeCalculator public feeCalc;

    uint256 constant MAX_EXPOSURE = 10_000_000e18;
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT = 1_000_000e6;
    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant ETOKEN_AMOUNT = 40e18; // 10000 / 250 = 40
    uint256 constant GRACE_PERIOD = 1 days;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    // Fee config: 1% mint, 0.5% redeem
    uint256 constant MINT_FEE_BPS = 100;
    uint256 constant REDEEM_FEE_BPS = 50;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configureVaultManager();
        _depositLPCollateral();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        // Set fees for volatility level 2
        feeCalc.setMintFee(2, MINT_FEE_BPS);
        feeCalc.setRedeemFee(2, REDEEM_FEE_BPS);
        // Zero fees for other levels
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));

        // protocolShareBps=20%, vmShareBps=20% of remainder
        vault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC",
            address(protocolRegistry), Actors.VM1, MAX_UTIL_BPS, 2000, 2000
        );

        market = new OwnMarket(address(protocolRegistry), address(vault), GRACE_PERIOD, CLAIM_THRESHOLD);

        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        vm.stopPrank();
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaConfig =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        vm.stopPrank();
    }

    function _configureVaultManager() private {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(vault));
        vaultMgr.setExposureCaps(MAX_EXPOSURE);
        vault.setPaymentToken(address(usdc));
        vm.stopPrank();
    }

    function _depositLPCollateral() private {
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    /// @dev Helper: place mint order and return orderId
    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeMintOrder(TSLA, amount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    /// @dev Helper: place redeem order (minter must have eTokens)
    function _placeRedeem(address minter, uint256 eAmount, uint256 expiry) internal returns (uint256) {
        vm.startPrank(minter);
        eTSLA.approve(address(market), eAmount);
        uint256 orderId = market.placeRedeemOrder(TSLA, eAmount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    /// @dev Helper: mint eTokens to a user directly (for redeem test setup)
    function _mintETokens(address to, uint256 amount) internal {
        vm.prank(address(market));
        eTSLA.mint(to, amount);
    }

    // ══════════════════════════════════════════════════════════
    //  Close order — mint (VM returns stablecoins after expiry)
    // ══════════════════════════════════════════════════════════

    function test_closeOrder_mint_fullFlow() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        // VM claims — gets stablecoins minus fee
        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 feeAmount = Math.mulDiv(MINT_AMOUNT, MINT_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 netToVM = MINT_AMOUNT - feeAmount;
        assertEq(usdc.balanceOf(Actors.VM1), netToVM, "VM received net stablecoins");

        // Warp past expiry
        vm.warp(expiry + 1);

        // VM closes — returns net stablecoins to user
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), netToVM);
        market.closeOrder(orderId);
        vm.stopPrank();

        // User gets full amount back (net from VM + fee from escrow)
        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "user refunded fully");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Closed));
    }

    // ══════════════════════════════════════════════════════════
    //  Close order — redeem (eTokens returned after expiry)
    // ══════════════════════════════════════════════════════════

    function test_closeOrder_redeem_fullFlow() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        // eTokens still in escrow
        assertEq(eTSLA.balanceOf(address(market)), ETOKEN_AMOUNT);

        vm.warp(expiry + 1);

        vm.prank(Actors.VM1);
        market.closeOrder(orderId);

        // eTokens returned to user
        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned");
        assertEq(eTSLA.balanceOf(address(market)), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — claimed mint (grace period, stub returns price not reachable)
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_claimedMint_priceNotReachable() public {
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 feeAmount = Math.mulDiv(MINT_AMOUNT, MINT_FEE_BPS, BPS, Math.Rounding.Ceil);

        // Warp past grace period
        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        // Force execute — stub returns priceNotReachable=false
        // For mint+price not reachable: user should get collateral (TODO in impl)
        // Currently: escrowed fee returned to user
        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.ForceExecuted));

        // Fee returned to user
        assertEq(usdc.balanceOf(Actors.MINTER1), feeAmount, "escrowed fee returned");
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — claimed redeem (grace period, price not reachable → eTokens returned)
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_claimedRedeem_priceNotReachable() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "");

        // eTokens returned to user
        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned");
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — unclaimed redeem (claim threshold)
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_unclaimedRedeem() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, expiry);

        // VM never claims. Warp past claim threshold.
        vm.warp(block.timestamp + CLAIM_THRESHOLD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "");

        // eTokens returned (price not reachable stub)
        assertEq(eTSLA.balanceOf(Actors.MINTER1), ETOKEN_AMOUNT, "eTokens returned");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.ForceExecuted));
    }

    // ══════════════════════════════════════════════════════════
    //  Fee flow end-to-end (mint with fees → 3-way split → claim)
    // ══════════════════════════════════════════════════════════

    function test_feeFlow_mint_threWaySplit() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        // Fee = 10000e6 * 100 / 10000 = 100e6
        uint256 totalFee = Math.mulDiv(MINT_AMOUNT, MINT_FEE_BPS, BPS, Math.Rounding.Ceil);

        // 3-way split: protocol=20%, vm=20% of remainder, lp=rest
        uint256 protocolAmount = Math.mulDiv(totalFee, 2000, BPS, Math.Rounding.Ceil);
        uint256 remainder = totalFee - protocolAmount;
        uint256 vmAmount = Math.mulDiv(remainder, 2000, BPS);
        uint256 lpAmount = remainder - vmAmount;

        assertEq(vault.accruedProtocolFees(), protocolAmount, "protocol fees accrued");
        assertEq(vault.accruedVMFees(), vmAmount, "VM fees accrued");

        // LP can claim
        uint256 claimable = vault.claimableLPRewards(Actors.LP1);
        assertEq(claimable, lpAmount, "LP rewards claimable");

        // Claim all fees
        uint256 treasuryBefore = usdc.balanceOf(Actors.FEE_RECIPIENT);
        vault.claimProtocolFees();
        assertEq(usdc.balanceOf(Actors.FEE_RECIPIENT), treasuryBefore + protocolAmount);

        uint256 vmBefore = usdc.balanceOf(Actors.VM1);
        vm.prank(Actors.VM1);
        vault.claimVMFees();
        assertEq(usdc.balanceOf(Actors.VM1), vmBefore + vmAmount);

        vm.prank(Actors.LP1);
        vault.claimLPRewards();
        assertEq(usdc.balanceOf(Actors.LP1), lpAmount);
    }

    // ══════════════════════════════════════════════════════════
    //  Fee flow end-to-end (redeem with fees)
    // ══════════════════════════════════════════════════════════

    function test_feeFlow_redeem_threWaySplit() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);
        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        // VM needs stablecoins for payout
        uint256 grossPayout = Math.mulDiv(ETOKEN_AMOUNT, TSLA_PRICE, PRECISION * 1e12);
        _fundUSDC(Actors.VM1, grossPayout);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), grossPayout);
        market.confirmOrder(orderId);
        vm.stopPrank();

        // Fee = grossPayout * 50 / 10000
        uint256 totalFee = Math.mulDiv(grossPayout, REDEEM_FEE_BPS, BPS, Math.Rounding.Ceil);

        // Verify fees accrued
        uint256 protocolAmount = vault.accruedProtocolFees();
        uint256 vmFees = vault.accruedVMFees();
        assertGt(protocolAmount, 0, "protocol fees > 0");
        assertGt(vmFees, 0, "VM fees > 0");
        assertEq(protocolAmount + vmFees + vault.claimableLPRewards(Actors.LP1), totalFee, "total fee matches");
    }

    // ══════════════════════════════════════════════════════════
    //  Payment token swap (flush fees → swap → new orders in new token)
    // ══════════════════════════════════════════════════════════

    function test_paymentTokenSwap_fullFlow() public {
        // Place and confirm a mint order to accrue fees
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);
        vm.prank(Actors.VM1);
        market.claimOrder(orderId);
        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        // Fees exist — can't swap token yet
        vm.prank(Actors.VM1);
        vm.expectRevert(IOwnVault.OutstandingFeesExist.selector);
        vault.setPaymentToken(address(usdt));

        // Flush protocol + VM fees
        vault.claimProtocolFees();
        vm.prank(Actors.VM1);
        vault.claimVMFees();

        // Now swap works (LP rewards are per-share, not blocking)
        vm.prank(Actors.VM1);
        vault.setPaymentToken(address(usdt));
        assertEq(vault.paymentToken(), address(usdt));
    }

    // ══════════════════════════════════════════════════════════
    //  Withdrawal wait period integration
    // ══════════════════════════════════════════════════════════

    function test_withdrawalWaitPeriod_integration() public {
        // Set 2-day wait period
        vm.prank(Actors.ADMIN);
        vault.setWithdrawalWaitPeriod(2 days);

        // LP requests withdrawal
        uint256 shares = vault.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        // Immediate fulfillment fails
        uint256 readyAt = block.timestamp + 2 days;
        vm.expectRevert(
            abi.encodeWithSelector(IOwnVault.WithdrawalWaitPeriodNotElapsed.selector, requestId, readyAt)
        );
        vault.fulfillWithdrawal(requestId);

        // After wait period
        vm.warp(block.timestamp + 2 days + 1);
        uint256 assets = vault.fulfillWithdrawal(requestId);

        assertEq(assets, LP_DEPOSIT, "LP gets full deposit back");
        assertEq(usdc.balanceOf(Actors.LP1), LP_DEPOSIT);
    }

    // ══════════════════════════════════════════════════════════
    //  Full mint → confirm → eToken balance check
    // ══════════════════════════════════════════════════════════

    function test_mint_eTokenAmount_correctAtSetPrice() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        // eTokens = (netAmount * 1e12 * 1e18) / price
        uint256 fee = Math.mulDiv(MINT_AMOUNT, MINT_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 net = MINT_AMOUNT - fee;
        uint256 expectedETokens = Math.mulDiv(net * 1e12, PRECISION, TSLA_PRICE);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "correct eToken amount at set price");
    }

    // ══════════════════════════════════════════════════════════
    //  Full redeem → confirm → stablecoin balance check
    // ══════════════════════════════════════════════════════════

    function test_redeem_stablecoinAmount_correctAtSetPrice() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);

        uint256 orderId = _placeRedeem(Actors.MINTER1, ETOKEN_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 grossPayout = Math.mulDiv(ETOKEN_AMOUNT, TSLA_PRICE, PRECISION * 1e12);
        uint256 fee = Math.mulDiv(grossPayout, REDEEM_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 netToUser = grossPayout - fee;

        _fundUSDC(Actors.VM1, grossPayout);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), grossPayout);
        market.confirmOrder(orderId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.MINTER1), netToUser, "correct stablecoin payout at set price");
        assertEq(eTSLA.balanceOf(address(market)), 0, "eTokens burned");
    }

    // ══════════════════════════════════════════════════════════
    //  Exposure tracking through full lifecycle
    // ══════════════════════════════════════════════════════════

    function test_exposureTracking_claimConfirm() public {
        assertEq(vaultMgr.getVMConfig(Actors.VM1).currentExposure, 0, "initial exposure = 0");

        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        // Exposure should increase after claim
        assertGt(vaultMgr.getVMConfig(Actors.VM1).currentExposure, 0, "exposure increased on claim");

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        // Exposure should return to 0 after confirm
        assertEq(vaultMgr.getVMConfig(Actors.VM1).currentExposure, 0, "exposure back to 0 after confirm");
    }

    function test_exposureTracking_claimClose() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 exposureAfterClaim = vaultMgr.getVMConfig(Actors.VM1).currentExposure;
        assertGt(exposureAfterClaim, 0);

        vm.warp(expiry + 1);

        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), MINT_AMOUNT);
        market.closeOrder(orderId);
        vm.stopPrank();

        assertEq(vaultMgr.getVMConfig(Actors.VM1).currentExposure, 0, "exposure back to 0 after close");
    }
}
