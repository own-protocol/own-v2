// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnVault} from "../../../src/core/OwnVault.sol";
import {WithdrawalRequest, WithdrawalStatus} from "../../../src/interfaces/types/Types.sol";

import {Actors} from "../../helpers/Actors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title VaultHandler — Invariant test handler for OwnVault
/// @notice Exercises LP deposit/withdrawal and fee claim flows with fuzzed inputs.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    OwnVault public vault;
    MockERC20 public weth;
    MockERC20 public usdc;

    address[] public lps;
    address public vmAddr;

    // ── Ghost variables ─────────────────────────────────────────

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_pendingWithdrawalShares;
    uint256 public ghost_protocolFeesClaimed;
    uint256 public ghost_vmFeesClaimed;
    uint256 public ghost_lpFeesClaimed;

    uint256[] public ghost_pendingWithdrawalIds;

    // ── Constructor ─────────────────────────────────────────────

    constructor(address _vault, address _weth, address _usdc) {
        vault = OwnVault(_vault);
        weth = MockERC20(_weth);
        usdc = MockERC20(_usdc);
        vmAddr = Actors.VM1;

        lps.push(Actors.LP1);
        lps.push(Actors.LP2);
        lps.push(Actors.LP3);
    }

    // ── Handler functions ───────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        address lp = lps[bound(actorSeed, 0, lps.length - 1)];
        amount = bound(amount, 1e18, 500e18); // 1 to 500 WETH

        weth.mint(lp, amount);

        vm.startPrank(lp);
        weth.approve(address(vault), amount);
        vault.deposit(amount, lp);
        vm.stopPrank();

        ghost_totalDeposited += amount;
    }

    function requestWithdrawal(uint256 actorSeed, uint256 shares) external {
        address lp = lps[bound(actorSeed, 0, lps.length - 1)];
        uint256 bal = vault.balanceOf(lp);
        if (bal == 0) return;

        shares = bound(shares, 1, bal);

        vm.prank(lp);
        uint256 requestId = vault.requestWithdrawal(shares);

        ghost_pendingWithdrawalShares += shares;
        ghost_pendingWithdrawalIds.push(requestId);
    }

    function fulfillWithdrawal(
        uint256 idSeed
    ) external {
        uint256 len = ghost_pendingWithdrawalIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 requestId = ghost_pendingWithdrawalIds[idx];

        WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        if (req.status != WithdrawalStatus.Pending) {
            _removeGhostWithdrawalId(idx);
            return;
        }

        // Warp past wait period if needed
        uint256 readyAt = req.timestamp + vault.withdrawalWaitPeriod();
        if (block.timestamp < readyAt) {
            vm.warp(readyAt + 1);
        }

        uint256 assets = vault.convertToAssets(req.shares);
        vault.fulfillWithdrawal(requestId);

        ghost_pendingWithdrawalShares -= req.shares;
        ghost_totalWithdrawn += assets;
        _removeGhostWithdrawalId(idx);
    }

    function cancelWithdrawal(
        uint256 idSeed
    ) external {
        uint256 len = ghost_pendingWithdrawalIds.length;
        if (len == 0) return;

        uint256 idx = bound(idSeed, 0, len - 1);
        uint256 requestId = ghost_pendingWithdrawalIds[idx];

        WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        if (req.status != WithdrawalStatus.Pending) {
            _removeGhostWithdrawalId(idx);
            return;
        }

        vm.prank(req.owner);
        vault.cancelWithdrawal(requestId);

        ghost_pendingWithdrawalShares -= req.shares;
        _removeGhostWithdrawalId(idx);
    }

    function claimProtocolFees() external {
        uint256 amount = vault.accruedProtocolFees();
        if (amount == 0) return;

        vault.claimProtocolFees();
        ghost_protocolFeesClaimed += amount;
    }

    function claimVMFees() external {
        uint256 amount = vault.accruedVMFees();
        if (amount == 0) return;

        vm.prank(vmAddr);
        vault.claimVMFees();
        ghost_vmFeesClaimed += amount;
    }

    function claimLPRewards(
        uint256 actorSeed
    ) external {
        address lp = lps[bound(actorSeed, 0, lps.length - 1)];
        uint256 claimable = vault.claimableLPRewards(lp);
        if (claimable == 0) return;

        vm.prank(lp);
        uint256 amount = vault.claimLPRewards();
        ghost_lpFeesClaimed += amount;
    }

    // ── Internal helpers ────────────────────────────────────────

    function _removeGhostWithdrawalId(
        uint256 idx
    ) private {
        uint256 len = ghost_pendingWithdrawalIds.length;
        ghost_pendingWithdrawalIds[idx] = ghost_pendingWithdrawalIds[len - 1];
        ghost_pendingWithdrawalIds.pop();
    }

    function pendingWithdrawalCount() external view returns (uint256) {
        return ghost_pendingWithdrawalIds.length;
    }
}
