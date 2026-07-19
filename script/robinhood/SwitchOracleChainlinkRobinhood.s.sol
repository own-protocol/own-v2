// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {ChainlinkOracleVerifier} from "../../src/core/ChainlinkOracleVerifier.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";

/// @title SwitchOracleChainlinkRobinhood — Cut all assets over to the Chainlink oracle
/// @notice Step 2 of the oracle migration. Replaces the in-house OracleVerifier with the deployed
///         ChainlinkOracleVerifier in the registry's INHOUSE_ORACLE slot. Every ticker already
///         resolves through that slot (oracleType 1), so the single setAddress switches all 15
///         atomically — no per-asset changes. Rollback is equally atomic: setAddress back to the
///         old verifier (address logged below; it keeps its state).
///
///         Preflight (fails before broadcasting anything): every ticker must be registered in the
///         AssetRegistry on oracleType 1, configured on the new verifier, and currently serving a
///         price from it.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, CHAINLINK_ORACLE_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/SwitchOracleChainlinkRobinhood.s.sol --rpc-url robinhood --broadcast
contract SwitchOracleChainlinkRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    function _tickers() internal pure returns (bytes32[] memory t) {
        t = new bytes32[](15);
        t[0] = bytes32("MU");
        t[1] = bytes32("SPCX");
        t[2] = bytes32("MSFT");
        t[3] = bytes32("GOOGL");
        t[4] = bytes32("TSLA");
        t[5] = bytes32("SPY");
        t[6] = bytes32("QQQ");
        t[7] = bytes32("R.MU");
        t[8] = bytes32("R.SPCX");
        t[9] = bytes32("R.MSFT");
        t[10] = bytes32("R.GOOGL");
        t[11] = bytes32("R.TSLA");
        t[12] = bytes32("R.SPY");
        t[13] = bytes32("R.QQQ");
        t[14] = bytes32("USDG");
    }

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        ProtocolRegistry registry = ProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        AssetRegistry assetRegistry = AssetRegistry(registry.assetRegistry());
        ChainlinkOracleVerifier verifier = ChainlinkOracleVerifier(vm.envAddress("CHAINLINK_ORACLE_ROBINHOOD"));
        bytes32[] memory tickers = _tickers();

        address oldOracle = registry.inhouseOracle();
        require(oldOracle != address(verifier), "already switched");

        // ── Preflight: fail fast, before any state change ──
        require(address(verifier.registry()) == address(registry), "verifier registry mismatch");
        for (uint256 i = 0; i < tickers.length; i++) {
            string memory name = string(abi.encodePacked(tickers[i]));
            AssetConfig memory cfg = assetRegistry.getAssetConfig(tickers[i]);
            require(cfg.activeToken != address(0), string.concat("not registered: ", name));
            require(cfg.oracleType == 1, string.concat("not routed via INHOUSE_ORACLE: ", name));
            require(
                verifier.getChainlinkConfig(tickers[i]).aggregator != address(0),
                string.concat("verifier config missing: ", name)
            );
            // The new oracle must be serving a live price before we route consumers to it.
            (uint256 price,) = verifier.getPrice(tickers[i]);
            require(price > 0, string.concat("no price on new oracle: ", name));
            console.log(name, "preflight OK, price:", price);
        }

        // ── Cutover: one atomic slot swap for all 15 tickers ──
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        registry.setAddress(registry.INHOUSE_ORACLE(), address(verifier));
        vm.stopBroadcast();

        console.log("");
        console.log("INHOUSE_ORACLE slot ->", address(verifier));
        console.log("Old OracleVerifier (rollback target):", oldOracle);
        console.log("Rollback: registry.setAddress(INHOUSE_ORACLE, oldOracle)");
    }
}
