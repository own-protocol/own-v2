// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundCurators — a fund's curators, their minimum stake and their income
/// @notice Curators run nothing (the Own keeper rebalances); they grow the fund through
///         distribution and market expertise, hold a base slice of every vote and share the
///         curators' income. This module receives all of it: the fund fee (fund tokens from mints
///         and redeems, USDG from pool trades), the curators' share of staker yield (staked fund
///         tokens) and the curators' cut of every bribe (in the bribe's reward token).
///
///         - The protocol curator (Own's seat, set on the factory) is a curator of every fund. It
///           cannot be removed, needs no stake and always takes the factory's protocol share
///           (default a third) of the curators' votes and income.
///         - Own adds the other curators up to the factory's cap; the governor adds, removes and
///           replaces them through proposals; Own can also remove them.
///         - Each of those curators must keep `minStakeBps` of the fund's supply staked in the
///           governor. The governor has it checked at each weekly flip: the first failed check is a
///           week of grace, the next one makes the curator non-compliant until a check passes again.
///         - The rest of the income is split equally among compliant curators as it arrives; while
///           none is compliant the protocol curator takes all of it.
///         - Staked fund tokens from staker yield unlock at the end of the 30-day period they are
///           earned in. A curator removed during a period forfeits that period's: they are unstaked and
///           burned, which raises NAV for every holder.
interface IFundCurators {
    /// @notice Emitted when a curator is added.
    /// @param curator The curator.
    event CuratorAdded(address indexed curator);

    /// @notice Emitted when a curator is removed.
    /// @param curator The curator.
    event CuratorRemoved(address indexed curator);

    /// @notice Emitted when a curator's compliance changes.
    /// @param curator   The curator.
    /// @param compliant Whether it meets the minimum stake.
    event ComplianceSet(address indexed curator, bool compliant);

    /// @notice Emitted when the minimum stake changes.
    /// @param minStakeBps New minimum, in basis points of supply.
    event MinStakeSet(uint16 minStakeBps);

    /// @notice Emitted when a curator claims income.
    /// @param curator The curator.
    /// @param token   Token claimed.
    /// @param amount  Amount.
    event FeesClaimed(address indexed curator, address indexed token, uint256 amount);

    /// @notice Emitted when a bribe reward token starts being tracked.
    /// @param token The token.
    event RewardTokenRegistered(address indexed token);

    /// @notice Emitted when a removed curator forfeits the staked fund tokens it earned this period.
    /// @param curator The curator.
    /// @param shares  Staked fund tokens forfeited.
    /// @param burned  Fund tokens burned.
    event YieldForfeited(address indexed curator, uint256 shares, uint256 burned);

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is not the governor.
    error NotGovernor();

    /// @notice Caller is neither the admin nor the governor.
    error NotAdminOrGovernor();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice The address is already a curator.
    error AlreadyCurator();

    /// @notice The address is not a curator.
    error NotCurator();

    /// @notice The fund already has the maximum number of curators.
    error CuratorCapReached();

    /// @notice The minimum stake is out of bounds.
    error InvalidMinStake();

    /// @notice The token is not tracked by this module.
    error NotFeeToken();

    /// @notice Caller is not the fund's bribes module.
    error NotBribes();

    /// @notice Caller is not the fund's staking module.
    error NotStaking();

    /// @notice The module already tracks the maximum number of bribe reward tokens.
    error TooManyRewardTokens();

    /// @notice Initialise a curators proxy. Called once by the factory.
    /// @param fund_        The fund.
    /// @param curators_    Starting curators.
    /// @param minStakeBps_ Minimum stake, in basis points of supply.
    function initialize(address fund_, address[] calldata curators_, uint16 minStakeBps_) external;

    /// @notice Add a curator, up to the factory's cap. Admin or governor.
    /// @param curator The curator.
    function addCurator(
        address curator
    ) external;

