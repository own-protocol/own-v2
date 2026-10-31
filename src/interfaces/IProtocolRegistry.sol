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
    event OracleSet(address indexed oracle);

    /// @notice Emitted when the treasury changes.
    event TreasurySet(address indexed treasury);

    /// @notice A required address was the zero address.
    error ZeroAddress();

    /// @notice The price oracle (ChainlinkOracleVerifier) read by the managers.
    function oracle() external view returns (address);

    /// @notice The protocol treasury: receives stability fees.
    function treasury() external view returns (address);

    /// @notice Set the price oracle (protocol admin).
    function setOracle(
        address oracle_
    ) external;

    /// @notice Set the treasury (protocol admin).
    function setTreasury(
        address treasury_
    ) external;
}
