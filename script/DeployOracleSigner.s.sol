// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../src/core/OracleVerifier.sol";
import {ProtocolRegistry} from "../src/core/ProtocolRegistry.sol";

/// @title DeployOracleSigner — Deploy in-house OracleVerifier, register in ProtocolRegistry, add signer
/// @notice Deploys the OracleVerifier contract, registers it as INHOUSE_ORACLE in the existing
///         ProtocolRegistry, and adds a trusted signer address.
///
/// Inhouse oracle offchain service uses https://twelvedata.com/ & https://eodhd.com/ as data sources.
///
/// Usage:
///   forge script script/DeployOracleSigner.s.sol --rpc-url base_sepolia --broadcast --verify
contract DeployOracleSigner is Script {
    address constant SIGNER = 0xbc686218d673AA5Db74243428d619dbbc7d1f9a4;

    function run() external {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");

        console.log("Deployer:", deployer);
        console.log("ProtocolRegistry:", registryAddr);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // 1. Deploy OracleVerifier
        OracleVerifier oracleVerifier = new OracleVerifier(deployer);
        console.log("OracleVerifier:", address(oracleVerifier));

        // 2. Add signer
        oracleVerifier.addSigner(SIGNER);
        console.log("Signer added:", SIGNER);

        // 3. Register in ProtocolRegistry as INHOUSE_ORACLE
        ProtocolRegistry registry = ProtocolRegistry(registryAddr);
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracleVerifier));
        console.log("Registered as INHOUSE_ORACLE in ProtocolRegistry");

        vm.stopBroadcast();

        console.log("");
        console.log("=== OracleVerifier Deployment Complete ===");
        console.log("INHOUSE_ORACLE=", address(oracleVerifier));
    }
}
