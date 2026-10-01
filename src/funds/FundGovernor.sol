// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundOracle} from "../interfaces/IFundOracle.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {GovernanceConfig, GovernanceConfigLib} from "../interfaces/types/FundTypes.sol";
import {BPS, PRECISION} from "../interfaces/types/Types.sol";
import {EpochHistory} from "./libraries/EpochHistory.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title FundGovernor — weekly weight vote (gauge) and proposals for one fund
/// @notice See {IFundGovernor}.
/// @dev Beacon proxy per fund; storage is append-only across upgrades.
///
///      Votes are kept as histories per epoch so any finished epoch can be tallied (and its bribes
///      paid) later: each account's power, the total power, and per token the stakers' votes
///      `sum(floor(power * weightBps / BPS))`. Every change rewrites only the current epoch and the
///      next one, keeping each aggregate exactly equal to the sum of its accounts' contributions.
///      Shares of the vote are 1e18-scaled ("WAD"): 1e18 is every possible vote.
contract FundGovernor is IFundGovernor, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EpochHistory for EpochHistory.History;

    /// @notice Maximum number of allowed wrappers.
    uint256 public constant MAX_WRAPPERS = 4;

    /// @notice Maximum basket size (matches the fund's own bound).
    uint256 public constant MAX_ASSETS = 20;

    /// @notice Epoch length; epochs flip Thursday 00:00 UTC (the Unix epoch was a Thursday).
    uint256 public constant EPOCH = 1 weeks;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS_TO_WAD = 1e14;

    struct Allocation {
        address[] tokens;
        uint16[] weightsBps;
    }

    /// @inheritdoc IFundGovernor
    address public override fund;

    GovernanceConfig private _config;
    address[] private _wrappers;
    mapping(address wrapper => bool) private _isWrapper;

    mapping(address account => mapping(address token => uint256)) private _escrow;
    mapping(address account => mapping(address token => uint256)) private _escrowPower;

    /// @inheritdoc IFundGovernor
    mapping(address account => mapping(address token => uint256)) public override unlockingOf;

    /// @inheritdoc IFundGovernor
    mapping(address account => uint64) public override unlockAt;

    /// @inheritdoc IFundGovernor
    mapping(address account => uint64) public override lastDepositAt;

    mapping(address account => uint64) private _voteLockUntil;

    mapping(address account => EpochHistory.History) private _power;
    EpochHistory.History private _totalPower;
    mapping(address token => EpochHistory.History) private _stakerVotes;

    mapping(address account => uint32[]) private _allocEpochs;
    mapping(address account => mapping(uint32 epoch => Allocation)) private _allocs;

    /// @inheritdoc IFundGovernor
    uint256 public override nextEpochToTally;

    mapping(uint256 epoch => bool) private _tallied;
    mapping(uint256 epoch => uint256) private _stakerShareWad;
    mapping(uint256 epoch => mapping(address curator => uint256)) private _curatorSlice;
    mapping(uint256 epoch => mapping(address token => uint256)) private _epochVotes;
    mapping(uint256 epoch => uint256) private _stakedSupply;

    /// @inheritdoc IFundGovernor
    mapping(address token => bool) public override delisted;

    /// @inheritdoc IFundGovernor
    mapping(address token => uint256) public override lowStreak;

    Proposal[] private _proposals;
    mapping(uint256 id => address[]) private _proposalCurators;
    mapping(uint256 id => mapping(address account => ProposalVote)) private _proposalVotes;
    mapping(address proposer => uint256) private _openProposal;

    modifier onlyAdmin() {
        if (msg.sender != _factory().owner()) revert NotAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFundGovernor
    function initialize(
        address fund_,
        GovernanceConfig calldata config_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        fund = fund_;
        _setConfig(config_);
    }

    // ──────────────────────────────────────────────────────────
    //  Escrow
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function deposit(
        address token,
        uint256 amount
    ) external override nonReentrant {
        if (!isVoteToken(token)) revert NotVoteToken();
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        uint256 power = token == IFund(fund).staking() ? received : IERC4626(token).convertToAssets(received);
        if (power == 0) revert ZeroAmount();

        _escrow[msg.sender][token] += received;
        _escrowPower[msg.sender][token] += power;
        lastDepositAt[msg.sender] = uint64(block.timestamp);

        uint256 e = currentEpoch();
        EpochHistory.History storage h = _power[msg.sender];
        _setPower(msg.sender, e, h.valueAt(e), h.valueAt(e + 1) + power);
        emit Deposited(msg.sender, token, received, power);
    }

    /// @inheritdoc IFundGovernor
    function requestWithdrawal(
        address token,
        uint256 amount
    ) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 escrowed = _escrow[msg.sender][token];
        if (amount > escrowed) revert InsufficientEscrow();
        uint256 tokenPower = _escrowPower[msg.sender][token];
        // Rounds up: a withdrawal never leaves power behind without tokens.
        uint256 power = amount == escrowed ? tokenPower : Math.mulDiv(tokenPower, amount, escrowed, Math.Rounding.Ceil);
        _escrow[msg.sender][token] = escrowed - amount;
        _escrowPower[msg.sender][token] = tokenPower - power;

        uint256 e = currentEpoch();
        EpochHistory.History storage h = _power[msg.sender];
        uint256 active = h.valueAt(e);
        uint256 next = h.valueAt(e + 1);
        // Pending power (deposited this epoch) goes first; the rest stops counting at once.
        uint256 fromPending = Math.min(power, next - active);
        _setPower(msg.sender, e, active - (power - fromPending), next - power);

        unlockingOf[msg.sender][token] += amount;
        uint256 until = Math.max(Math.max(unlockAt[msg.sender], (e + 1) * EPOCH), _voteLockUntil[msg.sender]);
        unlockAt[msg.sender] = uint64(until);
        emit WithdrawalRequested(msg.sender, token, amount, uint64(until));
    }

    /// @inheritdoc IFundGovernor
    function withdraw(
        address token
    ) external override nonReentrant returns (uint256 amount) {
        if (block.timestamp < unlockAt[msg.sender]) revert TokensLocked();
        amount = unlockingOf[msg.sender][token];
        if (amount == 0) revert ZeroAmount();
        unlockingOf[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Gauge
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function vote(
        address[] calldata tokens,
        uint16[] calldata weightsBps
    ) external override {
        IFund f = IFund(fund);
        if (!f.launched()) revert NotLaunched();
        _checkAllocation(f, tokens, weightsBps);

        uint256 e = currentEpoch();
        EpochHistory.History storage h = _power[msg.sender];
        uint256 active = h.valueAt(e);
        uint256 next = h.valueAt(e + 1);
        Allocation storage old = _latestAlloc(msg.sender);
        _applyAlloc(old, e, active, next, false);

        uint32 e32 = SafeCast.toUint32(e);
        uint32[] storage epochs = _allocEpochs[msg.sender];
        if (epochs.length == 0 || epochs[epochs.length - 1] != e32) epochs.push(e32);
        Allocation storage al = _allocs[msg.sender][e32];
        al.tokens = tokens;
        al.weightsBps = weightsBps;
        _applyAlloc(al, e, active, next, true);

        emit Voted(msg.sender, e, tokens, weightsBps);
    }

    /// @inheritdoc IFundGovernor
    function flip() external override nonReentrant {
        IFund f = IFund(fund);
        if (!f.launched()) revert NotLaunched();
        uint256 current = currentEpoch();
        uint256 e = nextEpochToTally;
        if (e == 0) e = current - 1;
        if (e >= current) revert NothingToTally();
        nextEpochToTally = e + 1;
        _tallied[e] = true;

        IFundCurators(f.curators()).checkCompliance(e);

        address[] memory assets = f.assets();
        uint256[] memory votes = _castVotes(f, e, assets);
        uint256[] memory targets = _targets(f, assets, votes);
        uint16[] memory weights = _move(f, assets, targets);
        (address[] memory kept, uint16[] memory keptWeights) = _drop(f, assets, weights);
        f.setTargetWeights(kept, keptWeights);

        emit EpochTallied(e, kept, keptWeights);
    }

    // ──────────────────────────────────────────────────────────
    //  Proposals
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function propose(
        ProposalKind kind,
        address target,
        address replacement
    ) external override returns (uint256 id) {
        IFund f = IFund(fund);
        if (!f.launched()) revert NotLaunched();
        IFundCurators cur = IFundCurators(f.curators());
        GovernanceConfig memory cfg = _config;
        uint256 next = currentEpoch() + 1;

        if (!cur.isCurator(msg.sender)) {
            uint256 power = _power[msg.sender].valueAt(next);
            uint256 assets = IFundStaking(f.staking()).convertToAssets(power);
            if (power == 0 || Math.mulDiv(assets, f.navPerShare(), PRECISION) < cfg.proposalThresholdUsd) {
                revert NotEligibleToPropose();
            }
        }
        uint256 open = _openProposal[msg.sender];
        if (open != 0) {
            ProposalState s = state(open - 1);
            if (s == ProposalState.Active || s == ProposalState.Queued || s == ProposalState.Executable) {
                revert ProposalOpen();
            }
        }
        if (!_isValid(f, cur, kind, target, replacement)) revert InvalidProposal();

        id = _proposals.length;
        _openProposal[msg.sender] = id + 1;
        bool curatorChange = kind >= ProposalKind.AddCurator;
        uint256 curatorCount = cur.curatorCount();
        uint16 curatorShare = curatorChange || curatorCount == 0 ? 0 : cfg.curatorShareBps;
        if (curatorShare != 0) _proposalCurators[id] = cur.curators();

        uint64 endTime = uint64(block.timestamp + cfg.votingPeriod);
        _proposals.push(
            Proposal({
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
                totalStake: _stakedSupplyNow(f, next),
                yesVotes: 0,
                noVotes: 0,
                quorumBps: cfg.quorumBps,
                vetoPeriod: cfg.vetoPeriod,
                executionWindow: cfg.executionWindow
            })
        );
        emit ProposalCreated(id, msg.sender, kind, target, replacement, endTime);
    }

    /// @inheritdoc IFundGovernor
    function castVote(
        uint256 id,
        bool support_
    ) external override nonReentrant returns (uint256 votes) {
        ProposalState s = state(id);
        if (s != ProposalState.Active) revert WrongState(s);
        Proposal storage p = _proposals[id];
        ProposalVote storage pv = _proposalVotes[id][msg.sender];
        if (pv.voted) revert AlreadyVoted();
        if (lastDepositAt[msg.sender] >= p.startTime) revert DepositedAfterProposal();

        if (p.curatorShareBps != 0) {
            address[] storage cs = _proposalCurators[id];
            IFundCurators cur = IFundCurators(IFund(fund).curators());
            if (_contains(cs, msg.sender) && cur.isCurator(msg.sender) && cur.isCompliant(msg.sender)) {
                votes = uint256(p.curatorShareBps) * BPS_TO_WAD / cs.length;
            }
        }
        uint256 total = p.totalStake;
        if (total != 0) {
            uint256 power = Math.min(_power[msg.sender].valueAt(currentEpoch() + 1), total);
            votes += Math.mulDiv(uint256(p.stakerShareBps) * BPS_TO_WAD, power, total);
        }
        if (votes == 0) revert NoVotingPower();

        pv.voted = true;
        pv.support = support_;
        pv.votes = votes;
        if (support_) p.yesVotes += votes;
        else p.noVotes += votes;
        if (p.endTime > _voteLockUntil[msg.sender]) _voteLockUntil[msg.sender] = p.endTime;

        emit ProposalVoteCast(id, msg.sender, support_, votes);
    }

    /// @inheritdoc IFundGovernor
    function execute(
        uint256 id
    ) external override nonReentrant {
        ProposalState s = state(id);
        if (s != ProposalState.Executable) revert WrongState(s);
        Proposal storage p = _proposals[id];
        p.executed = true;

        IFund f = IFund(fund);
        IFundCurators cur = IFundCurators(f.curators());
        if (!_isValid(f, cur, p.kind, p.target, p.replacement)) revert InvalidProposal();
        ProposalKind kind = p.kind;
        if (kind == ProposalKind.List) {
            _list(f, p.target);
        } else if (kind == ProposalKind.Delist) {
            delisted[p.target] = true;
            emit DelistedSet(p.target, true);
        } else if (kind == ProposalKind.AddCurator) {
            cur.addCurator(p.target);
        } else if (kind == ProposalKind.RemoveCurator) {
            cur.removeCurator(p.target);
        } else {
            cur.replaceCurator(p.target, p.replacement);
        }
        emit ProposalExecuted(id);
    }

    /// @inheritdoc IFundGovernor
    function cancel(
        uint256 id
    ) external override {
        ProposalState s = state(id);
        if (s != ProposalState.Active) revert WrongState(s);
        if (msg.sender != _proposals[id].proposer) revert NotProposer();
        _proposals[id].cancelled = true;
        emit ProposalCancelled(id);
    }

    /// @inheritdoc IFundGovernor
    function veto(
        uint256 id
    ) external override onlyAdmin {
        ProposalState s = state(id);
        if (s != ProposalState.Active && s != ProposalState.Queued && s != ProposalState.Executable) {
            revert WrongState(s);
        }
        _proposals[id].vetoed = true;
        emit ProposalVetoed(id);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function setDelisted(
        address token,
        bool delisted_
    ) external override onlyAdmin {
        if (delisted_ && !IFund(fund).isAsset(token)) revert InvalidProposal();
        delisted[token] = delisted_;
        emit DelistedSet(token, delisted_);
    }

    /// @inheritdoc IFundGovernor
    function setConfig(
        GovernanceConfig calldata config_
    ) external override onlyAdmin {
        _setConfig(config_);
    }

    /// @inheritdoc IFundGovernor
    function setWrapper(
        address wrapper,
        bool allowed
    ) external override onlyAdmin {
        if (wrapper == address(0)) revert ZeroAddress();
        if (allowed) {
            if (_isWrapper[wrapper]) return;
            if (_wrappers.length >= MAX_WRAPPERS || IERC4626(wrapper).asset() != IFund(fund).staking()) {
                revert InvalidWrapper();
            }
            _isWrapper[wrapper] = true;
            _wrappers.push(wrapper);
        } else {
            if (!_isWrapper[wrapper]) return;
            _isWrapper[wrapper] = false;
            uint256 n = _wrappers.length;
            for (uint256 i; i < n; ++i) {
                if (_wrappers[i] == wrapper) {
                    _wrappers[i] = _wrappers[n - 1];
                    _wrappers.pop();
                    break;
                }
            }
        }
        emit WrapperSet(wrapper, allowed);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function config() external view override returns (GovernanceConfig memory) {
        return _config;
    }

    /// @inheritdoc IFundGovernor
    function currentEpoch() public view override returns (uint256) {
        return block.timestamp / EPOCH;
    }

    /// @inheritdoc IFundGovernor
    function isTallied(
        uint256 epoch
    ) external view override returns (bool) {
        return _tallied[epoch];
    }

    /// @inheritdoc IFundGovernor
    function votesOf(
        address account,
        address token,
        uint256 epoch
    ) external view override returns (uint256 votes) {
        if (!_tallied[epoch]) return 0;
        (address[] memory tokens, uint16[] memory weights) = allocationAt(account, epoch);
        uint256 bps;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) {
                bps = weights[i];
                break;
            }
        }
        if (bps == 0) return 0;
        uint256 slice = _curatorSlice[epoch][account];
        if (slice != 0) votes = slice * bps / BPS;
        uint256 total = _stakedSupply[epoch];
        if (total != 0) {
            uint256 contribution = _power[account].valueAt(epoch) * bps / BPS;
            votes += Math.mulDiv(_stakerShareWad[epoch], contribution, total);
        }
    }

    /// @inheritdoc IFundGovernor
    function tokenVotes(
        address token,
        uint256 epoch
    ) external view override returns (uint256) {
        return _epochVotes[epoch][token];
    }

    /// @inheritdoc IFundGovernor
    function escrowOf(
        address account,
        address token
    ) external view override returns (uint256) {
        return _escrow[account][token] + unlockingOf[account][token];
    }

    /// @inheritdoc IFundGovernor
    function powerAt(
        address account,
        uint256 epoch
    ) external view override returns (uint256) {
        return _power[account].valueAt(epoch);
    }

    /// @inheritdoc IFundGovernor
    function totalPowerAt(
        uint256 epoch
    ) external view override returns (uint256) {
        return _totalPower.valueAt(epoch);
    }

    /// @inheritdoc IFundGovernor
    function stakedAssetsAt(
        address account,
        uint256 epoch
    ) external view override returns (uint256) {
        return IFundStaking(IFund(fund).staking()).convertToAssets(_power[account].valueAt(epoch));
    }

    /// @inheritdoc IFundGovernor
    function allocationAt(
        address account,
        uint256 epoch
    ) public view override returns (address[] memory tokens, uint16[] memory weightsBps) {
        uint32[] storage epochs = _allocEpochs[account];
        uint256 high = epochs.length;
        uint256 low;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (epochs[mid] > epoch) high = mid;
            else low = mid + 1;
        }
        if (high == 0) return (tokens, weightsBps);
        Allocation storage al = _allocs[account][epochs[high - 1]];
        return (al.tokens, al.weightsBps);
    }

    /// @inheritdoc IFundGovernor
    function proposalCount() external view override returns (uint256) {
        return _proposals.length;
    }

    /// @inheritdoc IFundGovernor
    function getProposal(
        uint256 id
    ) external view override returns (Proposal memory) {
        if (id >= _proposals.length) revert UnknownProposal();
        return _proposals[id];
    }

    /// @inheritdoc IFundGovernor
    function state(
        uint256 id
    ) public view override returns (ProposalState) {
        if (id >= _proposals.length) revert UnknownProposal();
        Proposal storage p = _proposals[id];
        if (p.executed) return ProposalState.Executed;
        if (p.vetoed) return ProposalState.Vetoed;
        if (p.cancelled) return ProposalState.Cancelled;
        uint256 end = p.endTime;
        if (block.timestamp < end) return ProposalState.Active;
        if (p.yesVotes <= p.noVotes || p.yesVotes < uint256(p.quorumBps) * BPS_TO_WAD) return ProposalState.Defeated;
        uint256 executableAt = end + p.vetoPeriod;
        if (block.timestamp < executableAt) return ProposalState.Queued;
        if (block.timestamp < executableAt + p.executionWindow) return ProposalState.Executable;
        return ProposalState.Expired;
    }

    /// @inheritdoc IFundGovernor
    function proposalVote(
        uint256 id,
        address account
    ) external view override returns (ProposalVote memory) {
        return _proposalVotes[id][account];
    }

    /// @inheritdoc IFundGovernor
    function isVoteToken(
        address token
    ) public view override returns (bool) {
        return token == IFund(fund).staking() || _isWrapper[token];
    }

    /// @inheritdoc IFundGovernor
    function wrappers() external view override returns (address[] memory) {
        return _wrappers;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal: vote accounting
    // ──────────────────────────────────────────────────────────

    function _setPower(
        address account,
        uint256 e,
        uint256 active,
        uint256 next
    ) internal {
        EpochHistory.History storage h = _power[account];
        uint256 oldActive = h.valueAt(e);
        uint256 oldNext = h.valueAt(e + 1);
        h.set(e, active, next);
        _totalPower.add(e, _delta(oldActive, active), _delta(oldNext, next));

        Allocation storage al = _latestAlloc(account);
        uint256 n = al.tokens.length;
        for (uint256 i; i < n; ++i) {
            uint256 bps = al.weightsBps[i];
            _stakerVotes[al.tokens[i]].add(
                e, _delta(oldActive * bps / BPS, active * bps / BPS), _delta(oldNext * bps / BPS, next * bps / BPS)
            );
        }
    }

    function _applyAlloc(
        Allocation storage al,
        uint256 e,
        uint256 active,
        uint256 next,
        bool add
    ) internal {
        uint256 n = al.tokens.length;
        for (uint256 i; i < n; ++i) {
            uint256 bps = al.weightsBps[i];
            int256 dActive = SafeCast.toInt256(active * bps / BPS);
            int256 dNext = SafeCast.toInt256(next * bps / BPS);
            if (add) _stakerVotes[al.tokens[i]].add(e, dActive, dNext);
            else _stakerVotes[al.tokens[i]].add(e, -dActive, -dNext);
        }
    }

    function _latestAlloc(
        address account
    ) internal view returns (Allocation storage) {
        uint32[] storage epochs = _allocEpochs[account];
        uint256 n = epochs.length;
        return _allocs[account][n == 0 ? 0 : epochs[n - 1]];
    }

    function _checkAllocation(
        IFund f,
        address[] calldata tokens,
        uint16[] calldata weightsBps
    ) internal view {
        uint256 n = tokens.length;
        if (n != weightsBps.length || n > MAX_ASSETS) revert InvalidAllocation();
        if (n == 0) return;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address t = tokens[i];
            if (weightsBps[i] == 0 || !f.isAsset(t) || delisted[t]) revert InvalidAllocation();
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == t) revert InvalidAllocation();
            }
            sum += weightsBps[i];
        }
        if (sum != BPS) revert InvalidAllocation();
    }

    // ──────────────────────────────────────────────────────────
    //  Internal: tally
    // ──────────────────────────────────────────────────────────

    /// @dev Votes cast per basket token in epoch `e`, as shares of all possible votes. Records what
    ///      bribe claims need: each compliant curator's slice, the stakers' share and the totals.
    function _castVotes(
        IFund f,
        uint256 e,
        address[] memory assets
    ) internal returns (uint256[] memory votes) {
        uint256 n = assets.length;
        votes = new uint256[](n);
        IFundCurators cur = IFundCurators(f.curators());
        address[] memory cs = cur.curators();
        uint256 curatorWad = cs.length == 0 ? 0 : uint256(_config.curatorShareBps) * BPS_TO_WAD;
        uint256 stakerWad = WAD - curatorWad;
        _stakerShareWad[e] = stakerWad;

        for (uint256 c; c < cs.length; ++c) {
            if (!cur.isCompliant(cs[c])) continue;
            (address[] memory tokens, uint16[] memory weights) = allocationAt(cs[c], e);
            if (tokens.length == 0) continue;
            uint256 slice = curatorWad / cs.length;
            _curatorSlice[e][cs[c]] = slice;
            for (uint256 k; k < tokens.length; ++k) {
                uint256 idx = _indexOf(assets, tokens[k]);
                if (idx < n) votes[idx] += slice * weights[k] / BPS;
            }
        }

        uint256 total = _stakedSupplyNow(f, e);
        _stakedSupply[e] = total;
        for (uint256 j; j < n; ++j) {
            if (total != 0) votes[j] += Math.mulDiv(stakerWad, _stakerVotes[assets[j]].valueAt(e), total);
            _epochVotes[e][assets[j]] = votes[j];
        }
    }

    /// @dev Targets (WAD, summing to 1e18): cast votes plus silent votes at the current weights,
    ///      then the minimum-vote and cap guardrails.
    function _targets(
        IFund f,
        address[] memory assets,
        uint256[] memory votes
    ) internal returns (uint256[] memory t) {
        uint256 n = assets.length;
        t = new uint256[](n);
        uint256 cast;
        for (uint256 j; j < n; ++j) {
            cast += votes[j];
        }
        uint256 silent = cast < WAD ? WAD - cast : 0;
        uint256 minVote = uint256(_config.minVoteBps) * BPS_TO_WAD;

        uint256 total;
        for (uint256 j; j < n; ++j) {
            address a = assets[j];
            uint256 v = votes[j] + silent * f.targetWeightBps(a) / BPS;
            if (v < minVote) {
                ++lowStreak[a];
                v = 0;
            } else {
                lowStreak[a] = 0;
            }
            if (delisted[a]) v = 0;
            t[j] = v;
            total += v;
        }
        if (total == 0) {
            for (uint256 j; j < n; ++j) {
                t[j] = uint256(f.targetWeightBps(assets[j])) * BPS_TO_WAD;
            }
            return t;
        }

        uint256 nonZero;
        for (uint256 j; j < n; ++j) {
            t[j] = Math.mulDiv(t[j], WAD, total);
            if (t[j] != 0) ++nonZero;
        }
        _cap(t, Math.max(uint256(_config.maxWeightBps) * BPS_TO_WAD, Math.ceilDiv(WAD, nonZero)));
    }

    /// @dev Caps every target at `cap`, handing the excess to the uncapped targets pro rata.
    function _cap(
        uint256[] memory t,
        uint256 cap
    ) internal pure {
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

    /// @dev Moves every weight the same fraction of the way to its target, so that none moves
    ///      more than the weekly shift; rounding dust goes to the largest weight.
    function _move(
        IFund f,
        address[] memory assets,
        uint256[] memory t
    ) internal view returns (uint16[] memory weights) {
        uint256 n = assets.length;
        weights = new uint16[](n);
        uint256[] memory old = new uint256[](n);
        uint256 maxDiff;
        for (uint256 j; j < n; ++j) {
            old[j] = uint256(f.targetWeightBps(assets[j])) * BPS_TO_WAD;
            uint256 d = t[j] > old[j] ? t[j] - old[j] : old[j] - t[j];
            if (d > maxDiff) maxDiff = d;
        }
        uint256 shift = uint256(_config.maxWeeklyShiftBps) * BPS_TO_WAD;
        uint256 k = maxDiff <= shift ? WAD : Math.mulDiv(shift, WAD, maxDiff);

        uint256 sum;
        uint256 largest;
        for (uint256 j; j < n; ++j) {
            uint256 w = t[j] >= old[j]
                ? old[j] + Math.mulDiv(t[j] - old[j], k, WAD)
                : old[j] - Math.mulDiv(old[j] - t[j], k, WAD, Math.Rounding.Ceil);
            weights[j] = uint16(w / BPS_TO_WAD);
            sum += weights[j];
            if (weights[j] > weights[largest]) largest = j;
        }
        weights[largest] += uint16(BPS - sum);
    }

    /// @dev Removes tokens at weight 0 that are delisted or have been under the minimum vote for
    ///      `dropAfterEpochs` weeks, once their balance is dust.
    function _drop(
        IFund f,
        address[] memory assets,
        uint16[] memory weights
    ) internal returns (address[] memory kept, uint16[] memory keptWeights) {
        uint256 n = assets.length;
        bool[] memory dropped = new bool[](n);
        uint256 count;
        uint256 dropAfter = _config.dropAfterEpochs;
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

    // ──────────────────────────────────────────────────────────
    //  Internal: proposals
    // ──────────────────────────────────────────────────────────

    function _isValid(
        IFund f,
        IFundCurators cur,
        ProposalKind kind,
        address target,
        address replacement
    ) internal view returns (bool) {
        if (target == address(0)) return false;
        if (kind == ProposalKind.List) {
            IFundFactory fac = _factory();
            return !f.isAsset(target) && target != address(f) && target != fac.usdg() && fac.isEligibleAsset(target)
                && IFundOracle(fac.oracle()).hasFeed(target) && f.assets().length < MAX_ASSETS;
        }
        if (kind == ProposalKind.Delist) return f.isAsset(target) && !delisted[target];
        if (kind == ProposalKind.AddCurator) {
            return !cur.isCurator(target) && cur.curatorCount() < _factory().curatorCap();
        }
        if (kind == ProposalKind.RemoveCurator) return cur.isCurator(target);
        return cur.isCurator(target) && replacement != address(0) && !cur.isCurator(replacement);
    }

    function _list(
        IFund f,
        address token
    ) internal {
        address[] memory current = f.assets();
        uint256 n = current.length;
        address[] memory assets = new address[](n + 1);
        uint16[] memory weights = new uint16[](n + 1);
        for (uint256 i; i < n; ++i) {
            assets[i] = current[i];
            weights[i] = f.targetWeightBps(current[i]);
        }
        assets[n] = token;
        delisted[token] = false;
        lowStreak[token] = 0;
        f.setTargetWeights(assets, weights);
    }

    /// @dev All staked tokens, the stakers' "all possible votes": stake that is not escrowed here
    ///      counts as silent. Read when the epoch is tallied (or the proposal opens); never below the
    ///      escrowed power, so no voter's share can exceed the stakers' share.
    function _stakedSupplyNow(
        IFund f,
        uint256 epoch
    ) internal view returns (uint256) {
        return Math.max(IERC20(f.staking()).totalSupply(), _totalPower.valueAt(epoch));
    }

    function _setConfig(
        GovernanceConfig calldata config_
    ) internal {
        if (!GovernanceConfigLib.isValid(config_)) revert InvalidConfig();
        _config = config_;
        emit ConfigSet(config_);
    }

    function _factory() internal view returns (IFundFactory) {
        return IFundFactory(IFund(fund).factory());
    }

    function _indexOf(
        address[] memory list,
        address a
    ) internal pure returns (uint256) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return i;
        }
        return type(uint256).max;
    }

    function _contains(
        address[] storage list,
        address a
    ) internal view returns (bool) {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    function _delta(
        uint256 from,
        uint256 to
    ) internal pure returns (int256) {
        return SafeCast.toInt256(to) - SafeCast.toInt256(from);
    }
}
