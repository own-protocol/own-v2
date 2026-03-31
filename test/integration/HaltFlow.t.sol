// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, BPS, OrderStatus, VaultStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title HaltFlow Integration Test
/// @notice Tests pause/unpause and halt/unhalt vault-wide and per-asset,
///         including LP deposit blocking and withdrawal behavior.
contract HaltFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 100 ether;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        vault = OwnVault(factory.createVault(address(weth), Actors.VM1, "Own WETH Vault", "oWETH", 8000, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vault.setGracePeriod(1 days);
        vault.setClaimThreshold(6 hours);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        vm.stopPrank();

        // Set payment token and enable asset
        vm.startPrank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();

        // LP deposits (via VM1)
        _fundWETH(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    function _haltVault() private {
        vm.startPrank(Actors.ADMIN);
        vault.haltAsset(TSLA, TSLA_PRICE);
        vault.haltVault();
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Vault-wide pause
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksDeposits() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Paused));

        _fundWETH(Actors.VM1, 10 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 10 ether);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        vault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
    }

    function test_pause_maxDepositReturnsZero() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        assertEq(vault.maxDeposit(Actors.LP1), 0);
        assertEq(vault.maxMint(Actors.LP1), 0);
    }

    function test_unpause_resumesNormal() public {
        vm.startPrank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Paused));

        vault.unpause();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Active));
        vm.stopPrank();

        _fundWETH(Actors.VM1, 10 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();

        assertGt(vault.balanceOf(Actors.LP2), 0);
    }

    function test_pause_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.pause(bytes32("attack"));
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.unpause();
    }

    function test_pause_requiresActive() public {
        _haltVault();

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidStatusTransition.selector);
        vault.pause(bytes32("try pause from halt"));
    }

    // ══════════════════════════════════════════════════════════
    //  Vault-wide halt
    // ══════════════════════════════════════════════════════════

    function test_halt_depositsBlocked() public {
        _haltVault();

        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Halted));

        _fundWETH(Actors.VM1, 10 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 10 ether);
        vm.expectRevert(IOwnVault.VaultIsHalted.selector);
        vault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
    }

    function test_halt_maxDepositReturnsZero() public {
        _haltVault();

        assertEq(vault.maxDeposit(Actors.LP1), 0);
        assertEq(vault.maxMint(Actors.LP1), 0);
    }

    function test_halt_directWithdrawalsDisabled() public {
        _haltVault();

        // maxWithdraw / maxRedeem always return 0 (direct withdrawals disabled, use async queue)
        assertEq(vault.maxWithdraw(Actors.LP1), 0);
        assertEq(vault.maxRedeem(Actors.LP1), 0);
    }

    function test_halt_requiresActive() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("paused"));

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidStatusTransition.selector);
        vault.haltVault();
    }

    function test_unhalt_resumesNormal() public {
        _haltVault();

        vm.prank(Actors.ADMIN);
        vault.unhalt();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Active));

        _fundWETH(Actors.VM1, 10 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();

        assertGt(vault.balanceOf(Actors.LP2), 0);
    }

    function test_halt_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.haltVault();
    }

    function test_unhalt_onlyFromHalted() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidStatusTransition.selector);
        vault.unhalt();
    }

    // ══════════════════════════════════════════════════════════
    //  Per-asset halt
    // ══════════════════════════════════════════════════════════

    function test_haltAsset_setsFlag() public {
        vm.prank(Actors.ADMIN);
        vault.haltAsset(TSLA, TSLA_PRICE);

        assertTrue(vault.isAssetHalted(TSLA));
        assertFalse(vault.isAssetHalted(GOLD));
        assertEq(vault.getAssetHaltPrice(TSLA), TSLA_PRICE);
    }

    function test_unhaltAsset_clearsFlagAndPrice() public {
        vm.startPrank(Actors.ADMIN);
        vault.haltAsset(TSLA, TSLA_PRICE);
        assertTrue(vault.isAssetHalted(TSLA));

        vault.unhaltAsset(TSLA);
        assertFalse(vault.isAssetHalted(TSLA));
        assertEq(vault.getAssetHaltPrice(TSLA), 0);
        vm.stopPrank();
    }

    function test_haltAsset_zeroPriceReverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidHaltPrice.selector);
        vault.haltAsset(TSLA, 0);
    }

    function test_haltAsset_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.haltAsset(TSLA, TSLA_PRICE);
    }

    // ══════════════════════════════════════════════════════════
    //  Per-asset pause
    // ══════════════════════════════════════════════════════════

    function test_pauseAsset_setsFlag() public {
        vm.prank(Actors.ADMIN);
        vault.pauseAsset(TSLA, bytes32("oracle issue"));

        assertTrue(vault.isAssetPaused(TSLA));
        assertFalse(vault.isAssetPaused(GOLD));
    }

    function test_unpauseAsset_clearsFlag() public {
        vm.startPrank(Actors.ADMIN);
        vault.pauseAsset(TSLA, bytes32("oracle issue"));
        assertTrue(vault.isAssetPaused(TSLA));

        vault.unpauseAsset(TSLA);
        assertFalse(vault.isAssetPaused(TSLA));
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Combined query helpers
    // ══════════════════════════════════════════════════════════

    function test_isEffectivelyPaused_vaultPaused() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        assertTrue(vault.isEffectivelyPaused(TSLA));
        assertTrue(vault.isEffectivelyPaused(GOLD));
    }

    function test_isEffectivelyPaused_assetPaused() public {
        vm.prank(Actors.ADMIN);
        vault.pauseAsset(TSLA, bytes32("oracle issue"));

        assertTrue(vault.isEffectivelyPaused(TSLA));
        assertFalse(vault.isEffectivelyPaused(GOLD));
    }

    function test_isEffectivelyHalted_vaultHalted() public {
        _haltVault();

        assertTrue(vault.isEffectivelyHalted(TSLA));
        // GOLD is not in the halt assets list, but vault is halted
        assertTrue(vault.isEffectivelyHalted(GOLD));
    }

    function test_isEffectivelyHalted_assetHalted() public {
        vm.prank(Actors.ADMIN);
        vault.haltAsset(TSLA, TSLA_PRICE);

        assertTrue(vault.isEffectivelyHalted(TSLA));
        assertFalse(vault.isEffectivelyHalted(GOLD));
    }

    // ══════════════════════════════════════════════════════════
    //  Withdrawal queue during halt
    // ══════════════════════════════════════════════════════════

    function test_halt_asyncWithdrawalStillRequestable() public {
        _haltVault();

        uint256 shares = vault.balanceOf(Actors.LP1);
        assertGt(shares, 0);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares / 2);
        assertGt(requestId, 0);
    }

    function test_halt_unhalt_fulfillWithdrawal() public {
        uint256 shares = vault.balanceOf(Actors.LP1);

        _haltVault();

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares / 2);

        vm.prank(Actors.ADMIN);
        vault.unhalt();

        uint256 balBefore = weth.balanceOf(Actors.LP1);
        vault.fulfillWithdrawal(requestId);
        uint256 balAfter = weth.balanceOf(Actors.LP1);

        assertGt(balAfter - balBefore, 0, "LP received assets");
    }

    // ══════════════════════════════════════════════════════════
    //  Halt -> Unhalt -> Halt cycle
    // ══════════════════════════════════════════════════════════

    function test_haltUnhaltCycle() public {
        vm.startPrank(Actors.ADMIN);

        vault.haltAsset(TSLA, TSLA_PRICE);
        vault.haltVault();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Halted));

        vault.unhalt();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Active));

        vault.haltAsset(TSLA, TSLA_PRICE);
        vault.haltVault();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Halted));

        vault.unhalt();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Active));

        vm.stopPrank();

        _fundWETH(Actors.VM1, 10 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
        assertGt(vault.balanceOf(Actors.LP2), 0);
    }
}
