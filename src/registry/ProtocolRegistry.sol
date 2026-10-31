// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @title ProtocolRegistry — roles, oracle and treasury for the eUSD contracts
/// @notice See {IProtocolRegistry}. The protocol admin (`DEFAULT_ADMIN_ROLE`) is held by the
///         governance Safe and grants ADMIN and OPERATOR.
contract ProtocolRegistry is IProtocolRegistry, AccessControlDefaultAdminRules {
    /// @inheritdoc IProtocolRegistry
    address public override oracle;

    /// @inheritdoc IProtocolRegistry
    address public override treasury;

    /// @param admin              Initial protocol admin (the governance Safe).
    /// @param adminTransferDelay Delay on handing the protocol admin role to a new address.
    constructor(address admin, uint48 adminTransferDelay) AccessControlDefaultAdminRules(adminTransferDelay, admin) {}

    /// @inheritdoc IProtocolRegistry
    function setOracle(
        address oracle_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(oracle_);
    }

    /// @inheritdoc IProtocolRegistry
    function setTreasury(
        address treasury_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }
}
