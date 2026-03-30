// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, BPS, OrderStatus, VaultStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title HaltFlow Integration Test
/// @notice Tests halt/unhalt vault-wide and per-asset, wind-down, and behavior
///         during halted state (deposits blocked, withdrawals blocked, etc.).
contract HaltFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    VaultManager public vaultMgr;
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

        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        vaultMgr = new VaultManager(Actors.ADMIN, address(protocolRegistry));

        usdcVault = new OwnVault(
            address(usdc), "Own USDC Vault", "oUSDC", address(protocolRegistry), Actors.VM1, 8000, 2000, 2000
        );

        market = new OwnMarket(address(protocolRegistry), address(usdcVault), 1 days, 6 hours);

        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), address(vaultMgr));

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        vm.stopPrank();

        // Set payment token (single token per vault)
        vm.prank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));

        // LP deposits (via VM1)
        _fundUSDC(Actors.VM1, LP_DEPOSIT);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Vault-wide halt
    // ══════════════════════════════════════════════════════════

    function test_halt_depositsBlocked() public {
        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Halted));

        _fundUSDC(Actors.VM1, 1000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 1000e6);
        vm.expectRevert(abi.encodeWithSignature("VaultIsHalted()"));
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
    }

    function test_halt_maxDepositReturnsZero() public {
        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        assertEq(usdcVault.maxDeposit(Actors.LP1), 0);
        assertEq(usdcVault.maxMint(Actors.LP1), 0);
    }

    function test_halt_maxWithdrawReturnsZero() public {
        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        assertEq(usdcVault.maxWithdraw(Actors.LP1), 0);
        assertEq(usdcVault.maxRedeem(Actors.LP1), 0);
    }

    function test_unhalt_resumesNormal() public {
        vm.startPrank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));
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

    function test_halt_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OnlyAdmin()"));
        usdcVault.halt(bytes32("attack"));
    }

    function test_unhalt_onlyAdmin() public {
        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OnlyAdmin()"));
        usdcVault.unhalt();
    }

    // ══════════════════════════════════════════════════════════
    //  Per-asset halt
    // ══════════════════════════════════════════════════════════

    function test_haltAsset_setsFlag() public {
        vm.prank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, bytes32("market closed"));

        assertTrue(usdcVault.isAssetHalted(TSLA));
        assertFalse(usdcVault.isAssetHalted(GOLD));
    }

    function test_unhaltAsset_clearsFlag() public {
        vm.startPrank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, bytes32("market closed"));
        assertTrue(usdcVault.isAssetHalted(TSLA));

        usdcVault.unhaltAsset(TSLA);
        assertFalse(usdcVault.isAssetHalted(TSLA));
        vm.stopPrank();
    }

    function test_haltAsset_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OnlyAdmin()"));
        usdcVault.haltAsset(TSLA, bytes32("attack"));
    }

    // ══════════════════════════════════════════════════════════
    //  Wind-down
    // ══════════════════════════════════════════════════════════

    function test_windDown_blocksDeposits() public {
        vm.prank(Actors.ADMIN);
        usdcVault.initiateWindDown();

        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.WindingDown));
        assertEq(usdcVault.maxDeposit(Actors.LP1), 0);
        assertEq(usdcVault.maxMint(Actors.LP1), 0);

        _fundUSDC(Actors.VM1, 1000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 1000e6);
        vm.expectRevert(abi.encodeWithSignature("VaultIsWindingDown()"));
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
    }

    function test_windDown_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OnlyAdmin()"));
        usdcVault.initiateWindDown();
    }

    // ══════════════════════════════════════════════════════════
    //  Withdrawal queue during halt
    // ══════════════════════════════════════════════════════════

    function test_halt_asyncWithdrawalStillRequestable() public {
        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        uint256 shares = usdcVault.balanceOf(Actors.LP1);
        assertGt(shares, 0);

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares / 2);
        assertGt(requestId, 0);
    }

    function test_halt_unhalt_fulfillWithdrawal() public {
        uint256 shares = usdcVault.balanceOf(Actors.LP1);

        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

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

        usdcVault.halt(bytes32("first"));
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Halted));

        usdcVault.unhalt();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));

        usdcVault.halt(bytes32("second"));
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
