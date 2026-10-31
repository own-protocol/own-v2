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
///      VAULT_SYMBOL, VAULT_APR_BPS (e.g. 1600), VAULT_CAP (asset units, 18 dec)
///
/// Usage:
///   forge script script/robinhood/DeployStakingVaultRobinhood.s.sol --rpc-url robinhood --broadcast
contract DeployStakingVaultRobinhood is Script {
    function run() external returns (address vault) {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        vault = address(
            new StakingVault(
                IERC20(vm.envAddress("VAULT_ASSET")),
                vm.envString("VAULT_NAME"),
                vm.envString("VAULT_SYMBOL"),
                vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"),
                vm.envUint("VAULT_APR_BPS"),
                vm.envUint("VAULT_CAP")
            )
        );
        vm.stopBroadcast();
        console.log("StakingVault:", vault);
    }
}
