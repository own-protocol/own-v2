// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {AssetConfig, BPS, OrderStatus, VaultStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
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

        assetRegistry = new AssetRegistry(address(protocolRegistry));

        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        vm.stopPrank();
        // Deploy + register the VaultManager before registering the vault (admin-gated).
        _deployVaultManager();
        vm.startPrank(Actors.ADMIN);

        vault = new OwnVault(address(weth), "Own WETH Vault", "oWETH", address(protocolRegistry), Actors.VM1);
        vaultManager.registerVault(address(vault), ETH);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        // Register the WETH collateral ticker so the VaultManager can resolve its oracle.
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ETH, address(weth), ethConfig);

        vm.stopPrank();

        // Global controls now live on the VaultManager.
        _setClaimThreshold(6 hours);
        _setPaymentToken(address(usdc));

        // LP deposits (via VM1)
        _fundWETH(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        // Seed the vault's collateral mark so the global pool is non-zero.
        _pullCollateralPrice(address(vault));
    }

    /// @dev Vault-status halt (emergency wind-down). Asset-level halt is a separate global
    ///      concept tested elsewhere; here we only exercise the vault status transition.
    function _haltVault() private {
        vm.startPrank(Actors.ADMIN);
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

    function test_pause_onlyManagerOrAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyManagerOrOperator.selector);
        vault.pause(bytes32("attack"));
    }

    function test_unpause_onlyManagerOrAdmin() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyManagerOrOperator.selector);
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
        _haltAsset(TSLA, TSLA_PRICE);

        assertTrue(vaultManager.isAssetHalted(TSLA));
        assertFalse(vaultManager.isAssetHalted(GOLD));
        assertEq(vaultManager.assetHaltPrice(TSLA), TSLA_PRICE);
    }

    /// @dev Asset halt is now PERMANENT (no unhalt). Re-halting reverts AssetAlreadyHalted.
    function test_haltAsset_isPermanent() public {
        _haltAsset(TSLA, TSLA_PRICE);
        assertTrue(vaultManager.isAssetHalted(TSLA));

        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.AssetAlreadyHalted.selector, TSLA));
        vaultManager.haltAsset(TSLA, TSLA_PRICE);
    }

    function test_haltAsset_zeroPriceReverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IVaultManager.InvalidHaltPrice.selector);
        vaultManager.haltAsset(TSLA, 0);
    }

    function test_haltAsset_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IVaultManager.OnlyOperator.selector);
        vaultManager.haltAsset(TSLA, TSLA_PRICE);
    }

    // ══════════════════════════════════════════════════════════
    //  Per-asset trading pause (global VaultManager control)
    // ══════════════════════════════════════════════════════════

    function test_pauseAsset_setsFlag() public {
        _setAssetTradingPaused(TSLA, true);

        assertTrue(vaultManager.isTradingPaused(TSLA));
        assertFalse(vaultManager.isTradingPaused(GOLD));
    }

    function test_unpauseAsset_clearsFlag() public {
        _setAssetTradingPaused(TSLA, true);
        assertTrue(vaultManager.isTradingPaused(TSLA));

        _setAssetTradingPaused(TSLA, false);
        assertFalse(vaultManager.isTradingPaused(TSLA));
    }

    // ══════════════════════════════════════════════════════════
    //  Trading-pause scope (global vs per-asset)
    // ══════════════════════════════════════════════════════════

    function test_globalTradingPause_affectsAllAssets() public {
        _setTradingPaused(true);

        assertTrue(vaultManager.isTradingPaused(TSLA));
        assertTrue(vaultManager.isTradingPaused(GOLD));
    }

    function test_assetTradingPause_isScopedToAsset() public {
        _setAssetTradingPaused(TSLA, true);

        assertTrue(vaultManager.isTradingPaused(TSLA));
        assertFalse(vaultManager.isTradingPaused(GOLD));
    }

    function test_assetHalt_isScopedToAsset() public {
        _haltAsset(TSLA, TSLA_PRICE);

        assertTrue(vaultManager.isAssetHalted(TSLA));
        assertFalse(vaultManager.isAssetHalted(GOLD));
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
        // Vault-status halt is reversible (asset-level halt is a separate permanent concept).
        vm.startPrank(Actors.ADMIN);

        vault.haltVault();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Halted));

        vault.unhalt();
        assertEq(uint8(vault.vaultStatus()), uint8(VaultStatus.Active));

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
