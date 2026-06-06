// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {
    AssetConfig,
    BPS,
    Order,
    OrderStatus,
    OrderType,
    PRECISION,
    Quote,
    VaultStatus
} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
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

    uint256 constant MAX_EXPOSURE = 10_000_000e18;
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT_WETH = 50_000e18;
    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant ETOKEN_AMOUNT = 40e18;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

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

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        vm.stopPrank();
        // Deploy + register the ExposureManager before createVault (which auto-registers the vault).
        _deployExposureManager();
        vm.startPrank(Actors.ADMIN);

        vault = OwnVault(factory.createVault(address(weth), vm1Signer, "Own ETH Vault", "oETH", ETH));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        vault.setClaimThreshold(CLAIM_THRESHOLD);
        vault.addQuoteSigner(vm1Signer);

        vm.stopPrank();

        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);
        _setAssetCap(GOLD, DEFAULT_ASSET_CAP_USD);
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

        eGOLD = new EToken("Own Gold", "eGOLD", GOLD, address(protocolRegistry), address(usdc));
        AssetConfig memory goldConfig = AssetConfig({
            activeToken: address(eGOLD),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(GOLD, address(eGOLD), goldConfig);

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
        vm.startPrank(vm1Signer);
        vault.setPaymentToken(address(usdc));
        vm.stopPrank();
    }

    function _depositLPCollateral() private {
        _fundWETH(vm1Signer, LP_DEPOSIT_WETH);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();

        _pokeCollateral(address(vault));
        _pokeAsset(TSLA);
        _pokeAsset(GOLD);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeOrder(address(vault), TSLA, OrderType.Mint, amount, TSLA_PRICE, expiry);
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
        uint256 orderId = market.placeOrder(address(vault), asset, OrderType.Mint, amount, price, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _placeRedeem(address minter, uint256 eAmount, uint256 expiry) internal returns (uint256) {
        vm.startPrank(minter);
        eTSLA.approve(address(market), eAmount);
        uint256 orderId = market.placeOrder(address(vault), TSLA, OrderType.Redeem, eAmount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    /// @dev Mint eTokens to `minter` via a market mint settled against a VM-signed quote.
    function _mintETokensViaFlow(address minter, uint256 usdcAmount) internal {
        _fundUSDC(minter, usdcAmount);
        vm.prank(minter);
        usdc.approve(address(market), usdcAmount);
        Quote memory q = _buildQuote(0, minter, address(vault), TSLA, OrderType.Mint, usdcAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(minter);
        market.executeOrder(q, sig);
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
        market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  2. Halt blocks market mint execution
    // ══════════════════════════════════════════════════════════

    function test_halt_blocksMintExecute() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        _haltAssetTSLA();

        Quote memory q = _buildQuote(0, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.executeOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  3. Halt blocks filling a resting mint order
    // ══════════════════════════════════════════════════════════

    function test_halt_blocksMintFill() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        _haltAssetTSLA();

        Quote memory q =
            _buildQuote(orderId, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(vm1Signer);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.fillOrder(q, sig);
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
        uint256 orderId =
            market.placeOrder(address(vault), TSLA, OrderType.Redeem, eTokenBal, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Open), "redeem order placed during halt");
    }

    // ══════════════════════════════════════════════════════════
    //  5. Halt blocks normal redeem fill (recourse is force execution)
    // ══════════════════════════════════════════════════════════

    function test_halt_blocksRedeemFill() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        uint256 orderId = _placeRedeem(Actors.MINTER1, eTokenBal, block.timestamp + 1 days);

        _haltAssetTSLA();

        Quote memory q =
            _buildQuote(orderId, Actors.MINTER1, address(vault), TSLA, OrderType.Redeem, eTokenBal, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(vm1Signer);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.TradingHalted.selector, TSLA));
        market.fillOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  6. Redeem force execution settles at halt price
    // ══════════════════════════════════════════════════════════

    function test_halt_redeemForceExecuteUsesHaltPrice() public {
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
        uint256 eTokenBal = eTSLA.balanceOf(Actors.MINTER1);
        // Limit price must be <= halt price for force execution to pass, so use a tiny limit.
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), eTokenBal);
        uint256 orderId =
            market.placeOrder(address(vault), TSLA, OrderType.Redeem, eTokenBal, 1, block.timestamp + 7 days);
        vm.stopPrank();

        _haltAssetTSLA();

        // Past the claim threshold the owner can force execution; halt price is used.
        vm.warp(block.timestamp + CLAIM_THRESHOLD + 1);

        // Collateral released = (eTokens * haltPrice / PRECISION) / ETH_PRICE (no fee).
        uint256 grossUsd = Math.mulDiv(eTokenBal, HALT_PRICE, PRECISION);
        uint256 grossCollateral = Math.mulDiv(grossUsd, PRECISION, ETH_PRICE);

        uint256 userWethBefore = weth.balanceOf(Actors.MINTER1);

        bytes memory collateralPriceData = abi.encode(uint256(ETH_PRICE), uint256(block.timestamp));

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderForceExecuted(orderId, Actors.MINTER1, eTokenBal, grossCollateral);

        vm.prank(Actors.MINTER1);
        market.forceExecuteOrder(orderId, "", collateralPriceData);

        // User received collateral valued at the halt price; eTokens burned.
        assertEq(weth.balanceOf(Actors.MINTER1), userWethBefore + grossCollateral, "user got collateral at halt price");
        assertEq(eTSLA.balanceOf(address(market)), 0, "eTokens burned from market");

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.ForceExecuted), "order force executed");
    }

    // removed: closeOrder no longer exists in RFQ model (claimed-mint close during halt).
    // removed: mint force execution no longer exists (mint orders are cancel/expire only).

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

        // Market mint succeeds once trading resumes.
        _mintETokensViaFlow(Actors.MINTER1, MINT_AMOUNT);
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
        market.placeOrder(address(vault), TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
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
