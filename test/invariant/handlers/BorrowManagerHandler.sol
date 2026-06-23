// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BorrowManager} from "../../../src/core/BorrowManager.sol";
import {IVaultManager} from "../../../src/interfaces/IVaultManager.sol";
import {EToken} from "../../../src/tokens/EToken.sol";
import {Actors} from "../../helpers/Actors.sol";
import {MockAaveV3Pool} from "../../helpers/MockAaveV3Pool.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title BorrowManagerHandler — Invariant handler for BorrowManager
/// @notice Drives random borrow / repay / accrue sequences and, crucially, simulates real Aave-side
///         interest outrunning the manager's sampled model (`aaveAccrue`) so the interest-index floor
///         is exercised. This handler is wired as the MARKET so it can mint borrower eToken collateral.
contract BorrowManagerHandler is CommonBase, StdCheats, StdUtils {
    BorrowManager public bm;
    IVaultManager public vmgr;
    EToken public eTSLA;
    MockERC20 public usdc;
    MockAaveV3Pool public pool;
    address public vault;

    bytes32 internal constant TSLA = bytes32("TSLA");
    uint256 internal constant TSLA_PX = 250e18;

    address[] public borrowers;

    uint256 public ghost_borrows;
    uint256 public ghost_repays;
    uint256 public ghost_aaveAccruals;

    constructor(address _bm, address _vmgr, address _eTSLA, address _usdc, address _pool, address _vault) {
        bm = BorrowManager(_bm);
        vmgr = IVaultManager(_vmgr);
        eTSLA = EToken(_eTSLA);
        usdc = MockERC20(_usdc);
        pool = MockAaveV3Pool(_pool);
        vault = _vault;
        borrowers.push(Actors.MINTER1);
        borrowers.push(Actors.MINTER2);
        borrowers.push(Actors.LP1);
    }

    function _pick(
        uint256 seed
    ) internal view returns (address) {
        return borrowers[bound(seed, 0, borrowers.length - 1)];
    }

    function borrow(uint256 seed, uint256 eAmt, uint256 stable) external {
        address b = _pick(seed);
        if (bm.positionOf(b, TSLA).principal != 0) return; // one position per (borrower, asset)
        eAmt = bound(eAmt, 1e18, 100e18);
        // Cap the loan at 60% of collateral value — comfortably under the 70% per-position LTV gate.
        uint256 collatUsd = eAmt * TSLA_PX / 1e18; // 18-dec USD
        uint256 maxStable = (collatUsd * 6000 / 10_000) / 1e12; // 6-dec USDC
        if (maxStable < 1e6) return;
        stable = bound(stable, 1e6, maxStable);

        // Keep the price-band mark fresh (the suite warps far past maxMarkAge over a campaign).
        vmgr.pullAssetPrice(TSLA);

        eTSLA.mint(b, eAmt); // this handler is the MARKET
        vm.startPrank(b);
        eTSLA.approve(address(bm), eAmt);
        try bm.borrow(TSLA, eAmt, stable, abi.encode(TSLA_PX, block.timestamp)) {
            ghost_borrows++;
        } catch {}
        vm.stopPrank();
    }

    function repay(uint256 seed, uint256 amount) external {
        address b = _pick(seed);
        uint256 debt = bm.debtOf(b, TSLA);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        usdc.mint(b, amount);
        vm.startPrank(b);
        usdc.approve(address(bm), amount);
        try bm.repay(TSLA, amount) {
            ghost_repays++;
        } catch {}
        vm.stopPrank();
    }

    function accrue() external {
        bm.accrue();
    }

    /// @dev Simulate Aave's continuous compounding outrunning the manager's sampled simple-interest
    ///      model — the exact condition the index floor exists to absorb.
    function aaveAccrue(
        uint256 extra
    ) external {
        uint256 real = pool.debtOf(vault, address(usdc));
        if (real == 0) return;
        extra = bound(extra, 0, real / 10); // up to +10% of outstanding Aave debt
        pool.accrueDebt(vault, address(usdc), extra);
        ghost_aaveAccruals++;
    }

    function warp(
        uint256 secs
    ) external {
        skip(bound(secs, 1, 30 days));
    }

    function borrowerCount() external view returns (uint256) {
        return borrowers.length;
    }

    function borrowerAt(
        uint256 i
    ) external view returns (address) {
        return borrowers[i];
    }
}
