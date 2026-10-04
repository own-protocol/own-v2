// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovernanceConfig} from "./types/FundTypes.sol";

/// @title IFundGovernor — a fund's weekly weight vote (gauge) and its proposals
/// @notice Stakers escrow staked fund tokens (or an admin-listed ERC-4626 wrapper of them) here to
///         vote. Curators vote with a fixed base slice. Everything is counted as a share of all
///         possible votes, and every vote that is not cast counts as a vote to keep the current
///         weights, so a group's influence is exactly its share of all possible votes.
///
///         Weekly gauge (epochs flip Thursday 00:00 UTC):
///         - Each curator spreads a slice of `curatorShareBps / curatorCount`. Each staker's votes
///           are worth the rest times its escrowed stake over all staked tokens, so stake that is
///           not escrowed is silent. With no curators, stakers hold it all. Allocations carry over
///           until changed.
///         - Escrow timing: a deposit counts from the next epoch; a withdrawal stops counting at
///           once, and its tokens unlock at the next flip (or when the last proposal the account
///           voted on ends, if later). Escrowed stake keeps earning staker yield.
///         - At the flip ({flip}) the votes become a target: cast votes as cast, silent votes
///           spread over the current weights. A token under `minVoteBps` is targeted at 0, no
///           token is targeted above `maxWeightBps`, and every weight moves the same fraction of
///           the way to its target, so that none moves more than `maxWeeklyShiftBps`.
///         - A token at weight 0 that has stayed under `minVoteBps` for `dropAfterEpochs` weeks
///           in a row, or that was delisted, leaves the basket once its balance is dust.
///         - The curators module checks each curator's minimum stake at the flip; a curator out of
///           compliance votes no slice (it counts as silent).
///
///         Proposals (list a token, delist a token, add/remove/replace a curator):
///         - Raised by a curator or anyone whose escrowed stake is worth at least the threshold at
///           NAV; one open proposal per proposer.
///         - Voting uses the same split, measured against all staked tokens when the proposal
///           opens, except curator changes, where curators' slices do not vote. Only accounts
///           whose last deposit came before the proposal opened can vote.
///         - Passes with yes above no and yes worth at least `quorumBps` of all possible votes;
///           then the admin can veto during the veto period, then anyone executes within the
///           execution window.
interface IFundGovernor {
    /// @notice What a proposal does.
    enum ProposalKind {
        List,
        Delist,
        AddCurator,
        RemoveCurator,
        ReplaceCurator
    }

    /// @notice Lifecycle of a proposal.
    enum ProposalState {
        Active,
        Defeated,
        Queued,
        Executable,
        Executed,
        Vetoed,
        Cancelled,
        Expired
    }

    /// @notice A proposal.
    /// @param kind            What it does.
    /// @param proposer        Who raised it.
    /// @param target          Token to list or delist, or curator to add, remove or replace.
    /// @param replacement     New curator for a replacement.
    /// @param startTime       When voting opened.
    /// @param endTime         When voting closes.
    /// @param executed        Whether it was executed.
    /// @param vetoed          Whether the admin vetoed it.
    /// @param cancelled       Whether the proposer cancelled it.
    /// @param curatorShareBps Curators' share of the vote (0 for curator changes).
    /// @param stakerShareBps  Stakers' share of the vote.
    /// @param totalStake      All staked tokens when voting opened, in staked-token shares.
    /// @param yesVotes        Yes votes, as a 1e18-scaled share of all possible votes.
    /// @param noVotes         No votes, as a 1e18-scaled share of all possible votes.
    /// @param quorumBps       Yes votes needed, in basis points of all possible votes.
    /// @param vetoPeriod      Veto period after voting.
    /// @param executionWindow Execution window after the veto period.
    /// @param bribeYesVotes   Yes votes from stake locked for bribes, in staked-token shares.
    struct Proposal {
        ProposalKind kind;
        address proposer;
        address target;
        address replacement;
        uint64 startTime;
        uint64 endTime;
        bool executed;
        bool vetoed;
        bool cancelled;
        uint16 curatorShareBps;
        uint16 stakerShareBps;
        uint256 totalStake;
        uint256 yesVotes;
        uint256 noVotes;
        uint16 quorumBps;
        uint32 vetoPeriod;
        uint32 executionWindow;
        uint256 bribeYesVotes;
    }

    /// @notice An account's vote on a proposal.
    /// @param voted   Whether it voted.
    /// @param support Yes or no.
    /// @param votes   Its votes, as a 1e18-scaled share of all possible votes.
    /// @param bribeVotes Its stake counted toward listing bribes, in staked-token shares (0 unless
    ///                   locked for bribes; never the curator slice).
    struct ProposalVote {
        bool voted;
        bool support;
        uint256 votes;
        uint256 bribeVotes;
    }

