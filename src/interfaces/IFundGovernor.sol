// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GovernanceConfig} from "./types/FundTypes.sol";

/// @title IFundGovernor — portfolio voting for one fund (the launch governor)
/// @notice The fund's assets and target weights change only through this contract.
///
///         - The creator (the fund's manager) proposes a new basket. Proposing casts the creator's
///           fixed share of the vote (30% by default) in favour.
///         - Holders share the rest (70% by default) in proportion to the fund tokens they vote
///           with, measured against the fund tokens outside the creator's hands when the proposal
///           was made (supply minus the pool and the creator's own balance; locked mints and
///           unclaimed launch allocations count). Fund tokens, staked fund tokens and admin-listed
///           ERC-4626 wrappers of the staked token all count, valued in fund tokens.
///         - A proposal passes with at least 50% of the total vote in favour, of which at least
///           20% comes from holders. So the creator alone can never pass one, and holders alone
///           need 50 of their 70 points.
///         - After voting there is a delay during which the admin can veto, then anyone executes.
///
///         Voting power is escrowed, not snapshotted: holders deposit tokens here and those tokens
///         stay locked until the end of every proposal they voted on. Only an account whose last
///         deposit came before a proposal was made can vote on it, so tokens that were outside
///         the count at that moment never vote. That rules out flash-loan votes and voting the
///         same tokens twice, and costs pool swaps nothing.
///
///         The admin can replace this module per fund ({IFund-setGovernor}) with another design
///         (quadratic voting, futarchy, bribe markets) or upgrade it for every fund through the
///         factory's beacon. Deposits stay withdrawable from a replaced governor.
interface IFundGovernor {
    /// @notice Lifecycle of a proposal.
    enum ProposalState {
        Active,
        Defeated,
        Queued,
        Executable,
        Expired,
        Executed,
        Cancelled,
        Vetoed
    }

    /// @notice A proposal and its tally.
    /// @param proposer       Creator that proposed it.
    /// @param startTime      Voting start.
    /// @param endTime        Voting end.
    /// @param eligibleSupply Fund tokens held by holders at proposal time (the holder vote's base).
    /// @param forVotes       Fund-token value voted in favour by holders.
    /// @param againstVotes   Fund-token value voted against by holders.
    /// @param config         Rules snapshotted at proposal time.
    /// @param executed       Whether it executed.
    /// @param cancelled      Whether the creator cancelled it.
    /// @param vetoed         Whether the admin vetoed it.
    /// @param assets         Proposed basket assets.
    /// @param weightsBps     Proposed target weights.
    struct Proposal {
        address proposer;
        uint64 startTime;
        uint64 endTime;
        uint256 eligibleSupply;
        uint256 forVotes;
        uint256 againstVotes;
        GovernanceConfig config;
        bool executed;
        bool cancelled;
        bool vetoed;
        address[] assets;
        uint16[] weightsBps;
    }

