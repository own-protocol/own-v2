// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ChainlinkOracleVerifier} from "../../src/oracle/ChainlinkOracleVerifier.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";

/// @title DeployCoreRobinhood — ProtocolRegistry + ChainlinkOracleVerifier for the eUSD managers
/// @notice Deploys a registry owned by the governance Safe and a verifier resolving roles through
///         it. The deployer holds no role; the Safe wires everything afterwards: registry
///         `setOracle`, `setTreasury`, `grantRole(ADMIN/OPERATOR)`, then verifier `addSigner` and
///         `setChainlinkConfig` per ticker. The oracle signer must sign for the new verifier's
///         EIP-712 domain (verifyingContract = this verifier).
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, SAFE_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/DeployCoreRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployCoreRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    /// @dev Delay on handing PROTOCOL_ADMIN to a new address (same as the previous registry).
    uint48 constant ADMIN_TRANSFER_DELAY = 3 hours;

    function run() external returns (address registry, address verifier) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        address safe = vm.envAddress("SAFE_ROBINHOOD");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        registry = address(new ProtocolRegistry(safe, ADMIN_TRANSFER_DELAY));
        verifier = address(new ChainlinkOracleVerifier(registry));
        vm.stopBroadcast();

        console.log("ProtocolRegistry:       ", registry);
        console.log("ChainlinkOracleVerifier:", verifier);
    }
}
