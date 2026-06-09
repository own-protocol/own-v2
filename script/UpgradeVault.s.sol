// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ProtocolRegistry} from "../src/core/ProtocolRegistry.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

/// @title UpgradeVault — Deploy new VaultFactory, then propose registry update
/// @notice Run in two phases:
///   Phase 1: Deploy factory + propose timelock (this script)
///   Phase 2: After timelock delay, run ExecuteTimelockVaultFactory (executes the timelock,
///            then creates + configures the vault through the now-active factory)
///
/// @dev Vault creation is deferred to phase 2 because the factory must be the registry's active
///      VAULT_FACTORY before `createVault` can register the vault with the VaultManager
///      (the manager's onlyFactory guard reads `registry.vaultFactory()`).
///
/// Usage:
///   forge script script/UpgradeVault.s.sol --rpc-url base_sepolia --broadcast --verify
contract UpgradeVault is Script {
    function run() external {
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");

        console.log("ProtocolRegistry:", registryAddr);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        ProtocolRegistry registry = ProtocolRegistry(registryAddr);

        // ── 1. Deploy new VaultFactory ──
        VaultFactory newFactory = new VaultFactory(deployer, registryAddr);
        console.log("New VaultFactory:", address(newFactory));

        // ── 2. Propose factory update in ProtocolRegistry (subject to timelock) ──
        registry.proposeAddress(registry.VAULT_FACTORY(), address(newFactory));
        console.log("Proposed VAULT_FACTORY update (timelock started)");

        vm.stopBroadcast();

        uint256 delay = registry.timelockDelay();
        console.log("");
        console.log("=== Phase 1 Complete ===");
        console.log("New VaultFactory:", address(newFactory));
        console.log("");
        console.log("Timelock delay:", delay, "seconds");
        console.log("After the delay, run:");
        console.log(
            "  forge script script/UpgradeVault.s.sol:ExecuteTimelockVaultFactory --rpc-url base_sepolia --broadcast"
        );
    }
}

/// @title ExecuteTimelockVaultFactory — Execute the pending VAULT_FACTORY timelock, then create the vault
/// @notice Run after the timelock delay has elapsed from UpgradeVault.
///
/// Usage:
///   forge script script/UpgradeVault.s.sol:ExecuteTimelockVaultFactory --rpc-url base_sepolia --broadcast
contract ExecuteTimelockVaultFactory is Script {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    bytes32 constant ETH = bytes32("ETH");

    function run() external {
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");
        address vmAddress = vm.envAddress("VM_ADDRESS");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        ProtocolRegistry registry = ProtocolRegistry(registryAddr);
        registry.executeTimelock(registry.VAULT_FACTORY());
        console.log("VAULT_FACTORY timelock executed");

        // The new factory is now active, so createVault can register with the VaultManager.
        VaultFactory factory = VaultFactory(registry.vaultFactory());
        address vaultAddr = factory.createVault(WETH, vmAddress, "Own ETH Vault", "oETH", ETH);
        console.log("New Vault:", vaultAddr);

        vm.stopBroadcast();

        console.log("New factory:", registry.vaultFactory());
        console.log("Run ConfigureVault.s.sol with VAULT_ADDRESS=", vaultAddr);
    }
}
