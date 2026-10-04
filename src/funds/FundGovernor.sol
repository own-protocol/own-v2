// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {
    BPS_TO_WAD,
    GovernanceConfig,
    GovernanceConfigLib,
    MAX_BASKET_ASSETS,
    WAD
} from "../interfaces/types/FundTypes.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {EpochHistory} from "./libraries/EpochHistory.sol";

import {GaugeMath} from "./libraries/GaugeMath.sol";
import {ProposalBook} from "./libraries/ProposalBook.sol";
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
    uint256 public constant MAX_ASSETS = MAX_BASKET_ASSETS;

    /// @notice Epoch length; epochs flip Thursday 00:00 UTC (the Unix epoch was a Thursday).
    uint256 public constant EPOCH = 1 weeks;

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

    ProposalBook.Book private _book;

    /// @inheritdoc IFundGovernor
    mapping(address account => uint32) public override bribeLockedFrom;

    mapping(address token => EpochHistory.History) private _bribeVotes;

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFundGovernor
    function initialize(address fund_, GovernanceConfig calldata config_) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        fund = fund_;
        _setConfig(config_);
    }

    // ──────────────────────────────────────────────────────────
    //  Escrow
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function deposit(address token, uint256 amount) external override nonReentrant {
        bool isStake = token == IFund(fund).staking();
        if (!isStake && !_isWrapper[token]) revert NotVoteToken();
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        uint256 power = isStake ? received : IERC4626(token).convertToAssets(received);
        if (power == 0) revert ZeroAmount();

        _escrow[msg.sender][token] += received;
        _escrowPower[msg.sender][token] += power;
        lastDepositAt[msg.sender] = uint64(block.timestamp);

        uint256 e = currentEpoch();
        EpochHistory.History storage h = _power[msg.sender];
        uint256 active = h.valueAt(e);
        uint256 next = h.valueAt(e + 1);
        _setPower(msg.sender, e, active, next, active, next + power);
        emit Deposited(msg.sender, token, received, power);
    }

    /// @inheritdoc IFundGovernor
    function requestWithdrawal(address token, uint256 amount) external override nonReentrant {
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
        _setPower(msg.sender, e, active, next, active - (power - fromPending), next - power);

        unlockingOf[msg.sender][token] += amount;
        uint256 until = Math.max(Math.max(unlockAt[msg.sender], (e + 1) * EPOCH), _voteLockUntil[msg.sender]);
        if (bribeLockedFrom[msg.sender] != 0) until = Math.max(until, block.timestamp + _config.bribeLock);
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

    /// @inheritdoc IFundGovernor
    function lockForBribes() external override {
        if (bribeLockedFrom[msg.sender] != 0) revert AlreadyBribeLocked();
        uint256 e = currentEpoch();
        EpochHistory.History storage h = _power[msg.sender];
        uint256 active = h.valueAt(e);
        uint256 next = h.valueAt(e + 1);
        Allocation storage al = _latestAlloc(msg.sender);
        // Re-adding the allocation once locked moves its votes into the bribe tallies as well.
        _applyAlloc(al, e, active, next, false, false);
        bribeLockedFrom[msg.sender] = SafeCast.toUint32(e);
        _applyAlloc(al, e, active, next, true, true);
        emit BribeLocked(msg.sender, e);
    }

    // ──────────────────────────────────────────────────────────
    //  Gauge
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function vote(address[] calldata tokens, uint16[] calldata weightsBps) external override {
        {
            IFund f = IFund(fund);
            if (!f.launched()) revert NotLaunched();
            _checkAllocation(f, tokens, weightsBps);
        }

        uint256 e = currentEpoch();
        EpochHistory.History storage h = _power[msg.sender];
        uint256 active = h.valueAt(e);
        uint256 next = h.valueAt(e + 1);
        bool locked = bribeLockedFrom[msg.sender] != 0;
        Allocation storage old = _latestAlloc(msg.sender);
        _applyAlloc(old, e, active, next, false, locked);

        uint32 e32 = SafeCast.toUint32(e);
        uint32[] storage epochs = _allocEpochs[msg.sender];
        if (epochs.length == 0 || epochs[epochs.length - 1] != e32) epochs.push(e32);
        Allocation storage al = _allocs[msg.sender][e32];
        al.tokens = tokens;
        al.weightsBps = weightsBps;
        _applyAlloc(al, e, active, next, true, locked);

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
        (uint256[] memory targets, uint16[] memory weightsNow) = _targets(f, assets, votes);
        uint16[] memory weights = GaugeMath.move(weightsNow, targets, _config.maxWeeklyShiftBps);
        (address[] memory kept, uint16[] memory keptWeights) = _drop(f, assets, weights);
        f.setTargetWeights(kept, keptWeights);

        emit EpochTallied(e, kept, keptWeights);
    }

    // ──────────────────────────────────────────────────────────
    //  Proposals
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function propose(ProposalKind kind, address target, address replacement) external override returns (uint256 id) {
        IFund f = IFund(fund);
        if (!f.launched()) revert NotLaunched();
        uint256 next = currentEpoch() + 1;
        ProposalBook.Context memory ctx = ProposalBook.Context({
            power: _power[msg.sender].valueAt(next),
            totalStake: _stakedSupplyNow(f, next),
            targetDelisted: delisted[target]
        });
        id = ProposalBook.propose(_book, fund, _config, ctx, kind, target, replacement);
    }

    /// @inheritdoc IFundGovernor
    function castVote(uint256 id, bool support_) external override nonReentrant returns (uint256 votes) {
        uint64 endTime;
        (votes, endTime) = ProposalBook.castVote(
            _book,
            fund,
            id,
            support_,
            _power[msg.sender].valueAt(currentEpoch() + 1),
            lastDepositAt[msg.sender],
            bribeLockedFrom[msg.sender] != 0
        );
        if (endTime > _voteLockUntil[msg.sender]) _voteLockUntil[msg.sender] = endTime;
    }

    /// @inheritdoc IFundGovernor
    function execute(
        uint256 id
    ) external override nonReentrant {
        address pending = id < _book.proposals.length ? _book.proposals[id].target : address(0);
        (ProposalKind kind, address target) = ProposalBook.execute(_book, fund, id, delisted[pending]);
        if (kind == ProposalKind.List) {
            _list(IFund(fund), target);
        } else if (kind == ProposalKind.Delist) {
            delisted[target] = true;
            emit DelistedSet(target, true);
        }
    }

    /// @inheritdoc IFundGovernor
    function cancel(
        uint256 id
    ) external override {
        ProposalBook.cancel(_book, id);
    }

    /// @inheritdoc IFundGovernor
    function veto(
        uint256 id
    ) external override onlyAdmin {
        ProposalBook.veto(_book, id);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IFundGovernor
    function setDelisted(address token, bool delisted_) external override onlyAdmin {
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
    function setWrapper(address wrapper, bool allowed) external override onlyAdmin {
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
    function votesOf(address account, address token, uint256 epoch) external view override returns (uint256 votes) {
        if (!_tallied[epoch]) return 0;
        uint256 bps = _bpsOf(account, token, epoch);
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
    function tokenVotes(address token, uint256 epoch) external view override returns (uint256) {
        return _epochVotes[epoch][token];
    }

    /// @inheritdoc IFundGovernor
    function bribeVotesOf(address account, address token, uint256 epoch) external view override returns (uint256) {
        uint256 from = bribeLockedFrom[account];
        if (from == 0 || from > epoch) return 0;
        return _power[account].valueAt(epoch) * _bpsOf(account, token, epoch) / BPS;
    }

    /// @inheritdoc IFundGovernor
    function bribeVotes(address token, uint256 epoch) external view override returns (uint256) {
        return _bribeVotes[token].valueAt(epoch);
    }

    /// @inheritdoc IFundGovernor
    function escrowOf(address account, address token) external view override returns (uint256) {
        return _escrow[account][token] + unlockingOf[account][token];
    }

    /// @inheritdoc IFundGovernor
    function powerAt(address account, uint256 epoch) external view override returns (uint256) {
        return _power[account].valueAt(epoch);
    }

    /// @inheritdoc IFundGovernor
    function totalPowerAt(
        uint256 epoch
    ) external view override returns (uint256) {
        return _totalPower.valueAt(epoch);
    }

    /// @inheritdoc IFundGovernor
    function stakedAssetsAt(address account, uint256 epoch) external view override returns (uint256) {
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
        return _book.proposals.length;
    }

    /// @inheritdoc IFundGovernor
    function getProposal(
        uint256 id
    ) external view override returns (Proposal memory) {
        if (id >= _book.proposals.length) revert UnknownProposal();
        return _book.proposals[id];
    }

    /// @inheritdoc IFundGovernor
    function state(
        uint256 id
    ) external view override returns (ProposalState) {
        return ProposalBook.state(_book, id);
    }

    /// @inheritdoc IFundGovernor
    function proposalVote(uint256 id, address account) external view override returns (ProposalVote memory) {
        return _book.votes[id][account];
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

    /// @dev Moves `account`'s power for epochs `e` and `e + 1` from the old values to the new ones,
    ///      and every aggregate with it.
    function _setPower(
        address account,
        uint256 e,
        uint256 oldActive,
        uint256 oldNext,
        uint256 active,
        uint256 next
    ) internal {
        _power[account].set(e, active, next);
        _totalPower.add(e, _delta(oldActive, active), _delta(oldNext, next));

        bool locked = bribeLockedFrom[account] != 0;
        Allocation storage al = _latestAlloc(account);
        uint256 n = al.tokens.length;
        for (uint256 i; i < n; ++i) {
            uint256 bps = al.weightsBps[i];
            _addVotes(
                al.tokens[i],
                e,
                _delta(oldActive * bps / BPS, active * bps / BPS),
                _delta(oldNext * bps / BPS, next * bps / BPS),
                locked
            );
        }
    }

    function _applyAlloc(
        Allocation storage al,
        uint256 e,
        uint256 active,
        uint256 next,
        bool add,
        bool locked
    ) internal {
        uint256 n = al.tokens.length;
        for (uint256 i; i < n; ++i) {
            uint256 bps = al.weightsBps[i];
            int256 dActive = SafeCast.toInt256(active * bps / BPS);
            int256 dNext = SafeCast.toInt256(next * bps / BPS);
            if (add) _addVotes(al.tokens[i], e, dActive, dNext, locked);
            else _addVotes(al.tokens[i], e, -dActive, -dNext, locked);
        }
    }

    function _addVotes(address token, uint256 e, int256 dActive, int256 dNext, bool locked) internal {
        _stakerVotes[token].add(e, dActive, dNext);
        if (locked) _bribeVotes[token].add(e, dActive, dNext);
    }

    function _bpsOf(address account, address token, uint256 epoch) internal view returns (uint256) {
        (address[] memory tokens, uint16[] memory weights) = allocationAt(account, epoch);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return weights[i];
        }
        return 0;
    }

    function _latestAlloc(
        address account
    ) internal view returns (Allocation storage) {
        uint32[] storage epochs = _allocEpochs[account];
        uint256 n = epochs.length;
        return _allocs[account][n == 0 ? 0 : epochs[n - 1]];
    }

    function _checkAllocation(IFund f, address[] calldata tokens, uint16[] calldata weightsBps) internal view {
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
    function _castVotes(IFund f, uint256 e, address[] memory assets) internal returns (uint256[] memory votes) {
        uint256 n = assets.length;
        votes = new uint256[](n);
        IFundCurators cur = IFundCurators(f.curators());
        address[] memory cs = cur.curators();
        uint256 curatorWad = cs.length == 0 ? 0 : uint256(_config.curatorShareBps) * BPS_TO_WAD;
        uint256 stakerWad = WAD - curatorWad;
        _stakerShareWad[e] = stakerWad;

        uint256 slice = cs.length == 0 ? 0 : curatorWad / cs.length;
        for (uint256 c; c < cs.length; ++c) {
            if (!cur.isCompliant(cs[c])) continue;
            (address[] memory tokens, uint16[] memory weights) = allocationAt(cs[c], e);
            if (tokens.length == 0) continue;
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

    /// @dev Targets for the tally, with each token's low-vote streak updated.
    function _targets(
        IFund f,
        address[] memory assets,
        uint256[] memory votes
    ) internal returns (uint256[] memory t, uint16[] memory current) {
        uint256 n = assets.length;
        current = new uint16[](n);
        bool[] memory isDelisted = new bool[](n);
        for (uint256 j; j < n; ++j) {
            current[j] = f.targetWeightBps(assets[j]);
            isDelisted[j] = delisted[assets[j]];
        }
        bool[] memory low;
        (t, low) = GaugeMath.targets(votes, current, isDelisted, _config.minVoteBps, _config.maxWeightBps);
        for (uint256 j; j < n; ++j) {
            if (low[j]) ++lowStreak[assets[j]];
            else lowStreak[assets[j]] = 0;
        }
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

    function _list(IFund f, address token) internal {
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
    function _stakedSupplyNow(IFund f, uint256 epoch) internal view returns (uint256) {
        return Math.max(IERC20(f.staking()).totalSupply(), _totalPower.valueAt(epoch));
    }

    function _checkAdmin() internal view {
        if (msg.sender != IFundFactory(IFund(fund).factory()).owner()) revert NotAdmin();
    }

    function _setConfig(
        GovernanceConfig calldata config_
    ) internal {
        if (!GovernanceConfigLib.isValid(config_)) revert InvalidConfig();
        _config = config_;
        emit ConfigSet(config_);
    }

    function _indexOf(address[] memory list, address a) internal pure returns (uint256) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return i;
        }
        return type(uint256).max;
    }

    function _delta(uint256 from, uint256 to) internal pure returns (int256) {
        return SafeCast.toInt256(to) - SafeCast.toInt256(from);
    }
}