    /// @notice Emitted when the creator proposes a basket.
    /// @param id             Proposal id.
    /// @param proposer       The creator.
    /// @param assets         Proposed assets.
    /// @param weightsBps     Proposed weights.
    /// @param endTime        Voting end.
    /// @param eligibleSupply Holder vote base.
    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        address[] assets,
        uint16[] weightsBps,
        uint64 endTime,
        uint256 eligibleSupply
    );

    /// @notice Emitted when a holder votes.
    /// @param id      Proposal id.
    /// @param voter   Holder.
    /// @param support Whether in favour.
    /// @param weight  Fund-token value voted.
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);

    /// @notice Emitted when a proposal executes.
    /// @param id Proposal id.
    event ProposalExecuted(uint256 indexed id);

    /// @notice Emitted when the creator cancels a proposal.
    /// @param id Proposal id.
    event ProposalCancelled(uint256 indexed id);

    /// @notice Emitted when the admin vetoes a proposal.
    /// @param id Proposal id.
    event ProposalVetoed(uint256 indexed id);

    /// @notice Emitted when tokens are escrowed for voting.
    /// @param account Owner.
    /// @param token   Vote token.
    /// @param amount  Amount received.
    event Deposited(address indexed account, address indexed token, uint256 amount);

    /// @notice Emitted when escrowed tokens are withdrawn.
    /// @param account  Owner.
    /// @param token    Vote token.
    /// @param amount   Amount.
    /// @param receiver Receiver.
    event Withdrawn(address indexed account, address indexed token, uint256 amount, address receiver);

    /// @notice Emitted when the rules for new proposals change.
    /// @param config New rules.
    event ConfigSet(GovernanceConfig config);

    /// @notice Emitted when a staked-token wrapper is allowed or removed as a vote token.
    /// @param wrapper The wrapper.
    /// @param allowed Whether it counts.
    event WrapperSet(address indexed wrapper, bool allowed);

    /// @notice Caller is not the fund's creator (manager).
    error NotCreator();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice The fund has not launched.
    error NotLaunched();

    /// @notice The proposed basket is malformed.
    error InvalidProposal();

    /// @notice The previous proposal is still open.
    error ProposalOpen();

    /// @notice The proposal does not exist.
    error UnknownProposal();

    /// @notice The proposal is not in a state that allows this.
    /// @param state Its state.
    error WrongState(ProposalState state);

    /// @notice The voter already voted on this proposal.
    error AlreadyVoted();

    /// @notice The voter has nothing escrowed.
    error NoVotingPower();

    /// @notice The creator votes by proposing, not with holdings.
    error CreatorCannotVote();

    /// @notice Escrowed tokens are locked until the proposals voted on end.
    error TokensLocked();

    /// @notice The voter deposited after the proposal was made.
    error DepositedAfterProposal();

    /// @notice The token does not count for voting.
    error NotVoteToken();

    /// @notice More is withdrawn than escrowed.
    error InsufficientEscrow();

    /// @notice The wrapper is not an ERC-4626 vault of the staked token, or the list is full.
    error InvalidWrapper();

    /// @notice A rule is out of range.
    error InvalidConfig();

    /// @notice Initialise a governor proxy. Called once by the factory.
    /// @param fund_   The fund.
    /// @param config_ Initial rules.
    function initialize(
        address fund_,
        GovernanceConfig calldata config_
    ) external;

    /// @notice Propose a new basket. Creator only, after launch, one open proposal at a time.
    ///         Casts the creator's share in favour.
    /// @param assets     Assets.
    /// @param weightsBps Target weights (sum 10 000).
    /// @return id Proposal id.
    function propose(
        address[] calldata assets,
        uint16[] calldata weightsBps
    ) external returns (uint256 id);

    /// @notice Withdraw a proposal that has not executed. Creator only.
    /// @param id Proposal id.
    function cancel(
        uint256 id
    ) external;

    /// @notice Veto a proposal before it executes. Admin only.
    /// @param id Proposal id.
    function veto(
        uint256 id
    ) external;

    /// @notice Vote with everything the caller has escrowed. Locks the escrow until voting ends.
    ///         Reverts if the caller's last deposit was at or after the proposal's start.
    /// @param id      Proposal id.
    /// @param support Whether in favour.
    /// @return weight Fund-token value voted.
    function castVote(
        uint256 id,
        bool support
    ) external returns (uint256 weight);

    /// @notice Apply a passed proposal's basket to the fund. Anyone, once the delay has passed.
    /// @param id Proposal id.
    function execute(
        uint256 id
    ) external;

    /// @notice Escrow vote tokens: the fund token, its staked token or an allowed wrapper.
    /// @param token  Vote token.
    /// @param amount Amount.
    function deposit(
        address token,
        uint256 amount
    ) external;

    /// @notice Withdraw escrowed tokens once every proposal voted on has ended.
    /// @param token    Vote token.
    /// @param amount   Amount.
    /// @param receiver Receiver.
    function withdraw(
        address token,
        uint256 amount,
        address receiver
    ) external;

    /// @notice Replace the rules for new proposals. Admin only.
    /// @param config_ New rules.
    function setConfig(
        GovernanceConfig calldata config_
    ) external;

    /// @notice Allow or remove an ERC-4626 wrapper of the staked token as a vote token. Admin only.
    /// @param wrapper The wrapper.
    /// @param allowed Whether it counts.
    function setWrapper(
        address wrapper,
        bool allowed
    ) external;

    /// @notice The fund.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice Rules for new proposals.
    /// @return The rules.
    function config() external view returns (GovernanceConfig memory);

    /// @notice Number of proposals made.
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

    /// @notice A proposal's support, in basis points of the total vote.
    /// @param id Proposal id.
    /// @return creatorBps Creator's share.
    /// @return holderBps  Holders' share in favour (capped at their total share).
    function support(
        uint256 id
    ) external view returns (uint256 creatorBps, uint256 holderBps);

    /// @notice Fund-token value of everything `account` has escrowed.
    /// @param account The account.
    /// @return The value.
    function votingPower(
        address account
    ) external view returns (uint256);

    /// @notice Fund tokens outside the creator's hands now: supply minus the pool and the
    ///         creator's own fund and staked balance.
    /// @return The amount.
    function eligibleSupply() external view returns (uint256);

    /// @notice Amount of `token` escrowed by `account`.
    /// @param account The account.
    /// @param token   Vote token.
    /// @return The amount.
    function escrowOf(
        address account,
        address token
    ) external view returns (uint256);

    /// @notice When `account` last deposited.
    /// @param account The account.
    /// @return Timestamp.
    function lastDepositAt(
        address account
    ) external view returns (uint64);

    /// @notice When `account`'s escrow unlocks.
    /// @param account The account.
    /// @return Timestamp.
    function unlockAt(
        address account
    ) external view returns (uint64);

    /// @notice Whether `account` voted on proposal `id`.
    /// @param id      Proposal id.
    /// @param account The account.
    /// @return True if voted.
    function hasVoted(
        uint256 id,
        address account
    ) external view returns (bool);

    /// @notice Whether `token` counts for voting.
    /// @param token The token.
    /// @return True if a vote token.
    function isVoteToken(
        address token
    ) external view returns (bool);

    /// @notice Allowed staked-token wrappers.
    /// @return The wrappers.
    function wrappers() external view returns (address[] memory);
}
