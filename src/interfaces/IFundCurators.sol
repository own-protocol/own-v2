// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundCurators — a fund's curators, their minimum stake and their fee
/// @notice Curators run nothing (the Own keeper rebalances); they grow the fund through
///         distribution and market expertise, hold a base slice of every vote and share the curator
///         fee. This module is the fund's curator fee recipient: fund tokens from mints and
///         redeems, USDG from pool trades.
///
///         - Own adds curators up to the factory's cap; the governor adds, removes and replaces
///           them through proposals; Own can also remove them.
///         - Each curator must keep `minStakeBps` of the fund's supply staked in the governor. The
///           governor has it checked at each weekly flip: the first failed check is a week of
///           grace, the next one makes the curator non-compliant until a check passes again.
///         - Fees are split equally among compliant curators as they arrive; while no curator is
///           compliant they wait for the next one that is.
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

    /// @notice Emitted when a curator claims fees.
    /// @param curator The curator.
    /// @param token   Fee token.
    /// @param amount  Amount.
    event FeesClaimed(address indexed curator, address indexed token, uint256 amount);

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

    /// @notice The token is not a fee token.
    error NotFeeToken();

    /// @notice Initialise a curators proxy. Called once by the factory.
    /// @param fund_        The fund.
    /// @param curators_    Starting curators.
    /// @param minStakeBps_ Minimum stake, in basis points of supply.
    function initialize(
        address fund_,
        address[] calldata curators_,
        uint16 minStakeBps_
    ) external;

    /// @notice Add a curator, up to the factory's cap. Admin or governor.
    /// @param curator The curator.
    function addCurator(
        address curator
    ) external;

    /// @notice Remove a curator; its unclaimed fees stay claimable. Admin or governor.
    /// @param curator The curator.
    function removeCurator(
        address curator
    ) external;

    /// @notice Replace a curator with a new one. Admin or governor.
    /// @param curator     The curator leaving.
    /// @param replacement The curator joining.
    function replaceCurator(
        address curator,
        address replacement
    ) external;

    /// @notice Set the minimum stake. Admin only.
    /// @param minStakeBps_ Minimum, in basis points of supply (at most 10%).
    function setMinStake(
        uint16 minStakeBps_
    ) external;

    /// @notice Check every curator's stake for `epoch`. Governor only, at each flip.
    /// @param epoch The epoch being tallied.
    function checkCompliance(
        uint256 epoch
    ) external;

    /// @notice Claim the caller's share of `token` fees.
    /// @param token The fund token or USDG.
    /// @return amount Amount claimed.
    function claim(
        address token
    ) external returns (uint256 amount);

    /// @notice The fund.
    /// @return The fund.
    function fund() external view returns (address);

    /// @notice Current curators.
    /// @return The curators.
    function curators() external view returns (address[] memory);

    /// @notice Number of curators.
    /// @return The count.
    function curatorCount() external view returns (uint256);

    /// @notice Whether `account` is a curator.
    /// @param account The account.
    /// @return True if a curator.
    function isCurator(
        address account
    ) external view returns (bool);

    /// @notice Whether `curator` currently meets the minimum stake (or is within its grace week).
    /// @param curator The curator.
    /// @return True if compliant.
    function isCompliant(
        address curator
    ) external view returns (bool);

    /// @notice Minimum stake, in basis points of supply.
    /// @return The minimum.
    function minStakeBps() external view returns (uint16);

    /// @notice Fees of `token` that `curator` can claim now.
    /// @param curator The curator.
    /// @param token   The fund token or USDG.
    /// @return The amount.
    function claimable(
        address curator,
        address token
    ) external view returns (uint256);
}