    /// @notice Emitted on an escrow deposit.
    /// @param account The account.
    /// @param token   Token deposited.
    /// @param amount  Amount.
    /// @param power   Voting power added, in staked-token shares (counts from the next epoch).
    event Deposited(address indexed account, address indexed token, uint256 amount, uint256 power);

    /// @notice Emitted when escrowed tokens start unlocking.
    /// @param account  The account.
    /// @param token    Token.
    /// @param amount   Amount.
    /// @param unlockAt When they can be claimed.
    event WithdrawalRequested(address indexed account, address indexed token, uint256 amount, uint64 unlockAt);

    /// @notice Emitted when an account locks its escrow for bribes.
    /// @param account The account.
    /// @param epoch   First epoch whose bribes it earns.
    event BribeLocked(address indexed account, uint256 epoch);

    /// @notice Emitted when unlocked tokens are claimed.
    /// @param account The account.
    /// @param token   Token.
    /// @param amount  Amount.
    event Withdrawn(address indexed account, address indexed token, uint256 amount);

    /// @notice Emitted when an account sets its weight allocation.
    /// @param account    The account.
    /// @param epoch      Epoch from which it counts.
    /// @param tokens     Basket tokens voted for.
    /// @param weightsBps Share of the account's votes per token (sum 10 000, or empty to go silent).
    event Voted(address indexed account, uint256 indexed epoch, address[] tokens, uint16[] weightsBps);

    /// @notice Emitted when an epoch's votes are tallied and the new weights applied.
    /// @param epoch      The epoch tallied.
    /// @param assets     Basket after the flip.
    /// @param weightsBps New target weights.
    event EpochTallied(uint256 indexed epoch, address[] assets, uint16[] weightsBps);

