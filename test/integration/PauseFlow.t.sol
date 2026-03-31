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
    PRECISION
} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
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
    FeeCalculator public feeCalc;

    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT_WETH = 50_000e18;
    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant ETOKEN_AMOUNT = 40e18;
    uint256 constant GRACE_PERIOD = 1 days;
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

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, amount, TSLA_PRICE, expiry);
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

    function _mintETokens(address to, uint256 amount) internal {
        vm.prank(address(market));
        eTSLA.mint(to, amount);
    }

    // ══════════════════════════════════════════════════════════
    //  1. Pause blocks mint order placement
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksMintOrderPlacement() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.placeMintOrder(address(vault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  2. Pause blocks redeem order placement
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksRedeemOrderPlacement() public {
        _mintETokens(Actors.MINTER1, ETOKEN_AMOUNT);

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), ETOKEN_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.placeRedeemOrder(address(vault), TSLA, ETOKEN_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  3. Pause blocks claim order
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksClaimOrder() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.claimOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  4. Pause allows confirm order
    // ══════════════════════════════════════════════════════════

    function test_pause_allowsConfirmOrder() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        // Confirm should still succeed while paused
        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  5. Pause allows close order
    // ══════════════════════════════════════════════════════════

    function test_pause_allowsCloseOrder() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        vm.warp(expiry + 1);

        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), MINT_AMOUNT);
        market.closeOrder(orderId);
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Closed));
    }

    // ══════════════════════════════════════════════════════════
    //  6. Pause allows cancel order
    // ══════════════════════════════════════════════════════════

    function test_pause_allowsCancelOrder() public {
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

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

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

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
        vault.requestDeposit(1000e18, Actors.LP2);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  10. Pause allows LP withdrawal
    // ══════════════════════════════════════════════════════════

    function test_pause_allowsLPWithdrawal() public {
        uint256 shares = vault.balanceOf(Actors.LP1);
        assertGt(shares, 0, "LP has shares");

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);
        assertGt(requestId, 0, "withdrawal request created");

        uint256 wethBefore = weth.balanceOf(Actors.LP1);
        vault.fulfillWithdrawal(requestId);
        uint256 wethAfter = weth.balanceOf(Actors.LP1);

        assertGt(wethAfter - wethBefore, 0, "LP received WETH");
    }

    // ══════════════════════════════════════════════════════════
    //  11. pauseAsset only affects target asset
    // ══════════════════════════════════════════════════════════

    function test_pauseAsset_onlyAffectsTargetAsset() public {
        vm.prank(Actors.ADMIN);
        vault.pauseAsset(TSLA, bytes32("oracle issue"));

        assertTrue(vault.isEffectivelyPaused(TSLA), "TSLA paused");
        assertFalse(vault.isEffectivelyPaused(GOLD), "GOLD not paused");

        // Placing a mint order for TSLA should revert
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.placeMintOrder(address(vault), TSLA, MINT_AMOUNT, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // Placing a mint order for GOLD should succeed
        _fundUSDC(Actors.MINTER2, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER2);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(address(vault), GOLD, MINT_AMOUNT, GOLD_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Open));
    }

    // ══════════════════════════════════════════════════════════
    //  12. Unpause resumes normal operation
    // ══════════════════════════════════════════════════════════

    function test_unpause_resumesNormalOperation() public {
        vm.startPrank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));
        vault.unpause();
        vm.stopPrank();

        // Full mint flow: place, claim, confirm
        uint256 orderId = _placeMint(Actors.MINTER1, MINT_AMOUNT, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.Confirmed));
        assertGt(eTSLA.balanceOf(Actors.MINTER1), 0, "minter received eTokens");
    }

    // ══════════════════════════════════════════════════════════
    //  13. Pause only callable by admin
    // ══════════════════════════════════════════════════════════

    function test_pause_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.pause(bytes32("attack"));
    }
}
