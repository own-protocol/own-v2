// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundBribes — bribes on a fund's weight vote and on its listing proposals
/// @notice Anyone can post a bribe, typically a token team wanting its token listed or
///         up-weighted. Bribes are paid in admin-listed tokens (e.g. USDG, MONEY) or in the bribed
///         token itself when it is a basket token or eligible for listing. The curators take the
///         factory's bribe cut (15% by default, at most 25%) when a bribe is posted: it goes to the
///         fund's curators module, which gives the protocol curator its share and splits the rest
///         among the other curators.
///
///         Only stake locked for bribes earns them (see {IFundGovernor-lockForBribes}); curators
///         earn on their own locked stake, never on their base slice.
///
///         - Weight-vote bribes are per token per epoch. After the epoch is tallied, the locked
///           stake that voted for the token that week splits the bribe in proportion to its votes.
///           Silent votes earn nothing. If no locked stake voted for the token that week, or the
///           epoch was never tallied, the briber takes the bribe back.
///         - Listing bribes are per listing proposal. If the listing executes, its locked yes stake
///           splits the bribe in proportion to its votes; if it fails, is vetoed, cancelled or
///           expires, or executes with no locked yes stake, the briber takes it back.
interface IFundBribes {
    /// @notice Emitted when a weight-vote bribe is posted.
    /// @param briber Who posted it.
    /// @param token  Basket token bribed for.
    /// @param epoch  Epoch it pays for.
    /// @param reward Token paid.
    /// @param amount Amount after the curators' cut.
    /// @param cut    The curators' cut.
    event BribePosted(
        address indexed briber,
        address indexed token,
        uint256 indexed epoch,
        address reward,
        uint256 amount,
        uint256 cut
    );

    /// @notice Emitted when a weight-vote bribe is claimed.
    /// @param account The voter.
    /// @param token   Basket token.
    /// @param epoch   Epoch.
    /// @param reward  Token paid.
    /// @param amount  Amount.
    event BribeClaimed(
        address indexed account, address indexed token, uint256 indexed epoch, address reward, uint256 amount
    );

    /// @notice Emitted when a weight-vote bribe is refunded.
    /// @param briber Who posted it.
    /// @param token  Basket token.
    /// @param epoch  Epoch.
    /// @param reward Token refunded.
    /// @param amount Amount.
    event BribeRefunded(
        address indexed briber, address indexed token, uint256 indexed epoch, address reward, uint256 amount
    );

    /// @notice Emitted when a listing bribe is posted.
    /// @param briber     Who posted it.
    /// @param proposalId Listing proposal.
    /// @param reward     Token paid.
    /// @param amount     Amount after the curators' cut.
    /// @param cut        The curators' cut.
    event ListingBribePosted(
        address indexed briber, uint256 indexed proposalId, address reward, uint256 amount, uint256 cut
    );

    /// @notice Emitted when a listing bribe is claimed.
    /// @param account    The yes voter.
    /// @param proposalId Listing proposal.
    /// @param reward     Token paid.
    /// @param amount     Amount.
    event ListingBribeClaimed(address indexed account, uint256 indexed proposalId, address reward, uint256 amount);

    /// @notice Emitted when a listing bribe is refunded.
    /// @param briber     Who posted it.
    /// @param proposalId Listing proposal.
    /// @param reward     Token refunded.
    /// @param amount     Amount.
    event ListingBribeRefunded(address indexed briber, uint256 indexed proposalId, address reward, uint256 amount);

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice The reward token is neither admin-listed nor the bribed token (a basket token or one
    ///         eligible for listing).
    error RewardNotAllowed();

    /// @notice The epoch is already tallied or in the past.
    error EpochClosed();

    /// @notice The epoch is not tallied yet.
    error EpochNotTallied();

    /// @notice The proposal is not an open listing proposal.
    error NotOpenListing();

    /// @notice Nothing to claim.
    error NothingToClaim();

    /// @notice Already claimed.
    error AlreadyClaimed();

    /// @notice The bribe is not refundable.
    error NotRefundable();

    /// @notice Initialise a bribes proxy. Called once by the factory.
    /// @param fund_ The fund.
    function initialize(
        address fund_
    ) external;

    /// @notice Post a bribe for `token` in `epoch` (the current epoch or a later one).
    /// @param token  Basket token.
    /// @param epoch  Epoch.
    /// @param reward Token paid.
    /// @param amount Amount sent (the curators' cut is taken from it).
    /// @return net Amount bribed after the cut.
    function postBribe(address token, uint256 epoch, address reward, uint256 amount) external returns (uint256 net);

    /// @notice Claim the caller's share of the `reward` bribes for `token` in a tallied `epoch`.
    /// @param token  Basket token.
    /// @param epoch  Epoch.
    /// @param reward Token paid.
    /// @return amount Amount claimed.
    function claimBribe(address token, uint256 epoch, address reward) external returns (uint256 amount);

    /// @notice Take back the caller's bribe when no locked stake voted for `token` in `epoch`, or the
    ///         epoch was skipped.
    /// @param token  Basket token.
    /// @param epoch  Epoch.
    /// @param reward Token.
    /// @return amount Amount refunded.
    function refundBribe(address token, uint256 epoch, address reward) external returns (uint256 amount);

    /// @notice Post a bribe on an active listing proposal, paid to its yes voters if it executes.
    /// @param proposalId Listing proposal.
    /// @param reward     Token paid.
    /// @param amount     Amount sent (the curators' cut is taken from it).
    /// @return net Amount bribed after the cut.
    function postListingBribe(uint256 proposalId, address reward, uint256 amount) external returns (uint256 net);

    /// @notice Claim the caller's share of an executed listing's `reward` bribes.
    /// @param proposalId Listing proposal.
    /// @param reward     Token paid.
    /// @return amount Amount claimed.
    function claimListingBribe(uint256 proposalId, address reward) external returns (uint256 amount);

    /// @notice Take back the caller's bribe on a listing that failed, was vetoed, cancelled or expired,
    ///         or executed with no locked yes stake.
    /// @param proposalId Listing proposal.
    /// @param reward     Token.
    /// @return amount Amount refunded.
    function refundListingBribe(uint256 proposalId, address reward) external returns (uint256 amount);

    /// @notice The fund.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice Total `reward` bribed for `token` in `epoch`, after the curators' cut.
    /// @param token  Basket token.
    /// @param epoch  Epoch.
    /// @param reward Token.
    /// @return The amount.
    function bribeOf(address token, uint256 epoch, address reward) external view returns (uint256);

    /// @notice Total `reward` bribed on a listing proposal, after the curators' cut.
    /// @param proposalId Listing proposal.
    /// @param reward     Token.
    /// @return The amount.
    function listingBribeOf(uint256 proposalId, address reward) external view returns (uint256);

    /// @notice What `account` can claim of the `reward` bribes for `token` in `epoch`.
    /// @param account The voter.
    /// @param token   Basket token.
    /// @param epoch   Epoch.
    /// @param reward  Token.
    /// @return The amount.
    function claimableBribe(
        address account,
        address token,
        uint256 epoch,
        address reward
    ) external view returns (uint256);
}
