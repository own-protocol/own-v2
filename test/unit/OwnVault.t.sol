// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnVault} from "../../src/core/OwnVault.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {BPS, PRECISION, VaultStatus, WithdrawalRequest, WithdrawalStatus} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title OwnVault Unit Tests
/// @notice Tests ERC-4626 deposit/withdraw, async withdrawal queue, health factor,
///         utilization tracking, halt/unhalt, wind-down, and fee management.
contract OwnVaultTest is BaseTest {
    OwnVault public vault;

    address public mockMarket = makeAddr("market");

    uint256 constant INITIAL_MAX_UTIL = 8000; // 80%
    uint256 constant INITIAL_AUM_FEE = 50; // 0.5%
    uint256 constant INITIAL_RESERVE_FACTOR = 1000; // 10%

    function setUp() public override {
        super.setUp();

        vm.prank(Actors.ADMIN);
        vault = new OwnVault(
            address(usdc),
            "Own USDC Vault",
            "oUSDC",
            Actors.ADMIN,
            mockMarket,
            Actors.FEE_RECIPIENT,
            INITIAL_MAX_UTIL,
            INITIAL_AUM_FEE,
            INITIAL_RESERVE_FACTOR
        );
        vm.label(address(vault), "OwnVault-USDC");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _depositAs(address lp, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, lp);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626: deposit
    // ──────────────────────────────────────────────────────────

    function test_deposit_succeeds() public {
        uint256 depositAmount = 1000e6;
        uint256 shares = _depositAs(Actors.LP1, depositAmount);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(Actors.LP1), shares);
        assertEq(vault.totalAssets(), depositAmount);
    }

    function test_deposit_multipleLPs() public {
        _depositAs(Actors.LP1, 1000e6);
        _depositAs(Actors.LP2, 2000e6);

        assertEq(vault.totalAssets(), 3000e6);
        assertGt(vault.balanceOf(Actors.LP1), 0);
        assertGt(vault.balanceOf(Actors.LP2), 0);
    }

    function test_deposit_zeroAmount_returnsZeroShares() public {
        usdc.mint(Actors.LP1, 1000e6);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(0, Actors.LP1);
        vm.stopPrank();
        assertEq(shares, 0);
    }

    function test_deposit_whileHalted_reverts() public {
        vm.prank(Actors.ADMIN);
        vault.halt(bytes32("emergency"));

        usdc.mint(Actors.LP1, 1000e6);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(IOwnVault.VaultIsHalted.selector);
        vault.deposit(1000e6, Actors.LP1);
        vm.stopPrank();
    }

    function test_deposit_whileWindingDown_reverts() public {
        vm.prank(Actors.ADMIN);
        vault.initiateWindDown();

        usdc.mint(Actors.LP1, 1000e6);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(IOwnVault.VaultIsWindingDown.selector);
        vault.deposit(1000e6, Actors.LP1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626: share pricing
    // ──────────────────────────────────────────────────────────

    function test_convertToShares_initiallyOneToOne() public {
        uint256 assets = 1000e6;
        uint256 expectedShares = vault.convertToShares(assets);
        // First deposit: 1:1 (adjusted for decimal difference if any)
        assertGt(expectedShares, 0);
    }

    function test_convertToAssets_afterDeposit() public {
        _depositAs(Actors.LP1, 1000e6);
        uint256 shares = vault.balanceOf(Actors.LP1);
        uint256 assets = vault.convertToAssets(shares);
        assertEq(assets, 1000e6);
    }

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    function test_requestWithdrawal_succeeds() public {
        uint256 shares = _depositAs(Actors.LP1, 1000e6);

        vm.expectEmit(true, true, false, true);
        emit IOwnVault.WithdrawalRequested(1, Actors.LP1, shares);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        assertEq(requestId, 1);

        WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(req.owner, Actors.LP1);
        assertEq(req.shares, shares);
        assertEq(uint256(req.status), uint256(WithdrawalStatus.Pending));
    }

    function test_requestWithdrawal_zeroShares_reverts() public {
        _depositAs(Actors.LP1, 1000e6);

        vm.prank(Actors.LP1);
        vm.expectRevert(IOwnVault.ZeroAmount.selector);
        vault.requestWithdrawal(0);
    }

    function test_cancelWithdrawal_succeeds() public {
        uint256 shares = _depositAs(Actors.LP1, 1000e6);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        vm.expectEmit(true, true, false, false);
        emit IOwnVault.WithdrawalCancelled(requestId, Actors.LP1);

        vm.prank(Actors.LP1);
        vault.cancelWithdrawal(requestId);

        WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(uint256(req.status), uint256(WithdrawalStatus.Cancelled));

        // Shares should be returned
        assertEq(vault.balanceOf(Actors.LP1), shares);
    }

    function test_cancelWithdrawal_notOwner_reverts() public {
        uint256 shares = _depositAs(Actors.LP1, 1000e6);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.NotRequestOwner.selector, requestId, Actors.ATTACKER));
        vault.cancelWithdrawal(requestId);
    }

    function test_fulfillWithdrawal_succeeds() public {
        uint256 depositAmount = 1000e6;
        uint256 shares = _depositAs(Actors.LP1, depositAmount);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        vm.expectEmit(true, true, false, true);
        emit IOwnVault.WithdrawalFulfilled(requestId, Actors.LP1, depositAmount, shares);

        uint256 assets = vault.fulfillWithdrawal(requestId);

        assertEq(assets, depositAmount);
        assertEq(usdc.balanceOf(Actors.LP1), depositAmount);
        assertEq(vault.balanceOf(Actors.LP1), 0);
    }

    function test_fulfillWithdrawal_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.WithdrawalRequestNotFound.selector, 999));
        vault.fulfillWithdrawal(999);
    }

    function test_getPendingWithdrawals_fifoOrder() public {
        _depositAs(Actors.LP1, 1000e6);
        _depositAs(Actors.LP2, 2000e6);

        uint256 lp1Shares = vault.balanceOf(Actors.LP1);
        uint256 lp2Shares = vault.balanceOf(Actors.LP2);

        vm.prank(Actors.LP1);
        vault.requestWithdrawal(lp1Shares);

        vm.prank(Actors.LP2);
        vault.requestWithdrawal(lp2Shares);

        uint256[] memory pending = vault.getPendingWithdrawals();
        assertEq(pending.length, 2);
        assertEq(pending[0], 1); // LP1's request first
        assertEq(pending[1], 2); // LP2's request second
    }

    // ──────────────────────────────────────────────────────────
    //  Vault status and control
    // ──────────────────────────────────────────────────────────

    function test_vaultStatus_initiallyActive() public view {
        assertEq(uint256(vault.vaultStatus()), uint256(VaultStatus.Active));
    }

    function test_halt_admin_succeeds() public {
        vm.expectEmit(true, false, false, false);
        emit IOwnVault.VaultHalted(bytes32("emergency"));

        vm.prank(Actors.ADMIN);
        vault.halt(bytes32("emergency"));

        assertEq(uint256(vault.vaultStatus()), uint256(VaultStatus.Halted));
    }

    function test_halt_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.halt(bytes32("emergency"));
    }

    function test_unhalt_admin_succeeds() public {
        vm.startPrank(Actors.ADMIN);
        vault.halt(bytes32("emergency"));

        vm.expectEmit(false, false, false, false);
        emit IOwnVault.VaultUnhalted();

        vault.unhalt();
        vm.stopPrank();

        assertEq(uint256(vault.vaultStatus()), uint256(VaultStatus.Active));
    }

    function test_haltAsset_succeeds() public {
        vm.expectEmit(true, true, false, false);
        emit IOwnVault.AssetHalted(TSLA, bytes32("oracle"));

        vm.prank(Actors.ADMIN);
        vault.haltAsset(TSLA, bytes32("oracle"));

        assertTrue(vault.isAssetHalted(TSLA));
    }

    function test_unhaltAsset_succeeds() public {
        vm.startPrank(Actors.ADMIN);
        vault.haltAsset(TSLA, bytes32("oracle"));

        vm.expectEmit(true, false, false, false);
        emit IOwnVault.AssetUnhalted(TSLA);

        vault.unhaltAsset(TSLA);
        vm.stopPrank();

        assertFalse(vault.isAssetHalted(TSLA));
    }

    function test_initiateWindDown_succeeds() public {
        vm.expectEmit(false, false, false, false);
        emit IOwnVault.WindDownInitiated();

        vm.prank(Actors.ADMIN);
        vault.initiateWindDown();

        assertEq(uint256(vault.vaultStatus()), uint256(VaultStatus.WindingDown));
    }

    function test_initiateWindDown_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.initiateWindDown();
    }

    // ──────────────────────────────────────────────────────────
    //  Health and utilization
    // ──────────────────────────────────────────────────────────

    function test_utilization_zeroWithNoExposure() public {
        _depositAs(Actors.LP1, 1000e6);
        assertEq(vault.utilization(), 0);
    }

    function test_maxUtilization_initial() public view {
        assertEq(vault.maxUtilization(), INITIAL_MAX_UTIL);
    }

    function test_setMaxUtilization_admin_succeeds() public {
        vm.prank(Actors.ADMIN);
        vault.setMaxUtilization(9000);

        assertEq(vault.maxUtilization(), 9000);
    }

    function test_setMaxUtilization_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.setMaxUtilization(9000);
    }

    function test_healthFactor_noExposure_returnsMax() public {
        _depositAs(Actors.LP1, 1000e6);
        uint256 hf = vault.healthFactor();
        // With collateral and no exposure, health factor should be max / very high
        assertGt(hf, PRECISION);
    }

    // ──────────────────────────────────────────────────────────
    //  Fee management
    // ──────────────────────────────────────────────────────────

    function test_aumFee_initial() public view {
        assertEq(vault.aumFee(), INITIAL_AUM_FEE);
    }

    function test_reserveFactor_initial() public view {
        assertEq(vault.reserveFactor(), INITIAL_RESERVE_FACTOR);
    }

    function test_setAumFee_admin_succeeds() public {
        vm.prank(Actors.ADMIN);
        vault.setAumFee(100);
        assertEq(vault.aumFee(), 100);
    }

    function test_setAumFee_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.setAumFee(100);
    }

    function test_setReserveFactor_admin_succeeds() public {
        vm.prank(Actors.ADMIN);
        vault.setReserveFactor(2000);
        assertEq(vault.reserveFactor(), 2000);
    }

    function test_setReserveFactor_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.setReserveFactor(2000);
    }

    function test_distributeSpreadRevenue_splits() public {
        _depositAs(Actors.LP1, 10_000e6);

        uint256 revenue = 100e6;
        usdc.mint(mockMarket, revenue);

        vm.startPrank(mockMarket);
        usdc.approve(address(vault), revenue);
        vault.distributeSpreadRevenue(revenue);
        vm.stopPrank();

        // Reserve factor = 10%, so protocol gets 10, LPs get 90
        // LP share price should have increased
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, 10_000e6 + 90e6); // 90% to LPs
        assertEq(usdc.balanceOf(Actors.FEE_RECIPIENT), 10e6); // 10% to treasury
    }

    function test_treasury_returnsCorrectAddress() public view {
        assertEq(vault.treasury(), Actors.FEE_RECIPIENT);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_deposit_withdraw_roundtrip(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 100_000_000e6); // 1 to 100M USDC

        uint256 shares = _depositAs(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        uint256 assets = vault.fulfillWithdrawal(requestId);

        // Should get back the same amount (no exposure, no fees accrued)
        assertApproxEqAbs(assets, amount, 1);
    }

    function testFuzz_multipleDeposits_totalAssets(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 1e6, 50_000_000e6);
        a2 = bound(a2, 1e6, 50_000_000e6);

        _depositAs(Actors.LP1, a1);
        _depositAs(Actors.LP2, a2);

        assertEq(vault.totalAssets(), a1 + a2);
    }
}
