// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnVault} from "../src/core/OwnVault.sol";
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
        address vmAddress = vm.envAddress("VM_ADDRESS");
        address factoryAddr = vm.envAddress("VAULT_FACTORY");

        console.log("VM Address:", vmAddress);
        console.log("VaultFactory:", factoryAddr);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        VaultFactory factory = VaultFactory(factoryAddr);

        // Create WETH vault: 80% max utilization, 20% VM fee share
        address vaultAddr = factory.createVault(WETH, vmAddress, "Own ETH Vault", "oETH", 8000, 0);
        console.log("Vault created:", vaultAddr);

        OwnVault vault = OwnVault(vaultAddr);

        // Admin configuration
        vault.setGracePeriod(1 days);
        vault.setClaimThreshold(6 hours);
        vault.setCollateralOracleAsset(ETH);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Vault Created ===");
        console.log("Update .env with:");
        console.log("VAULT_ADDRESS=", vaultAddr);
        console.log("");
        console.log("Next: run ConfigureVault.s.sol with VM_PRIVATE_KEY");
    }
}
