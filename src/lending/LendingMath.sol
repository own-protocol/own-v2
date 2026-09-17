// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LendingMath — Pure debt-accounting math for UserBorrowManager
/// @notice Stateless helpers for the manager's index-based debt model. Kept as a
///         library (Morpho `MathLib` style) so the unit-and-rounding-sensitive
///         arithmetic is tested in isolation and the manager reads as flow, not
///         math. All functions are `internal pure` and inline into the caller —
///         no external call, no separate deployment.
///
///         Conventions used throughout:
///         - `index`  : cumulative interest index, PRECISION-scaled, starts at
///                      PRECISION (= 1.0). Actual debt = scaledDebt × index / PRECISION.
///         - `*Bps`   : basis points, where BPS (10_000) = 100%.
///         - USD      : 18-decimal fixed point. Stablecoin native units are
///                      lifted to USD via {stableToUSD}, assuming a 1:1 peg.
///         - Rounding : every division floors (OZ `Math.mulDiv` default), which
///                      is protocol-favorable for debt (keeps a sliver of debt)
///                      and conservative for released value.
library LendingMath {
    using Math for uint256;

    /// @dev Seconds in a year used to annualize the per-second accrual.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ──────────────────────────────────────────────────────────
    //  Interest index
    // ──────────────────────────────────────────────────────────

    /// @notice Advance an interest index by simple interest over `dt` seconds.
    /// @dev    `newIndex = index + index × rateBps × dt / (BPS × SECONDS_PER_YEAR)`.
    ///         Simple (not continuously compounded) within the window; callers
    ///         compound by folding growth into the stored index at each touch
    ///         point. No-ops when `dt` or `rateBps` is zero so idle/zero-rate
    ///         periods accrue nothing. Floors, so dust interest is dropped in
    ///         the borrower's favor.
    /// @param index   Current index (PRECISION-scaled).
    /// @param rateBps Annualized borrow rate in BPS, snapshotted for this window.
    /// @param dt      Elapsed seconds since the last accrual.
    /// @return The index advanced to now.
    function accrueIndex(uint256 index, uint256 rateBps, uint256 dt) internal pure returns (uint256) {
        if (dt == 0 || rateBps == 0) return index;
        return index + index.mulDiv(rateBps * dt, BPS * SECONDS_PER_YEAR);
    }

    /// @notice Convert a position's stored scaled debt to its current actual amount.
    /// @dev    `actual = scaledDebt × index / PRECISION`. Floors.
    /// @param scaledDebt Position principal stored in scaled units.
    /// @param index      Current (or projected) interest index.
    /// @return Actual debt in stablecoin native units.
    function scaledToActual(uint256 scaledDebt, uint256 index) internal pure returns (uint256) {
        return scaledDebt.mulDiv(index, PRECISION);
    }

    /// @notice Convert an actual stablecoin amount into scaled-debt units.
    /// @dev    `scaled = amount × PRECISION / index`. Floors — recording slightly
    ///         less scaled debt than exact, which is protocol-favorable on
    ///         partial repay (keeps a sliver of debt rather than over-releasing).
    /// @param amount Actual stablecoin amount.
    /// @param index  Current interest index.
    /// @return Scaled-debt units.
    function actualToScaled(uint256 amount, uint256 index) internal pure returns (uint256) {
        return amount.mulDiv(PRECISION, index);
    }

    // ──────────────────────────────────────────────────────────
    //  Unit conversions
    // ──────────────────────────────────────────────────────────

    /// @notice Lift a stablecoin amount from native decimals to 18-decimal USD.
    /// @dev    Assumes a 1:1 stablecoin↔USD peg — no stablecoin oracle, so a
    ///         depeg is invisible to every value computed from this. The >18
    ///         branch truncates sub-unit dust (irrelevant for ≤18-dec tokens).
    /// @param amount         Stablecoin amount in native units.
    /// @param stableDecimals Decimals of the stablecoin (cached by the caller).
    /// @return USD value, 18-decimal fixed point.
    function stableToUSD(uint256 amount, uint8 stableDecimals) internal pure returns (uint256) {
        if (stableDecimals == 18) return amount;
        if (stableDecimals < 18) return amount * 10 ** (18 - stableDecimals);
        return amount / 10 ** (stableDecimals - 18);
    }

    /// @notice USD value of an eToken collateral amount at a given oracle price.
    /// @dev    `collateralUSD = collateral × oraclePrice / PRECISION`. Both
    ///         collateral and price are 18-decimal, so the result is 18-dec USD.
    /// @param collateral  eToken amount (18 decimals).
    /// @param oraclePrice Asset price, 18-decimal USD per token.
    /// @return Collateral value in 18-decimal USD.
    function collateralUSD(uint256 collateral, uint256 oraclePrice) internal pure returns (uint256) {
        return collateral.mulDiv(oraclePrice, PRECISION);
    }

    // ──────────────────────────────────────────────────────────
    //  Risk math
    // ──────────────────────────────────────────────────────────

    /// @notice Health factor for a position (PRECISION = 1.0).
    /// @dev    `hf = collateralUSD × liqThresholdBps / BPS × PRECISION / debtUSD`.
    ///         A position is liquidatable when `hf < PRECISION`. Returns
    ///         `type(uint256).max` for zero debt (infinitely healthy).
    /// @param collateral      eToken collateral (18 decimals).
    /// @param currentDebt     Debt in stablecoin native units.
    /// @param oraclePrice     Asset price, 18-decimal USD per token.
    /// @param liqThresholdBps Liquidation threshold in BPS.
    /// @param stableDecimals  Decimals of the stablecoin.
    /// @return Health factor, PRECISION-scaled.
    function healthFactor(
        uint256 collateral,
        uint256 currentDebt,
        uint256 oraclePrice,
        uint256 liqThresholdBps,
        uint8 stableDecimals
    ) internal pure returns (uint256) {
        if (currentDebt == 0) return type(uint256).max;
        uint256 adjusted = collateralUSD(collateral, oraclePrice).mulDiv(liqThresholdBps, BPS);
        uint256 debtUSD = stableToUSD(currentDebt, stableDecimals);
        return adjusted.mulDiv(PRECISION, debtUSD);
    }

    /// @notice Target collateral to seize on liquidation, in eToken units.
    /// @dev    `seize = debtUSD × (BPS + bonusBps) / BPS × PRECISION / oraclePrice`.
    ///         The caller caps this at the position's remaining collateral. Floors.
    /// @param currentDebt    Debt being repaid, in stablecoin native units.
    /// @param oraclePrice    Asset price, 18-decimal USD per token.
    /// @param bonusBps       Liquidation bonus in BPS.
    /// @param stableDecimals Decimals of the stablecoin.
    /// @return eToken units the liquidator is entitled to (pre-cap).
    function seizeAmount(
        uint256 currentDebt,
        uint256 oraclePrice,
        uint256 bonusBps,
        uint8 stableDecimals
    ) internal pure returns (uint256) {
        uint256 withBonusUSD = stableToUSD(currentDebt, stableDecimals).mulDiv(BPS + bonusBps, BPS);
        return withBonusUSD.mulDiv(PRECISION, oraclePrice);
    }
}
