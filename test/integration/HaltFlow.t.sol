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
    OwnVault public usdcVault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 500_000e6;

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

        usdcVault = OwnVault(factory.createVault(address(usdc), Actors.VM1, "Own USDC Vault", "oUSDC", 8000, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        usdcVault.setGracePeriod(1 days);
        usdcVault.setClaimThreshold(6 hours);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        vm.stopPrank();

        // Set payment token and enable asset
        vm.startPrank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));
        usdcVault.enableAsset(TSLA);
        vm.stopPrank();

        // LP deposits (via VM1)
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    function _haltVault() private {
        vm.startPrank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, TSLA_PRICE);
        usdcVault.haltVault();
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Vault-wide pause
    // ══════════════════════════════════════════════════════════

    function test_pause_blocksDeposits() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pause(bytes32("emergency"));

        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Paused));

        _fundUSDC(Actors.VM1, 1000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 1000e6);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
    }

    function test_pause_maxDepositReturnsZero() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pause(bytes32("emergency"));

        assertEq(usdcVault.maxDeposit(Actors.LP1), 0);
        assertEq(usdcVault.maxMint(Actors.LP1), 0);
    }

    function test_unpause_resumesNormal() public {
        vm.startPrank(Actors.ADMIN);
        usdcVault.pause(bytes32("emergency"));
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Paused));

        usdcVault.unpause();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));
        vm.stopPrank();

        _fundUSDC(Actors.VM1, 1000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 1000e6);
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();

        assertGt(usdcVault.balanceOf(Actors.LP2), 0);
    }

    function test_pause_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        usdcVault.pause(bytes32("attack"));
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pause(bytes32("emergency"));

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        usdcVault.unpause();
    }

    function test_pause_requiresActive() public {
        _haltVault();

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidStatusTransition.selector);
        usdcVault.pause(bytes32("try pause from halt"));
    }

    // ══════════════════════════════════════════════════════════
    //  Vault-wide halt
    // ══════════════════════════════════════════════════════════

    function test_halt_depositsBlocked() public {
        _haltVault();

        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Halted));

        _fundUSDC(Actors.VM1, 1000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 1000e6);
        vm.expectRevert(IOwnVault.VaultIsHalted.selector);
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
    }

    function test_halt_maxDepositReturnsZero() public {
        _haltVault();

        assertEq(usdcVault.maxDeposit(Actors.LP1), 0);
        assertEq(usdcVault.maxMint(Actors.LP1), 0);
    }

    function test_halt_directWithdrawalsDisabled() public {
        _haltVault();

        // maxWithdraw / maxRedeem always return 0 (direct withdrawals disabled, use async queue)
        assertEq(usdcVault.maxWithdraw(Actors.LP1), 0);
        assertEq(usdcVault.maxRedeem(Actors.LP1), 0);
    }

    function test_halt_requiresActive() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pause(bytes32("paused"));

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidStatusTransition.selector);
        usdcVault.haltVault();
    }

    function test_unhalt_resumesNormal() public {
        _haltVault();

        vm.prank(Actors.ADMIN);
        usdcVault.unhalt();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));

        _fundUSDC(Actors.VM1, 1000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 1000e6);
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();

        assertGt(usdcVault.balanceOf(Actors.LP2), 0);
    }

    function test_halt_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        usdcVault.haltVault();
    }

    function test_unhalt_onlyFromHalted() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidStatusTransition.selector);
        usdcVault.unhalt();
    }

    // ══════════════════════════════════════════════════════════
    //  Per-asset halt
    // ══════════════════════════════════════════════════════════

    function test_haltAsset_setsFlag() public {
        vm.prank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, TSLA_PRICE);

        assertTrue(usdcVault.isAssetHalted(TSLA));
        assertFalse(usdcVault.isAssetHalted(GOLD));
        assertEq(usdcVault.getAssetHaltPrice(TSLA), TSLA_PRICE);
    }

    function test_unhaltAsset_clearsFlagAndPrice() public {
        vm.startPrank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, TSLA_PRICE);
        assertTrue(usdcVault.isAssetHalted(TSLA));

        usdcVault.unhaltAsset(TSLA);
        assertFalse(usdcVault.isAssetHalted(TSLA));
        assertEq(usdcVault.getAssetHaltPrice(TSLA), 0);
        vm.stopPrank();
    }

    function test_haltAsset_zeroPriceReverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.InvalidHaltPrice.selector);
        usdcVault.haltAsset(TSLA, 0);
    }

    function test_haltAsset_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        usdcVault.haltAsset(TSLA, TSLA_PRICE);
    }

    // ══════════════════════════════════════════════════════════
    //  Per-asset pause
    // ══════════════════════════════════════════════════════════

    function test_pauseAsset_setsFlag() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pauseAsset(TSLA, bytes32("oracle issue"));

        assertTrue(usdcVault.isAssetPaused(TSLA));
        assertFalse(usdcVault.isAssetPaused(GOLD));
    }

    function test_unpauseAsset_clearsFlag() public {
        vm.startPrank(Actors.ADMIN);
        usdcVault.pauseAsset(TSLA, bytes32("oracle issue"));
        assertTrue(usdcVault.isAssetPaused(TSLA));

        usdcVault.unpauseAsset(TSLA);
        assertFalse(usdcVault.isAssetPaused(TSLA));
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Combined query helpers
    // ══════════════════════════════════════════════════════════

    function test_isEffectivelyPaused_vaultPaused() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pause(bytes32("emergency"));

        assertTrue(usdcVault.isEffectivelyPaused(TSLA));
        assertTrue(usdcVault.isEffectivelyPaused(GOLD));
    }

    function test_isEffectivelyPaused_assetPaused() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pauseAsset(TSLA, bytes32("oracle issue"));

        assertTrue(usdcVault.isEffectivelyPaused(TSLA));
        assertFalse(usdcVault.isEffectivelyPaused(GOLD));
    }

    function test_isEffectivelyHalted_vaultHalted() public {
        _haltVault();

        assertTrue(usdcVault.isEffectivelyHalted(TSLA));
        // GOLD is not in the halt assets list, but vault is halted
        assertTrue(usdcVault.isEffectivelyHalted(GOLD));
    }

    function test_isEffectivelyHalted_assetHalted() public {
        vm.prank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, TSLA_PRICE);

        assertTrue(usdcVault.isEffectivelyHalted(TSLA));
        assertFalse(usdcVault.isEffectivelyHalted(GOLD));
    }

    // ══════════════════════════════════════════════════════════
    //  Withdrawal queue during halt
    // ══════════════════════════════════════════════════════════

    function test_halt_asyncWithdrawalStillRequestable() public {
        _haltVault();

        uint256 shares = usdcVault.balanceOf(Actors.LP1);
        assertGt(shares, 0);

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares / 2);
        assertGt(requestId, 0);
    }

    function test_halt_unhalt_fulfillWithdrawal() public {
        uint256 shares = usdcVault.balanceOf(Actors.LP1);

        _haltVault();

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares / 2);

        vm.prank(Actors.ADMIN);
        usdcVault.unhalt();

        uint256 balBefore = usdc.balanceOf(Actors.LP1);
        usdcVault.fulfillWithdrawal(requestId);
        uint256 balAfter = usdc.balanceOf(Actors.LP1);

        assertGt(balAfter - balBefore, 0, "LP received assets");
    }

    // ══════════════════════════════════════════════════════════
    //  Halt -> Unhalt -> Halt cycle
    // ══════════════════════════════════════════════════════════

    function test_haltUnhaltCycle() public {
        vm.startPrank(Actors.ADMIN);

        usdcVault.haltAsset(TSLA, TSLA_PRICE);
        usdcVault.haltVault();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Halted));

        usdcVault.unhalt();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));

        usdcVault.haltAsset(TSLA, TSLA_PRICE);
        usdcVault.haltVault();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Halted));

        usdcVault.unhalt();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));

        vm.stopPrank();

        _fundUSDC(Actors.VM1, 1000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 1000e6);
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
        assertGt(usdcVault.balanceOf(Actors.LP2), 0);
    }
}
