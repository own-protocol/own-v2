// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";

/// @title SetOracleConfigsMainnet — Set per-asset oracle config for the 6 launch tickers
/// @notice Without a config, updatePrice() reverts OracleConfigNotSet for an asset. Run by the admin
///         (deployer) once, BEFORE the price service starts pushing marks for the launch assets.
///         USDC (collateral) is already configured by BootstrapUsdcPriceMainnet.s.sol.
///
/// Env: DEPLOYER_PRIVATE_KEY_MAINNET
///
/// Usage:
///   forge script script/mainnet/SetOracleConfigsMainnet.s.sol --rpc-url base --broadcast
contract SetOracleConfigsMainnet is Script {
    address constant INHOUSE_ORACLE = 0xc82f5835Fe132D34A7491961e2875941CF37aE03;

    uint256 constant MAX_STALENESS = 3600; // 1 hour — matches VaultManager max mark age
    uint256 constant MAX_DEVIATION_BPS = 2000; // 20% max jump between consecutive pushes

    function run() external {
        OracleVerifier oracle = OracleVerifier(INHOUSE_ORACLE);

        bytes32[] memory assets = new bytes32[](6);
        assets[0] = bytes32("MU");
        assets[1] = bytes32("SPCX");
        assets[2] = bytes32("MSFT");
        assets[3] = bytes32("GOOG");
        assets[4] = bytes32("TSLA");
        assets[5] = bytes32("SPY");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET"));

        for (uint256 i = 0; i < assets.length; i++) {
            oracle.setAssetOracleConfig(assets[i], MAX_STALENESS, MAX_DEVIATION_BPS);
        }

        vm.stopBroadcast();

        console.log("Oracle config set for launch assets:", assets.length);
        console.log("maxStaleness (s):", MAX_STALENESS);
        console.log("maxDeviation (BPS):", MAX_DEVIATION_BPS);
    }
}
