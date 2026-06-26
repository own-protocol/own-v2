// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";

/// @title EnableLendingMainnet — Deploy + wire the BorrowManager for the aUSDC vault (Base mainnet)
/// @notice Deploys the vault's one-and-only BorrowManager (1:1, permanent), binds it via
///         setBorrowManager, grants Aave credit delegation, and enables the vault's aUSDC as Aave
///         collateral. Run by the deployer (= ADMIN) AFTER the vault has received its first aUSDC
///         deposit — enableAaveCollateral reads the vault's Aave reserve and the position must exist.
///
/// Env: DEPLOYER_PRIVATE_KEY, PROTOCOL_REGISTRY, VAULT_ADDRESS
///
/// Usage:
///   forge script script/mainnet/EnableLendingMainnet.s.sol --rpc-url base --broadcast --verify
contract EnableLendingMainnet is Script {
    // Base mainnet (verified on-chain via Aave Pool.getReserveData(USDC)).
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDC_VARIABLE_DEBT = 0x59dca05b6c26dbd64b5381374aAaC5CD05644C28;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    /// @dev Target loan-to-value the manager runs the vault's Aave position at (35%). Must be < BPS.
    uint256 constant TARGET_LTV_BPS = 3500;

    // Base mainnet deploy (see docs/contracts-mainnet.md).
    address constant PROTOCOL_REGISTRY = 0xAb3C9c1A5cf70fA63AF59644Dd45F82392206C04;
    address constant VAULT_ADDRESS = 0xfF8d4d4D139716d32d3A3C0bD7a2cE55a916E91A;

    function run() external {
        address registryAddr = PROTOCOL_REGISTRY;
        address payable vaultAddr = payable(VAULT_ADDRESS);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET"));

        // Interest-rate curve premium: base 4%, optimal util 80%, slope1 4%, slope2 72%.
        BorrowManager borrowManager = new BorrowManager(
            vaultAddr,
            USDC,
            USDC_VARIABLE_DEBT,
            AAVE_V3_POOL,
            registryAddr,
            TARGET_LTV_BPS,
            InterestRateModel.Params({basePremiumBps: 400, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7200})
        );
        console.log("BorrowManager:", address(borrowManager));

        OwnVault vault = OwnVault(vaultAddr);
        // 1:1 permanent bind (one-shot — no rotation).
        vault.setBorrowManager(address(borrowManager));
        // Delegate USDC borrowing power to the manager (collateral cannot be moved by this).
        vault.grantCreditDelegation(USDC_VARIABLE_DEBT);
        // Enable the vault's aUSDC as Aave collateral (required — aToken transfers don't auto-enable).
        // Reverts unless the vault already holds aUSDC, hence: run after the first deposit.
        vault.enableAaveCollateral(AAVE_V3_POOL, USDC);

        vm.stopBroadcast();

        console.log("=== Lending Enabled ===");
        console.log("Vault:", vaultAddr);
        console.log("BorrowManager bound + credit delegated + aUSDC collateral enabled.");
    }
}
