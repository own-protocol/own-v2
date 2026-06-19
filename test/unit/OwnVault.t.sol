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
        // Minimal asset registry so VaultManager price resolution (onVaultUnhalted) works.
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(new StubAssetRegistryForVault()));
        vault = new OwnVault(address(weth), "Own WETH Vault", "oWETH", address(protocolRegistry), Actors.VM1);
        vm.stopPrank();
        vm.label(address(vault), "OwnVault-WETH");

        // fulfillWithdrawal consults the VaultManager (withdrawalBreachesUtil); haltVault/unhalt
        // notify it too. Deploy it and register the vault (collateral ticker "ETH" so onVaultUnhalted
        // can resolve a price). With zero collateral mark and no exposure, withdrawalBreachesUtil
        // still returns false, so the deposit/withdrawal tests are unaffected.
        _deployVaultManager();
        vm.prank(Actors.ADMIN);
        vaultManager.registerVault(address(vault), ETH);
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
    //  ERC-4626: maxDeposit / maxMint capacity reporting (A2-L-01)
    // ──────────────────────────────────────────────────────────

    /// @dev maxMint must report 0 to non-manager callers — mint() is manager-only in every mode.
    function test_maxMint_zeroForNonManager() public {
        vm.prank(Actors.LP1);
        assertEq(vault.maxMint(Actors.LP1), 0, "non-manager cannot mint");
    }

    /// @dev The bound manager can mint to any receiver, so it reports unlimited.
    function test_maxMint_maxForManager() public {
        vm.prank(Actors.VM1);
        assertEq(vault.maxMint(Actors.LP1), type(uint256).max, "manager can mint");
    }

    /// @dev With the approval gate off (default), deposit() is open, so capacity is unlimited.
    function test_maxDeposit_openMode_maxForAnyone() public {
        vm.prank(Actors.LP1);
        assertEq(vault.maxDeposit(Actors.LP1), type(uint256).max, "open deposits");
    }

    /// @dev With the approval gate on, only the manager's deposit() succeeds — others get 0.
    function test_maxDeposit_approvalMode_zeroForNonManager() public {
        _enableDepositApproval();
        vm.prank(Actors.LP1);
        assertEq(vault.maxDeposit(Actors.LP1), 0, "gated: non-manager");
    }

    /// @dev The manager can still deposit (for any receiver) under the approval gate.
    function test_maxDeposit_approvalMode_maxForManager() public {
        _enableDepositApproval();
        vm.prank(Actors.VM1);
        assertEq(vault.maxDeposit(Actors.LP1), type(uint256).max, "gated: manager ok");
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
        vm.expectRevert(IOwnVault.OnlyManager.selector);
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

    /// @dev Regression: an external Aave liquidation can pull the vault's collateral (aToken)
    ///      balance below `_pendingDepositAssets`. `totalAssets()` must saturate to 0 rather than
    ///      underflow-revert — a revert here would brick every path that reads it (previews,
    ///      withdrawals, keeper price marks).
    function test_totalAssets_saturatesWhenBalanceBelowPending() public {
        _enableDepositApproval();

        // Accepted backing (5) + a larger pending deposit (10) => balance 15, pending 10.
        _depositAs(Actors.LP2, 5 ether);

        uint256 pending = 10 ether;
        weth.mint(Actors.LP1, pending);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), pending);
        vault.requestDeposit(pending, Actors.LP1, 0);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 5 ether, "accepted assets before seizure");

        // Simulate an external Aave liquidation seizing collateral below the pending total.
        vm.prank(address(vault));
        weth.transfer(address(0xdead), 13 ether); // balance 15 -> 2, below 10 pending
        assertLt(weth.balanceOf(address(vault)), pending, "balance now below pending");

        // Pre-fix this underflowed (Panic 0x11) and bricked the vault; now it saturates.
        assertEq(vault.totalAssets(), 0, "totalAssets saturates to zero");
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

    function test_getPendingWithdrawals_removeMiddle() public {
        _depositAs(Actors.LP1, 30 ether);
        uint256 third = vault.balanceOf(Actors.LP1) / 3;

        vm.startPrank(Actors.LP1);
        uint256 id1 = vault.requestWithdrawal(third);
        uint256 id2 = vault.requestWithdrawal(third);
        uint256 id3 = vault.requestWithdrawal(third);
        // Cancel the middle request — O(1) removal must keep the other two intact.
        vault.cancelWithdrawal(id2);
        vm.stopPrank();

        uint256[] memory pending = vault.getPendingWithdrawals();
        assertEq(pending.length, 2, "two remain");

        bool has1;
        bool has2;
        bool has3;
        for (uint256 i; i < pending.length; ++i) {
            if (pending[i] == id1) has1 = true;
            if (pending[i] == id2) has2 = true;
            if (pending[i] == id3) has3 = true;
        }
        assertTrue(has1, "id1 retained");
        assertTrue(has3, "id3 retained");
        assertFalse(has2, "id2 removed");
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

    // Per-asset halt moved to VaultManager (permanent); see VaultManager.t.sol.

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

    // Exposure / utilisation / health are now owned by VaultManager; see VaultManager.t.sol.
    // Payment token moved to VaultManager (global); see VaultManager.t.sol.

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

    /// @dev H-05: fulfillWithdrawal must sync the VaultManager collateral mark when collateral leaves
    ///      (mirrors releaseCollateral). Without the onCollateralReleased call the mark stays stale-high
    ///      and the global utilisation gate (mint/borrow/serial-withdraw) reads collateral already gone.
    function test_fulfillWithdrawal_syncsCollateralMark() public {
        // Deposit 10 WETH and mark the collateral at the $3,000 ETH price → $30,000 mark.
        uint256 shares = _depositAs(Actors.LP1, 10 ether);
        _pullCollateralPrice(address(vault));
        assertEq(vaultManager.collateralMark(address(vault)), 30_000e18, "mark seeded");
        assertEq(vaultManager.globalCollateralUSD(), 30_000e18, "global seeded");

        // Withdraw half the position; the mark/global collateral must drop ~50% as the assets leave.
        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(shares / 2);
        vault.fulfillWithdrawal(requestId);

        assertApproxEqRel(vaultManager.collateralMark(address(vault)), 15_000e18, 1e15, "mark ~ -50%");
        assertApproxEqRel(vaultManager.globalCollateralUSD(), 15_000e18, 1e15, "global ~ -50%");
        assertLt(vaultManager.collateralMark(address(vault)), 30_000e18, "mark reduced (H-05 regression)");
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
    //  Lending opt-in (setBorrowManager + grantCreditDelegation)
    // ──────────────────────────────────────────────────────────

    /// @dev Mock variable debt token recording the last approveDelegation call.
    ///      Lives inline to avoid pulling another helper into test/.
    function _deployDebtTokenMock() internal returns (address) {
        return address(new MockDebtTokenForVault());
    }

    function test_setBorrowManager_setsManager() public {
        address userBM = makeAddr("userBM");
        assertEq(vault.borrowManager(), address(0));

        vm.prank(Actors.ADMIN);
        vault.setBorrowManager(userBM);

        assertEq(vault.borrowManager(), userBM);
    }

    function test_setBorrowManager_emitsEvent() public {
        address userBM = makeAddr("userBM");
        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, false, false, false);
        emit IOwnVault.LendingEnabled(userBM);
        vault.setBorrowManager(userBM);
    }

    function test_setBorrowManager_zeroManager_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.setBorrowManager(address(0));
    }

    function test_setBorrowManager_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.setBorrowManager(makeAddr("userBM"));
    }

    function test_setBorrowManager_alreadyEnabled_reverts() public {
        vm.startPrank(Actors.ADMIN);
        vault.setBorrowManager(makeAddr("userBM"));
        vm.expectRevert(IOwnVault.LendingAlreadyEnabled.selector);
        vault.setBorrowManager(makeAddr("u2"));
        vm.stopPrank();
    }

    function test_grantCreditDelegation_delegatesToBoundManager() public {
        address userBM = makeAddr("userBM");
        address debt = _deployDebtTokenMock();

        vm.startPrank(Actors.ADMIN);
        vault.setBorrowManager(userBM);
        vault.grantCreditDelegation(debt);
        vm.stopPrank();

        // Beneficiary is the bound manager — never an admin-chosen address.
        assertEq(MockDebtTokenForVault(debt).borrowAllowance(address(vault), userBM), type(uint256).max);
    }

    function test_grantCreditDelegation_requiresManager_reverts() public {
        address debt = _deployDebtTokenMock();
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.LendingNotEnabled.selector);
        vault.grantCreditDelegation(debt);
    }

    function test_grantCreditDelegation_zeroToken_reverts() public {
        vm.startPrank(Actors.ADMIN);
        vault.setBorrowManager(makeAddr("userBM"));
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.grantCreditDelegation(address(0));
        vm.stopPrank();
    }

    function test_grantCreditDelegation_onlyAdmin() public {
        address debt = _deployDebtTokenMock();
        vm.prank(Actors.ADMIN);
        vault.setBorrowManager(makeAddr("userBM"));
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.grantCreditDelegation(debt);
    }

    // ──────────────────────────────────────────────────────────
    //  Manager binding
    // ──────────────────────────────────────────────────────────
    // Quote signers moved to the global signer registry on VaultManager; see VaultManager.t.sol.

    function test_constructor_bindsManager() public view {
        assertEq(vault.manager(), Actors.VM1, "manager bound at construction");
    }

    function test_setManager_byAdmin_succeeds() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, false);
        emit IOwnVault.ManagerUpdated(Actors.VM1, newManager);
        vm.prank(Actors.ADMIN);
        vault.setManager(newManager);

        assertEq(vault.manager(), newManager);
    }

    function test_setManager_notAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.setManager(makeAddr("newManager"));
    }

    function test_setManager_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.setManager(address(0));
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
        vm.expectRevert(IOwnVault.OnlyManager.selector);
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

    // ──────────────────────────────────────────────────────────
    //  Collateral release — free-collateral bound (H-06)
    // ──────────────────────────────────────────────────────────

    /// @dev 1 token backing the share pool + 100 tokens of pending-deposit escrow held in the vault.
    ///      Raw balance is 101 while totalAssets() (backing only) is 1.
    function _backingPlusPendingEscrow() internal returns (uint256 backing, uint256 escrow) {
        backing = 1 ether;
        escrow = 100 ether;
        _depositAs(Actors.LP1, backing); // accepted backing (approval still off)
        _enableDepositApproval();
        weth.mint(Actors.LP2, escrow);
        vm.startPrank(Actors.LP2);
        weth.approve(address(vault), escrow);
        vault.requestDeposit(escrow, Actors.LP2, 0);
        vm.stopPrank();
    }

    /// @notice H-06: releaseCollateral must not exceed share-backing collateral (totalAssets()).
    ///         Without the bound, a force-execute can release more than the backing pool — the extra
    ///         comes out of pending-deposit escrow, and the next totalAssets() read underflows
    ///         (super.totalAssets() - _pendingDepositAssets), permanently bricking the vault.
    function test_releaseCollateral_exceedingBackedCollateral_reverts() public {
        (uint256 backing, uint256 escrow) = _backingPlusPendingEscrow();

        uint256 attempt = 50 ether; // > backing, but the raw balance (101) would cover it — the trap.
        assertEq(vault.totalAssets(), backing, "only backing is spendable");
        assertGt(attempt, vault.totalAssets(), "attempt exceeds backing");
        assertLe(attempt, weth.balanceOf(address(vault)), "raw balance would cover it");

        vm.prank(mockMarket);
        vm.expectRevert(IOwnVault.AmountExceedsBackedCollateral.selector);
        vault.releaseCollateral(Actors.LP1, attempt);

        // Vault stays healthy: no underflow brick, escrow untouched and still refundable.
        assertEq(vault.totalAssets(), backing, "totalAssets intact");
        assertEq(weth.balanceOf(address(vault)), backing + escrow, "escrow untouched");
    }

    /// @notice The bound is not over-strict: releasing exactly the backing pool is allowed.
    function test_releaseCollateral_atBackedCollateral_succeeds() public {
        _depositAs(Actors.LP1, 10 ether); // backing only, no escrow
        assertEq(vault.totalAssets(), 10 ether);

        vm.prank(mockMarket);
        vault.releaseCollateral(Actors.LP1, 10 ether);

        assertEq(vault.totalAssets(), 0, "full backing released");
        assertEq(weth.balanceOf(Actors.LP1), 10 ether, "recipient received the collateral");
    }

    /// @notice H-06: the same bound guards the bad-debt release path.
    function test_releaseCollateralForBadDebt_exceedingBackedCollateral_reverts() public {
        (uint256 backing,) = _backingPlusPendingEscrow();

        address bm = makeAddr("badDebtBM");
        vm.prank(Actors.ADMIN);
        vault.setBorrowManager(bm);
        _setTreasury(makeAddr("treasury"));

        vm.prank(bm);
        vm.expectRevert(IOwnVault.AmountExceedsBackedCollateral.selector);
        vault.releaseCollateralForBadDebt(50 ether);

        assertEq(vault.totalAssets(), backing, "totalAssets intact");
    }
}

/// @dev Minimal asset registry stub: every asset uses the in-house oracle. Lets the VaultManager
///      resolve a collateral price during onVaultUnhalted.
contract StubAssetRegistryForVault {
    function getOracleType(
        bytes32
    ) external pure returns (uint8) {
        return 1; // in-house
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
