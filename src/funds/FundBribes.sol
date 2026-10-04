// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundBribes} from "../interfaces/IFundBribes.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundBribes — weight-vote and listing bribes for one fund
/// @notice See {IFundBribes}.
/// @dev Beacon proxy per fund; storage is append-only across upgrades. Votes are read from the
///      fund's current governor. Each claim is the claimant's share of a total fixed before claims
///      open (bribes close when the epoch is tallied or the proposal stops being active), rounded
///      down, so claims never exceed the bribe.
contract FundBribes is IFundBribes, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFundBribes
    address public override fund;

    mapping(uint256 epoch => mapping(address token => mapping(address reward => uint256))) private _bribes;
    mapping(uint256 epoch => mapping(address token => mapping(address reward => mapping(address briber => uint256))))
        private _bribesBy;
    mapping(uint256 epoch => mapping(address token => mapping(address reward => mapping(address account => bool))))
        private _claimed;

    mapping(uint256 id => mapping(address reward => uint256)) private _listingBribes;
    mapping(uint256 id => mapping(address reward => mapping(address briber => uint256))) private _listingBribesBy;
    mapping(uint256 id => mapping(address reward => mapping(address account => bool))) private _listingClaimed;

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFundBribes
    function initialize(
        address fund_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        fund = fund_;
    }

    /// @inheritdoc IFundBribes
    function postBribe(
        address token,
        uint256 epoch,
        address reward,
        uint256 amount
    ) external override nonReentrant returns (uint256 net) {
        if (token == address(0)) revert ZeroAddress();
        IFundGovernor gov = _governor();
        if (epoch < gov.currentEpoch() || gov.isTallied(epoch)) revert EpochClosed();
        uint256 cut;
        (net, cut) = _pull(token, reward, amount);
        _bribes[epoch][token][reward] += net;
        _bribesBy[epoch][token][reward][msg.sender] += net;
        emit BribePosted(msg.sender, token, epoch, reward, net, cut);
    }

    /// @inheritdoc IFundBribes
    function claimBribe(
        address token,
        uint256 epoch,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        if (_claimed[epoch][token][reward][msg.sender]) revert AlreadyClaimed();
        IFundGovernor gov = _governor();
        if (!gov.isTallied(epoch)) revert EpochNotTallied();
        amount = _share(gov, msg.sender, token, epoch, reward);
        if (amount == 0) revert NothingToClaim();
        _claimed[epoch][token][reward][msg.sender] = true;
        IERC20(reward).safeTransfer(msg.sender, amount);
        emit BribeClaimed(msg.sender, token, epoch, reward, amount);
    }

    /// @inheritdoc IFundBribes
    function refundBribe(
        address token,
        uint256 epoch,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        IFundGovernor gov = _governor();
        bool skipped = !gov.isTallied(epoch) && epoch < gov.nextEpochToTally();
        bool unvoted = gov.isTallied(epoch) && gov.tokenVotes(token, epoch) == 0;
        if (!skipped && !unvoted) revert NotRefundable();
        amount = _bribesBy[epoch][token][reward][msg.sender];
        if (amount == 0) revert NothingToClaim();
        _bribesBy[epoch][token][reward][msg.sender] = 0;
        _bribes[epoch][token][reward] -= amount;
        IERC20(reward).safeTransfer(msg.sender, amount);
        emit BribeRefunded(msg.sender, token, epoch, reward, amount);
    }

    /// @inheritdoc IFundBribes
    function postListingBribe(
        uint256 proposalId,
        address reward,
        uint256 amount
    ) external override nonReentrant returns (uint256 net) {
        IFundGovernor gov = _governor();
        IFundGovernor.Proposal memory p = gov.getProposal(proposalId);
        if (p.kind != IFundGovernor.ProposalKind.List || gov.state(proposalId) != IFundGovernor.ProposalState.Active) {
            revert NotOpenListing();
        }
        uint256 cut;
        (net, cut) = _pull(p.target, reward, amount);
        _listingBribes[proposalId][reward] += net;
        _listingBribesBy[proposalId][reward][msg.sender] += net;
        emit ListingBribePosted(msg.sender, proposalId, reward, net, cut);
    }

    /// @inheritdoc IFundBribes
    function claimListingBribe(
        uint256 proposalId,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        if (_listingClaimed[proposalId][reward][msg.sender]) revert AlreadyClaimed();
        IFundGovernor gov = _governor();
        if (gov.state(proposalId) != IFundGovernor.ProposalState.Executed) revert NothingToClaim();
        IFundGovernor.ProposalVote memory v = gov.proposalVote(proposalId, msg.sender);
        if (!v.voted || !v.support) revert NothingToClaim();
        // Rounds down: claims together never exceed the bribe.
        amount = Math.mulDiv(_listingBribes[proposalId][reward], v.votes, gov.getProposal(proposalId).yesVotes);
        if (amount == 0) revert NothingToClaim();
        _listingClaimed[proposalId][reward][msg.sender] = true;
        IERC20(reward).safeTransfer(msg.sender, amount);
        emit ListingBribeClaimed(msg.sender, proposalId, reward, amount);
    }

    /// @inheritdoc IFundBribes
    function refundListingBribe(
        uint256 proposalId,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        IFundGovernor.ProposalState s = _governor().state(proposalId);
        if (
            s != IFundGovernor.ProposalState.Defeated && s != IFundGovernor.ProposalState.Vetoed
                && s != IFundGovernor.ProposalState.Cancelled && s != IFundGovernor.ProposalState.Expired
        ) revert NotRefundable();
        amount = _listingBribesBy[proposalId][reward][msg.sender];
        if (amount == 0) revert NothingToClaim();
        _listingBribesBy[proposalId][reward][msg.sender] = 0;
        _listingBribes[proposalId][reward] -= amount;
        IERC20(reward).safeTransfer(msg.sender, amount);
        emit ListingBribeRefunded(msg.sender, proposalId, reward, amount);
    }

    /// @inheritdoc IFundBribes
    function bribeOf(address token, uint256 epoch, address reward) external view override returns (uint256) {
        return _bribes[epoch][token][reward];
    }

    /// @inheritdoc IFundBribes
    function listingBribeOf(uint256 proposalId, address reward) external view override returns (uint256) {
        return _listingBribes[proposalId][reward];
    }

    /// @inheritdoc IFundBribes
    function claimableBribe(
        address account,
        address token,
        uint256 epoch,
        address reward
    ) external view override returns (uint256) {
        IFundGovernor gov = _governor();
        if (_claimed[epoch][token][reward][account] || !gov.isTallied(epoch)) return 0;
        return _share(gov, account, token, epoch, reward);
    }

    function _share(
        IFundGovernor gov,
        address account,
        address token,
        uint256 epoch,
        address reward
    ) internal view returns (uint256) {
        uint256 total = gov.tokenVotes(token, epoch);
        if (total == 0) return 0;
        // Rounds down: claims together never exceed the bribe.
        return Math.mulDiv(_bribes[epoch][token][reward], gov.votesOf(account, token, epoch), total);
    }

    function _pull(address token, address reward, uint256 amount) internal returns (uint256 net, uint256 cut) {
        if (amount == 0) revert ZeroAmount();
        IFundFactory fac = IFundFactory(IFund(fund).factory());
        if (reward != token && !fac.isBribeToken(reward)) revert RewardNotAllowed();
        IERC20 r = IERC20(reward);
        uint256 balanceBefore = r.balanceOf(address(this));
        r.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = r.balanceOf(address(this)) - balanceBefore;
        // Rounds down: Own's cut never exceeds its configured share.
        cut = Math.mulDiv(received, fac.bribeCutBps(), BPS);
        net = received - cut;
        if (net == 0) revert ZeroAmount();
        if (cut != 0) r.safeTransfer(fac.protocolFeeRecipient(), cut);
    }

    function _governor() internal view returns (IFundGovernor) {
        return IFundGovernor(IFund(fund).governor());
    }
}
