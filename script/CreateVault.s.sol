// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnVault} from "../src/core/OwnVault.sol";
import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../src/interfaces/IVaultManager.sol";

/// @title CreateVault — Deploy a WETH vault and register it with the VaultManager
/// @notice Run by deployer (= admin) after Deploy.s.sol. Vaults are deployed directly (no factory)
///         and registered on the VaultManager, which holds the vault allowlist + risk accounting.
///
/// Usage:
///   forge script script/CreateVault.s.sol --rpc-url base_sepolia --broadcast
contract CreateVault is Script {
    address constant WETH = 0xfbd78Da8aDbc322084eE7F80C10F914B92CEb6FE;
    bytes32 constant ETH = bytes32("ETH");

    function run() external {
        address managerAddress = vm.envAddress("VM_ADDRESS");
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");

        console.log("Manager Address:", managerAddress);
        console.log("ProtocolRegistry:", registryAddr);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // Deploy the vault directly. The collateral oracle ticker (ETH) is registered with the
        // VaultManager below; global utilisation, payment token, and claim threshold are central.
        OwnVault vault = new OwnVault(WETH, "Own ETH Vault", "oETH", registryAddr, managerAddress);
        console.log("Vault deployed:", address(vault));

        // Register with the VaultManager (admin-gated; adds it to the vault allowlist + risk pool).
        IVaultManager(IProtocolRegistry(registryAddr).vaultManager()).registerVault(address(vault), ETH);
        console.log("Vault registered with VaultManager");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Vault Created ===");
        console.log("Update .env with:");
        console.log("VAULT_ADDRESS=", address(vault));
    }
}
