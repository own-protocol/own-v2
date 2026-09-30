// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {IFundHook} from "../interfaces/IFundHook.sol";
import {IFundStaking} from "../interfaces/IFundStaking.sol";
import {GovernanceConfig, GovernanceConfigLib} from "../interfaces/types/FundTypes.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundGovernor — creator-plus-holder voting on a fund's basket
/// @notice See {IFundGovernor}.
/// @dev Beacon proxy per fund; storage is append-only across upgrades.
contract FundGovernor is IFundGovernor, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum number of allowed wrappers (bounds {votingPower}).
    uint256 public constant MAX_WRAPPERS = 4;

    /// @notice Maximum basket size a proposal may carry (matches the fund's own bound).
    uint256 public constant MAX_ASSETS = 20;

    /// @inheritdoc IFundGovernor
    address public override fund;

    GovernanceConfig private _config;
    Proposal[] private _proposals;
    address[] private _wrappers;

    /// @inheritdoc IFundGovernor
    mapping(address account => mapping(address token => uint256)) public override escrowOf;

    /// @inheritdoc IFundGovernor
    mapping(address account => uint64) public override unlockAt;

    mapping(uint256 id => mapping(address account => bool)) private _voted;
    mapping(address wrapper => bool) private _isWrapper;

    modifier onlyAdmin() {
        if (msg.sender != _admin()) revert NotAdmin();
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

    /// @inheritdoc IFundGovernor
    function propose(
        address[] calldata assets,
        uint16[] calldata weightsBps
    ) external override returns (uint256 id) {
        IFund f = IFund(fund);
        if (msg.sender != f.manager()) revert NotCreator();
        if (!f.launched()) revert NotLaunched();
        _checkBasket(assets, weightsBps);

        id = _proposals.length;
        if (id != 0) {
            ProposalState last = state(id - 1);
            if (last == ProposalState.Active || last == ProposalState.Queued || last == ProposalState.Executable) {
                revert ProposalOpen();
            }
        }

        GovernanceConfig memory cfg = _config;
        uint64 endTime = uint64(block.timestamp + cfg.votingPeriod);
        uint256 eligible = eligibleSupply();

        Proposal storage p = _proposals.push();
        p.proposer = msg.sender;
        p.startTime = uint64(block.timestamp);
        p.endTime = endTime;
        p.eligibleSupply = eligible;
        p.config = cfg;
        p.assets = assets;
        p.weightsBps = weightsBps;

        emit ProposalCreated(id, msg.sender, assets, weightsBps, endTime, eligible);
    }

    /// @inheritdoc IFundGovernor
    function cancel(
        uint256 id
    ) external override {
        if (msg.sender != IFund(fund).manager()) revert NotCreator();
        ProposalState s = state(id);
        if (s != ProposalState.Active && s != ProposalState.Queued && s != ProposalState.Executable) {
            revert WrongState(s);
        }
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

    /// @inheritdoc IFundGovernor
    function castVote(
        uint256 id,
        bool support_
    ) external override nonReentrant returns (uint256 weight) {
        ProposalState s = state(id);
        if (s != ProposalState.Active) revert WrongState(s);
        if (msg.sender == IFund(fund).manager()) revert CreatorCannotVote();
        if (_voted[id][msg.sender]) revert AlreadyVoted();
        weight = votingPower(msg.sender);
        if (weight == 0) revert NoVotingPower();

        _voted[id][msg.sender] = true;
        Proposal storage p = _proposals[id];
        if (support_) p.forVotes += weight;
        else p.againstVotes += weight;
        if (p.endTime > unlockAt[msg.sender]) unlockAt[msg.sender] = p.endTime;

        emit VoteCast(id, msg.sender, support_, weight);
    }

    /// @inheritdoc IFundGovernor
    function execute(
        uint256 id
    ) external override nonReentrant {
        ProposalState s = state(id);
        if (s != ProposalState.Executable) revert WrongState(s);
        Proposal storage p = _proposals[id];
        p.executed = true;
        IFund(fund).setTargetWeights(p.assets, p.weightsBps);
        emit ProposalExecuted(id);
    }

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
        if (received == 0) revert ZeroAmount();
        escrowOf[msg.sender][token] += received;
        emit Deposited(msg.sender, token, received);
    }

    /// @inheritdoc IFundGovernor
    function withdraw(
        address token,
        uint256 amount,
        address receiver
    ) external override nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < unlockAt[msg.sender]) revert TokensLocked();
        uint256 escrowed = escrowOf[msg.sender][token];
        if (amount > escrowed) revert InsufficientEscrow();
        escrowOf[msg.sender][token] = escrowed - amount;
        IERC20(token).safeTransfer(receiver, amount);
        emit Withdrawn(msg.sender, token, amount, receiver);
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

    /// @inheritdoc IFundGovernor
    function config() external view override returns (GovernanceConfig memory) {
        return _config;
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
        if (!_passed(p)) return ProposalState.Defeated;
        uint256 executableAt = end + p.config.executionDelay;
        if (block.timestamp < executableAt) return ProposalState.Queued;
        if (block.timestamp < executableAt + p.config.executionWindow) return ProposalState.Executable;
        return ProposalState.Expired;
    }

    /// @inheritdoc IFundGovernor
    function support(
        uint256 id
    ) external view override returns (uint256 creatorBps, uint256 holderBps) {
        if (id >= _proposals.length) revert UnknownProposal();
        return _support(_proposals[id]);
    }

    /// @inheritdoc IFundGovernor
    function votingPower(
        address account
    ) public view override returns (uint256 power) {
        address f = fund;
        address staking = IFund(f).staking();
        power = escrowOf[account][f];
        uint256 staked = escrowOf[account][staking];
        uint256 n = _wrappers.length;
        for (uint256 i; i < n; ++i) {
            address w = _wrappers[i];
            uint256 wrapped = escrowOf[account][w];
            if (wrapped != 0) staked += IERC4626(w).convertToAssets(wrapped);
        }
        if (staked != 0) power += IFundStaking(staking).convertToAssets(staked);
    }

    /// @inheritdoc IFundGovernor
    function eligibleSupply() public view override returns (uint256) {
        IFund f = IFund(fund);
        address creator = f.manager();
        IFundStaking staking = IFundStaking(f.staking());
        address poolManager = address(IFundHook(IFundFactory(f.factory()).hook()).poolManager());
        uint256 excluded = f.balanceOf(poolManager) + f.balanceOf(address(f)) + f.balanceOf(f.launch())
            + f.balanceOf(creator) + staking.convertToAssets(staking.balanceOf(creator));
        uint256 supply = f.totalSupply();
        return supply > excluded ? supply - excluded : 0;
    }

    /// @inheritdoc IFundGovernor
    function hasVoted(
        uint256 id,
        address account
    ) external view override returns (bool) {
        return _voted[id][account];
    }

    /// @inheritdoc IFundGovernor
    function isVoteToken(
        address token
    ) public view override returns (bool) {
        return token == fund || token == IFund(fund).staking() || _isWrapper[token];
    }

    /// @inheritdoc IFundGovernor
    function wrappers() external view override returns (address[] memory) {
        return _wrappers;
    }

    function _passed(
        Proposal storage p
    ) internal view returns (bool) {
        (uint256 creatorBps, uint256 holderBps) = _support(p);
        return creatorBps + holderBps >= p.config.passThresholdBps && holderBps >= p.config.minUserSupportBps;
    }

    function _support(
        Proposal storage p
    ) internal view returns (uint256 creatorBps, uint256 holderBps) {
        creatorBps = p.config.creatorPowerBps;
        uint256 holderShare = BPS - creatorBps;
        uint256 eligible = p.eligibleSupply;
        if (eligible == 0) return (creatorBps, 0);
        // Rounds down: holder support is never overstated.
        holderBps = Math.mulDiv(holderShare, p.forVotes, eligible);
        if (holderBps > holderShare) holderBps = holderShare;
    }

    function _checkBasket(
        address[] calldata assets,
        uint16[] calldata weightsBps
    ) internal view {
        uint256 n = assets.length;
        if (n == 0 || n > MAX_ASSETS || n != weightsBps.length) revert InvalidProposal();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (assets[i] == address(0) || assets[i] == fund) revert InvalidProposal();
            sum += weightsBps[i];
        }
        if (sum != BPS) revert InvalidProposal();
    }

    function _setConfig(
        GovernanceConfig calldata config_
    ) internal {
        if (!GovernanceConfigLib.isValid(config_)) revert InvalidConfig();
        _config = config_;
        emit ConfigSet(config_);
    }

    function _admin() internal view returns (address) {
        return IFundFactory(IFund(fund).factory()).owner();
    }
}
