// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnVault} from "../src/core/OwnVault.sol";
import {ProtocolRegistry} from "../src/core/ProtocolRegistry.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

/// @title UpgradeVault — Deploy new VaultFactory + vault, then propose registry update
/// @notice Run in two phases:
///   Phase 1: Deploy factory + vault + propose timelock (this script)
///   Phase 2: After timelock delay, run ExecuteTimelockVaultFactory.s.sol
///
/// Usage:
///   forge script script/UpgradeVault.s.sol --rpc-url base_sepolia --broadcast --verify
contract UpgradeVault is Script {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    bytes32 constant ETH = bytes32("ETH");

    function run() external {
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");
        address vmAddress = vm.envAddress("VM_ADDRESS");

        console.log("ProtocolRegistry:", registryAddr);
        console.log("VM Address:", vmAddress);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        ProtocolRegistry registry = ProtocolRegistry(registryAddr);

        // ── 1. Deploy new VaultFactory ──
        VaultFactory newFactory = new VaultFactory(deployer, registryAddr);
        console.log("New VaultFactory:", address(newFactory));

        // ── 2. Create vault ──
        address vaultAddr = newFactory.createVault(WETH, vmAddress, "Own ETH Vault", "oETH", 8000, 0);
        console.log("New Vault:", vaultAddr);

        // ── 3. Configure admin parameters ──
        OwnVault vault = OwnVault(vaultAddr);
        vault.setGracePeriod(1 days);
        vault.setClaimThreshold(6 hours);
        vault.setCollateralOracleAsset(ETH);

        // ── 4. Propose factory update in ProtocolRegistry (subject to timelock) ──
        registry.proposeAddress(registry.VAULT_FACTORY(), address(newFactory));
        console.log("Proposed VAULT_FACTORY update (timelock started)");

        vm.stopBroadcast();

        uint256 delay = registry.timelockDelay();
        console.log("");
        console.log("=== Phase 1 Complete ===");
        console.log("New VaultFactory:", address(newFactory));
        console.log("New Vault:", vaultAddr);
        console.log("");
        console.log("Timelock delay:", delay, "seconds");
        console.log("After the delay, run:");
        console.log("  forge script script/ExecuteTimelockVaultFactory.s.sol --rpc-url base_sepolia --broadcast");
        console.log("");
        console.log("Then run ConfigureVault.s.sol with the new VAULT_ADDRESS");
    }
}

/// @title ExecuteTimelockVaultFactory — Execute the pending VAULT_FACTORY timelock
/// @notice Run after the timelock delay has elapsed from UpgradeVault.
///
/// Usage:
///   forge script script/UpgradeVault.s.sol:ExecuteTimelockVaultFactory --rpc-url base_sepolia --broadcast
contract ExecuteTimelockVaultFactory is Script {
    function run() external {
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        ProtocolRegistry registry = ProtocolRegistry(registryAddr);
        registry.executeTimelock(registry.VAULT_FACTORY());

        vm.stopBroadcast();

        console.log("VAULT_FACTORY timelock executed");
        console.log("New factory:", registry.vaultFactory());
    }
}
