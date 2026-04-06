// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../src/core/AssetRegistry.sol";
import {AssetConfig} from "../src/interfaces/types/Types.sol";

/// @title UpdateOracleType — Switch TSLA and GOLD to in-house oracle
/// @notice Calls AssetRegistry.updateAssetConfig() to set oracleType=1 (in-house)
///         for TSLA and GOLD, preserving their existing volatility levels.
///
/// Usage:
///   forge script script/UpdateOracleType.s.sol --rpc-url base_sepolia --broadcast
contract UpdateOracleType is Script {
    bytes32 constant TSLA = bytes32("TSLA");
    bytes32 constant GOLD = bytes32("GOLD");

    function run() external {
        address assetRegistryAddr = vm.envAddress("ASSET_REGISTRY");

        console.log("AssetRegistry:", assetRegistryAddr);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        AssetRegistry assetRegistry = AssetRegistry(assetRegistryAddr);

        // TSLA: volatilityLevel=2, oracleType=1 (in-house)
        assetRegistry.updateAssetConfig(
            TSLA,
            AssetConfig({
                activeToken: address(0),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 1
            })
        );
        console.log("TSLA oracleType updated to 1 (in-house)");

        // GOLD: volatilityLevel=1, oracleType=1 (in-house)
        assetRegistry.updateAssetConfig(
            GOLD,
            AssetConfig({
                activeToken: address(0),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 1,
                oracleType: 1
            })
        );
        console.log("GOLD oracleType updated to 1 (in-house)");

        vm.stopBroadcast();
    }
}
