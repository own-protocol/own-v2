// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnVault} from "../../src/core/OwnVault.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {
    BPS,
    DepositRequest,
    DepositStatus,
    PRECISION,
    VaultStatus,
    WithdrawalRequest,
    WithdrawalStatus
} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title OwnVault Unit Tests
/// @notice Tests ERC-4626 deposit/withdraw (with slippage + inflation-attack resistance), async
///         deposit/withdrawal queues, health factor, utilization, halt/unhalt, and VM share yield.
contract OwnVaultTest is BaseTest {
    OwnVault public vault;

    address public mockMarket = makeAddr("market");

    uint256 constant INITIAL_MAX_UTIL = 8000; // 80%

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        vault = new OwnVault(
            address(weth), "Own WETH Vault", "oWETH", address(protocolRegistry), Actors.VM1, INITIAL_MAX_UTIL
        );
        vm.stopPrank();
        vm.label(address(vault), "OwnVault-WETH");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Deposit as the bound VM.
    function _depositAs(address lp, uint256 amount) internal returns (uint256 shares) {
        weth.mint(Actors.VM1, amount);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, lp);
        vm.stopPrank();
    }

    /// @dev Enable deposit approval mode (admin-only toggle).
    function _enableDepositApproval() internal {
        vm.prank(Actors.ADMIN);
        vault.setRequireDepositApproval(true);
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626: deposit (VM only)
    // ──────────────────────────────────────────────────────────

    function test_deposit_succeeds() public {
        uint256 depositAmount = 10 ether;
        uint256 shares = _depositAs(Actors.LP1, depositAmount);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(Actors.LP1), shares);
        assertEq(vault.totalAssets(), depositAmount);
    }

    function test_deposit_multipleLPs() public {
        _depositAs(Actors.LP1, 10 ether);
        _depositAs(Actors.LP2, 20 ether);

        assertEq(vault.totalAssets(), 30 ether);
        assertGt(vault.balanceOf(Actors.LP1), 0);
        assertGt(vault.balanceOf(Actors.LP2), 0);
    }

    function test_deposit_onlyVM() public {
        // With approval required, non-VM deposit reverts
        _enableDepositApproval();

        weth.mint(Actors.LP1, 10 ether);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), 10 ether);
        vm.expectRevert(IOwnVault.DepositApprovalRequired.selector);
        vault.deposit(10 ether, Actors.LP1);
        vm.stopPrank();
    }

    function test_deposit_whileHalted_reverts() public {
        vm.prank(Actors.ADMIN);
        vault.haltVault();

        weth.mint(Actors.VM1, 10 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 10 ether);
        vm.expectRevert(IOwnVault.VaultIsHalted.selector);
        vault.deposit(10 ether, Actors.LP1);
        vm.stopPrank();
    }

    function test_deposit_whilePaused_reverts() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        weth.mint(Actors.VM1, 10 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 10 ether);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        vault.deposit(10 ether, Actors.LP1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  ERC-4626: share pricing
    // ──────────────────────────────────────────────────────────

    function test_convertToShares_firstDepositAppliesOffset() public view {
        uint256 assets = 10 ether;
        // Virtual-shares offset of 6: first deposit mints assets * 1e6 shares.
        assertEq(vault.convertToShares(assets), assets * 1e6);
    }

    function test_decimals_includesOffset() public view {
        // Share decimals = collateral decimals (18 for WETH) + offset (6).
        assertEq(vault.decimals(), 24);
    }

    function test_convertToAssets_afterDeposit() public {
        _depositAs(Actors.LP1, 10 ether);
        uint256 shares = vault.balanceOf(Actors.LP1);
        uint256 assets = vault.convertToAssets(shares);
        assertEq(assets, 10 ether);
    }

    // ──────────────────────────────────────────────────────────
    //  Async deposit queue
    // ──────────────────────────────────────────────────────────

    function test_requestDeposit_succeeds() public {
        _enableDepositApproval();
        uint256 depositAmount = 10 ether;
        weth.mint(Actors.LP1, depositAmount);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), depositAmount);

        vm.expectEmit(true, true, false, true);
        emit IOwnVault.DepositRequested(1, Actors.LP1, Actors.LP1, depositAmount);

        uint256 requestId = vault.requestDeposit(depositAmount, Actors.LP1, 0);
        vm.stopPrank();

        assertEq(requestId, 1);

        // Assets should be escrowed in vault
        assertEq(weth.balanceOf(address(vault)), depositAmount);
        assertEq(weth.balanceOf(Actors.LP1), 0);

        DepositRequest memory req = vault.getDepositRequest(requestId);
        assertEq(req.depositor, Actors.LP1);
        assertEq(req.receiver, Actors.LP1);
        assertEq(req.assets, depositAmount);
        assertEq(uint256(req.status), uint256(DepositStatus.Pending));
    }

    function test_acceptDeposit_mintsShares() public {
        _enableDepositApproval();
        // Bootstrap vault with an initial VM deposit to establish share price
        _depositAs(Actors.LP2, 10 ether);

        uint256 depositAmount = 10 ether;
        weth.mint(Actors.LP1, depositAmount);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), depositAmount);
        uint256 requestId = vault.requestDeposit(depositAmount, Actors.LP1, 0);
        vm.stopPrank();

        uint256 expectedShares = vault.previewDeposit(depositAmount);

        vm.expectEmit(true, true, false, true);
        emit IOwnVault.DepositAccepted(requestId, Actors.LP1, expectedShares);

        vm.prank(Actors.VM1);
        vault.acceptDeposit(requestId);

        DepositRequest memory req = vault.getDepositRequest(requestId);
        assertEq(uint256(req.status), uint256(DepositStatus.Accepted));

        // Shares should be minted to receiver
        assertGt(vault.balanceOf(Actors.LP1), 0);
        assertEq(vault.totalAssets(), 20 ether); // initial + async deposit
    }

    function test_rejectDeposit_returnsAssets() public {
        _enableDepositApproval();
        uint256 depositAmount = 10 ether;
        weth.mint(Actors.LP1, depositAmount);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), depositAmount);
        uint256 requestId = vault.requestDeposit(depositAmount, Actors.LP1, 0);
        vm.stopPrank();

        vm.expectEmit(true, true, false, false);
        emit IOwnVault.DepositRejected(requestId, Actors.LP1);

        vm.prank(Actors.VM1);
        vault.rejectDeposit(requestId);

        DepositRequest memory req = vault.getDepositRequest(requestId);
        assertEq(uint256(req.status), uint256(DepositStatus.Rejected));

        // Assets should be returned to depositor
        assertEq(weth.balanceOf(Actors.LP1), depositAmount);
        assertEq(vault.balanceOf(Actors.LP1), 0);
    }

    function test_cancelDeposit_returnsAssets() public {
        _enableDepositApproval();
        uint256 depositAmount = 10 ether;
        weth.mint(Actors.LP1, depositAmount);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), depositAmount);
        uint256 requestId = vault.requestDeposit(depositAmount, Actors.LP1, 0);

        vm.expectEmit(true, true, false, false);
        emit IOwnVault.DepositCancelled(requestId, Actors.LP1);

        vault.cancelDeposit(requestId);
        vm.stopPrank();

        DepositRequest memory req = vault.getDepositRequest(requestId);
        assertEq(uint256(req.status), uint256(DepositStatus.Cancelled));

        // Assets should be returned to depositor
        assertEq(weth.balanceOf(Actors.LP1), depositAmount);
        assertEq(vault.balanceOf(Actors.LP1), 0);
    }

    function test_acceptDeposit_notVM_reverts() public {
        _enableDepositApproval();
        uint256 depositAmount = 10 ether;
        weth.mint(Actors.LP1, depositAmount);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), depositAmount);
        uint256 requestId = vault.requestDeposit(depositAmount, Actors.LP1, 0);
        vm.stopPrank();

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        vault.acceptDeposit(requestId);
    }

    function test_cancelDeposit_notDepositor_reverts() public {
        _enableDepositApproval();
        uint256 depositAmount = 10 ether;
        weth.mint(Actors.LP1, depositAmount);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), depositAmount);
        uint256 requestId = vault.requestDeposit(depositAmount, Actors.LP1, 0);
        vm.stopPrank();

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.OnlyDepositor.selector, requestId));
        vault.cancelDeposit(requestId);
    }

    // ──────────────────────────────────────────────────────────
    //  Async withdrawal queue
    // ──────────────────────────────────────────────────────────

    function test_requestWithdrawal_succeeds() public {
        uint256 shares = _depositAs(Actors.LP1, 10 ether);

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
        _depositAs(Actors.LP1, 10 ether);

        vm.prank(Actors.LP1);
        vm.expectRevert(IOwnVault.ZeroAmount.selector);
        vault.requestWithdrawal(0);
    }

    function test_cancelWithdrawal_succeeds() public {
        uint256 shares = _depositAs(Actors.LP1, 10 ether);

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
        uint256 shares = _depositAs(Actors.LP1, 10 ether);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.NotRequestOwner.selector, requestId, Actors.ATTACKER));
        vault.cancelWithdrawal(requestId);
    }

    function test_fulfillWithdrawal_succeeds() public {
        uint256 depositAmount = 10 ether;
        uint256 shares = _depositAs(Actors.LP1, depositAmount);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        vm.expectEmit(true, true, false, true);
        emit IOwnVault.WithdrawalFulfilled(requestId, Actors.LP1, depositAmount, shares);

        uint256 assets = vault.fulfillWithdrawal(requestId);

        assertEq(assets, depositAmount);
        assertEq(weth.balanceOf(Actors.LP1), depositAmount);
        assertEq(vault.balanceOf(Actors.LP1), 0);
    }

    function test_fulfillWithdrawal_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.WithdrawalRequestNotFound.selector, 999));
        vault.fulfillWithdrawal(999);
    }

    function test_getPendingWithdrawals_fifoOrder() public {
        _depositAs(Actors.LP1, 10 ether);
        _depositAs(Actors.LP2, 20 ether);

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
        vm.expectEmit(false, false, false, false);
        emit IOwnVault.VaultHalted();

        vm.prank(Actors.ADMIN);
        vault.haltVault();

        assertEq(uint256(vault.vaultStatus()), uint256(VaultStatus.Halted));
    }

    function test_halt_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.haltVault();
    }

    function test_unhalt_admin_succeeds() public {
        vm.startPrank(Actors.ADMIN);
        vault.haltVault();

        vm.expectEmit(false, false, false, false);
        emit IOwnVault.VaultUnhalted();

        vault.unhalt();
        vm.stopPrank();

        assertEq(uint256(vault.vaultStatus()), uint256(VaultStatus.Active));
    }

    function test_haltAsset_succeeds() public {
        vm.expectEmit(true, false, false, false);
        emit IOwnVault.AssetHalted(TSLA);

        vm.prank(Actors.ADMIN);
        vault.haltAsset(TSLA, TSLA_PRICE);

        assertTrue(vault.isAssetHalted(TSLA));
        assertEq(vault.getAssetHaltPrice(TSLA), TSLA_PRICE);
    }

    function test_unhaltAsset_succeeds() public {
        vm.startPrank(Actors.ADMIN);
        vault.haltAsset(TSLA, TSLA_PRICE);

        vm.expectEmit(true, false, false, false);
        emit IOwnVault.AssetUnhalted(TSLA);

        vault.unhaltAsset(TSLA);
        vm.stopPrank();

        assertFalse(vault.isAssetHalted(TSLA));
        assertEq(vault.getAssetHaltPrice(TSLA), 0);
    }

    function test_pause_admin_succeeds() public {
        vm.expectEmit(true, false, false, false);
        emit IOwnVault.VaultPaused(bytes32("emergency"));

        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        assertEq(uint256(vault.vaultStatus()), uint256(VaultStatus.Paused));
    }

    function test_pause_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.pause(bytes32("emergency"));
    }

    // ──────────────────────────────────────────────────────────
    //  Health and utilization
    // ──────────────────────────────────────────────────────────

    function test_utilization_zeroWithNoExposure() public {
        _depositAs(Actors.LP1, 10 ether);
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
        _depositAs(Actors.LP1, 10 ether);
        uint256 hf = vault.healthFactor();
        // With collateral and no exposure, health factor should be max / very high
        assertGt(hf, PRECISION);
    }

    // ──────────────────────────────────────────────────────────
    //  Payment token
    // ──────────────────────────────────────────────────────────

    function test_setPaymentToken_VM_succeeds() public {
        vm.expectEmit(true, true, false, false);
        emit IOwnVault.PaymentTokenUpdated(address(0), address(usdc));

        vm.prank(Actors.VM1);
        vault.setPaymentToken(address(usdc));

        assertEq(vault.paymentToken(), address(usdc));
    }

    function test_setPaymentToken_notVM_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        vault.setPaymentToken(address(usdc));
    }

    function test_setPaymentToken_zeroAddress_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.setPaymentToken(address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Withdrawal wait period
    // ──────────────────────────────────────────────────────────

    function test_withdrawalWaitPeriod_default_isZero() public view {
        assertEq(vault.withdrawalWaitPeriod(), 0);
    }

    function test_setWithdrawalWaitPeriod_admin_succeeds() public {
        vm.prank(Actors.ADMIN);
        vault.setWithdrawalWaitPeriod(3 days);
        assertEq(vault.withdrawalWaitPeriod(), 3 days);
    }

    function test_setWithdrawalWaitPeriod_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        vault.setWithdrawalWaitPeriod(3 days);
    }

    function test_fulfillWithdrawal_beforeWaitPeriod_reverts() public {
        vm.prank(Actors.ADMIN);
        vault.setWithdrawalWaitPeriod(3 days);

        uint256 shares = _depositAs(Actors.LP1, 10 ether);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        // Try immediately — should fail
        uint256 readyAt = block.timestamp + 3 days;
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.WithdrawalWaitPeriodNotElapsed.selector, requestId, readyAt));
        vault.fulfillWithdrawal(requestId);
    }

    function test_fulfillWithdrawal_afterWaitPeriod_succeeds() public {
        vm.prank(Actors.ADMIN);
        vault.setWithdrawalWaitPeriod(3 days);

        uint256 shares = _depositAs(Actors.LP1, 10 ether);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        // Warp past wait period
        vm.warp(block.timestamp + 3 days + 1);

        uint256 assets = vault.fulfillWithdrawal(requestId);
        assertEq(assets, 10 ether);
        assertEq(weth.balanceOf(Actors.LP1), 10 ether);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_deposit_withdraw_roundtrip(
        uint256 amount
    ) public {
        amount = bound(amount, 0.01 ether, 100_000 ether); // 0.01 to 100K ETH

        uint256 shares = _depositAs(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares);

        uint256 assets = vault.fulfillWithdrawal(requestId);

        // Should get back the same amount (no exposure, no fees accrued)
        assertApproxEqAbs(assets, amount, 1);
    }

    function testFuzz_multipleDeposits_totalAssets(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 0.01 ether, 50_000 ether);
        a2 = bound(a2, 0.01 ether, 50_000 ether);

        _depositAs(Actors.LP1, a1);
        _depositAs(Actors.LP2, a2);

        assertEq(vault.totalAssets(), a1 + a2);
    }

    // ──────────────────────────────────────────────────────────
    //  enableLending (Aave credit delegation)
    // ──────────────────────────────────────────────────────────

    /// @dev Mock variable debt token recording the last approveDelegation call.
    ///      Lives inline to avoid pulling another helper into test/.
    function _deployDebtTokenMock() internal returns (address) {
        return address(new MockDebtTokenForVault());
    }

    function test_enableLending_setsManagerAndApprovesDelegation() public {
        address userBM = makeAddr("userBM");
        address debt = _deployDebtTokenMock();

        assertEq(vault.borrowManager(), address(0));

        vm.prank(Actors.ADMIN);
        vault.enableLending(userBM, debt);

        assertEq(vault.borrowManager(), userBM);
        assertEq(MockDebtTokenForVault(debt).borrowAllowance(address(vault), userBM), type(uint256).max);
    }

    function test_enableLending_emitsEvent() public {
        address userBM = makeAddr("userBM");
        address debt = _deployDebtTokenMock();

        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, true, false, false);
        emit IOwnVault.LendingEnabled(userBM, debt);
        vault.enableLending(userBM, debt);
    }

    function test_enableLending_zeroUserManager_reverts() public {
        address debt = _deployDebtTokenMock();
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.enableLending(address(0), debt);
    }

    function test_enableLending_zeroDebtToken_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.enableLending(makeAddr("userBM"), address(0));
    }

    function test_enableLending_onlyAdmin() public {
        address debt = _deployDebtTokenMock();
        address userBM = makeAddr("userBM");
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.enableLending(userBM, debt);
    }

    function test_enableLending_alreadyEnabled_reverts() public {
        address userBM = makeAddr("userBM");
        address debt = _deployDebtTokenMock();

        vm.startPrank(Actors.ADMIN);
        vault.enableLending(userBM, debt);

        vm.expectRevert(IOwnVault.LendingAlreadyEnabled.selector);
        vault.enableLending(makeAddr("u2"), debt);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Quote signers
    // ──────────────────────────────────────────────────────────

    function test_constructor_noSignersSeeded() public view {
        // No signer is registered at construction — not even the bound VM.
        assertFalse(vault.isQuoteSigner(Actors.VM1), "no signer seeded");
    }

    function test_addQuoteSigner_byVM_succeeds() public {
        address signer = makeAddr("kmsSigner");
        assertFalse(vault.isQuoteSigner(signer));

        vm.expectEmit(true, false, false, false);
        emit IOwnVault.QuoteSignerAdded(signer);
        vm.prank(Actors.VM1);
        vault.addQuoteSigner(signer);

        assertTrue(vault.isQuoteSigner(signer));
    }

    function test_addQuoteSigner_byAdmin_succeeds() public {
        address signer = makeAddr("kmsSigner");
        vm.prank(Actors.ADMIN);
        vault.addQuoteSigner(signer);
        assertTrue(vault.isQuoteSigner(signer));
    }

    function test_addQuoteSigner_unauthorized_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyVMOrAdmin.selector);
        vault.addQuoteSigner(makeAddr("kmsSigner"));
    }

    function test_addQuoteSigner_zeroAddress_reverts() public {
        vm.prank(Actors.VM1);
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.addQuoteSigner(address(0));
    }

    function test_addQuoteSigner_duplicate_reverts() public {
        address signer = makeAddr("kmsSigner");
        vm.startPrank(Actors.VM1);
        vault.addQuoteSigner(signer);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.AlreadyQuoteSigner.selector, signer));
        vault.addQuoteSigner(signer);
        vm.stopPrank();
    }

    function test_removeQuoteSigner_byVM_succeeds() public {
        address signer = makeAddr("kmsSigner");
        vm.startPrank(Actors.VM1);
        vault.addQuoteSigner(signer);

        vm.expectEmit(true, false, false, false);
        emit IOwnVault.QuoteSignerRemoved(signer);
        vault.removeQuoteSigner(signer);
        vm.stopPrank();

        assertFalse(vault.isQuoteSigner(signer));
    }

    function test_removeQuoteSigner_byAdmin_succeeds() public {
        address signer = makeAddr("kmsSigner");
        vm.prank(Actors.VM1);
        vault.addQuoteSigner(signer);

        vm.prank(Actors.ADMIN);
        vault.removeQuoteSigner(signer);
        assertFalse(vault.isQuoteSigner(signer));
    }

    function test_removeQuoteSigner_notSigner_reverts() public {
        address notSigner = makeAddr("notSigner");
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.NotQuoteSigner.selector, notSigner));
        vault.removeQuoteSigner(notSigner);
    }

    function test_setVM_doesNotChangeSignerSet() public {
        // Register the current VM as a signer, then rotate the VM.
        vm.prank(Actors.VM1);
        vault.addQuoteSigner(Actors.VM1);

        address newVM = makeAddr("newVM");
        vm.prank(Actors.ADMIN);
        vault.setVM(newVM);

        // Old VM remains an authorised signer; new VM is not auto-added.
        assertTrue(vault.isQuoteSigner(Actors.VM1), "old signer retained");
        assertFalse(vault.isQuoteSigner(newVM), "new vm not auto-signer");
    }

    // ──────────────────────────────────────────────────────────
    //  Deposit slippage (minSharesOut)
    // ──────────────────────────────────────────────────────────

    function test_depositWithMinShares_succeeds() public {
        uint256 amount = 10 ether;
        uint256 expected = vault.previewDeposit(amount);

        weth.mint(Actors.VM1, amount);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, Actors.LP1, expected);
        vm.stopPrank();

        assertEq(shares, expected);
        assertEq(vault.balanceOf(Actors.LP1), expected);
    }

    function test_depositWithMinShares_slippageExceeded_reverts() public {
        uint256 amount = 10 ether;
        uint256 expected = vault.previewDeposit(amount);

        weth.mint(Actors.VM1, amount);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), amount);
        // Demand one more share than achievable.
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.InsufficientSharesOut.selector, expected, expected + 1));
        vault.deposit(amount, Actors.LP1, expected + 1);
        vm.stopPrank();
    }

    function test_acceptDeposit_belowMinShares_reverts() public {
        _enableDepositApproval();
        uint256 amount = 10 ether;
        uint256 fair = vault.previewDeposit(amount);

        weth.mint(Actors.LP1, amount);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), amount);
        // Floor above what the deposit can produce.
        uint256 requestId = vault.requestDeposit(amount, Actors.LP1, fair + 1);
        vm.stopPrank();

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.InsufficientSharesOut.selector, fair, fair + 1));
        vault.acceptDeposit(requestId);
    }

    function test_acceptDeposit_atMinShares_succeeds() public {
        _enableDepositApproval();
        uint256 amount = 10 ether;
        uint256 fair = vault.previewDeposit(amount);

        weth.mint(Actors.LP1, amount);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), amount);
        uint256 requestId = vault.requestDeposit(amount, Actors.LP1, fair);
        vm.stopPrank();

        vm.prank(Actors.VM1);
        vault.acceptDeposit(requestId);

        assertEq(vault.balanceOf(Actors.LP1), fair);
    }

    // ──────────────────────────────────────────────────────────
    //  shareYield (VM-distributed LP rewards)
    // ──────────────────────────────────────────────────────────

    function test_shareYield_raisesSharePrice() public {
        _depositAs(Actors.LP1, 10 ether);
        uint256 sharesBefore = vault.balanceOf(Actors.LP1);
        uint256 assetsBefore = vault.convertToAssets(sharesBefore);

        uint256 yield = 2 ether;
        weth.mint(Actors.VM1, yield);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), yield);
        vault.shareYield(yield);
        vm.stopPrank();

        // Same shares now redeem for more collateral.
        assertEq(vault.balanceOf(Actors.LP1), sharesBefore, "shares unchanged");
        assertEq(vault.totalAssets(), 12 ether, "yield added to assets");
        assertGt(vault.convertToAssets(sharesBefore), assetsBefore, "share price rose");
    }

    function test_shareYield_emitsEvent() public {
        _depositAs(Actors.LP1, 10 ether);

        uint256 yield = 1 ether;
        weth.mint(Actors.VM1, yield);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), yield);
        vm.expectEmit(true, false, false, true);
        emit IOwnVault.ShareYieldAdded(Actors.VM1, yield);
        vault.shareYield(yield);
        vm.stopPrank();
    }

    function test_shareYield_notVM_reverts() public {
        _depositAs(Actors.LP1, 10 ether);

        weth.mint(Actors.LP1, 1 ether);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), 1 ether);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        vault.shareYield(1 ether);
        vm.stopPrank();
    }

    function test_shareYield_zeroAmount_reverts() public {
        _depositAs(Actors.LP1, 10 ether);
        vm.prank(Actors.VM1);
        vm.expectRevert(IOwnVault.ZeroAmount.selector);
        vault.shareYield(0);
    }

    function test_shareYield_noShares_reverts() public {
        // Empty vault: nothing to distribute to.
        weth.mint(Actors.VM1, 1 ether);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), 1 ether);
        vm.expectRevert(IOwnVault.NoSharesToReward.selector);
        vault.shareYield(1 ether);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Inflation / first-depositor attack resistance (offset 6)
    // ──────────────────────────────────────────────────────────

    /// @notice An attacker who seeds 1 wei then donates a large amount cannot make a
    ///         later victim deposit round down to zero shares — the offset makes the
    ///         attack economically irrational and protects victim value.
    function test_inflationAttack_victimRetainsValue() public {
        // Attacker is first depositor with 1 wei.
        weth.mint(Actors.ATTACKER, 1);
        vm.startPrank(Actors.ATTACKER);
        weth.approve(address(vault), 1);
        vault.deposit(1, Actors.ATTACKER);
        vm.stopPrank();

        // Attacker donates a large amount directly to inflate the raw balance.
        uint256 donation = 100 ether;
        weth.mint(address(vault), donation);
        uint256 attackerShares = vault.balanceOf(Actors.ATTACKER);

        // Victim deposits a normal amount.
        uint256 victimDeposit = 10 ether;
        weth.mint(Actors.LP1, victimDeposit);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), victimDeposit);
        uint256 victimShares = vault.deposit(victimDeposit, Actors.LP1);
        vm.stopPrank();

        // Victim still receives shares (does not round to zero) and retains essentially
        // all of their value — the donation did not let the attacker steal it.
        assertGt(victimShares, 0, "victim got non-zero shares");
        uint256 victimRedeemable = vault.convertToAssets(victimShares);
        assertGe(victimRedeemable, victimDeposit * 9999 / 10_000, "victim retains ~all value");

        // The attack is a massive loss: the attacker can never recover the donation,
        // so redeeming all their shares yields far less than the 1 wei + donation they sank.
        uint256 attackerRedeemable = vault.convertToAssets(attackerShares);
        assertLt(attackerRedeemable, donation, "attacker cannot recover the donation");
    }
}

/// @dev Inline minimal mock — records the last approveDelegation call so the
///      OwnVault.enableLending test can assert delegation was wired.
contract MockDebtTokenForVault {
    mapping(address => mapping(address => uint256)) private _allowances;

    function approveDelegation(address delegatee, uint256 amount) external {
        _allowances[msg.sender][delegatee] = amount;
    }

    function borrowAllowance(address fromUser, address toUser) external view returns (uint256) {
        return _allowances[fromUser][toUser];
    }
}
