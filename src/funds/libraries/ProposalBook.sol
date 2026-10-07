// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../../interfaces/IFund.sol";
import {IFundCurators} from "../../interfaces/IFundCurators.sol";
import {IFundFactory} from "../../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../../interfaces/IFundGovernor.sol";
import {IFundOracle} from "../../interfaces/IFundOracle.sol";
import {IFundStaking} from "../../interfaces/IFundStaking.sol";
import {BPS_TO_WAD, GovernanceConfig, MAX_BASKET_ASSETS} from "../../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../../interfaces/types/Types.sol";
import {EpochHistory} from "./EpochHistory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ProposalBook — the governor's proposals: raising, voting, state and execution checks
/// @notice External library, linked at deployment and run in the governor's context (delegatecall),
///         so the governor stays under the contract size limit. `msg.sender` is the governor's
///         caller and calls to the curators module come from the governor.
library ProposalBook {
    using EpochHistory for EpochHistory.History;

    // Same weekly epoch as the governor's.
    uint256 private constant EPOCH = 1 weeks;

    struct Book {
        IFundGovernor.Proposal[] proposals;
        mapping(uint256 id => address[]) curators;
        mapping(uint256 id => mapping(address account => IFundGovernor.ProposalVote)) votes;
        mapping(address proposer => uint256) open;
    }

    /// @notice What the governor knows about the caller and the target when a proposal is raised.
    /// @param power          The caller's escrowed power from the next epoch.
    /// @param totalStake     All staked tokens (the stakers' "all possible votes").
    /// @param targetDelisted Whether the target token is already delisted.
    struct Context {
        uint256 power;
        uint256 totalStake;
        bool targetDelisted;
    }

    /// @notice Raise a proposal as `msg.sender`. See {IFundGovernor-propose}.
    /// @param power      The caller's power history.
    /// @param totalPower The governor's total power history.
    function propose(
        Book storage b,
        GovernanceConfig storage cfg,
        mapping(address => bool) storage delisted,
        EpochHistory.History storage power,
        EpochHistory.History storage totalPower,
        address fund,
        IFundGovernor.ProposalKind kind,
        address target,
        address replacement
    ) public returns (uint256 id) {
        IFund f = IFund(fund);
        if (!f.launched()) revert IFundGovernor.NotLaunched();
        uint256 next = block.timestamp / EPOCH + 1;
        // Empty in the launch epoch, whose stake only counts from the next one.
        uint256 staked = Math.max(IFundStaking(f.staking()).totalSupplyAt(next - 1), totalPower.valueAt(next - 1));
        if (staked == 0) revert IFundGovernor.GovernanceNotStarted();
        Context memory ctx = Context({
            power: power.valueAt(next),
            totalStake: Math.max(staked, totalPower.valueAt(next)),
            targetDelisted: delisted[target]
        });
        id = _propose(b, fund, cfg, ctx, kind, target, replacement);
    }

    function _propose(
        Book storage b,
        address fund,
        GovernanceConfig storage cfg,
        Context memory ctx,
        IFundGovernor.ProposalKind kind,
        address target,
        address replacement
    ) private returns (uint256 id) {
        IFund f = IFund(fund);
        IFundCurators cur = IFundCurators(f.curators());
        if (!cur.isCurator(msg.sender)) {
            uint256 assets = IFundStaking(f.staking()).convertToAssets(ctx.power);
            if (ctx.power == 0 || Math.mulDiv(assets, f.navPerShare(), PRECISION) < cfg.proposalThresholdUsd) {
                revert IFundGovernor.NotEligibleToPropose();
            }
        }
        uint256 open = b.open[msg.sender];
        if (open != 0) {
            IFundGovernor.ProposalState s = state(b, open - 1);
            if (
                s == IFundGovernor.ProposalState.Active || s == IFundGovernor.ProposalState.Queued
                    || s == IFundGovernor.ProposalState.Executable
            ) revert IFundGovernor.ProposalOpen();
        }
        if (!isValid(fund, kind, target, replacement, ctx.targetDelisted)) revert IFundGovernor.InvalidProposal();

        id = b.proposals.length;
        b.open[msg.sender] = id + 1;
        bool curatorChange = kind >= IFundGovernor.ProposalKind.AddCurator;
        uint16 curatorShare = curatorChange ? 0 : cfg.curatorShareBps;
        if (curatorShare != 0) {
            address[] memory cs = cur.curators();
            address[] storage snapshot = b.curators[id];
            snapshot.push(cur.protocolCurator());
            for (uint256 i; i < cs.length; ++i) {
                snapshot.push(cs[i]);
            }
        }

        uint64 endTime = uint64(block.timestamp + cfg.votingPeriod);
        b.proposals.push(
            IFundGovernor.Proposal({
                kind: kind,
                proposer: msg.sender,
                target: target,
                replacement: replacement,
                startTime: uint64(block.timestamp),
                endTime: endTime,
                executed: false,
                vetoed: false,
                cancelled: false,
                curatorShareBps: curatorShare,
                stakerShareBps: uint16(BPS - curatorShare),
                totalStake: ctx.totalStake,
                yesVotes: 0,
                noVotes: 0,
                quorumBps: curatorChange ? cfg.curatorQuorumBps : cfg.quorumBps,
                vetoPeriod: cfg.vetoPeriod,
                executionWindow: cfg.executionWindow,
                bribeYesVotes: 0
            })
        );
        emit IFundGovernor.ProposalCreated(id, msg.sender, kind, target, replacement, endTime);
    }

    /// @notice Vote as `msg.sender` and extend its vote lock to the proposal's end. See
    ///         {IFundGovernor-castVote}.
    /// @param power The caller's power history.
    /// @return votes Votes cast, as a 1e18-scaled share of all possible votes.
    function castVote(
        Book storage b,
        EpochHistory.History storage power,
        mapping(address => uint64) storage lastDepositAt,
        mapping(address => uint32) storage bribeLockedFrom,
        mapping(address => uint64) storage voteLockUntil,
        address fund,
        uint256 id,
        bool support
    ) public returns (uint256 votes) {
        uint64 endTime;
        (votes, endTime) = _castVote(
            b,
            fund,
            id,
            support,
            power.valueAt(block.timestamp / EPOCH + 1),
            lastDepositAt[msg.sender],
            bribeLockedFrom[msg.sender] != 0
        );
        if (endTime > voteLockUntil[msg.sender]) voteLockUntil[msg.sender] = endTime;
    }

    /// @dev Records the vote.
    /// @param power       The caller's escrowed power from the next epoch.
    /// @param lastDeposit When the caller last deposited.
    /// @param bribeLocked Whether the caller is locked for bribes (its stake then counts toward
    ///                    listing bribes).
    /// @return votes   Votes cast, as a 1e18-scaled share of all possible votes.
    /// @return endTime When voting on the proposal ends.
    function _castVote(
        Book storage b,
        address fund,
        uint256 id,
        bool support,
        uint256 power,
        uint64 lastDeposit,
        bool bribeLocked
    ) private returns (uint256 votes, uint64 endTime) {
        IFundGovernor.ProposalState s = state(b, id);
        if (s != IFundGovernor.ProposalState.Active) revert IFundGovernor.WrongState(s);
        IFundGovernor.Proposal storage p = b.proposals[id];
        IFundGovernor.ProposalVote storage pv = b.votes[id][msg.sender];
        if (pv.voted) revert IFundGovernor.AlreadyVoted();
        if (lastDeposit >= p.startTime) revert IFundGovernor.DepositedAfterProposal();

        if (p.curatorShareBps != 0) votes = _curatorVotes(b.curators[id], fund, p.curatorShareBps);
        uint256 total = p.totalStake;
        uint256 stake = Math.min(power, total);
        if (total != 0) votes += Math.mulDiv(uint256(p.stakerShareBps) * BPS_TO_WAD, stake, total);
        if (votes == 0) revert IFundGovernor.NoVotingPower();

        pv.voted = true;
        pv.support = support;
        pv.votes = votes;
        uint256 bribe = bribeLocked && p.stakerShareBps != 0 ? stake : 0;
        if (bribe != 0) pv.bribeVotes = bribe;
        if (support) {
            p.yesVotes += votes;
            if (bribe != 0) p.bribeYesVotes += bribe;
        } else {
            p.noVotes += votes;
        }
        endTime = p.endTime;

        emit IFundGovernor.ProposalVoteCast(id, msg.sender, support, votes);
    }

    /// @notice Mark an executable proposal executed, re-check it and apply it. See
    ///         {IFundGovernor-execute}.
    function execute(
        Book storage b,
        mapping(address => bool) storage delisted,
        mapping(address => uint256) storage lowStreak,
        address fund,
        uint256 id
    ) public {
        IFundGovernor.ProposalState s = state(b, id);
        if (s != IFundGovernor.ProposalState.Executable) revert IFundGovernor.WrongState(s);
        IFundGovernor.Proposal storage p = b.proposals[id];
        p.executed = true;
        IFundGovernor.ProposalKind kind = p.kind;
        address target = p.target;
        if (!isValid(fund, kind, target, p.replacement, delisted[target])) revert IFundGovernor.InvalidProposal();

        IFund f = IFund(fund);
        IFundCurators cur = IFundCurators(f.curators());
        if (kind == IFundGovernor.ProposalKind.AddCurator) cur.addCurator(target);
        else if (kind == IFundGovernor.ProposalKind.RemoveCurator) cur.removeCurator(target);
        else if (kind == IFundGovernor.ProposalKind.ReplaceCurator) cur.replaceCurator(target, p.replacement);
        emit IFundGovernor.ProposalExecuted(id);
        if (kind == IFundGovernor.ProposalKind.List) {
            address[] memory current = f.assets();
            uint256 n = current.length;
            address[] memory assets = new address[](n + 1);
            uint16[] memory weights = new uint16[](n + 1);
            for (uint256 i; i < n; ++i) {
                assets[i] = current[i];
                weights[i] = f.targetWeightBps(current[i]);
            }
            assets[n] = target;
            delisted[target] = false;
            lowStreak[target] = 0;
            f.setTargetWeights(assets, weights);
        } else if (kind == IFundGovernor.ProposalKind.Delist) {
            delisted[target] = true;
            emit IFundGovernor.DelistedSet(target, true);
        }
    }

    /// @notice Cancel an active proposal as its proposer.
    function cancel(Book storage b, uint256 id) public {
        IFundGovernor.ProposalState s = state(b, id);
        if (s != IFundGovernor.ProposalState.Active) revert IFundGovernor.WrongState(s);
        if (msg.sender != b.proposals[id].proposer) revert IFundGovernor.NotProposer();
        b.proposals[id].cancelled = true;
        emit IFundGovernor.ProposalCancelled(id);
    }

    /// @notice Veto a proposal that is still open (the governor checks the caller is the admin).
    function veto(Book storage b, uint256 id) public {
        IFundGovernor.ProposalState s = state(b, id);
        if (
            s != IFundGovernor.ProposalState.Active && s != IFundGovernor.ProposalState.Queued
                && s != IFundGovernor.ProposalState.Executable
        ) revert IFundGovernor.WrongState(s);
        b.proposals[id].vetoed = true;
        emit IFundGovernor.ProposalVetoed(id);
    }

    /// @notice A proposal's lifecycle state. See {IFundGovernor-state}.
    function state(Book storage b, uint256 id) public view returns (IFundGovernor.ProposalState) {
        if (id >= b.proposals.length) revert IFundGovernor.UnknownProposal();
        IFundGovernor.Proposal storage p = b.proposals[id];
        if (p.executed) return IFundGovernor.ProposalState.Executed;
        if (p.vetoed) return IFundGovernor.ProposalState.Vetoed;
        if (p.cancelled) return IFundGovernor.ProposalState.Cancelled;
        uint256 end = p.endTime;
        if (block.timestamp < end) return IFundGovernor.ProposalState.Active;
        if (p.yesVotes <= p.noVotes || p.yesVotes < uint256(p.quorumBps) * BPS_TO_WAD) {
            return IFundGovernor.ProposalState.Defeated;
        }
        uint256 executableAt = end + p.vetoPeriod;
        if (block.timestamp < executableAt) return IFundGovernor.ProposalState.Queued;
        if (block.timestamp < executableAt + p.executionWindow) return IFundGovernor.ProposalState.Executable;
        return IFundGovernor.ProposalState.Expired;
    }

    /// @notice Whether a proposal can be raised or executed right now.
    function isValid(
        address fund,
        IFundGovernor.ProposalKind kind,
        address target,
        address replacement,
        bool targetDelisted
    ) public view returns (bool) {
        if (target == address(0)) return false;
        IFund f = IFund(fund);
        IFundFactory fac = IFundFactory(f.factory());
        if (kind == IFundGovernor.ProposalKind.List) {
            return !f.isAsset(target) && target != fund && target != fac.usdg() && fac.isEligibleAsset(target)
                && IFundOracle(fac.oracle()).hasFeed(target) && f.assets().length < MAX_BASKET_ASSETS;
        }
        if (kind == IFundGovernor.ProposalKind.Delist) return f.isAsset(target) && !targetDelisted;
        IFundCurators cur = IFundCurators(f.curators());
        if (kind == IFundGovernor.ProposalKind.AddCurator) {
            return !cur.isCurator(target) && cur.curatorCount() < fac.curatorCap();
        }
        if (target == cur.protocolCurator()) return false;
        if (kind == IFundGovernor.ProposalKind.RemoveCurator) return cur.isCurator(target);
        return cur.isCurator(target) && replacement != address(0) && !cur.isCurator(replacement);
    }

    /// @dev The caller's part of a proposal's curator slice: the protocol share for the protocol
    ///      curator at the proposal (first in the snapshot), an equal part of the rest for each other
    ///      curator in the snapshot that is still a compliant curator.
    function _curatorVotes(address[] storage cs, address fund, uint16 curatorShareBps) private view returns (uint256) {
        bool isProtocol = msg.sender == cs[0];
        if (!isProtocol) {
            if (!_contains(cs, msg.sender)) return 0;
            IFundCurators cur = IFundCurators(IFund(fund).curators());
            if (!cur.isCurator(msg.sender) || !cur.isCompliant(msg.sender)) return 0;
        }
        uint256 protocolShare = IFundFactory(IFund(fund).factory()).protocolCuratorShareBps();
        uint256 slice = uint256(curatorShareBps) * BPS_TO_WAD;
        if (isProtocol) return slice * protocolShare / BPS;
        return slice * (BPS - protocolShare) / BPS / (cs.length - 1);
    }

    function _contains(address[] storage list, address a) private view returns (bool) {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}
