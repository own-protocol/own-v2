// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, DepositRequest, DepositStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";

/// @title EscrowSeizureFlow Integration Test
/// @notice Pending-deposit escrow is accounted separately (excluded from `totalAssets`) but is NOT
///         segregated custody: the escrowed collateral sits in the vault's single (aToken) balance,
///         which an external Aave liquidation can seize. These tests pin the consequence worth keeping
///         visible — after a seizure that drops the balance below the pending total, the backing pool
///         saturates to zero AND pending depositors can no longer all reclaim principal
///         (first-come-first-served; later reclaimers revert and their funds are stranded).
///         Complements the unit-level saturation regression with the multi-depositor economic outcome.
contract EscrowSeizureFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnVault public vault;

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        // ETH is the vault's collateral ticker — register it so pullCollateralPrice resolves a price.
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ETH, address(weth), ethConfig);
        vm.stopPrank();

        _deployVaultManager();

        vm.startPrank(Actors.ADMIN);
        vault = new OwnVault(address(weth), "Own WETH Vault", "oWETH", address(protocolRegistry), Actors.VM1);
        vaultManager.registerVault(address(vault), ETH);
        vault.setRequireDepositApproval(true);
        vm.stopPrank();

        _setPaymentToken(address(usdc));
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _requestDeposit(address lp, uint256 amount) internal returns (uint256 id) {
        _fundWETH(lp, amount);
        vm.startPrank(lp);
        weth.approve(address(vault), amount);
        id = vault.requestDeposit(amount, lp, 0);
        vm.stopPrank();
    }

    /// @dev Simulate an external Aave liquidation pulling collateral out of the vault's single balance.
    ///      Aave seizes from the raw aToken balance and is blind to the pending/backing split.
    function _seizeCollateral(
        uint256 amount
    ) internal {
        vm.prank(address(vault));
        weth.transfer(address(0xdead), amount);
    }

    // ══════════════════════════════════════════════════════════
    //  Escrow is excluded from backing AND from the collateral mark
    // ══════════════════════════════════════════════════════════

    /// @dev A pending deposit lands in the vault's balance but contributes nothing to `totalAssets`
    ///      or to the VaultManager collateral mark — it is inert until accepted.
    function test_escrow_excludedFromTotalAssetsAndCollateralMark() public {
        // Accept one backing deposit so the vault has live shares and a non-zero collateral mark.
        uint256 backing = 5 ether;
        uint256 id0 = _requestDeposit(Actors.LP3, backing);
        vm.prank(Actors.VM1);
        vault.acceptDeposit(id0);
        _pullCollateralPrice(address(vault));

        uint256 markBefore = vaultManager.globalCollateralUSD();
        assertGt(markBefore, 0, "backing marked into the pool");
        assertEq(vault.totalAssets(), backing, "backing is the only counted collateral");

        // A pending request escrows collateral into the vault balance but adds nothing to the pool.
        _requestDeposit(Actors.LP1, 10 ether);
        assertEq(weth.balanceOf(address(vault)), backing + 10 ether, "escrow physically held in vault");
        assertEq(vault.totalAssets(), backing, "escrow excluded from totalAssets");

        _pullCollateralPrice(address(vault));
        assertEq(vaultManager.globalCollateralUSD(), markBefore, "escrow excluded from collateral mark");
    }

    // ══════════════════════════════════════════════════════════
    //  Aave seizure: backing wiped + later reclaimer locked out
    // ══════════════════════════════════════════════════════════

    /// @dev Two pending depositors, no backing. An external seizure drops the balance below the pending
    ///      total: `totalAssets` saturates to 0 (vault stays usable), but the escrow is now under-funded
    ///      — the first reclaimer is made whole and the second is stranded with their request still
    ///      Pending. Demonstrates pending principal is NOT segregated from the vault's Aave risk.
    function test_escrow_aaveSeizure_wipesBackingAndLocksOutLaterReclaimer() public {
        uint256 id1 = _requestDeposit(Actors.LP1, 10 ether);
        uint256 id2 = _requestDeposit(Actors.LP2, 10 ether);
        assertEq(weth.balanceOf(address(vault)), 20 ether, "both deposits escrowed");
        assertEq(vault.totalAssets(), 0, "no backing - escrow excluded");

        // External Aave liquidation seizes 8 → balance 12, below the 20 pending total.
        _seizeCollateral(8 ether);
        assertEq(weth.balanceOf(address(vault)), 12 ether, "seized below pending total");
        assertEq(vault.totalAssets(), 0, "backing saturates to zero (no underflow / brick)");

        // First reclaimer is made whole out of the remaining balance...
        vm.prank(Actors.LP1);
        vault.cancelDeposit(id1);
        assertEq(weth.balanceOf(Actors.LP1), 10 ether, "LP1 reclaimed full principal");
        assertEq(weth.balanceOf(address(vault)), 2 ether, "only 2 left against LP2's 10");

        // ...the second cannot: the escrow still owes 10 but only 2 remains. Principal is NOT safe.
        vm.prank(Actors.LP2);
        vm.expectRevert(); // ERC20 insufficient balance
        vault.cancelDeposit(id2);

        // The manager's reject path is equally stuck — same underlying shortfall.
        vm.prank(Actors.VM1);
        vm.expectRevert();
        vault.rejectDeposit(id2);

        // LP2's request is untouched by the failed reclaims — funds are stranded, still Pending.
        DepositRequest memory req = vault.getDepositRequest(id2);
        assertEq(uint8(req.status), uint8(DepositStatus.Pending), "LP2 stranded, request still pending");
    }
}
