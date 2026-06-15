// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../src/core/OracleVerifier.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";

/// @title UpdateSigners — Rotate the in-house oracle signer and register the market-maker quote signer
/// @notice Run by deployer (= admin / OracleVerifier owner). Resolves the OracleVerifier and
///         VaultManager from the ProtocolRegistry.
///
/// Usage:
///   forge script script/UpdateSigners.s.sol --rpc-url base_sepolia --broadcast
contract UpdateSigners is Script {
    // In-house oracle price-attestation signer rotation.
    address constant OLD_ORACLE_SIGNER = 0xbc686218d673AA5Db74243428d619dbbc7d1f9a4;
    address constant NEW_ORACLE_SIGNER = 0x6Ff4688f3de3354eed591B737bFf5DCdD9642A32;

    // Market-maker quote signer on the VaultManager. Signing + settlement funds are the same address.
    address constant MM_SIGNER = 0x7eAa2748CF934a310B86Ae16CF4cA604809527e2;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY"));
        OracleVerifier oracle = OracleVerifier(registry.inhouseOracle());
        VaultManager vaultManager = VaultManager(registry.vaultManager());

        console.log("OracleVerifier:", address(oracle));
        console.log("VaultManager:", address(vaultManager));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // 1. Rotate the in-house oracle signer: add the new one before removing the old one so the
        //    authorised set is never empty.
        oracle.addSigner(NEW_ORACLE_SIGNER);
        oracle.removeSigner(OLD_ORACLE_SIGNER);
        console.log("Oracle signer rotated to:", NEW_ORACLE_SIGNER);

        // 2. Register the market-maker quote signer with itself as the linked settlement address.
        vaultManager.registerSigner(MM_SIGNER, MM_SIGNER);
        console.log("MM quote signer registered:", MM_SIGNER);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Signers updated ===");
    }
}
