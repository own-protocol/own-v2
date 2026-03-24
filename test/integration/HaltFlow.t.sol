// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, BPS, OrderStatus, PriceType, VaultStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title HaltFlow Integration Test
/// @notice Tests halt/unhalt vault-wide and per-asset, wind-down, and behavior
///         during halted state (deposits blocked, withdrawals blocked, etc.).
contract HaltFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    PaymentTokenRegistry public paymentRegistry;
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
        paymentRegistry = new PaymentTokenRegistry(Actors.ADMIN);

        market = new OwnMarket(Actors.ADMIN, address(oracle), address(assetRegistry), address(paymentRegistry));
        vaultMgr = new VaultManager(Actors.ADMIN, address(market), 30);
        market.setVaultManager(address(vaultMgr));

        usdcVault = new OwnVault(
            address(usdc),
            "Own USDC Vault",
            "oUSDC",
            Actors.ADMIN,
            address(market),
            Actors.FEE_RECIPIENT,
            8000,
            50,
            1000
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

        // LP deposits
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
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

        // Deposits should revert when halted
        _fundUSDC(Actors.LP2, 1000e6);
        vm.startPrank(Actors.LP2);
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

        // Deposits work again
        _fundUSDC(Actors.LP2, 1000e6);
        vm.startPrank(Actors.LP2);
        usdc.approve(address(usdcVault), 1000e6);
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();

        assertGt(usdcVault.balanceOf(Actors.LP2), 0);
    }

    function test_halt_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert("OwnVault: not admin");
        usdcVault.halt(bytes32("attack"));
    }

    function test_unhalt_onlyAdmin() public {
        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        vm.prank(Actors.ATTACKER);
        vm.expectRevert("OwnVault: not admin");
        usdcVault.unhalt();
    }

    // ══════════════════════════════════════════════════════════
    //  Per-asset halt
    // ══════════════════════════════════════════════════════════

    function test_haltAsset_setsFlag() public {
        vm.prank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, bytes32("market closed"));

        assertTrue(usdcVault.isAssetHalted(TSLA));
        assertFalse(usdcVault.isAssetHalted(GOLD)); // other assets unaffected
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
        vm.expectRevert("OwnVault: not admin");
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

        // Deposits revert
        _fundUSDC(Actors.LP2, 1000e6);
        vm.startPrank(Actors.LP2);
        usdc.approve(address(usdcVault), 1000e6);
        vm.expectRevert(abi.encodeWithSignature("VaultIsWindingDown()"));
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
    }

    function test_windDown_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert("OwnVault: not admin");
        usdcVault.initiateWindDown();
    }

    // ══════════════════════════════════════════════════════════
    //  Withdrawal queue during halt
    // ══════════════════════════════════════════════════════════

    function test_halt_asyncWithdrawalStillRequestable() public {
        // LP can still request withdrawal when vault is halted (to allow exit)
        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        uint256 shares = usdcVault.balanceOf(Actors.LP1);
        assertGt(shares, 0);

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares / 2);
        assertGt(requestId, 0);
    }

    function test_halt_unhalt_fulfillWithdrawal() public {
        // Request withdrawal during halt, fulfill after unhalt
        uint256 shares = usdcVault.balanceOf(Actors.LP1);

        vm.prank(Actors.ADMIN);
        usdcVault.halt(bytes32("emergency"));

        vm.prank(Actors.LP1);
        uint256 requestId = usdcVault.requestWithdrawal(shares / 2);

        vm.prank(Actors.ADMIN);
        usdcVault.unhalt();

        // Fulfill the withdrawal
        uint256 balBefore = usdc.balanceOf(Actors.LP1);
        usdcVault.fulfillWithdrawal(requestId);
        uint256 balAfter = usdc.balanceOf(Actors.LP1);

        assertGt(balAfter - balBefore, 0, "LP received assets");
    }

    // ══════════════════════════════════════════════════════════
    //  Halt → Unhalt → Halt cycle
    // ══════════════════════════════════════════════════════════

    function test_haltUnhaltCycle() public {
        vm.startPrank(Actors.ADMIN);

        // First halt
        usdcVault.halt(bytes32("first"));
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Halted));

        // Unhalt
        usdcVault.unhalt();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));

        // Second halt
        usdcVault.halt(bytes32("second"));
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Halted));

        // Unhalt again
        usdcVault.unhalt();
        assertEq(uint8(usdcVault.vaultStatus()), uint8(VaultStatus.Active));

        vm.stopPrank();

        // Deposits work after cycle
        _fundUSDC(Actors.LP2, 1000e6);
        vm.startPrank(Actors.LP2);
        usdc.approve(address(usdcVault), 1000e6);
        usdcVault.deposit(1000e6, Actors.LP2);
        vm.stopPrank();
        assertGt(usdcVault.balanceOf(Actors.LP2), 0);
    }
}