    /// @notice Remove a curator. Its unclaimed income stays claimable, except the staked fund
    ///         tokens earned this period, which are burned. Admin or governor. The protocol
    ///         curator cannot be removed.
    /// @param curator The curator.
    function removeCurator(
        address curator
    ) external;

    /// @notice Replace a curator with a new one. Admin or governor.
    /// @param curator     The curator leaving.
    /// @param replacement The curator joining.
    function replaceCurator(address curator, address replacement) external;

    /// @notice Set the minimum stake. Admin only.
    /// @param minStakeBps_ Minimum, in basis points of supply (at most 10%).
    function setMinStake(
        uint16 minStakeBps_
    ) external;

    /// @notice Share out staked fund tokens just minted to this module, so they vest in the period
    ///         they were earned. Staking module only.
    function notifyYield() external;

    /// @notice Track a bribe reward token, so the curators' cut paid in it can be claimed. Bribes
    ///         module only; tokens already tracked are ignored.
    /// @param token The reward token.
    function registerRewardToken(
        address token
    ) external;

    /// @notice Check every curator's stake for `epoch`. Governor only, at each flip.
    /// @param epoch The epoch being tallied.
    function checkCompliance(
        uint256 epoch
    ) external;

    /// @notice Claim the caller's share of `token` income (for the protocol curator, its share).
    ///         Staked fund tokens are claimable once the period they were earned in has ended.
    /// @param token A tracked token (see {rewardTokens}).
    /// @return amount Amount claimed.
    function claim(
        address token
    ) external returns (uint256 amount);

    /// @notice The fund.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice The protocol curator, from the factory.
    /// @return The protocol curator.
    function protocolCurator() external view returns (address);

    /// @notice Each curator's share of the curators' base slice of the vote and of the silent
    ///         staker votes in the weekly weight vote. The protocol curator comes first with the
    ///         protocol share of both. Every other curator holds an equal part of the rest of the
    ///         base slice and the compliant ones split the rest of the silent votes equally;
    ///         non-compliant curators hold neither.
    /// @return accounts  The protocol curator, then the other curators.
    /// @return baseBps   Share of the base slice, in basis points.
    /// @return silentBps Share of the silent staker votes, in basis points.
    function voteShares()
        external
        view
        returns (address[] memory accounts, uint256[] memory baseBps, uint256[] memory silentBps);

    /// @notice Current curators, without the protocol curator.
    /// @return The curators.
    function curators() external view returns (address[] memory);

    /// @notice Number of curators, without the protocol curator (the factory's cap applies to it).
    /// @return The count.
    function curatorCount() external view returns (uint256);

    /// @notice Whether `account` is a curator (the protocol curator included).
    /// @param account The account.
    /// @return True if a curator.
    function isCurator(
        address account
    ) external view returns (bool);

    /// @notice Whether `curator` currently meets the minimum stake (or is within its grace week).
    ///         Always true for the protocol curator.
    /// @param curator The curator.
    /// @return True if compliant.
    function isCompliant(
        address curator
    ) external view returns (bool);

    /// @notice Minimum stake, in basis points of supply.
    /// @return The minimum.
    function minStakeBps() external view returns (uint16);

    /// @notice Every token this module pays out: the fund token, USDG, staked fund tokens, then the
    ///         bribe reward tokens.
    /// @return The tokens.
    function rewardTokens() external view returns (address[] memory);

    /// @notice Income in `token` that `curator` can claim now.
    /// @param curator The curator.
    /// @param token   A tracked token.
    /// @return The amount.
    function claimable(address curator, address token) external view returns (uint256);

    /// @notice Staked fund tokens `curator` earned this period, still locked.
    /// @param curator The curator.
    /// @return shares   Staked fund tokens locked.
    /// @return unlockAt When the period ends and they unlock.
    function lockedYieldOf(
        address curator
    ) external view returns (uint256 shares, uint256 unlockAt);
}
