// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {
    AssetConfig,
    BPS,
    OracleConfig,
    Order,
    OrderStatus,
    OrderType,
    PRECISION,
    VaultStatus
} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title HaltWithPriceFlow Integration Test
/// @notice Tests HALT-WITH-PRICE functionality of OwnVault + OwnMarket: mint blocking,
///         redeem settlement at halt price, force execution refunds, cancel during halt,
///         LP deposit blocking, LP withdrawal, unhalt resume, per-asset scope, and edge cases.
contract HaltWithPriceFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;
    EToken public eGOLD;
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

    uint256 constant HALT_PRICE = 200e18;

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
        feeCalc.setMintFee(2, MINT_FEE_BPS);
        feeCalc.setRedeemFee(2, REDEEM_FEE_BPS);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        vault = OwnVault(factory.createVault(address(weth), Actors.VM1, "Own ETH Vault", "oETH", MAX_UTIL_BPS, 2000));

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
        OracleConfig memory tslaOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(TSLA, tslaOracleConfig);

        eGOLD = new EToken("Own Gold", "eGOLD", GOLD, address(protocolRegistry), address(usdc));
        AssetConfig memory goldConfig =
            AssetConfig({activeToken: address(eGOLD), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(GOLD, address(eGOLD), goldConfig);
        OracleConfig memory goldOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(GOLD, goldOracleConfig);

        bytes32 ethAsset = bytes32("ETH");
        AssetConfig memory ethConfig =
            AssetConfig({activeToken: address(weth), legacyTokens: new address[](0), active: true, volatilityLevel: 1});
        assetRegistry.addAsset(ethAsset, address(weth), ethConfig);
        OracleConfig memory ethOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(ethAsset, ethOracleConfig);
        vault.setCollateralOracleAsset(ethAsset);

        vm.stopPrank();

        _setOraclePrice(ethAsset, ETH_PRICE);
    }

    function _configureVault() private {
        vm.startPrank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vault.enableAsset(GOLD);
        vm.stopPrank();

        // Initialize asset and collateral valuations so exposure tracking works
        vault.updateAssetValuation(TSLA);
        vault.updateAssetValuation(GOLD);
        vault.updateCollateralValuation();
    }

    function _depositLPCollateral() private {
        _fundWETH(Actors.VM1, LP_DEPOSIT_WETH);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, amount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _placeMintForAsset(
        address minter,
        bytes32 asset,
        uint256 amount,
        uint256 price,
        uint256 expiry
    ) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeMintOrder(address(vault), asset, amount, price, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _placeRedeem(address minter, uint256 eAmount, uint256 expiry) internal returns (uint256) {
        vm.startPrank(minter);
        eTSLA.approve(address(market), eAmount);
        uint256 orderId = market.placeRedeemOrder(address(vault), TSLA, eAmount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _mintETokensViaFlow(address minter, uint256 usdcAmount) internal {
        _fundUSDC(minter, usdcAmount);
        vm.startPrank(minter);
        usdc.approve(address(market), usdcAmount);
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, usdcAmount, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
        vm.prank(Actors.VM1);
        market.claimOrder(orderId);
        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);
    }

    function _haltAssetTSLA() private {
        vm.prank(Actors.ADMIN);
        vault.haltAsset(TSLA, HALT_PRICE);
    }

    function _haltVaultWithPrice() private {
        vm.startPrank(Actors.ADMIN);
        vault.haltAsset(TSLA, HALT_PRICE);
        vault.haltVault();
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  1. Halt blocks mint placement
    // ══════════════════════════════════════════════════════════

    function test_halt_blocksMintPlacement() public {
        _haltAssetTSLA();

        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.placeMintOrder(address(vault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  2. Halt blocks mint claim
    // ══════════════════════════════════════════════════════════

    function test_halt_blocksMintClaim() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        _haltAssetTSLA();

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.claimOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  3. Halt blocks mint confirm
    // ══════════════════════════════════════════════════════════

    function test_halt_blocksMintConfirm() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        _haltAssetTSLA();

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.confirmOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  4. Halt allows redeem placement
    // ══════════════════════════════════════════════════════════

    function test_halt_allowsRedeemPlacement() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        _haltAssetTSLA();

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), eTokenBal);
        uint256 orderId = market.placeRedeemOrder(address(vault), TSLA, eTokenBal, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Open), "redeem order placed during halt");
    }

    // ══════════════════════════════════════════════════════════
    //  5. Halt allows redeem claim
    // ══════════════════════════════════════════════════════════

    function test_halt_allowsRedeemClaim() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        uint256 orderId = _placeRedeem(Actors.MINTER1, eTokenBal, block.timestamp + 1 days);

        _haltAssetTSLA();

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Claimed), "redeem order claimed during halt");
    }

    // ══════════════════════════════════════════════════════════
    //  6. Redeem confirm uses halt price
    // ══════════════════════════════════════════════════════════

    function test_halt_redeemConfirmUsesHaltPrice() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        uint256 orderId = _placeRedeem(Actors.MINTER1, eTokenBal, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        _haltAssetTSLA();

        // Calculate payout at halt price (not order price)
        uint256 grossPayout = Math.mulDiv(eTokenBal, HALT_PRICE, PRECISION * 1e12);
        uint256 fee = Math.mulDiv(grossPayout, REDEEM_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 netPayout = grossPayout - fee;

        // VM must fund and approve grossPayout of USDC
        _fundUSDC(Actors.VM1, grossPayout);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), grossPayout);

        vm.expectEmit(true, true, true, true);
        emit IOwnMarket.OrderConfirmedAtHaltPrice(orderId, Actors.VM1, HALT_PRICE, eTokenBal);

        market.confirmOrder(orderId);
        vm.stopPrank();

        // User received net payout at halt price
        assertEq(usdc.balanceOf(Actors.MINTER1), netPayout, "user received net payout at halt price");

        // eTokens burned
        assertEq(eTSLA.balanceOf(address(market)), 0, "eTokens burned from market");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed), "order confirmed");
    }

    // ══════════════════════════════════════════════════════════
    //  7. Claimed mint close — no expiry wait during halt
    // ══════════════════════════════════════════════════════════

    function test_halt_claimedMintCloseNoExpiryWait() public {
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 fee = Math.mulDiv(MINT_AMOUNT, MINT_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 netToVM = MINT_AMOUNT - fee;

        _haltAssetTSLA();

        // Close immediately — no warp to expiry needed
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), netToVM);
        market.closeOrder(orderId);
        vm.stopPrank();

        // User gets full refund (net from VM + escrowed fee)
        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "user refunded fully");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Closed), "order closed");
    }

    // ══════════════════════════════════════════════════════════
    //  8. Claimed mint force execute — refund during halt
    // ══════════════════════════════════════════════════════════

    function test_halt_claimedMintForceExecuteRefund() public {
        uint256 expiry = block.timestamp + 7 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 fee = Math.mulDiv(MINT_AMOUNT, MINT_FEE_BPS, BPS, Math.Rounding.Ceil);

        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 userWethBefore = weth.balanceOf(Actors.MINTER1);

        _haltAssetTSLA();

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        bytes memory collateralPriceData = abi.encode(uint256(ETH_PRICE), uint256(block.timestamp));

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", collateralPriceData);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.ForceExecuted), "order force executed");

        // Calculate expected collateral: net amount converted to WETH
        uint256 usdValue = (MINT_AMOUNT - fee) * 1e12; // scale 6-decimal USDC to 18
        uint256 expectedCollateral = Math.mulDiv(usdValue, PRECISION, ETH_PRICE);

        // User receives WETH collateral from vault
        assertEq(weth.balanceOf(Actors.MINTER1), userWethBefore + expectedCollateral, "user received WETH collateral");
        assertEq(weth.balanceOf(address(vault)), vaultWethBefore - expectedCollateral, "vault released WETH");

        // Escrowed fee returned as USDC
        assertEq(usdc.balanceOf(Actors.MINTER1), fee, "escrowed fee returned");
        assertEq(usdc.balanceOf(address(market)), 0, "market escrow cleared");
    }

    // ══════════════════════════════════════════════════════════
    //  9. Halt allows cancel (user gets stablecoins back)
    // ══════════════════════════════════════════════════════════

    function test_halt_allowsCancel() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        _haltAssetTSLA();

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "user got stablecoins back");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Cancelled), "order cancelled");
    }

    // ══════════════════════════════════════════════════════════
    //  10. Halt blocks LP deposit
    // ══════════════════════════════════════════════════════════

    function test_halt_blocksLPDeposit() public {
        _haltVaultWithPrice();

        _fundWETH(Actors.VM1, 1000e18);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 1000e18);
        vm.expectRevert(IOwnVault.VaultIsHalted.selector);
        vault.deposit(1000e18, Actors.LP2);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  11. Halt allows LP withdrawal
    // ══════════════════════════════════════════════════════════

    function test_halt_allowsLPWithdrawal() public {
        _haltVaultWithPrice();

        uint256 shares = vault.balanceOf(Actors.LP1);
        assertGt(shares, 0, "LP has shares");

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares / 2);
        assertGt(requestId, 0, "withdrawal requested");

        // Unhalt to fulfill (fulfillWithdrawal may require active state)
        vm.prank(Actors.ADMIN);
        vault.unhalt();

        uint256 wethBefore = weth.balanceOf(Actors.LP1);
        vault.fulfillWithdrawal(requestId);
        uint256 wethAfter = weth.balanceOf(Actors.LP1);

        assertGt(wethAfter - wethBefore, 0, "LP received WETH");
    }

    // ══════════════════════════════════════════════════════════
    //  12. Unhalt resumes trading
    // ══════════════════════════════════════════════════════════

    function test_halt_unhaltResumesTrading() public {
        _haltVaultWithPrice();

        vm.startPrank(Actors.ADMIN);
        vault.unhalt();
        vault.unhaltAsset(TSLA);
        vm.stopPrank();

        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Active), "vault active after unhalt");

        // Place + claim + confirm mint succeeds
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed), "mint confirmed after unhalt");
        assertGt(eTSLA.balanceOf(Actors.MINTER1), 0, "minter received eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  13. Per-asset halt scope
    // ══════════════════════════════════════════════════════════

    function test_haltAsset_perAssetScope() public {
        // Halt only TSLA
        _haltAssetTSLA();

        // TSLA mint blocked
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.placeMintOrder(address(vault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // GOLD mint works
        uint256 orderId = _placeMintForAsset(Actors.MINTER1, GOLD, MINT_AMOUNT, GOLD_PRICE, block.timestamp + 1 days);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Open), "GOLD mint placed while TSLA halted");
    }

    // ══════════════════════════════════════════════════════════
    //  14. haltAsset with zero price reverts
    // ══════════════════════════════════════════════════════════

    function test_haltAsset_zeroPriceReverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidHaltPrice.selector);
        vault.haltAsset(TSLA, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  16. Halt state transition — only from Active
    // ══════════════════════════════════════════════════════════

    function test_halt_stateTransition_onlyFromActive() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("paused"));

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidStatusTransition.selector);
        vault.haltVault();
    }
}
