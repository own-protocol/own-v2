// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ILendingRouter} from "../../src/interfaces/ILendingRouter.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SeedDepositRobinhood — Seed the oUSDG vault with the VM's USDG and refresh the collateral mark
/// @notice Broadcast by the VM (it holds the USDG). Approves the LendingRouter, deposits USDG
///         (→ oUSDG → vault shares to the VM), then pulls the vault's collateral mark (now
///         non-zero). Test float. NOTE: with the VaultYieldManager installed as vault.manager, the
///         VM drives deposit acceptance through the shell's acceptDeposit passthrough.
///
/// Env: VM_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, LENDING_ROUTER_ROBINHOOD,
///      VAULT_ADDRESS_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/SeedDepositRobinhood.s.sol --rpc-url robinhood --broadcast
contract SeedDepositRobinhood is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 constant AMOUNT = 100_000_000; // 100 USDG (6 decimals)

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_ROBINHOOD");
        address vmAddr = vm.addr(vmPk);

        address router = vm.envAddress("LENDING_ROUTER_ROBINHOOD");
        address vault = vm.envAddress("VAULT_ADDRESS_ROBINHOOD");
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));

        vm.startBroadcast(vmPk);

        IERC20(USDG).approve(router, AMOUNT);
        uint256 shares = ILendingRouter(router).deposit(USDG, IERC4626(vault), AMOUNT, vmAddr, 0);
        IVaultManager(registry.vaultManager()).pullCollateralPrice(vault);

        vm.stopBroadcast();

        console.log("Depositor (VM):", vmAddr);
        console.log("Shares minted:", shares);
        console.log("Vault totalAssets (oUSDG, 6dec):", IERC4626(vault).totalAssets());
    }
}
