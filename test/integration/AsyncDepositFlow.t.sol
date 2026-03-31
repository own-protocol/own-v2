// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, DepositRequest, DepositStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title AsyncDepositFlow Integration Test
/// @notice Tests the async deposit lifecycle: requestDeposit → acceptDeposit / rejectDeposit / cancelDeposit.
contract AsyncDepositFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 50 ether;

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

        vm.startPrank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();

        vm.prank(Actors.ADMIN);
        vault.setRequireDepositApproval(true);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Request deposit + VM accepts → shares minted
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_requestAndAccept() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        // Collateral transferred to vault
        assertEq(weth.balanceOf(Actors.LP1), 0, "LP drained");
        assertEq(weth.balanceOf(address(vault)), LP_DEPOSIT, "vault received collateral");

        // Request is pending
        DepositRequest memory req = vault.getDepositRequest(requestId);
        assertEq(req.depositor, Actors.LP1);
        assertEq(req.receiver, Actors.LP1);
        assertEq(req.assets, LP_DEPOSIT);
        assertEq(uint8(req.status), uint8(DepositStatus.Pending));

        // Check pending list
        uint256[] memory pending = vault.getPendingDeposits();
        assertEq(pending.length, 1);
        assertEq(pending[0], requestId);

        // VM accepts
        vm.prank(Actors.VM1);
        vault.acceptDeposit(requestId);

        // Shares minted to LP
        uint256 shares = vault.balanceOf(Actors.LP1);
        assertGt(shares, 0, "LP received shares");
        assertEq(vault.totalAssets(), LP_DEPOSIT, "total assets match");

        // Request status updated
        req = vault.getDepositRequest(requestId);
        assertEq(uint8(req.status), uint8(DepositStatus.Accepted));

        // Pending list cleared
        pending = vault.getPendingDeposits();
        assertEq(pending.length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Request deposit + VM rejects → collateral returned
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_requestAndReject() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        assertEq(weth.balanceOf(Actors.LP1), 0, "LP collateral escrowed");

        // VM rejects
        vm.prank(Actors.VM1);
        vault.rejectDeposit(requestId);

        // Collateral returned
        assertEq(weth.balanceOf(Actors.LP1), LP_DEPOSIT, "LP collateral returned");
        assertEq(vault.balanceOf(Actors.LP1), 0, "no shares minted");

        // Request status updated
        DepositRequest memory req = vault.getDepositRequest(requestId);
        assertEq(uint8(req.status), uint8(DepositStatus.Rejected));

        // Pending list cleared
        assertEq(vault.getPendingDeposits().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Depositor cancels pending request → collateral returned
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_cancelByDepositor() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);

        assertEq(weth.balanceOf(Actors.LP1), 0, "collateral escrowed");

        vault.cancelDeposit(requestId);
        vm.stopPrank();

        assertEq(weth.balanceOf(Actors.LP1), LP_DEPOSIT, "collateral returned");
        assertEq(vault.balanceOf(Actors.LP1), 0, "no shares minted");

        DepositRequest memory req = vault.getDepositRequest(requestId);
        assertEq(uint8(req.status), uint8(DepositStatus.Cancelled));
        assertEq(vault.getPendingDeposits().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Only depositor can cancel
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_cancelByNonOwner_reverts() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.LP2);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.OnlyDepositor.selector, requestId));
        vault.cancelDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple LPs request → VM processes in order
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_multipleRequests() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);
        _fundWETH(Actors.LP2, LP_DEPOSIT * 2);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 reqId1 = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.startPrank(Actors.LP2);
        weth.approve(address(vault), LP_DEPOSIT * 2);
        uint256 reqId2 = vault.requestDeposit(LP_DEPOSIT * 2, Actors.LP2);
        vm.stopPrank();

        uint256[] memory pending = vault.getPendingDeposits();
        assertEq(pending.length, 2);

        // VM accepts first request
        vm.prank(Actors.VM1);
        vault.acceptDeposit(reqId1);

        pending = vault.getPendingDeposits();
        assertEq(pending.length, 1);

        uint256 lp1Shares = vault.balanceOf(Actors.LP1);
        assertGt(lp1Shares, 0, "LP1 received shares");

        // VM accepts second request
        vm.prank(Actors.VM1);
        vault.acceptDeposit(reqId2);

        uint256 lp2Shares = vault.balanceOf(Actors.LP2);
        assertGt(lp2Shares, 0, "LP2 received shares");
        assertApproxEqAbs(lp2Shares, lp1Shares * 2, 1, "LP2 has ~2x shares");

        assertEq(vault.getPendingDeposits().length, 0);
        assertEq(vault.totalAssets(), LP_DEPOSIT * 3, "total assets correct");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: requestDeposit blocked during pause
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_whilePaused_reverts() public {
        vm.prank(Actors.ADMIN);
        vault.pause(bytes32("emergency"));

        _fundWETH(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: requestDeposit blocked during halt
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_whileHalted_reverts() public {
        vm.startPrank(Actors.ADMIN);
        vault.haltAsset(TSLA, TSLA_PRICE);
        vault.haltVault();
        vm.stopPrank();

        _fundWETH(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.VaultIsHalted.selector);
        vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Accept deposit from non-VM reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_acceptByNonVM_reverts() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.LP2);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        vault.acceptDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Reject deposit from non-VM reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_rejectByNonVM_reverts() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.LP2);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        vault.rejectDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Double accept reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_doubleAccept_reverts() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.VM1);
        vault.acceptDeposit(requestId);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.DepositRequestNotPending.selector, requestId));
        vault.acceptDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Zero amount request reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_zeroAmount_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        vault.requestDeposit(0, Actors.LP1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Different receiver gets shares
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_differentReceiver() public {
        _fundWETH(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 requestId = vault.requestDeposit(LP_DEPOSIT, Actors.LP2);
        vm.stopPrank();

        vm.prank(Actors.VM1);
        vault.acceptDeposit(requestId);

        assertEq(vault.balanceOf(Actors.LP1), 0, "depositor has no shares");
        assertGt(vault.balanceOf(Actors.LP2), 0, "receiver has shares");
    }

    // ══════════════════════════════════════════════════════════
    //  Deposit Approval Toggle
    // ══════════════════════════════════════════════════════════

    function test_requestDeposit_reverts_whenApprovalNotRequired() public {
        // Disable approval (setUp enabled it)
        vm.prank(Actors.ADMIN);
        vault.setRequireDepositApproval(false);

        _fundWETH(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.DepositApprovalNotRequired.selector);
        vault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    function test_directDeposit_succeeds_whenApprovalNotRequired() public {
        // Disable approval
        vm.prank(Actors.ADMIN);
        vault.setRequireDepositApproval(false);

        _fundWETH(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        uint256 shares = vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        assertGt(shares, 0, "LP received shares directly");
        assertEq(vault.balanceOf(Actors.LP1), shares);
        assertEq(vault.totalAssets(), LP_DEPOSIT);
    }

    function test_directDeposit_reverts_whenApprovalRequired() public {
        // Approval is already enabled in setUp
        _fundWETH(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        weth.approve(address(vault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.DepositApprovalRequired.selector);
        vault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    function test_setRequireDepositApproval_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.setRequireDepositApproval(true);
    }

    function test_setRequireDepositApproval_emitsEvent() public {
        vm.prank(Actors.ADMIN);
        vm.expectEmit(false, false, false, true);
        emit IOwnVault.DepositApprovalUpdated(false);
        vault.setRequireDepositApproval(false);
    }
}
