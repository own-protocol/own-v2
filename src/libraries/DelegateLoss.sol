// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILiquidityVault} from "../interfaces/ILiquidityVault.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DelegateLoss — a vault's daily budget for value lost by its delegate's calls
/// @notice Shared by the liquidity vault adapters. Each losing call adds its loss, as a share of
///         the equity before the call, to the current one-day window's total.
library DelegateLoss {
    /// @notice Length of a loss window.
    uint256 internal constant WINDOW = 1 days;

    /// @notice A vault's budget and current window, in one slot.
    /// @param budgetBps   Most equity the delegate's calls may lose per window (BPS).
    /// @param windowStart When the latest window began (unix seconds).
    /// @param usedBps     Losses counted in that window (BPS of equity).
    struct Budget {
        uint16 budgetBps;
        uint64 windowStart;
        uint32 usedBps;
    }

    /// @notice Set the budget. The current window's losses stay counted.
    /// @param b         The budget.
    /// @param budgetBps New budget (BPS, at most 100%).
    function setBudget(Budget storage b, uint16 budgetBps) internal {
        if (budgetBps > BPS) revert ILiquidityVault.InvalidLossBudget();
        b.budgetBps = budgetBps;
    }

    /// @notice Count a call's loss; reverts past the budget.
    /// @param b            The budget.
    /// @param equityBefore Equity before the call.
    /// @param equityAfter  Equity after the call.
    function charge(Budget storage b, uint256 equityBefore, uint256 equityAfter) internal {
        if (equityAfter >= equityBefore) return;
        uint256 used;
        uint64 start = b.windowStart;
        if (block.timestamp < start + WINDOW) {
            used = b.usedBps;
        } else {
            b.windowStart = uint64(block.timestamp);
        }
        // Rounded up so no loss is free; equityBefore > equityAfter ≥ 0.
        used += Math.mulDiv(equityBefore - equityAfter, BPS, equityBefore, Math.Rounding.Ceil);
        uint256 budget = b.budgetBps;
        if (used > budget) revert ILiquidityVault.DelegateLossBudgetExceeded(used, budget);
        // used ≤ budget ≤ BPS
        b.usedBps = uint32(used);
    }
}
