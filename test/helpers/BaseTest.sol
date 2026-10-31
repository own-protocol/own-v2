// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {Actors} from "./Actors.sol";
import {MockOracleVerifier} from "./MockOracleVerifier.sol";
import {Test} from "forge-std/Test.sol";

/// @title BaseTest — Common setup for eUSD tests
/// @notice Deploys a ProtocolRegistry (Actors.ADMIN as PROTOCOL_ADMIN, ADMIN and OPERATOR) with a
///         mock oracle registered as the in-house oracle.
contract BaseTest is Test {
    /// @notice Protocol registry (deployed with Actors.ADMIN as owner).
    ProtocolRegistry public protocolRegistry;

    /// @notice Mock oracle verifier registered as INHOUSE_ORACLE.
    MockOracleVerifier public oracle;

    /// @dev Functional access-control roles (mirrors the per-contract inline `keccak256` constants).
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR");

    function setUp() public virtual {
        oracle = new MockOracleVerifier();
        vm.startPrank(Actors.ADMIN);
        protocolRegistry = new ProtocolRegistry(Actors.ADMIN, 2 days, 2 minutes);
        protocolRegistry.grantRole(ADMIN_ROLE, Actors.ADMIN);
        protocolRegistry.grantRole(OPERATOR_ROLE, Actors.ADMIN);
        protocolRegistry.setAddress(keccak256("INHOUSE_ORACLE"), address(oracle));
        vm.stopPrank();
        vm.label(Actors.ADMIN, "admin");
        vm.label(address(oracle), "oracle");
        vm.label(address(protocolRegistry), "ProtocolRegistry");
    }
}
