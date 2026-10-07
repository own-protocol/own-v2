// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../../interfaces/IFund.sol";
import {IFundGovernor} from "../../interfaces/IFundGovernor.sol";
import {BPS_TO_WAD, GovernanceConfig, WAD} from "../../interfaces/types/FundTypes.sol";
import {BPS} from "../../interfaces/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GaugeMath — turns a week's votes into new target weights
/// @notice Shares of the vote and targets are 1e18-scaled ("WAD"): 1e18 is every possible vote.
///         External library, linked at deployment and run in the governor's context
///         (delegatecall), so the governor stays under the contract size limit.
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
    ) internal pure returns (uint256[] memory t, bool[] memory low) {
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
    ///         more than the weekly shift; rounding dust goes to the largest remainders, one basis
    ///         point each, so no weight ends more than a point above its exact value (or its cap).
    /// @param current  Current weights (bps, summing to 10 000).
    /// @param t        Targets (WAD).
    /// @param shiftBps Largest move allowed for any weight.
    /// @return weights New weights (bps, summing to 10 000).
    function move(
        uint16[] memory current,
        uint256[] memory t,
        uint256 shiftBps
    ) internal pure returns (uint16[] memory weights) {
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
        uint256[] memory rem = new uint256[](n);
        for (uint256 j; j < n; ++j) {
            uint256 old = uint256(current[j]) * BPS_TO_WAD;
            uint256 w = t[j] >= old
                ? old + Math.mulDiv(t[j] - old, k, WAD)
                : old - Math.mulDiv(old - t[j], k, WAD, Math.Rounding.Ceil);
            weights[j] = uint16(w / BPS_TO_WAD);
            rem[j] = w % BPS_TO_WAD;
            sum += weights[j];
        }
        for (uint256 left = BPS - sum; left != 0; --left) {
            uint256 best;
            for (uint256 j = 1; j < n; ++j) {
                if (rem[j] > rem[best]) best = j;
            }
            ++weights[best];
            rem[best] = 0;
        }
    }

    /// @notice Settle a tallied epoch: move the basket toward the vote's targets, drop what has
    ///         left it and set the fund's new weights. See {IFundGovernor-flip}.
    /// @param delisted  The governor's delisted tokens.
    /// @param lowStreak The governor's low-vote streaks, updated here.
    /// @param cfg       The governor's config.
    /// @param f         The fund.
    /// @param e         The tallied epoch.
    /// @param assets    The basket.
    /// @param votes     Votes cast per basket token (WAD).
    function settle(
        mapping(address => bool) storage delisted,
        mapping(address => uint256) storage lowStreak,
        GovernanceConfig storage cfg,
        IFund f,
        uint256 e,
        address[] memory assets,
        uint256[] memory votes
    ) public {
        uint16[] memory weights = _weights(delisted, lowStreak, cfg, f, assets, votes);
        (address[] memory kept, uint16[] memory keptWeights) =
            _drop(delisted, lowStreak, f, assets, weights, cfg.dropAfterEpochs);
        f.setTargetWeights(kept, keptWeights);
        emit IFundGovernor.EpochTallied(e, kept, keptWeights);
    }

    /// @dev The weights after this week's move, with each token's low-vote streak updated.
    function _weights(
        mapping(address => bool) storage delisted,
        mapping(address => uint256) storage lowStreak,
        GovernanceConfig storage cfg,
        IFund f,
        address[] memory assets,
        uint256[] memory votes
    ) private returns (uint16[] memory weights) {
        uint256 n = assets.length;
        uint16[] memory current = new uint16[](n);
        bool[] memory isDelisted = new bool[](n);
        for (uint256 j; j < n; ++j) {
            current[j] = f.targetWeightBps(assets[j]);
            isDelisted[j] = delisted[assets[j]];
        }
        (uint256[] memory t, bool[] memory low) = targets(votes, current, isDelisted, cfg.minVoteBps, cfg.maxWeightBps);
        for (uint256 j; j < n; ++j) {
            if (low[j]) ++lowStreak[assets[j]];
            else lowStreak[assets[j]] = 0;
        }
        weights = move(current, t, cfg.maxWeeklyShiftBps);
    }

    /// @dev Removes tokens at weight 0 that are delisted or have been under the minimum vote for
    ///      `dropAfter` weeks, once their balance is dust.
    function _drop(
        mapping(address => bool) storage delisted,
        mapping(address => uint256) storage lowStreak,
        IFund f,
        address[] memory assets,
        uint16[] memory weights,
        uint256 dropAfter
    ) private returns (address[] memory kept, uint16[] memory keptWeights) {
        uint256 n = assets.length;
        bool[] memory dropped = new bool[](n);
        uint256 count;
        for (uint256 j; j < n; ++j) {
            address a = assets[j];
            if (weights[j] == 0 && (delisted[a] || lowStreak[a] >= dropAfter) && f.isDust(a)) {
                dropped[j] = true;
                delisted[a] = false;
                lowStreak[a] = 0;
            } else {
                ++count;
            }
        }
        kept = new address[](count);
        keptWeights = new uint16[](count);
        uint256 k;
        for (uint256 j; j < n; ++j) {
            if (dropped[j]) continue;
            kept[k] = assets[j];
            keptWeights[k] = weights[j];
            ++k;
        }
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