    /// @notice Emitted when a proposal is raised.
    /// @param id          Proposal id.
    /// @param proposer    Proposer.
    /// @param kind        What it does.
    /// @param target      Token or curator.
    /// @param replacement New curator for a replacement.
    /// @param endTime     Voting end.
    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        ProposalKind kind,
        address target,
        address replacement,
        uint64 endTime
    );

    /// @notice Emitted on a proposal vote.
    /// @param id      Proposal id.
    /// @param voter   Voter.
    /// @param support Yes or no.
    /// @param votes   Votes, as a 1e18-scaled share of all possible votes.
    event ProposalVoteCast(uint256 indexed id, address indexed voter, bool support, uint256 votes);

    /// @notice Emitted when a proposal executes.
    /// @param id Proposal id.
    event ProposalExecuted(uint256 indexed id);

    /// @notice Emitted when the admin vetoes a proposal.
    /// @param id Proposal id.
    event ProposalVetoed(uint256 indexed id);

    /// @notice Emitted when the proposer cancels a proposal.
    /// @param id Proposal id.
    event ProposalCancelled(uint256 indexed id);

    /// @notice Emitted when a token is delisted or relisted.
    /// @param token    The token.
    /// @param delisted Whether it is delisted.
    event DelistedSet(address indexed token, bool delisted);

    /// @notice Emitted when the governance rules change.
    /// @param config New rules.
    event ConfigSet(GovernanceConfig config);

    /// @notice Emitted when a wrapper is allowed or disallowed as a vote token.
    /// @param wrapper The wrapper.
    /// @param allowed Whether allowed.
    event WrapperSet(address indexed wrapper, bool allowed);

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice The fund has not launched.
    error NotLaunched();

    /// @notice The token cannot be escrowed.
    error NotVoteToken();

    /// @notice More than the escrowed amount.
    error InsufficientEscrow();

    /// @notice The tokens are still unlocking.
    error TokensLocked();

    /// @notice The account is already locked for bribes.
    error AlreadyBribeLocked();

    /// @notice The allocation is invalid (unknown or delisted token, duplicate, or weights not
    ///         summing to 10 000).
    error InvalidAllocation();

    /// @notice There is no epoch left to tally yet.
    error NothingToTally();

    /// @notice The governance rules are out of bounds.
    error InvalidConfig();

    /// @notice The wrapper is not an ERC-4626 vault of the staked fund token, or the list is full.
    error InvalidWrapper();

    /// @notice The proposal is invalid for its kind.
    error InvalidProposal();

    /// @notice The caller is neither a curator nor staked enough to propose.
    error NotEligibleToPropose();

    /// @notice The proposer already has an open proposal.
    error ProposalOpen();

    /// @notice The proposal does not exist.
    error UnknownProposal();

    /// @notice The proposal is not in the required state.
    /// @param state Its state.
    error WrongState(ProposalState state);

    /// @notice The caller is not the proposer.
    error NotProposer();

    /// @notice The account already voted on the proposal.
    error AlreadyVoted();

    /// @notice The account deposited after the proposal opened.
    error DepositedAfterProposal();

    /// @notice The account has no votes on this proposal.
    error NoVotingPower();

    /// @notice Initialise a governor proxy. Called once by the factory.
    /// @param fund_   The fund.
    /// @param config_ Governance rules.
    function initialize(address fund_, GovernanceConfig calldata config_) external;

    /// @notice Escrow staked fund tokens (or an allowed wrapper) to vote. Counts from the next epoch.
    /// @param token  Staking module or allowed wrapper.
    /// @param amount Amount.
    function deposit(address token, uint256 amount) external;

    /// @notice Stop counting `amount` of escrowed `token` now; it unlocks at the next flip, or when
    ///         the last proposal the caller voted on ends, or `bribeLock` after now for an account
    ///         locked for bribes, whichever is latest.
    /// @param token  Token.
    /// @param amount Amount.
    function requestWithdrawal(address token, uint256 amount) external;

    /// @notice Claim unlocked tokens to the caller (the account that deposited them).
    /// @param token Token.
    /// @return amount Amount claimed.
    function withdraw(
        address token
    ) external returns (uint256 amount);

    /// @notice Lock the caller's escrow for bribes, from the current epoch on. Only locked stake
    ///         earns bribes, and every later withdrawal by the caller waits `bribeLock`. One-way.
    function lockForBribes() external;

    /// @notice Set the caller's weight allocation (curator slice and stake alike). It counts in the
    ///         current epoch and carries over until changed.
    /// @param tokens     Basket tokens.
    /// @param weightsBps Share per token (sum 10 000), or both empty to go silent.
    function vote(address[] calldata tokens, uint16[] calldata weightsBps) external;

    /// @notice Tally the oldest untallied finished epoch, apply the new weights and drop tokens
    ///         that qualify. Anyone can call (the Own keeper in practice); call again to catch up.
    function flip() external;

    /// @notice Raise a proposal.
    /// @param kind        What it does.
    /// @param target      Token to list or delist, or curator to add, remove or replace.
    /// @param replacement New curator for a replacement (zero otherwise).
    /// @return id Proposal id.
    function propose(ProposalKind kind, address target, address replacement) external returns (uint256 id);

    /// @notice Vote on a proposal.
    /// @param id      Proposal id.
    /// @param support Yes or no.
    /// @return votes Votes cast, as a 1e18-scaled share of all possible votes.
    function castVote(uint256 id, bool support) external returns (uint256 votes);

    /// @notice Execute a passed proposal after the veto period. Anyone.
    /// @param id Proposal id.
    function execute(
        uint256 id
    ) external;

    /// @notice Cancel an open proposal. Proposer only.
    /// @param id Proposal id.
    function cancel(
        uint256 id
    ) external;

    /// @notice Veto a proposal before it executes. Admin only.
    /// @param id Proposal id.
    function veto(
        uint256 id
    ) external;

    /// @notice Delist (or relist) a basket token directly. Admin only.
    /// @param token    The token.
    /// @param delisted Whether it is delisted.
    function setDelisted(address token, bool delisted) external;

    /// @notice Replace the governance rules. Admin only.
    /// @param config_ New rules.
    function setConfig(
        GovernanceConfig calldata config_
    ) external;

    /// @notice Allow or disallow an ERC-4626 wrapper of the staked fund token. Admin only.
    /// @param wrapper The wrapper.
    /// @param allowed Whether allowed.
    function setWrapper(address wrapper, bool allowed) external;

    /// @notice The fund.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice Governance rules.
    /// @return The rules.
    function config() external view returns (GovernanceConfig memory);

    /// @notice The epoch now (weeks since Thursday 1 January 1970).
    /// @return The epoch.
    function currentEpoch() external view returns (uint256);

    /// @notice The next epoch {flip} will tally (0 until the first flip).
    /// @return The epoch.
    function nextEpochToTally() external view returns (uint256);

    /// @notice Whether `epoch` has been tallied.
    /// @param epoch The epoch.
    /// @return True once tallied.
    function isTallied(
        uint256 epoch
    ) external view returns (bool);

    /// @notice Votes `account` cast for `token` in a tallied `epoch` (curator slice and stake),
    ///         as a 1e18-scaled share of all possible votes.
    /// @param account The account.
    /// @param token   The token.
    /// @param epoch   The epoch.
    /// @return The votes.
    function votesOf(address account, address token, uint256 epoch) external view returns (uint256);

    /// @notice All votes cast for `token` in a tallied `epoch`, as a 1e18-scaled share of all
    ///         possible votes.
    /// @param token The token.
    /// @param epoch The epoch.
    /// @return The votes.
    function tokenVotes(address token, uint256 epoch) external view returns (uint256);

    /// @notice Votes from stake locked for bribes that `account` cast for `token` in `epoch`, in
    ///         staked-token shares. Curator slices never count.
    /// @param account The account.
    /// @param token   The token.
    /// @param epoch   The epoch.
    /// @return The votes.
    function bribeVotesOf(address account, address token, uint256 epoch) external view returns (uint256);

    /// @notice All votes from stake locked for bribes cast for `token` in `epoch`, in staked-token
    ///         shares. Final once the epoch has ended.
    /// @param token The token.
    /// @param epoch The epoch.
    /// @return The votes.
    function bribeVotes(address token, uint256 epoch) external view returns (uint256);

    /// @notice The epoch from which `account` is locked for bribes (0 if it is not).
    /// @param account The account.
    /// @return The epoch.
    function bribeLockedFrom(
        address account
    ) external view returns (uint32);

    /// @notice Escrowed tokens of `account`, including tokens still unlocking (they return to it).
    /// @param account The account.
    /// @param token   The token.
    /// @return The amount.
    function escrowOf(address account, address token) external view returns (uint256);

    /// @notice Tokens of `account` that are unlocking.
    /// @param account The account.
    /// @param token   The token.
    /// @return The amount.
    function unlockingOf(address account, address token) external view returns (uint256);

    /// @notice When the account's unlocking tokens can be claimed.
    /// @param account The account.
    /// @return The timestamp.
    function unlockAt(
        address account
    ) external view returns (uint64);

    /// @notice When the account last deposited.
    /// @param account The account.
    /// @return The timestamp.
    function lastDepositAt(
        address account
    ) external view returns (uint64);

    /// @notice Voting power of `account` counted in `epoch`, in staked-token shares.
    /// @param account The account.
    /// @param epoch   The epoch (at most the next one).
    /// @return The power.
    function powerAt(address account, uint256 epoch) external view returns (uint256);

    /// @notice Total voting power counted in `epoch`, in staked-token shares.
    /// @param epoch The epoch (at most the next one).
    /// @return The power.
    function totalPowerAt(
        uint256 epoch
    ) external view returns (uint256);

    /// @notice Fund tokens `account` had staked in the governor in `epoch` (its power converted at
    ///         today's staking rate). Used for the curators' minimum stake.
    /// @param account The account.
    /// @param epoch   The epoch.
    /// @return The fund tokens.
    function stakedAssetsAt(address account, uint256 epoch) external view returns (uint256);

    /// @notice The allocation `account` had in `epoch`.
    /// @param account The account.
    /// @param epoch   The epoch.
    /// @return tokens     Tokens.
    /// @return weightsBps Weights.
    function allocationAt(
        address account,
        uint256 epoch
    ) external view returns (address[] memory tokens, uint16[] memory weightsBps);

    /// @notice Whether `token` is delisted (targeted at 0 until dropped).
    /// @param token The token.
    /// @return True if delisted.
    function delisted(
        address token
    ) external view returns (bool);

    /// @notice Consecutive tallied weeks `token` has been under the minimum vote.
    /// @param token The token.
    /// @return The streak.
    function lowStreak(
        address token
    ) external view returns (uint256);

    /// @notice Number of proposals.
    /// @return The count.
    function proposalCount() external view returns (uint256);

    /// @notice A proposal.
    /// @param id Proposal id.
    /// @return The proposal.
    function getProposal(
        uint256 id
    ) external view returns (Proposal memory);

    /// @notice A proposal's state.
    /// @param id Proposal id.
    /// @return The state.
    function state(
        uint256 id
    ) external view returns (ProposalState);

    /// @notice How `account` voted on a proposal.
    /// @param id      Proposal id.
    /// @param account The account.
    /// @return The vote.
    function proposalVote(uint256 id, address account) external view returns (ProposalVote memory);

    /// @notice Whether `token` can be escrowed.
    /// @param token The token.
    /// @return True if it is the staking module or an allowed wrapper.
    function isVoteToken(
        address token
    ) external view returns (bool);

    /// @notice Allowed wrappers.
    /// @return The wrappers.
    function wrappers() external view returns (address[] memory);
}
