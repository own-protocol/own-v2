// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../src/core/OracleVerifier.sol";
import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";

/// @title SetOracleConfigs — Set per-asset oracle config on the in-house OracleVerifier
/// @notice Without a config, updatePrice() reverts OracleConfigNotSet for an asset. Sets maxStaleness
///         + maxDeviation for every active asset (ETH collateral + 19 US stocks/ETFs). Owner-only.
///
/// Usage:
///   forge script script/SetOracleConfigs.s.sol --rpc-url base_sepolia --broadcast
contract SetOracleConfigs is Script {
    uint256 constant MAX_STALENESS = 3600; // 1 hour
    uint256 constant MAX_DEVIATION_BPS = 2000; // 20%

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY"));
        OracleVerifier oracle = OracleVerifier(registry.inhouseOracle());
        console.log("OracleVerifier:", address(oracle));

        bytes32[] memory assets = new bytes32[](20);
        assets[0] = bytes32("ETH");
        assets[1] = bytes32("AAPL");
        assets[2] = bytes32("NVDA");
        assets[3] = bytes32("AMZN");
        assets[4] = bytes32("MSFT");
        assets[5] = bytes32("META");
        assets[6] = bytes32("GOOG");
        assets[7] = bytes32("COIN");
        assets[8] = bytes32("MSTR");
        assets[9] = bytes32("AMD");
        assets[10] = bytes32("PLTR");
        assets[11] = bytes32("TSM");
        assets[12] = bytes32("NFLX");
        assets[13] = bytes32("HOOD");
        assets[14] = bytes32("WMT");
        assets[15] = bytes32("SPY");
        assets[16] = bytes32("QQQ");
        assets[17] = bytes32("TLT");
        assets[18] = bytes32("MAGS");
        assets[19] = bytes32("ITA");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        for (uint256 i = 0; i < assets.length; i++) {
            oracle.setAssetOracleConfig(assets[i], MAX_STALENESS, MAX_DEVIATION_BPS);
        }

        vm.stopBroadcast();

        console.log("Set oracle config for assets:", assets.length);
        console.log("maxStaleness (s):", MAX_STALENESS);
        console.log("maxDeviation (BPS):", MAX_DEVIATION_BPS);
    }
}
