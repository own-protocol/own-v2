// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IProtocolRegistry — roles, oracle and treasury for the eUSD contracts
/// @notice The AccessControl authority for every eUSD contract (ADMIN, OPERATOR) and the source of
///         the two shared addresses they resolve at call time: the price oracle and the treasury.
///         Both addresses and all roles are set by the protocol admin (`DEFAULT_ADMIN_ROLE`), whose
///         own transfer is two-step and delayed.
interface IProtocolRegistry is IAccessControl {
    /// @notice Emitted when the oracle changes.
    /// @param oracle New oracle address.
    event OracleSet(address indexed oracle);

    /// @notice Emitted when the treasury changes.
    /// @param treasury New treasury address.
    event TreasurySet(address indexed treasury);

    /// @notice A required address was the zero address.
    error ZeroAddress();

    /// @notice The price oracle (ChainlinkOracleVerifier) read by the managers.
    /// @return Oracle address.
    function oracle() external view returns (address);

    /// @notice The protocol treasury: receives stability fees and funds staking rewards.
    /// @return Treasury address.
    function treasury() external view returns (address);

    /// @notice Set the price oracle (protocol admin).
    /// @param oracle_ New oracle address.
    function setOracle(
        address oracle_
    ) external;

    /// @notice Set the treasury (protocol admin).
    /// @param treasury_ New treasury address.
    function setTreasury(
        address treasury_
    ) external;
}
