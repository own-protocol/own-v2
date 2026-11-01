// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {StakingVault} from "../../src/staking/StakingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployStakingVaultRobinhood — one fixed-APR staking vault
/// @notice Deploys a StakingVault for one asset (eUSD → seUSD, $MONEY → sMONEY). The vault is
///         admin-gated through the ProtocolRegistry ADMIN role, so the deployer holds no powers.
///         Rewards start once the reserve is funded with {StakingVault.fund}.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, VAULT_ASSET, VAULT_NAME,
///      VAULT_SYMBOL, VAULT_APR_BPS (BPS), VAULT_CAP (asset units, 18 dec)
///
/// Usage:
///   forge script script/robinhood/DeployStakingVaultRobinhood.s.sol --rpc-url robinhood --broadcast
contract DeployStakingVaultRobinhood is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external returns (address vault) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");
        uint256 aprBps = vm.envUint("VAULT_APR_BPS");
        uint256 cap = vm.envUint("VAULT_CAP");
        // Typo guards: APR at most 50%, cap 18-dec between 1 and 1B tokens.
        require(aprBps <= 5000, "apr out of range");
        require(cap >= 1e18 && cap <= 1e27, "cap out of range");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        vault = address(
            new StakingVault(
                IERC20(vm.envAddress("VAULT_ASSET")),
                vm.envString("VAULT_NAME"),
                vm.envString("VAULT_SYMBOL"),
                vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"),
                aprBps,
                cap
            )
        );
        vm.stopBroadcast();
        console.log("StakingVault:", vault);
    }
}
