// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ILendingRouter} from "../../src/interfaces/ILendingRouter.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SeedDepositMainnet — Seed the aUSDC vault with the VM's USDC and refresh the collateral mark
/// @notice Broadcast by the VM (it holds the USDC). Approves the LendingRouter, deposits USDC (→ aUSDC →
///         vault shares to the VM), then pulls the vault's collateral mark (now non-zero). Test float.
///
/// Env: VM_PRIVATE_KEY_MAINNET
///
/// Usage:
///   forge script script/mainnet/SeedDepositMainnet.s.sol --rpc-url base --broadcast
contract SeedDepositMainnet is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant LENDING_ROUTER = 0x5744daea555ebbE2d8e093fF8b79eD7513bb20DF;
    address constant VAULT = 0xfF8d4d4D139716d32d3A3C0bD7a2cE55a916E91A;
    address constant VAULT_MANAGER = 0x4A3c284f3293250C84899A220Cf4Cb6dFCd317ba;

    uint256 constant AMOUNT = 100_000_000; // 100 USDC (6 decimals)

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_MAINNET");
        address vmAddr = vm.addr(vmPk);

        vm.startBroadcast(vmPk);

        IERC20(USDC).approve(LENDING_ROUTER, AMOUNT);
        uint256 shares = ILendingRouter(LENDING_ROUTER).deposit(USDC, IERC4626(VAULT), AMOUNT, vmAddr, 0);
        IVaultManager(VAULT_MANAGER).pullCollateralPrice(VAULT);

        vm.stopBroadcast();

        console.log("Depositor (VM):", vmAddr);
        console.log("Shares minted:", shares);
        console.log("Vault totalAssets (aUSDC, 6dec):", IERC4626(VAULT).totalAssets());
    }
}
