// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";

/// @title SetOracleConfigsRobinhood — Set per-asset oracle config for the 7 launch tickers
/// @notice Without a config, updatePrice() reverts OracleConfigNotSet for an asset. Run by the admin
///         (deployer) once, BEFORE the price service starts pushing marks for the launch assets.
///         USDG (collateral) is configured by BootstrapUsdgPriceRobinhood.s.sol.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/SetOracleConfigsRobinhood.s.sol --rpc-url robinhood --broadcast
contract SetOracleConfigsRobinhood is Script {
    uint256 constant MAX_STALENESS = 3600; // 1 hour — matches VaultManager max mark age
    uint256 constant MAX_DEVIATION_BPS = 2000; // 20% max jump between consecutive pushes

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        OracleVerifier oracle = OracleVerifier(registry.inhouseOracle());

        bytes32[] memory assets = new bytes32[](7);
        assets[0] = bytes32("MU");
        assets[1] = bytes32("SPCX");
        assets[2] = bytes32("MSFT");
        assets[3] = bytes32("GOOGL");
        assets[4] = bytes32("TSLA");
        assets[5] = bytes32("SPY");
        assets[6] = bytes32("QQQ");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        for (uint256 i = 0; i < assets.length; i++) {
            oracle.setAssetOracleConfig(assets[i], MAX_STALENESS, MAX_DEVIATION_BPS);
        }

        vm.stopBroadcast();

        console.log("Oracle config set for launch assets:", assets.length);
        console.log("maxStaleness (s):", MAX_STALENESS);
        console.log("maxDeviation (BPS):", MAX_DEVIATION_BPS);
    }
}
