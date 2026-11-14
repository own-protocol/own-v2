// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {PegArbitrage} from "../../misc/PegArbitrage.sol";
import {EUSDPsm} from "../../src/eusd/EUSDPsm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployEusdPsmRobinhood — eUSD PSM and its keeper arbitrage helper
/// @notice Deploys the EUSDPsm implementation and its UUPS proxy, and a PegArbitrage bound to it.
///         Both are gated through the ProtocolRegistry (ADMIN, OPERATOR), so the deployer holds no
///         powers. Nothing mints until the governance Safe grants the proxy eUSD's MINTER_ROLE and
///         lists assets with {EUSDPsm.addAsset}; that is a separate Safe batch.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, EUSD_ROBINHOOD,
///      FABLES_POOL_MANAGER_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/DeployEusdPsmRobinhood.s.sol --rpc-url robinhood --broadcast
contract DeployEusdPsmRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external returns (address psm, address arbitrage) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        address registry = vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD");
        address eusd = vm.envAddress("EUSD_ROBINHOOD");
        address poolManager = vm.envAddress("FABLES_POOL_MANAGER_ROBINHOOD");
        require(registry.code.length > 0 && eusd.code.length > 0 && poolManager.code.length > 0, "not a contract");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        EUSDPsm impl = new EUSDPsm();
        psm = address(new ERC1967Proxy(address(impl), abi.encodeCall(EUSDPsm.initialize, (registry, eusd))));
        arbitrage = address(new PegArbitrage(registry, poolManager, psm));
        vm.stopBroadcast();

        require(EUSDPsm(psm).eusd() == eusd && address(EUSDPsm(psm).registry()) == registry, "bad init");
        console.log("EUSDPsm implementation:", address(impl));
        console.log("EUSDPsm proxy:", psm);
        console.log("PegArbitrage:", arbitrage);
    }
}
