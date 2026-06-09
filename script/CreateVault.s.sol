// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {VaultFactory} from "../src/core/VaultFactory.sol";

/// @title CreateVault — Create a WETH vault and configure admin parameters
/// @notice Run by deployer (= admin) after Deploy.s.sol. Reads deployed addresses from .env.
///
/// Usage:
///   forge script script/CreateVault.s.sol --rpc-url base_sepolia --broadcast
contract CreateVault is Script {
    address constant WETH = 0xfbd78Da8aDbc322084eE7F80C10F914B92CEb6FE;
    bytes32 constant ETH = bytes32("ETH");

    function run() external {
        address managerAddress = vm.envAddress("VM_ADDRESS");
        address factoryAddr = vm.envAddress("VAULT_FACTORY");

        console.log("Manager Address:", managerAddress);
        console.log("VaultFactory:", factoryAddr);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        VaultFactory factory = VaultFactory(factoryAddr);

        // Create WETH vault. The collateral oracle ticker (ETH) is registered with the
        // VaultManager by the factory; global utilisation, payment token, and the claim
        // threshold are managed centrally on the VaultManager.
        address vaultAddr = factory.createVault(WETH, managerAddress, "Own ETH Vault", "oETH", ETH);
        console.log("Vault created:", vaultAddr);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Vault Created ===");
        console.log("Update .env with:");
        console.log("VAULT_ADDRESS=", vaultAddr);
    }
}
