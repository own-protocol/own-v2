// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, BPS, OrderStatus, PriceType, VMConfig} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title VMLifecycle Integration Test
/// @notice Tests VM registration, configuration, order claiming, delegation,
///         and multi-VM competition with real contract instances.
contract VMLifecycleTest is BaseTest {
    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
    VaultManager public vaultMgr;
    OwnMarket public market;
    OwnVault public usdcVault;
    EToken public eTSLA;

    uint256 constant MIN_SPREAD = 30;
    uint256 constant MINT_AMOUNT = 10_000e6;
    uint256 constant LP_DEPOSIT = 500_000e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        paymentRegistry = new PaymentTokenRegistry(Actors.ADMIN);

        market = new OwnMarket(Actors.ADMIN, address(oracle), address(assetRegistry), address(paymentRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(market), MIN_SPREAD);
        market.setVaultManager(address(vaultMgr));

        usdcVault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC", Actors.ADMIN, address(market), Actors.FEE_RECIPIENT, 8000, 0, 1000
        );

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, Actors.ADMIN, address(market), address(usdc));

        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            minCollateralRatio: 11_000,
            liquidationThreshold: 10_500,
            liquidationReward: 500,
            active: true
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), config);
        paymentRegistry.addPaymentToken(address(usdc));

        vm.stopPrank();

        // LP deposits collateral
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Registration
    // ══════════════════════════════════════════════════════════

    function test_vmRegistration() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        VMConfig memory cfg = vaultMgr.getVMConfig(Actors.VM1);
        assertTrue(cfg.registered);
        assertTrue(cfg.active);
        assertEq(vaultMgr.getVMVault(Actors.VM1), address(usdcVault));
    }

    function test_vmRegistration_alreadyRegistered_reverts() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        vm.expectRevert(abi.encodeWithSignature("VMAlreadyRegistered(address)", Actors.VM1));
        vaultMgr.registerVM(address(usdcVault));
        vm.stopPrank();
    }

    function test_vmRegistration_zeroVault_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vaultMgr.registerVM(address(0));
    }

    function test_vmDeregistration() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.deregisterVM();
        vm.stopPrank();

        VMConfig memory cfg = vaultMgr.getVMConfig(Actors.VM1);
        assertFalse(cfg.registered);
        assertFalse(cfg.active);
        assertEq(vaultMgr.getVMVault(Actors.VM1), address(0));
    }

    function test_vmDeregistration_notRegistered_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("VMNotRegistered(address)", Actors.VM1));
        vaultMgr.deregisterVM();
    }

    // ══════════════════════════════════════════════════════════
    //  Configuration
    // ══════════════════════════════════════════════════════════

    function test_vmSetSpread() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(50);
        vm.stopPrank();

        assertEq(vaultMgr.getVMConfig(Actors.VM1).spread, 50);
    }

    function test_vmSetSpread_belowMinimum_reverts() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        vm.expectRevert(abi.encodeWithSignature("SpreadBelowMinimum(uint256,uint256)", 20, MIN_SPREAD));
        vaultMgr.setSpread(20);
        vm.stopPrank();
    }

    function test_vmSetSpread_aboveBPS_reverts() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        vm.expectRevert(abi.encodeWithSignature("InvalidSpread()"));
        vaultMgr.setSpread(BPS + 1);
        vm.stopPrank();
    }

    function test_vmSetExposureCaps() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setExposureCaps(5_000_000e18, 2_000_000e18);
        vm.stopPrank();

        VMConfig memory cfg = vaultMgr.getVMConfig(Actors.VM1);
        assertEq(cfg.maxExposure, 5_000_000e18);
        assertEq(cfg.maxOffMarketExposure, 2_000_000e18);
    }

    function test_vmPaymentTokenAcceptance() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vaultMgr.setPaymentTokenAcceptance(address(usdt), false);
        vm.stopPrank();

        assertTrue(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdc)));
        assertFalse(vaultMgr.isPaymentTokenAccepted(Actors.VM1, address(usdt)));
    }

    function test_vmAssetOffMarketToggle() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setAssetOffMarketEnabled(TSLA, true);
        vm.stopPrank();

        assertTrue(vaultMgr.isAssetOffMarketEnabled(Actors.VM1, TSLA));

        vm.prank(Actors.VM1);
        vaultMgr.setAssetOffMarketEnabled(TSLA, false);

        assertFalse(vaultMgr.isAssetOffMarketEnabled(Actors.VM1, TSLA));
    }

    function test_vmActiveToggle() public {
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        // Deactivate
        vaultMgr.setVMActive(false);
        assertFalse(vaultMgr.getVMConfig(Actors.VM1).active);

        // Reactivate
        vaultMgr.setVMActive(true);
        assertTrue(vaultMgr.getVMConfig(Actors.VM1).active);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Delegation
    // ══════════════════════════════════════════════════════════

    function test_delegation_fullFlow() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        // LP proposes
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);

        // VM accepts
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);

        assertEq(vaultMgr.getDelegatedVM(Actors.LP1), Actors.VM1);
        assertEq(vaultMgr.getDelegatedLPs(Actors.VM1).length, 1);
        assertEq(vaultMgr.getDelegatedLPs(Actors.VM1)[0], Actors.LP1);
    }

    function test_delegation_alreadyDelegated_reverts() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);

        // Register VM2
        vm.prank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault));

        // LP1 tries to propose again while already delegated
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSignature("AlreadyDelegated(address)", Actors.LP1));
        vaultMgr.proposeDelegation(Actors.VM2);
    }

    function test_delegation_notProposed_reverts() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        // VM tries to accept without LP proposing
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("DelegationNotProposed(address,address)", Actors.LP1, Actors.VM1));
        vaultMgr.acceptDelegation(Actors.LP1);
    }

    function test_delegation_proposeToUnregisteredVM_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSignature("VMNotRegistered(address)", Actors.VM1));
        vaultMgr.proposeDelegation(Actors.VM1);
    }

    function test_delegation_multipleLPs() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));

        // LP1 delegates
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);

        // LP2 delegates
        vm.prank(Actors.LP2);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP2);

        address[] memory lps = vaultMgr.getDelegatedLPs(Actors.VM1);
        assertEq(lps.length, 2);
    }

    function test_delegation_remove_and_redelegate() public {
        vm.prank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vm.prank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault));

        // Delegate to VM1
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);

        // Remove delegation
        vm.prank(Actors.LP1);
        vaultMgr.removeDelegation();

        // Redelegate to VM2
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM2);
        vm.prank(Actors.VM2);
        vaultMgr.acceptDelegation(Actors.LP1);

        assertEq(vaultMgr.getDelegatedVM(Actors.LP1), Actors.VM2);
    }

    // ══════════════════════════════════════════════════════════
    //  Multi-VM competition for orders
    // ══════════════════════════════════════════════════════════

    function test_multiVM_competitionForOpenOrder() public {
        // Register both VMs
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(50);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        vm.startPrank(Actors.VM2);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(40); // VM2 offers better spread
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        // Minter places open order with partial fills
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

        // VM2 claims half first (better spread)
        vm.prank(Actors.VM2);
        uint256 claimId2 = market.claimOrder(orderId, MINT_AMOUNT / 2);

        // VM1 claims other half
        vm.prank(Actors.VM1);
        uint256 claimId1 = market.claimOrder(orderId, MINT_AMOUNT / 2);

        // Both confirm
        vm.prank(Actors.VM2);
        market.confirmOrder(claimId2, _emptyPriceData());
        vm.prank(Actors.VM1);
        market.confirmOrder(claimId1, _emptyPriceData());

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT / 2);
        assertEq(usdc.balanceOf(Actors.VM2), MINT_AMOUNT / 2);
    }

    // ══════════════════════════════════════════════════════════
    //  Admin — minSpread
    // ══════════════════════════════════════════════════════════

    function test_admin_setMinSpread() public {
        assertEq(vaultMgr.minSpread(), MIN_SPREAD);

        vm.prank(Actors.ADMIN);
        vaultMgr.setMinSpread(50);

        assertEq(vaultMgr.minSpread(), 50);
    }

    function test_admin_setMinSpread_onlyOwner() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vaultMgr.setMinSpread(50);
    }

    // ══════════════════════════════════════════════════════════
    //  Config only if registered
    // ══════════════════════════════════════════════════════════

    function test_configOnlyRegistered() public {
        // Unregistered VM cannot set spread
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSignature("VMNotRegistered(address)", Actors.VM1));
        vaultMgr.setSpread(50);
    }

    // ══════════════════════════════════════════════════════════
    //  Full lifecycle
    // ══════════════════════════════════════════════════════════

    function test_fullVMLifecycle() public {
        // 1. Register
        vm.startPrank(Actors.VM1);
        vaultMgr.registerVM(address(usdcVault));
        vaultMgr.setSpread(50);
        vaultMgr.setExposureCaps(10_000_000e18, 5_000_000e18);
        vaultMgr.setPaymentTokenAcceptance(address(usdc), true);
        vm.stopPrank();

        // 2. LP delegates
        vm.prank(Actors.LP1);
        vaultMgr.proposeDelegation(Actors.VM1);
        vm.prank(Actors.VM1);
        vaultMgr.acceptDelegation(Actors.LP1);

        // 3. Minter places order
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

        // 4. VM claims and confirms
        vm.startPrank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, MINT_AMOUNT);
        market.confirmOrder(claimId, _emptyPriceData());
        vm.stopPrank();

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Confirmed));
        assertEq(usdc.balanceOf(Actors.VM1), MINT_AMOUNT);

        // 5. Deregister
        vm.prank(Actors.VM1);
        vaultMgr.deregisterVM();

        assertFalse(vaultMgr.getVMConfig(Actors.VM1).registered);
    }
}
