// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ProtocolRegistry} from "../src/core/ProtocolRegistry.sol";

/// @title SetupGovernance — Hand protocol control from the deployer to governance + a timelock
/// @notice Run by the current PROTOCOL_ADMIN (the deployer, after Deploy.s.sol). Grants the functional
///         ADMIN/OPERATOR roles to the governance and ops wallets, drops the deployer's bootstrap roles,
///         and begins transferring PROTOCOL_ADMIN (the registry root, OZ DEFAULT_ADMIN_ROLE) to the
///         TimelockController.
///
/// Roles (see src/libraries — inlined per contract as keccak256 of the name):
///   - ADMIN     → delayed bucket (risk/config). Grant to governance; later move under the timelock.
///   - OPERATOR  → instant bucket (pause/halt/disable/revoke). Grant to a hot multisig.
///   - PROTOCOL_ADMIN (DEFAULT_ADMIN_ROLE) → administers the above + the registry's own setters.
///
/// Prerequisite: deploy a TimelockController (e.g. minDelay 1h, proposer = governance multisig,
/// open executor) and pass its address via TIMELOCK. After this script begins the transfer, the
/// timelock must call `acceptDefaultAdminTransfer()` once the registry's admin-transfer delay elapses.
///
/// Usage:
///   GOV_ADMIN=0x.. OPS_OPERATOR=0x.. TIMELOCK=0x.. \
///   forge script script/SetupGovernance.s.sol --rpc-url base_sepolia --broadcast
contract SetupGovernance is Script {
    bytes32 constant ADMIN = keccak256("ADMIN");
    bytes32 constant OPERATOR = keccak256("OPERATOR");

    function run() external {
        ProtocolRegistry registry = ProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY"));
        address govAdmin = vm.envAddress("GOV_ADMIN"); // receives ADMIN (delayed bucket)
        address opsOperator = vm.envAddress("OPS_OPERATOR"); // receives OPERATOR (instant bucket)
        address timelock = vm.envAddress("TIMELOCK"); // becomes PROTOCOL_ADMIN (registry root)
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // 1. Grant functional roles to the governance / ops wallets.
        registry.grantRole(ADMIN, govAdmin);
        registry.grantRole(OPERATOR, opsOperator);

        // 2. Drop the deployer's bootstrap roles — governance/ops own the live surface now.
        registry.revokeRole(ADMIN, deployer);
        registry.revokeRole(OPERATOR, deployer);

        // 3. Begin handing PROTOCOL_ADMIN (registry root) to the timelock. The timelock must then call
        //    acceptDefaultAdminTransfer() after the configured admin-transfer delay (2-step + delayed).
        registry.beginDefaultAdminTransfer(timelock);

        vm.stopBroadcast();

        console.log("=== Governance Setup ===");
        console.log("ADMIN granted to:", govAdmin);
        console.log("OPERATOR granted to:", opsOperator);
        console.log("Deployer bootstrap roles revoked:", deployer);
        console.log("PROTOCOL_ADMIN transfer begun to timelock:", timelock);
        console.log("NEXT: timelock must call registry.acceptDefaultAdminTransfer() after the delay.");
    }
}
