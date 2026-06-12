// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../src/interfaces/IVaultManager.sol";

/// @title ConfigureVault — Global protocol order-settlement config
/// @notice Run by the admin after deployment. Sets the single global payment token on the
///         VaultManager. Payment token, signers, pause/halt, and the claim threshold are all
///         global now — there is no per-vault order config.
///
/// Usage:
///   forge script script/ConfigureVault.s.sol --rpc-url base_sepolia --broadcast
contract ConfigureVault is Script {
    function run() external {
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");
        address mockUSDC = vm.envAddress("MOCK_USDC");

        console.log("ProtocolRegistry:", registryAddr);
        console.log("Payment Token (USDC):", mockUSDC);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        IVaultManager vaultManager = IVaultManager(IProtocolRegistry(registryAddr).vaultManager());
        vaultManager.setPaymentToken(mockUSDC);
        console.log("Global payment token set");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Protocol Configured ===");
    }
}
