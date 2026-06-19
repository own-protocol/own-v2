// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
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

    uint256 constant MAX_EXPOSURE = 10_000_000e18;
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT_WETH = 50_000e18;
    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant ETOKEN_AMOUNT = 40e18;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configureVault();
        _depositLPCollateral();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(address(protocolRegistry));
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

        _setClaimThreshold(CLAIM_THRESHOLD);
        _setForceExecuteVault(address(vault));
        _registerSigner(vm1Signer, Actors.VM1);
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
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

        // Per-asset issuance ceiling (global util default is set by _deployVaultManager).
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);
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

        // Seed the manager's marks: collateral and asset price.
        _pullCollateralPrice(address(vault));
        _pullAssetPrice(TSLA);
    }

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, amount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _placeRedeem(address minter, uint256 eAmount, uint256 expiry) internal returns (uint256) {
        vm.startPrank(minter);
        eTSLA.approve(address(market), eAmount);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Redeem, eAmount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    /// @dev Fill a resting mint order in full with a VM-signed quote.
    function _fillMint(uint256 orderId, address minter, uint256 amount) internal {
        Quote memory q = _buildQuote(orderId, minter, TSLA, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(vm1Signer);
        market.fillOrder(q, sig);
    }

    /// @dev Fill a resting redeem order in full with a VM-signed quote. The signer's linked
    ///      address funds the payout.
    function _fillRedeem(uint256 orderId, address minter, uint256 eAmount) internal {
        uint256 grossPayout = _redeemGrossPayout(eAmount);
        _fundUSDC(Actors.VM1, grossPayout);
        vm.prank(Actors.VM1);
        usdc.approve(address(market), grossPayout);
        Quote memory q = _buildQuote(orderId, minter, TSLA, OrderType.Redeem, eAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(vm1Signer);
        market.fillOrder(q, sig);
    }

    /// @dev Mint eTokens to `minter` via a market mint settled against a VM-signed quote.
    function _mintETokensViaFlow(address minter, uint256 usdcAmount) internal {
        _fundUSDC(minter, usdcAmount);
        vm.prank(minter);
        usdc.approve(address(market), usdcAmount);
        Quote memory q = _buildQuote(0, minter, TSLA, OrderType.Mint, usdcAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(minter);
        market.executeOrder(q, sig);
    }

    function _redeemGrossPayout(
        uint256 eAmount
    ) internal pure returns (uint256) {
        return Math.mulDiv(eAmount, TSLA_PRICE, PRECISION * 1e12);
    }

    // removed: closeOrder (mint & redeem) no longer exists in the RFQ model — resting
    // orders are recovered via cancel / expire, and there is no VM-driven claimed-order close.

    // ══════════════════════════════════════════════════════════
    //  Force execute — redeem, releases collateral at oracle price
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_redeem_releasesCollateral() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        // Limit = the price the user wants; force execution settles at this limit (the proof only
        // proves the limit was reachable in the window).
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), eTokenBal);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Redeem, eTokenBal, TSLA_PRICE, block.timestamp + 7 days);
        vm.stopPrank();

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 userWethBefore = weth.balanceOf(Actors.MINTER1);
        uint256 markBefore = vaultManager.collateralMark(address(vault));

        vm.warp(block.timestamp + CLAIM_THRESHOLD + 1);

        bytes memory assetPriceData = abi.encode(uint256(TSLA_PRICE), uint256(block.timestamp));
        bytes memory collateralPriceData = abi.encode(uint256(ETH_PRICE), uint256(block.timestamp));

        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, address(vault), assetPriceData, collateralPriceData);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.ForceExecuted));

        // Collateral released = (eTokens * limitPrice / PRECISION) / ETH_PRICE (no fee).
        // limitPrice == TSLA_PRICE here, so the figure matches the order's settle-at-limit value.
        uint256 grossUsd = Math.mulDiv(eTokenBal, TSLA_PRICE, PRECISION);
        uint256 grossCollateral = Math.mulDiv(grossUsd, PRECISION, ETH_PRICE);

        assertEq(weth.balanceOf(Actors.MINTER1), userWethBefore + grossCollateral, "user received WETH collateral");
        assertEq(weth.balanceOf(address(vault)), vaultWethBefore - grossCollateral, "vault released WETH");
        // H-03: the cached collateral mark is synced down as collateral leaves (no stale window).
        assertLt(vaultManager.collateralMark(address(vault)), markBefore, "mark synced down on release");
        assertEq(eTSLA.balanceOf(address(market)), 0, "escrowed eTokens burned");
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — mint order is not allowed
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_mintOrder_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 7 days);

        vm.warp(block.timestamp + CLAIM_THRESHOLD + 1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ForceMintNotAllowed.selector, orderId));
        market.forceExecuteOrder(orderId, address(vault), "", "");
    }

    // ══════════════════════════════════════════════════════════
    //  Force execute — before the claim window reverts
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_beforeWindow_reverts() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        uint256 orderId = _placeRedeem(Actors.MINTER1, eTokenBal, block.timestamp + 7 days);

        bytes memory assetPriceData = abi.encode(uint256(TSLA_PRICE), uint256(block.timestamp));
        bytes memory collateralPriceData = abi.encode(uint256(ETH_PRICE), uint256(block.timestamp));

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ForceWindowNotElapsed.selector, orderId));
        market.forceExecuteOrder(orderId, address(vault), assetPriceData, collateralPriceData);
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
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.WithdrawalWaitPeriodNotElapsed.selector, requestId, readyAt));
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
        _fillMint(orderId, Actors.MINTER1, MINT_AMOUNT);

        uint256 expectedETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), expectedETokens, "exact eToken amount");
        assertGt(expectedETokens, 0, "non-zero eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  Exact redeem payout math
    // ══════════════════════════════════════════════════════════

    function test_redeem_stablecoinAmount_correctAtSetPrice() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        uint256 orderId = _placeRedeem(Actors.MINTER1, eTokenBal, block.timestamp + 1 days);

        uint256 grossPayout = _redeemGrossPayout(eTokenBal);

        _fillRedeem(orderId, Actors.MINTER1, eTokenBal);

        assertEq(usdc.balanceOf(Actors.MINTER1), grossPayout, "exact stablecoin payout");
        assertEq(eTSLA.balanceOf(address(market)), 0, "eTokens burned");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "minter has no eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  Exposure tracking — escrow then fill
    // ══════════════════════════════════════════════════════════

    function test_exposureTracking_placeThenFill() public {
        assertEq(vaultManager.globalExposureUSD(), 0, "initial exposure = 0");

        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        // Escrow alone does not add exposure
        assertEq(vaultManager.globalExposureUSD(), 0, "exposure unchanged after placement");

        // Fill mint → exposure increases
        _fillMint(orderId, Actors.MINTER1, MINT_AMOUNT);

        // exposureUSD = eTokenUnits * TSLA_PRICE / PRECISION (no fee; full amount minted)
        uint256 eTokenUnits = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        uint256 expectedExposure = Math.mulDiv(eTokenUnits, TSLA_PRICE, PRECISION);
        assertEq(vaultManager.globalExposureUSD(), expectedExposure, "exposure = minted notional after fill");
    }

    // ══════════════════════════════════════════════════════════
    //  Exposure tracking — cancel leaves exposure untouched
    // ══════════════════════════════════════════════════════════

    function test_exposureTracking_cancel() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        assertEq(vaultManager.globalExposureUSD(), 0, "exposure unchanged after placement");

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        // Cancel returns escrow — nothing was executed
        assertEq(vaultManager.globalExposureUSD(), 0, "exposure still 0 after cancel");
    }

    // ══════════════════════════════════════════════════════════
    //  Exposure tracking — redeem force execute decreases exposure
    // ══════════════════════════════════════════════════════════

    function test_exposureTracking_redeemForceExecute() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        assertGt(vaultManager.globalExposureUSD(), 0, "exposure from mint");

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), eTokenBal);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Redeem, eTokenBal, TSLA_PRICE, block.timestamp + 7 days);
        vm.stopPrank();

        vm.warp(block.timestamp + CLAIM_THRESHOLD + 1);

        bytes memory assetPriceData = abi.encode(uint256(TSLA_PRICE), uint256(block.timestamp));
        bytes memory collateralPriceData = abi.encode(uint256(ETH_PRICE), uint256(block.timestamp));

        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, address(vault), assetPriceData, collateralPriceData);

        // Force execution burns the eTokens and shrinks exposure back to zero.
        assertEq(vaultManager.globalExposureUSD(), 0, "exposure cleared after force execution");
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: filling an already-filled order reverts
    // ══════════════════════════════════════════════════════════

    function test_fillAlreadyFilled_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);
        _fillMint(orderId, Actors.MINTER1, MINT_AMOUNT);

        Quote memory q = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(vm1Signer);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId));
        market.fillOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: replaying a market quote reverts
    // ══════════════════════════════════════════════════════════

    function test_marketQuoteReplay_reverts() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT * 2);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT * 2);

        Quote memory q = _buildQuote(0, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.QuoteAlreadyUsed.selector);
        market.executeOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: cancel after full fill reverts
    // ══════════════════════════════════════════════════════════

    function test_cancelAfterFill_reverts() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);
        _fillMint(orderId, Actors.MINTER1, MINT_AMOUNT);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId));
        market.cancelOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Edge case: force execute on an expired redeem order reverts
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_expiredOrder_reverts() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeRedeem(Actors.MINTER1, eTokenBal, expiry);

        vm.warp(expiry + 1);
        market.expireOrder(orderId);

        bytes memory assetPriceData = abi.encode(uint256(TSLA_PRICE), uint256(block.timestamp));
        bytes memory collateralPriceData = abi.encode(uint256(ETH_PRICE), uint256(block.timestamp));

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId));
        market.forceExecuteOrder(orderId, address(vault), assetPriceData, collateralPriceData);
    }

    // ══════════════════════════════════════════════════════════
    //  Partial fill — mint order filled in two chunks
    // ══════════════════════════════════════════════════════════

    function test_partialFill_mint_twoChunks() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        uint256 firstChunk = MINT_AMOUNT * 6 / 10;
        Quote memory q1 = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Mint, firstChunk, TSLA_PRICE);
        vm.prank(vm1Signer);
        market.fillOrder(q1, _signQuote(market, q1, vm1SignerPk));

        Order memory o1 = market.getOrder(orderId);
        assertEq(o1.filledAmount, firstChunk, "first chunk recorded");
        assertEq(uint8(o1.status), uint8(OrderStatus.Open), "still open after partial fill");

        uint256 secondChunk = MINT_AMOUNT - firstChunk;
        Quote memory q2 = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Mint, secondChunk, TSLA_PRICE);
        vm.prank(vm1Signer);
        market.fillOrder(q2, _signQuote(market, q2, vm1SignerPk));

        Order memory o2 = market.getOrder(orderId);
        assertEq(o2.filledAmount, MINT_AMOUNT, "fully filled");
        assertEq(uint8(o2.status), uint8(OrderStatus.Filled), "order filled");

        // No fee: VM receives the full amount across both fills.
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT, "linked address received both fills");
    }
}
