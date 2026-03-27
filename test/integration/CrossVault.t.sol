// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, ClaimInfo, OrderStatus, PriceType} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title CrossVault Integration Test
/// @notice Tests VMs from different vaults competing for the same order.
///         Security attribution and cross-vault partial fills.
contract CrossVaultTest is BaseTest {
    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    OwnVault public wethVault;
    EToken public eTSLA;
    FeeCalculator public feeCalc;
    address public feeAccrual = makeAddr("feeAccrual");

    uint256 constant MINT_AMOUNT = 10_000e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
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
        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry), 30);

        // Register market and vault manager
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        // USDC vault
        usdcVault = new OwnVault(address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), 8000, 0, 1000);

        // WETH vault
        wethVault = new OwnVault(address(weth), "Own WETH Vault", "oWETH", address(protocolRegistry), 8000, 0, 1000);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);
        paymentRegistry.addPaymentToken(address(usdc));

        vm.stopPrank();

        vm.label(address(usdcVault), "USDCVault");
        vm.label(address(wethVault), "WETHVault");

        // LP1 deposits into USDC vault
        _fundUSDC(Actors.LP1, 500_000e6);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), 500_000e6);
        usdcVault.deposit(500_000e6, Actors.LP1);
        vm.stopPrank();

        // LP2 deposits into WETH vault
        _fundWETH(Actors.LP2, 100e18);
        vm.startPrank(Actors.LP2);
        weth.approve(address(wethVault), 100e18);
        wethVault.deposit(100e18, Actors.LP2);
        vm.stopPrank();

        // VM1 registered with USDC vault
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(50);
        vaultMgr.setExposureCaps(10_000_000e18, 5_000_000e18);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        // VM2 registered with WETH vault
        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(wethVault));
        vaultMgr.setSpread(40);
        vaultMgr.setExposureCaps(10_000_000e18, 5_000_000e18);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: VMs from different vaults claim same open order
    // ══════════════════════════════════════════════════════════

    function test_crossVault_bothVMsClaimSameOrder() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            true, // partial fill
            address(0), // open
            _emptyPriceData()
        );
        vm.stopPrank();

        uint256 halfAmount = MINT_AMOUNT / 2;

        // VM1 (USDC vault) claims half
        vm.prank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId, halfAmount);

        // VM2 (WETH vault) claims other half
        vm.prank(Actors.VM2);
        uint256 claimId2 = market.claimOrder(orderId, halfAmount);

        // Verify claims from different VMs
        ClaimInfo memory claim1 = market.getClaim(claimId1);
        ClaimInfo memory claim2 = market.getClaim(claimId2);
        assertEq(claim1.vm, Actors.VM1);
        assertEq(claim2.vm, Actors.VM2);
        assertEq(claim1.amount, halfAmount);
        assertEq(claim2.amount, halfAmount);

        // Both receive stablecoins
        assertEq(usdc.balanceOf(Actors.VM1), halfAmount);
        assertEq(usdc.balanceOf(Actors.VM2), halfAmount);

        // Order fully claimed
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.FullyClaimed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cross-vault confirm independently
    // ══════════════════════════════════════════════════════════

    function test_crossVault_independentConfirmation() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            true,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        uint256 halfAmount = MINT_AMOUNT / 2;

        vm.prank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId, halfAmount);
        vm.prank(Actors.VM2);
        uint256 claimId2 = market.claimOrder(orderId, halfAmount);

        // VM1 confirms first
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId1, _emptyPriceData());

        // Order is partially confirmed
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.PartiallyConfirmed));

        // VM2 confirms
        vm.prank(Actors.VM2);
        market.confirmOrder(claimId2, _emptyPriceData());

        // Now fully confirmed
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Directed order to VM in specific vault
    // ══════════════════════════════════════════════════════════

    function test_crossVault_directedOrder() public {
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);

        // Directed to VM2 (WETH vault)
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            Actors.VM2,
            _emptyPriceData()
        );
        vm.stopPrank();

        // VM1 (USDC vault) cannot claim
        vm.prank(Actors.VM1);
        vm.expectRevert(
            abi.encodeWithSignature("DirectedOrderWrongVM(uint256,address,address)", orderId, Actors.VM2, Actors.VM1)
        );
        market.claimOrder(orderId, MINT_AMOUNT);

        // VM2 can claim
        vm.prank(Actors.VM2);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);

        vm.prank(Actors.VM2);
        market.confirmOrder(claimId, _emptyPriceData());

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: VMs registered to different vaults verified
    // ══════════════════════════════════════════════════════════

    function test_crossVault_vaultAttribution() public {
        assertEq(vaultMgr.getVMVault(Actors.VM1), address(usdcVault));
        assertEq(vaultMgr.getVMVault(Actors.VM2), address(wethVault));
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Both vaults maintain independent collateral
    // ══════════════════════════════════════════════════════════

    function test_crossVault_independentCollateral() public {
        uint256 usdcAssets = usdcVault.totalAssets();
        uint256 wethAssets = wethVault.totalAssets();

        // Run a full order that VM1 claims
        _fundUSDC(Actors.MINTER1, MINT_AMOUNT);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), MINT_AMOUNT);
        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            MINT_AMOUNT,
            PriceType.Market,
            100,
            block.timestamp + 1 days,
            false,
            Actors.VM1,
            _emptyPriceData()
        );
        vm.stopPrank();

        vm.startPrank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);
        market.confirmOrder(claimId, _emptyPriceData());
        vm.stopPrank();

        // Vault collateral is unchanged (stablecoins went to VM, not from vault)
        assertEq(usdcVault.totalAssets(), usdcAssets, "USDC vault unchanged");
        assertEq(wethVault.totalAssets(), wethAssets, "WETH vault unchanged");
    }
}
