// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BPS} from "../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title InterestRateModel — Two-slope utilization curve for borrow premium
/// @notice Pure library. Computes the lending premium (in BPS, annualized) on
///         top of the underlying Aave borrow rate. Mirrors Aave's two-slope
///         model: a gentle slope below the optimal utilization kink, a steep
///         slope above to force deleveraging.
///
///         Caller composes the final rate as
///         `lendingRate = aaveBorrowRate + premium(utilization, params)`.
library InterestRateModel {
    /// @notice Curve parameters. All values in BPS where applicable.
    /// @param basePremiumBps    Premium at zero utilization (e.g. 100 = 1% APR).
    /// @param optimalUtilBps    Utilization kink (e.g. 8000 = 80%).
    /// @param slope1Bps         Slope below the kink, expressed as the premium
    ///                          increment from 0 → optimalUtilBps utilization
    ///                          (e.g. 400 = +4% APR over the range).
    /// @param slope2Bps         Slope above the kink, expressed as the premium
    ///                          increment from optimalUtilBps → 100% (e.g.
    ///                          7500 = +75% APR over the range).
    struct Params {
        uint64 basePremiumBps;
        uint64 optimalUtilBps;
        uint64 slope1Bps;
        uint64 slope2Bps;
    }

    /// @notice Invalid configuration (e.g. optimal > 100% or zero parameters).
    error InvalidParams();

    /// @notice Compute the premium (BPS, annualized) at a given utilization.
    /// @param utilizationBps Current utilization in BPS (0–10 000).
    /// @param p              Curve parameters.
    /// @return premiumBps Annualized premium in BPS (above the underlying borrow rate).
    function premium(uint256 utilizationBps, Params memory p) internal pure returns (uint256 premiumBps) {
        if (p.optimalUtilBps == 0 || p.optimalUtilBps >= BPS) revert InvalidParams();

        uint256 util = utilizationBps > BPS ? BPS : utilizationBps;

        if (util <= p.optimalUtilBps) {
            // premium = base + slope1 * util / optimal
            premiumBps = uint256(p.basePremiumBps) + Math.mulDiv(p.slope1Bps, util, p.optimalUtilBps);
        } else {
            // premium = base + slope1 + slope2 * (util - optimal) / (BPS - optimal)
            uint256 excess = util - p.optimalUtilBps;
            uint256 range = BPS - p.optimalUtilBps;
            premiumBps = uint256(p.basePremiumBps) + uint256(p.slope1Bps) + Math.mulDiv(p.slope2Bps, excess, range);
        }
    }

    /// @notice Convenience: combine an external borrow rate with the premium curve.
    /// @param utilizationBps    Current utilization in BPS.
    /// @param underlyingRateBps External borrow rate (e.g. Aave variable rate) in BPS.
    /// @param p                 Curve parameters.
    /// @return rateBps Total annualized lending rate in BPS.
    function totalRate(
        uint256 utilizationBps,
        uint256 underlyingRateBps,
        Params memory p
    ) internal pure returns (uint256 rateBps) {
        return underlyingRateBps + premium(utilizationBps, p);
    }
}
