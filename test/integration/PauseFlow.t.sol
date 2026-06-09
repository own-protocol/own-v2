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
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PauseFlow Integration Test
/// @notice Tests vault-wide and per-asset pause behavior across mint/redeem
///         order lifecycle and LP deposit/withdrawal operations.
contract PauseFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;
    EToken public eGOLD;

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

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        vm.stopPrank();
        // Deploy + register the VaultManager before createVault (which auto-registers the vault).
        _deployVaultManager();
        vm.startPrank(Actors.ADMIN);

        vault = OwnVault(factory.createVault(address(weth), vm1Signer, "Own ETH Vault", "oETH", ETH));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vm.stopPrank();

        // Global controls now live on the VaultManager.
        _setClaimThreshold(CLAIM_THRESHOLD);
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

        // Per-asset issuance ceilings (global util default is set by _deployVaultManager).
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);
        _setAssetCap(GOLD, DEFAULT_ASSET_CAP_USD);
    }

    function _configureVault() private {
        // Payment token is now a global VaultManager setting.
        _setPaymentToken(address(usdc));
    }

    function _depositLPCollateral() private {
        _fundWETH(vm1Signer, LP_DEPOSIT_WETH);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();

        // Seed the manager's marks: collateral and asset prices.
        _pullCollateralPrice(address(vault));
        _pullAssetPrice(TSLA);
        _pullAssetPrice(GOLD);
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

    function _mintETokens(address to, uint256 amount) internal {
        vm.prank(address(market));
        eTSLA.mint(to, amount);
    }

    // ══════════════════════════════════════════════════════════
    //  1. Pause blocks mint order placement
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksMintOrderPlacement() public {
        // Trading pause is now a global VaultManager control, distinct from vault-status pause.
        _setAssetTradingPaused(TSLA, true);

        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.placeOrder(TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  2. Pause blocks redeem order placement
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksRedeemOrderPlacement() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);

        _setAssetTradingPaused(TSLA, true);

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.placeOrder(TSLA, OrderType.Redeem, ETOKEN_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  3. Pause blocks market executeOrder
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksExecuteOrder() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        _setAssetTradingPaused(TSLA, true);

        Quote memory q = _buildQuote(0, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.executeOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  4. Pause blocks filling a resting order
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksFillOrder() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        _setAssetTradingPaused(TSLA, true);

        Quote memory q = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(vm1Signer);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.fillOrder(q, sig);
    }

    // removed: closeOrder no longer exists in RFQ model — escrow recovery during pause
    // is covered by cancel (test 6) and expire (test 7).

    // ══════════════════════════════════════════════════════════
    //  6. Pause allows cancel order
    // ══════════════════════════════════════════════════════════

    function test_pause_allowsCancelOrder() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        _setAssetTradingPaused(TSLA, true);

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Cancelled));
        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "stablecoins refunded");
    }

    // ══════════════════════════════════════════════════════════
    //  7. Pause allows expire order
    // ══════════════════════════════════════════════════════════

    function test_pause_allowsExpireOrder() public {
        uint256 expiry = block.timestamp + 1 hours;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        _setAssetTradingPaused(TSLA, true);

        vm.warp(expiry + 1);

        market.expireOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Expired));
        assertEq(usdc.balanceOf(Actors.MINTER1), MINT_AMOUNT, "stablecoins refunded on expiry");
    }

    // ══════════════════════════════════════════════════════════
    //  8. Pause blocks LP deposit (VM direct deposit)
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksLPDeposit() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        _fundWETH(Actors.VM1, 1000e18);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 1000e18);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        vault.deposit(1000e18, Actors.LP2);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  9. Pause blocks requestDeposit
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksRequestDeposit() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        _fundWETH(Actors.LP2, 1000e18);
        vm.startPrank(Actors.LP2);
        weth.approve(address(vault), 1000e18);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        vault.requestDeposit(1000e18, Actors.LP2, 0);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  10. Pause now BLOCKS LP withdrawal (semantics changed)
    // ══════════════════════════════════════════════════════════

    /// @dev Under the refactor, vault pause freezes BOTH deposits and withdrawals:
    ///      requestWithdrawal and fulfillWithdrawal both revert VaultIsPaused.
    function test_pause_blocksLPWithdrawal() public {
        uint256 shares = vault.balanceOf(Actors.LP1);
        assertGt(shares, 0, "LP has shares");

        // Request a withdrawal while active, then pause and confirm fulfill is frozen.
        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);
        assertGt(requestId, 0, "withdrawal request created");

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        vault.fulfillWithdrawal(requestId);

        // A fresh withdrawal request is also blocked while paused.
        _fundWETH(Actors.VM1, 1 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 1 ether);
        vm.stopPrank();
        vm.prank(Actors.LP1);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        vault.requestWithdrawal(1);
    }

    // ══════════════════════════════════════════════════════════
    //  11. pauseAsset only affects target asset
    // ══════════════════════════════════════════════════════════

    function test_pauseAsset_onlyAffectsTargetAsset() public {
        // Per-asset trading pause is now a global VaultManager control.
        _setAssetTradingPaused(TSLA, true);

        assertTrue(vaultManager.isTradingPaused(TSLA), "TSLA paused");
        assertFalse(vaultManager.isTradingPaused(GOLD), "GOLD not paused");

        // Placing a mint order for TSLA should revert
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.placeOrder(TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // Placing a mint order for GOLD should succeed
        _fundUSDC(Actors.MINTER2, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER2);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeOrder(GOLD, OrderType.Mint, MINT_AMOUNT, GOLD_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Open));
    }

    // ══════════════════════════════════════════════════════════
    //  12. Unpause resumes normal operation
    // ══════════════════════════════════════════════════════════

    function test_unpause_resumesNormalOperation() public {
        // Pause then resume trading for the asset via the VaultManager.
        _setAssetTradingPaused(TSLA, true);
        _setAssetTradingPaused(TSLA, false);

        // Market mint settles atomically once trading resumes.
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);

        Quote memory q = _buildQuote(0, Actors.MINTER1, TSLA, OrderType.Mint, MINT_AMOUNT, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertGt(eTSLA.balanceOf(Actors.MINTER1), 0, "minter received eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  13. Pause only callable by admin
    // ══════════════════════════════════════════════════════════

    function test_pause_onlyManagerOrAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyManagerOrAdmin.selector);
        vault.pause(bytes32("attack"));
    }
}
