// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnVault} from "../src/core/OwnVault.sol";

/// @title ConfigureVault — VM-specific vault setup
/// @notice Run by the vault manager after CreateVault.s.sol.
///         Sets payment token and enables assets for trading.
///
/// Usage:
///   forge script script/ConfigureVault.s.sol --rpc-url base_sepolia --broadcast
contract ConfigureVault is Script {
    bytes32 constant TSLA = bytes32("TSLA");
    bytes32 constant GOLD = bytes32("GOLD");

    function run() external {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address mockUSDC = vm.envAddress("MOCK_USDC");

        console.log("Vault:", vaultAddr);
        console.log("Payment Token (USDC):", mockUSDC);

        vm.startBroadcast(vm.envUint("VM_PRIVATE_KEY"));

        OwnVault vault = OwnVault(vaultAddr);

        // Set payment token (stablecoin for mint/redeem orders)
        vault.setPaymentToken(mockUSDC);
        console.log("Payment token set");

        // Enable assets for trading
        vault.enableAsset(TSLA);
        console.log("TSLA enabled");

        vault.enableAsset(GOLD);
        console.log("GOLD enabled");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Vault Configured ===");
        console.log("The vault is ready for trading on Base Sepolia.");
    }
}
