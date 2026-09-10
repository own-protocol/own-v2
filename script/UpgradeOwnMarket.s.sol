// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnMarket} from "../src/core/OwnMarket.sol";
import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title UpgradeOwnMarket — Deploy a new market implementation and upgrade the proxy
/// @notice The single upgrade path for OwnMarket logic, including any change to the linked
///         ForceExecuteLib (a deployed library is immutable — shipping a library fix means
///         deploying a new implementation linked against the fixed library and upgrading to it).
///         Forge auto-deploys and links a fresh ForceExecuteLib in the same broadcast.
///
///         If the broadcaster holds the protocol ADMIN role the upgrade executes directly;
///         otherwise the implementation is still deployed and the exact upgrade calldata is
///         printed for scheduling through governance (Safe / timelock).
///
/// @dev PRE-UPGRADE CHECKLIST — do not skip:
///        1. Storage layout is append-only from the live baseline: diff
///           `forge inspect OwnMarket storageLayout` against the layout of the deployed
///           implementation. Reordered/removed/retyped slots corrupt live orders.
///        2. `forge test` green, including the UUPS suite in test/unit/OwnMarket.t.sol.
///        3. Explorer verification of the new implementation needs the freshly linked
///           ForceExecuteLib address (printed in the broadcast artifacts).
///        4. Post-upgrade smoke test: getOrder on a known pre-upgrade order, then a small
///           executeOrder round-trip.
///
/// Env: DEPLOYER_PRIVATE_KEY, PROTOCOL_REGISTRY
///
/// Usage:
///   forge script script/UpgradeOwnMarket.s.sol --rpc-url <chain> --broadcast --verify
contract UpgradeOwnMarket is Script {
    bytes32 private constant ADMIN = keccak256("ADMIN");

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY"));
        address proxy = registry.market();
        require(proxy != address(0), "market not registered");
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // 1. Fresh implementation (ForceExecuteLib deployed + linked by forge in this broadcast).
        OwnMarket newImpl = new OwnMarket();

        // 2. Upgrade directly if the broadcaster holds ADMIN; otherwise hand the calldata to
        //    governance. The implementation deploy above is useful either way.
        bytes memory upgradeCalldata = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), bytes("")));
        if (registry.hasRole(ADMIN, deployer)) {
            UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");
            // Sanity: proxy state must be intact and still bound to this registry.
            require(address(OwnMarket(proxy).registry()) == address(registry), "registry mismatch after upgrade");
            console.log("Upgraded OwnMarket proxy:", proxy);
        } else {
            console.log("Deployer lacks ADMIN - schedule via governance:");
            console.log("  target:", proxy);
            console.log("  calldata:");
            console.logBytes(upgradeCalldata);
        }

        vm.stopBroadcast();

        console.log("New OwnMarket implementation:", address(newImpl));
    }
}
