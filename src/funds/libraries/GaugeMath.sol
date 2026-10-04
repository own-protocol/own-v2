// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BPS_TO_WAD, WAD} from "../../interfaces/types/FundTypes.sol";
import {BPS} from "../../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GaugeMath — turns a week's votes into new target weights
/// @notice Shares of the vote and targets are 1e18-scaled ("WAD"): 1e18 is every possible vote.
///         External library, linked at deployment, so the governor stays under the contract size
///         limit.
library GaugeMath {
    /// @notice Targets: cast votes plus silent votes spread at the current weights, then the
    ///         minimum-vote and cap guardrails.
    /// @param votes       Cast votes per token (WAD).
    /// @param current     Current weights (bps).
    /// @param delisted    Whether each token is delisted (targeted at 0).
    /// @param minVoteBps  Minimum share of the vote to keep a non-zero target.
    /// @param maxWeightBps Cap per token (raised to 1 / non-zero tokens if that is higher).
    /// @return t   Targets (WAD, summing to at most 1e18).
    /// @return low Whether each token was under the minimum vote.
    function targets(
        uint256[] memory votes,
        uint16[] memory current,
        bool[] memory delisted,
        uint256 minVoteBps,
        uint256 maxWeightBps
    ) public pure returns (uint256[] memory t, bool[] memory low) {
        uint256 n = votes.length;
        t = new uint256[](n);
        low = new bool[](n);
        uint256 cast;
        for (uint256 j; j < n; ++j) {
            cast += votes[j];
        }
        uint256 silent = cast < WAD ? WAD - cast : 0;
        uint256 minVote = minVoteBps * BPS_TO_WAD;

        uint256 total;
        for (uint256 j; j < n; ++j) {
            uint256 v = votes[j] + silent * current[j] / BPS;
            if (v < minVote) {
                low[j] = true;
                v = 0;
            }
            if (delisted[j]) v = 0;
            t[j] = v;
            total += v;
        }
        if (total == 0) {
            for (uint256 j; j < n; ++j) {
                t[j] = uint256(current[j]) * BPS_TO_WAD;
            }
            return (t, low);
        }

        uint256 nonZero;
        for (uint256 j; j < n; ++j) {
            t[j] = Math.mulDiv(t[j], WAD, total);
            if (t[j] != 0) ++nonZero;
        }
        _cap(t, Math.max(maxWeightBps * BPS_TO_WAD, Math.ceilDiv(WAD, nonZero)));
    }

    /// @notice Moves every weight the same fraction of the way to its target, so that none moves
    ///         more than the weekly shift; rounding dust goes to the largest weight.
    /// @param current  Current weights (bps, summing to 10 000).
    /// @param t        Targets (WAD).
    /// @param shiftBps Largest move allowed for any weight.
    /// @return weights New weights (bps, summing to 10 000).
    function move(
        uint16[] memory current,
        uint256[] memory t,
        uint256 shiftBps
    ) public pure returns (uint16[] memory weights) {
        uint256 n = current.length;
        weights = new uint16[](n);
        uint256 maxDiff;
        for (uint256 j; j < n; ++j) {
            uint256 old = uint256(current[j]) * BPS_TO_WAD;
            uint256 d = t[j] > old ? t[j] - old : old - t[j];
            if (d > maxDiff) maxDiff = d;
        }
        uint256 shift = shiftBps * BPS_TO_WAD;
        uint256 k = maxDiff <= shift ? WAD : Math.mulDiv(shift, WAD, maxDiff);

        uint256 sum;
        uint256 largest;
        for (uint256 j; j < n; ++j) {
            uint256 old = uint256(current[j]) * BPS_TO_WAD;
            uint256 w = t[j] >= old
                ? old + Math.mulDiv(t[j] - old, k, WAD)
                : old - Math.mulDiv(old - t[j], k, WAD, Math.Rounding.Ceil);
            weights[j] = uint16(w / BPS_TO_WAD);
            sum += weights[j];
            if (weights[j] > weights[largest]) largest = j;
        }
        weights[largest] += uint16(BPS - sum);
    }

    /// @dev Caps every target at `cap`, handing the excess to the uncapped targets pro rata.
    function _cap(uint256[] memory t, uint256 cap) private pure {
        uint256 n = t.length;
        for (uint256 round; round < n; ++round) {
            uint256 excess;
            uint256 base;
            for (uint256 j; j < n; ++j) {
                if (t[j] > cap) {
                    excess += t[j] - cap;
                    t[j] = cap;
                } else if (t[j] < cap) {
                    base += t[j];
                }
            }
            if (excess == 0 || base == 0) return;
            for (uint256 j; j < n; ++j) {
                if (t[j] < cap) t[j] += Math.mulDiv(excess, t[j], base);
            }
        }
    }
}
