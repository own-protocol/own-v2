// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnLendingPool} from "../../src/core/OwnLendingPool.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {IVaultYieldManager} from "../../src/interfaces/IVaultYieldManager.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";
import {VaultYieldManager} from "../../src/periphery/VaultYieldManager.sol";
import {OwnAToken} from "../../src/tokens/OwnAToken.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title VaultYieldManager Unit Tests
/// @notice Shell wiring: receives stablecoin revenue, distribute() splits it —
///         treasury cut to registry.treasury(), remainder converted 1:1 via
///         OwnLendingPool.supply and pushed to LPs via OwnVault.shareYield.
///         Uses the real pool + vault (both unit-tested elsewhere); BorrowManager
///         flows are covered in the integration suite.
contract VaultYieldManagerTest is BaseTest {
    OwnLendingPool public pool;
    OwnAToken public aUSDG;
    OwnVault public vault;
    VaultYieldManager public yieldManager;
    MockERC20 public usdg;

    address public supplier = makeAddr("supplier"); // stands in for the router
    address public lp = makeAddr("lp");
    address public treasury = makeAddr("treasury");
    address public stranger = makeAddr("stranger");
    address public vmManager = makeAddr("vmManager"); // the VM entity (shell manager)

    uint256 constant CUT = 2000; // 20%
    uint256 constant LP_DEPOSIT = 100_000e6;

    function setUp() public override {
        super.setUp();

        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.startPrank(Actors.ADMIN);
        pool = new OwnLendingPool(
            address(protocolRegistry), address(usdg), "Own aUSDG", "oaUSDG", "Own Debt USDG", "odUSDG", 8000, 9500
        );
        pool.setSupplierAllowed(supplier, true);
        vm.stopPrank();

        aUSDG = OwnAToken(pool.aToken());

        vm.startPrank(Actors.ADMIN);
        vault = new OwnVault(pool.aToken(), "Own aUSDG Vault", "owaUSDG", address(protocolRegistry), Actors.ADMIN);
        yieldManager = new VaultYieldManager(address(protocolRegistry), address(vault), address(pool), vmManager, CUT);
        vault.setManager(address(yieldManager));
        pool.setSupplierAllowed(address(yieldManager), true);
        vm.stopPrank();

        // Seed the vault with LP shares (supply → aUSDG → open ERC-4626 deposit).
        usdg.mint(supplier, LP_DEPOSIT);
        vm.startPrank(supplier);
        usdg.approve(address(pool), LP_DEPOSIT);
        pool.supply(address(usdg), LP_DEPOSIT, lp, 0);
        vm.stopPrank();
        vm.startPrank(lp);
        aUSDG.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, lp);
        vm.stopPrank();
    }

    /// @dev Simulate a BorrowManager premium sweep landing on the shell.
    function _sweep(
        uint256 amount
    ) internal {
        usdg.mint(address(yieldManager), amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_wiring() public view {
        assertEq(yieldManager.vault(), address(vault));
        assertEq(yieldManager.pool(), address(pool));
        assertEq(yieldManager.stablecoin(), address(usdg));
        assertEq(yieldManager.manager(), vmManager);
        assertEq(yieldManager.treasuryCutBps(), CUT);
        assertEq(yieldManager.pendingYield(), 0);
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        new VaultYieldManager(address(0), address(vault), address(pool), vmManager, CUT);
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        new VaultYieldManager(address(protocolRegistry), address(0), address(pool), vmManager, CUT);
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        new VaultYieldManager(address(protocolRegistry), address(vault), address(0), vmManager, CUT);
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        new VaultYieldManager(address(protocolRegistry), address(vault), address(pool), address(0), CUT);
    }

    function test_constructor_invalidCut_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultYieldManager.InvalidTreasuryCut.selector, BPS + 1));
        new VaultYieldManager(address(protocolRegistry), address(vault), address(pool), vmManager, BPS + 1);
    }

    function test_constructor_assetMismatch_reverts() public {
        // A vault whose asset is the raw stablecoin, not the pool's aToken.
        vm.prank(Actors.ADMIN);
        OwnVault wrongVault =
            new OwnVault(address(usdg), "Wrong Vault", "wUSDG", address(protocolRegistry), Actors.ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultYieldManager.AssetMismatch.selector, address(usdg), address(aUSDG))
        );
        new VaultYieldManager(address(protocolRegistry), address(wrongVault), address(pool), vmManager, CUT);
    }

    // ──────────────────────────────────────────────────────────
    //  distribute
    // ──────────────────────────────────────────────────────────

    function test_distribute_splitsAndLiftsSharePrice() public {
        _setTreasury(treasury);
        _sweep(10_000e6);
        assertEq(yieldManager.pendingYield(), 10_000e6);

        uint256 assetsBefore = vault.previewRedeem(vault.balanceOf(lp));

        vm.expectEmit(true, false, false, true, address(yieldManager));
        emit IVaultYieldManager.YieldDistributed(stranger, 2000e6, 8000e6);
        vm.prank(stranger); // permissionless crank
        yieldManager.distribute();

        assertEq(usdg.balanceOf(treasury), 2000e6, "treasury got 20%");
        assertEq(aUSDG.balanceOf(address(vault)), LP_DEPOSIT + 8000e6, "vault got 80% as aUSDG");
        assertEq(yieldManager.pendingYield(), 0, "shell drained");
        assertEq(aUSDG.balanceOf(address(yieldManager)), 0, "no aToken residue");

        // LP share price rose by exactly the distributed yield.
        uint256 assetsAfter = vault.previewRedeem(vault.balanceOf(lp));
        assertGt(assetsAfter, assetsBefore, "share price rose");
        assertApproxEqAbs(assetsAfter - assetsBefore, 8000e6, 1);
    }

    function test_distribute_roundingFloorsTreasuryCut() public {
        _setTreasury(treasury);
        _sweep(33); // cut = 33 × 2000 / 10000 = 6.6 → 6 (floor favors LPs)
        yieldManager.distribute();
        assertEq(usdg.balanceOf(treasury), 6);
        assertEq(aUSDG.balanceOf(address(vault)), LP_DEPOSIT + 27);
    }

    function test_distribute_zeroCut_allToLPs() public {
        _setTreasury(treasury);
        vm.prank(Actors.ADMIN);
        yieldManager.setTreasuryCutBps(0);

        _sweep(10_000e6);
        yieldManager.distribute();
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(aUSDG.balanceOf(address(vault)), LP_DEPOSIT + 10_000e6);
    }

    function test_distribute_fullCut_allToTreasury() public {
        _setTreasury(treasury);
        vm.prank(Actors.ADMIN);
        yieldManager.setTreasuryCutBps(BPS);

        _sweep(10_000e6);
        yieldManager.distribute();
        assertEq(usdg.balanceOf(treasury), 10_000e6);
        assertEq(aUSDG.balanceOf(address(vault)), LP_DEPOSIT, "nothing supplied to vault");
    }

    function test_distribute_zeroBalance_reverts() public {
        _setTreasury(treasury);
        vm.expectRevert(IVaultYieldManager.NothingToDistribute.selector);
        yieldManager.distribute();
    }

    function test_distribute_noShares_reverts() public {
        // Fresh vault with no LPs — yield must wait, not accrue to the first depositor.
        vm.startPrank(Actors.ADMIN);
        OwnVault emptyVault =
            new OwnVault(pool.aToken(), "Empty Vault", "owEmpty", address(protocolRegistry), Actors.ADMIN);
        VaultYieldManager freshShell =
            new VaultYieldManager(address(protocolRegistry), address(emptyVault), address(pool), vmManager, CUT);
        pool.setSupplierAllowed(address(freshShell), true);
        vm.stopPrank();

        _setTreasury(treasury);
        usdg.mint(address(freshShell), 1000e6);
        vm.expectRevert(IVaultYieldManager.NoSharesOutstanding.selector);
        freshShell.distribute();
    }

    function test_distribute_treasuryUnset_reverts() public {
        // BaseTest leaves the registry TREASURY slot unset by default.
        _sweep(1000e6);
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        yieldManager.distribute();
    }

    // ──────────────────────────────────────────────────────────
    //  Manager passthroughs
    // ──────────────────────────────────────────────────────────

    function test_acceptDeposit_passthrough() public {
        // Turn on the async queue (operator setting), request as LP, accept via shell.
        vm.prank(Actors.ADMIN);
        vault.setRequireDepositApproval(true);

        usdg.mint(supplier, 5000e6);
        vm.startPrank(supplier);
        usdg.approve(address(pool), 5000e6);
        pool.supply(address(usdg), 5000e6, lp, 0);
        vm.stopPrank();

        vm.startPrank(lp);
        aUSDG.approve(address(vault), 5000e6);
        uint256 requestId = vault.requestDeposit(5000e6, lp, 0);
        vm.stopPrank();

        uint256 sharesBefore = vault.balanceOf(lp);
        vm.prank(vmManager);
        yieldManager.acceptDeposit(requestId);
        assertGt(vault.balanceOf(lp), sharesBefore, "shares minted via passthrough");
    }

    function test_rejectDeposit_passthrough() public {
        vm.prank(Actors.ADMIN);
        vault.setRequireDepositApproval(true);

        usdg.mint(supplier, 5000e6);
        vm.startPrank(supplier);
        usdg.approve(address(pool), 5000e6);
        pool.supply(address(usdg), 5000e6, lp, 0);
        vm.stopPrank();

        vm.startPrank(lp);
        aUSDG.approve(address(vault), 5000e6);
        uint256 requestId = vault.requestDeposit(5000e6, lp, 0);
        vm.stopPrank();

        vm.prank(vmManager);
        yieldManager.rejectDeposit(requestId);
        assertEq(aUSDG.balanceOf(lp), 5000e6, "assets returned via passthrough");
    }

    function test_depositPassthroughs_onlyManager_revert() public {
        // Neither strangers nor protocol operators drive the deposit queue — only
        // the shell manager (the VM entity).
        vm.startPrank(stranger);
        vm.expectRevert(IVaultYieldManager.OnlyManager.selector);
        yieldManager.acceptDeposit(1);
        vm.expectRevert(IVaultYieldManager.OnlyManager.selector);
        yieldManager.rejectDeposit(1);
        vm.stopPrank();

        vm.startPrank(Actors.ADMIN); // holds OPERATOR in BaseTest — still not the manager
        vm.expectRevert(IVaultYieldManager.OnlyManager.selector);
        yieldManager.acceptDeposit(1);
        vm.stopPrank();
    }

    function test_claimEarnedInterest_noBorrowManager_reverts() public {
        // Permissionless entry, but lending was never enabled on this vault.
        vm.prank(stranger);
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        yieldManager.claimEarnedInterest(1e6);
    }

    function test_setManager_onlyAdmin_updatesAndEmits() public {
        vm.prank(stranger);
        vm.expectRevert(IVaultYieldManager.OnlyAdmin.selector);
        yieldManager.setManager(stranger);

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        yieldManager.setManager(address(0));

        address newManager = makeAddr("newManager");
        vm.expectEmit(true, true, false, true, address(yieldManager));
        emit IVaultYieldManager.ManagerUpdated(vmManager, newManager);
        vm.prank(Actors.ADMIN);
        yieldManager.setManager(newManager);
        assertEq(yieldManager.manager(), newManager);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function test_setTreasuryCutBps_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(IVaultYieldManager.OnlyAdmin.selector);
        yieldManager.setTreasuryCutBps(1000);
    }

    function test_setTreasuryCutBps_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(yieldManager));
        emit IVaultYieldManager.TreasuryCutUpdated(CUT, 1000);
        vm.prank(Actors.ADMIN);
        yieldManager.setTreasuryCutBps(1000);
        assertEq(yieldManager.treasuryCutBps(), 1000);
    }

    function test_setTreasuryCutBps_aboveMax_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IVaultYieldManager.InvalidTreasuryCut.selector, BPS + 1));
        yieldManager.setTreasuryCutBps(BPS + 1);
    }

    function test_rescueToken_recoversNonRevenueToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(yieldManager), 5e18);

        vm.expectEmit(true, true, false, true, address(yieldManager));
        emit IVaultYieldManager.TokenRescued(address(stray), treasury, 5e18);
        vm.prank(Actors.ADMIN);
        yieldManager.rescueToken(address(stray), treasury);
        assertEq(stray.balanceOf(treasury), 5e18);
    }

    function test_rescueToken_revenueToken_reverts() public {
        _sweep(1000e6);
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IVaultYieldManager.CannotRescueRevenue.selector, address(usdg)));
        yieldManager.rescueToken(address(usdg), treasury);
    }

    function test_rescueToken_byManager() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(yieldManager), 3e18);
        vm.prank(vmManager);
        yieldManager.rescueToken(address(stray), vmManager);
        assertEq(stray.balanceOf(vmManager), 3e18);
    }

    function test_rescueToken_onlyOperatorOrManager() public {
        vm.prank(stranger);
        vm.expectRevert(IVaultYieldManager.OnlyOperatorOrManager.selector);
        yieldManager.rescueToken(address(weth), stranger);
    }

    function test_rescueToken_zeroRecipient_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IVaultYieldManager.ZeroAddress.selector);
        yieldManager.rescueToken(address(weth), address(0));
    }
}
