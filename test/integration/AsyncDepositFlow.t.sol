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
    OwnVault public usdcVault;
    EToken public eTSLA;

    uint256 constant LP_DEPOSIT = 100_000e6;

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

        vm.startPrank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));
        usdcVault.enableAsset(TSLA);
        vm.stopPrank();

        vm.prank(Actors.ADMIN);
        usdcVault.setRequireDepositApproval(true);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Request deposit + VM accepts → shares minted
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_requestAndAccept() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        // Collateral transferred to vault
        assertEq(usdc.balanceOf(Actors.LP1), 0, "LP drained");
        assertEq(usdc.balanceOf(address(usdcVault)), LP_DEPOSIT, "vault received collateral");

        // Request is pending
        DepositRequest memory req = usdcVault.getDepositRequest(requestId);
        assertEq(req.depositor, Actors.LP1);
        assertEq(req.receiver, Actors.LP1);
        assertEq(req.assets, LP_DEPOSIT);
        assertEq(uint8(req.status), uint8(DepositStatus.Pending));

        // Check pending list
        uint256[] memory pending = usdcVault.getPendingDeposits();
        assertEq(pending.length, 1);
        assertEq(pending[0], requestId);

        // VM accepts
        vm.prank(Actors.VM1);
        usdcVault.acceptDeposit(requestId);

        // Shares minted to LP
        uint256 shares = usdcVault.balanceOf(Actors.LP1);
        assertGt(shares, 0, "LP received shares");
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT, "total assets match");

        // Request status updated
        req = usdcVault.getDepositRequest(requestId);
        assertEq(uint8(req.status), uint8(DepositStatus.Accepted));

        // Pending list cleared
        pending = usdcVault.getPendingDeposits();
        assertEq(pending.length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Request deposit + VM rejects → collateral returned
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_requestAndReject() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.LP1), 0, "LP collateral escrowed");

        // VM rejects
        vm.prank(Actors.VM1);
        usdcVault.rejectDeposit(requestId);

        // Collateral returned
        assertEq(usdc.balanceOf(Actors.LP1), LP_DEPOSIT, "LP collateral returned");
        assertEq(usdcVault.balanceOf(Actors.LP1), 0, "no shares minted");

        // Request status updated
        DepositRequest memory req = usdcVault.getDepositRequest(requestId);
        assertEq(uint8(req.status), uint8(DepositStatus.Rejected));

        // Pending list cleared
        assertEq(usdcVault.getPendingDeposits().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Depositor cancels pending request → collateral returned
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_cancelByDepositor() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);

        assertEq(usdc.balanceOf(Actors.LP1), 0, "collateral escrowed");

        usdcVault.cancelDeposit(requestId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.LP1), LP_DEPOSIT, "collateral returned");
        assertEq(usdcVault.balanceOf(Actors.LP1), 0, "no shares minted");

        DepositRequest memory req = usdcVault.getDepositRequest(requestId);
        assertEq(uint8(req.status), uint8(DepositStatus.Cancelled));
        assertEq(usdcVault.getPendingDeposits().length, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Only depositor can cancel
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_cancelByNonOwner_reverts() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.LP2);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.OnlyDepositor.selector, requestId));
        usdcVault.cancelDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple LPs request → VM processes in order
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_multipleRequests() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        _fundUSDC(Actors.LP2, LP_DEPOSIT * 2);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 reqId1 = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.startPrank(Actors.LP2);
        usdc.approve(address(usdcVault), LP_DEPOSIT * 2);
        uint256 reqId2 = usdcVault.requestDeposit(LP_DEPOSIT * 2, Actors.LP2);
        vm.stopPrank();

        uint256[] memory pending = usdcVault.getPendingDeposits();
        assertEq(pending.length, 2);

        // VM accepts first request
        vm.prank(Actors.VM1);
        usdcVault.acceptDeposit(reqId1);

        pending = usdcVault.getPendingDeposits();
        assertEq(pending.length, 1);

        uint256 lp1Shares = usdcVault.balanceOf(Actors.LP1);
        assertGt(lp1Shares, 0, "LP1 received shares");

        // VM accepts second request
        vm.prank(Actors.VM1);
        usdcVault.acceptDeposit(reqId2);

        uint256 lp2Shares = usdcVault.balanceOf(Actors.LP2);
        assertGt(lp2Shares, 0, "LP2 received shares");
        assertApproxEqAbs(lp2Shares, lp1Shares * 2, 1, "LP2 has ~2x shares");

        assertEq(usdcVault.getPendingDeposits().length, 0);
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT * 3, "total assets correct");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: requestDeposit blocked during pause
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_whilePaused_reverts() public {
        vm.prank(Actors.ADMIN);
        usdcVault.pause(bytes32("emergency"));

        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.VaultIsPaused.selector);
        usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: requestDeposit blocked during halt
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_whileHalted_reverts() public {
        vm.startPrank(Actors.ADMIN);
        usdcVault.haltAsset(TSLA, TSLA_PRICE);
        usdcVault.haltVault();
        vm.stopPrank();

        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.VaultIsHalted.selector);
        usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Accept deposit from non-VM reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_acceptByNonVM_reverts() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.LP2);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        usdcVault.acceptDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Reject deposit from non-VM reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_rejectByNonVM_reverts() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.LP2);
        vm.expectRevert(IOwnVault.OnlyVM.selector);
        usdcVault.rejectDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Double accept reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_doubleAccept_reverts() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        vm.prank(Actors.VM1);
        usdcVault.acceptDeposit(requestId);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnVault.DepositRequestNotPending.selector, requestId));
        usdcVault.acceptDeposit(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Zero amount request reverts
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_zeroAmount_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        usdcVault.requestDeposit(0, Actors.LP1);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Different receiver gets shares
    // ══════════════════════════════════════════════════════════

    function test_asyncDeposit_differentReceiver() public {
        _fundUSDC(Actors.LP1, LP_DEPOSIT);

        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 requestId = usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP2);
        vm.stopPrank();

        vm.prank(Actors.VM1);
        usdcVault.acceptDeposit(requestId);

        assertEq(usdcVault.balanceOf(Actors.LP1), 0, "depositor has no shares");
        assertGt(usdcVault.balanceOf(Actors.LP2), 0, "receiver has shares");
    }

    // ══════════════════════════════════════════════════════════
    //  Deposit Approval Toggle
    // ══════════════════════════════════════════════════════════

    function test_requestDeposit_reverts_whenApprovalNotRequired() public {
        // Disable approval (setUp enabled it)
        vm.prank(Actors.ADMIN);
        usdcVault.setRequireDepositApproval(false);

        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.DepositApprovalNotRequired.selector);
        usdcVault.requestDeposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    function test_directDeposit_succeeds_whenApprovalNotRequired() public {
        // Disable approval
        vm.prank(Actors.ADMIN);
        usdcVault.setRequireDepositApproval(false);

        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        uint256 shares = usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();

        assertGt(shares, 0, "LP received shares directly");
        assertEq(usdcVault.balanceOf(Actors.LP1), shares);
        assertEq(usdcVault.totalAssets(), LP_DEPOSIT);
    }

    function test_directDeposit_reverts_whenApprovalRequired() public {
        // Approval is already enabled in setUp
        _fundUSDC(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(usdcVault), LP_DEPOSIT);
        vm.expectRevert(IOwnVault.DepositApprovalRequired.selector);
        usdcVault.deposit(LP_DEPOSIT, Actors.LP1);
        vm.stopPrank();
    }

    function test_setRequireDepositApproval_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        usdcVault.setRequireDepositApproval(true);
    }

    function test_setRequireDepositApproval_emitsEvent() public {
        vm.prank(Actors.ADMIN);
        vm.expectEmit(false, false, false, true);
        emit IOwnVault.DepositApprovalUpdated(false);
        usdcVault.setRequireDepositApproval(false);
    }
}
