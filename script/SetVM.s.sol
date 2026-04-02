// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnVault} from "../src/core/OwnVault.sol";

/// @title SetVM — Update the vault manager address
/// @notice Run by admin (deployer) to change the VM bound to a vault.
///
/// Usage:
///   NEW_VM=0x... forge script script/SetVM.s.sol --rpc-url base_sepolia --broadcast
contract SetVM is Script {
    function run() external {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address newVM = vm.envAddress("NEW_VM");

        console.log("Vault:", vaultAddr);
        console.log("New VM:", newVM);

        OwnVault vault = OwnVault(vaultAddr);
        console.log("Current VM:", vault.vm());

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        vault.setVM(newVM);
        vm.stopBroadcast();

        console.log("VM updated to:", vault.vm());
    }
}
