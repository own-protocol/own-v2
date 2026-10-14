// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../interfaces/IFund.sol";
import {IFundBribes} from "../interfaces/IFundBribes.sol";
import {IFundCurators} from "../interfaces/IFundCurators.sol";
import {IFundFactory} from "../interfaces/IFundFactory.sol";
import {IFundGovernor} from "../interfaces/IFundGovernor.sol";
import {BPS} from "../interfaces/types/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundBribes — weight-vote and listing bribes for one fund
/// @notice See {IFundBribes}.
/// @dev Beacon proxy per fund; storage is append-only across upgrades. Every bribe is kept under the
///      governor live when it was posted, and its claims and refunds read that governor's votes, so
///      a governor swap neither reopens old bribes nor mixes up proposal ids. Only stake locked for
///      bribes counts, never curator slices. Each
///      claim is the claimant's share of a total fixed before claims open (bribes close when the
///      epoch is tallied or the proposal stops being active), rounded down, so claims never exceed
///      the bribe.
contract FundBribes is IFundBribes, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFundBribes
    address public override fund;

    mapping(address gov => mapping(uint256 epoch => mapping(address token => mapping(address reward => uint256))))
        private _bribes;
    mapping(
        address gov
            => mapping(
                uint256 epoch => mapping(address token => mapping(address reward => mapping(address => uint256)))
            )
    ) private _bribesBy;
    mapping(
        address gov
            => mapping(uint256 epoch => mapping(address token => mapping(address reward => mapping(address => bool))))
    ) private _claimed;

    mapping(address gov => mapping(uint256 id => mapping(address reward => uint256))) private _listingBribes;
    mapping(address gov => mapping(uint256 id => mapping(address reward => mapping(address briber => uint256)))) private
        _listingBribesBy;
    mapping(address gov => mapping(uint256 id => mapping(address reward => mapping(address account => bool)))) private
        _listingClaimed;

    IFundFactory private _factory;

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFundBribes
    function initialize(
        address fund_
    ) external override initializer {
        if (fund_ == address(0)) revert ZeroAddress();
        fund = fund_;
        _factory = IFundFactory(IFund(fund_).factory());
    }

    /// @inheritdoc IFundBribes
    function postBribe(
        address token,
        uint256 epoch,
        address reward,
        uint256 amount
    ) external override nonReentrant returns (uint256 net) {
        if (token == address(0)) revert ZeroAddress();
        // A launch that fails never tallies, so a bribe posted before launch could never leave.
        if (!IFund(fund).launched()) revert NotLaunched();
        IFundGovernor gov = _governor();
        if (epoch < gov.currentEpoch() || gov.isTallied(epoch)) revert EpochClosed();
        uint256 cut;
        (net, cut) = _pull(token, reward, amount);
        _bribes[address(gov)][epoch][token][reward] += net;
        _bribesBy[address(gov)][epoch][token][reward][msg.sender] += net;
        emit BribePosted(msg.sender, token, epoch, reward, net, cut);
    }

    /// @inheritdoc IFundBribes
    function claimBribe(
        IFundGovernor gov,
        address token,
        uint256 epoch,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        if (_claimed[address(gov)][epoch][token][reward][msg.sender]) revert AlreadyClaimed();
        if (!gov.isTallied(epoch)) revert EpochNotTallied();
        amount = _share(gov, msg.sender, token, epoch, reward);
        if (amount == 0) revert NothingToClaim();
        _claimed[address(gov)][epoch][token][reward][msg.sender] = true;
        IERC20(reward).safeTransfer(msg.sender, amount);
        emit BribeClaimed(msg.sender, token, epoch, reward, amount);
    }

    /// @inheritdoc IFundBribes
    function refundBribe(
        IFundGovernor gov,
        address token,
        uint256 epoch,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        // Refundable when no locked stake voted for the token in a tallied epoch, or the epoch was
        // skipped or will never be tallied (its governor was replaced).
        bool refundable = gov.isTallied(epoch)
            ? gov.bribeVotes(token, epoch) == 0
            : epoch < gov.nextEpochToTally() || gov != _governor();
        if (!refundable) revert NotRefundable();
        amount = _bribesBy[address(gov)][epoch][token][reward][msg.sender];
        if (amount == 0) revert NothingToClaim();
        _bribesBy[address(gov)][epoch][token][reward][msg.sender] = 0;
        _bribes[address(gov)][epoch][token][reward] -= amount;
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
        _listingBribes[address(gov)][proposalId][reward] += net;
        _listingBribesBy[address(gov)][proposalId][reward][msg.sender] += net;
        emit ListingBribePosted(msg.sender, proposalId, reward, net, cut);
    }

    /// @inheritdoc IFundBribes
    function claimListingBribe(
        IFundGovernor gov,
        uint256 proposalId,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        if (_listingClaimed[address(gov)][proposalId][reward][msg.sender]) revert AlreadyClaimed();
        if (gov.state(proposalId) != IFundGovernor.ProposalState.Executed) revert NothingToClaim();
        IFundGovernor.ProposalVote memory v = gov.proposalVote(proposalId, msg.sender);
        if (!v.support || v.bribeVotes == 0) revert NothingToClaim();
        // Rounds down: claims together never exceed the bribe.
        amount = Math.mulDiv(
            _listingBribes[address(gov)][proposalId][reward], v.bribeVotes, gov.getProposal(proposalId).bribeYesVotes
        );
        if (amount == 0) revert NothingToClaim();
        _listingClaimed[address(gov)][proposalId][reward][msg.sender] = true;
        IERC20(reward).safeTransfer(msg.sender, amount);
        emit ListingBribeClaimed(msg.sender, proposalId, reward, amount);
    }

    /// @inheritdoc IFundBribes
    function refundListingBribe(
        IFundGovernor gov,
        uint256 proposalId,
        address reward
    ) external override nonReentrant returns (uint256 amount) {
        IFundGovernor.ProposalState s = gov.state(proposalId);
        // An executed listing with no locked yes stake has no one to pay.
        bool unpaid = s == IFundGovernor.ProposalState.Executed && gov.getProposal(proposalId).bribeYesVotes == 0;
        if (
            !unpaid && s != IFundGovernor.ProposalState.Defeated && s != IFundGovernor.ProposalState.Vetoed
                && s != IFundGovernor.ProposalState.Cancelled && s != IFundGovernor.ProposalState.Expired
        ) revert NotRefundable();
        amount = _listingBribesBy[address(gov)][proposalId][reward][msg.sender];
        if (amount == 0) revert NothingToClaim();
        _listingBribesBy[address(gov)][proposalId][reward][msg.sender] = 0;
        _listingBribes[address(gov)][proposalId][reward] -= amount;
        IERC20(reward).safeTransfer(msg.sender, amount);
        emit ListingBribeRefunded(msg.sender, proposalId, reward, amount);
    }

    /// @inheritdoc IFundBribes
    function bribeOf(
        IFundGovernor gov,
        address token,
        uint256 epoch,
        address reward
    ) external view override returns (uint256) {
        return _bribes[address(gov)][epoch][token][reward];
    }

    /// @inheritdoc IFundBribes
    function listingBribeOf(
        IFundGovernor gov,
        uint256 proposalId,
        address reward
    ) external view override returns (uint256) {
        return _listingBribes[address(gov)][proposalId][reward];
    }

    /// @inheritdoc IFundBribes
    function claimableBribe(
        IFundGovernor gov,
        address account,
        address token,
        uint256 epoch,
        address reward
    ) external view override returns (uint256) {
        if (_claimed[address(gov)][epoch][token][reward][account] || !gov.isTallied(epoch)) return 0;
        return _share(gov, account, token, epoch, reward);
    }

    function _share(
        IFundGovernor gov,
        address account,
        address token,
        uint256 epoch,
        address reward
    ) internal view returns (uint256) {
        uint256 total = gov.bribeVotes(token, epoch);
        if (total == 0) return 0;
        // Rounds down: claims together never exceed the bribe.
        return Math.mulDiv(_bribes[address(gov)][epoch][token][reward], gov.bribeVotesOf(account, token, epoch), total);
    }

    function _pull(address token, address reward, uint256 amount) internal returns (uint256 net, uint256 cut) {
        if (amount == 0) revert ZeroAmount();
        IFundFactory fac = _factory;
        if (
            !fac.isBribeToken(reward)
                && (reward != token || (!fac.isEligibleAsset(token) && !IFund(fund).isAsset(token)))
        ) revert RewardNotAllowed();
        IERC20 r = IERC20(reward);
        uint256 balanceBefore = r.balanceOf(address(this));
        r.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = r.balanceOf(address(this)) - balanceBefore;
        // Rounds down: the curators' cut never exceeds its configured share.
        cut = Math.mulDiv(received, fac.bribeCutBps(), BPS);
        net = received - cut;
        if (net == 0) revert ZeroAmount();
        if (cut != 0) _payCut(r, cut);
    }

    /// @dev Pays the curators' cut out now, to the curators compliant at this moment. A curator that
    ///      cannot receive the token forfeits its part to the protocol curator.
    function _payCut(IERC20 r, uint256 cut) internal {
        (address[] memory to, uint256[] memory amounts) = IFundCurators(IFund(fund).curators()).bribeSplit(cut);
        uint256 toProtocol = amounts[0];
        for (uint256 i = 1; i < to.length; ++i) {
            if (amounts[i] != 0 && !r.trySafeTransfer(to[i], amounts[i])) toProtocol += amounts[i];
        }
        if (toProtocol != 0) r.safeTransfer(to[0], toProtocol);
    }

    function _governor() internal view returns (IFundGovernor) {
        return IFundGovernor(IFund(fund).governor());
    }
}
