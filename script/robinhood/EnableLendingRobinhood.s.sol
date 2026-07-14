// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {OwnLendingPool} from "../../src/core/OwnLendingPool.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {VaultYieldManager} from "../../src/periphery/VaultYieldManager.sol";

/// @title EnableLendingRobinhood — BorrowManager + VaultYieldManager for the oUSDG vault
/// @notice Deploys the vault's one-and-only BorrowManager (1:1, permanent), binds it via
///         setBorrowManager, grants pool credit delegation, and enables the vault's oUSDG as pool
///         collateral (a compatibility no-op on OwnLendingPool — no first-deposit precondition,
///         unlike Aave on Base). Then deploys the VaultYieldManager (automated LP yield: treasury
///         cut → registry.treasury(), remainder 1:1 pool.supply → shareYield), installs it as the
///         vault's manager, and allowlists it as a pool supplier. Run by the deployer (= ADMIN)
///         after DeployRobinhood.s.sol.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD, VAULT_ADDRESS_ROBINHOOD,
///      LENDING_POOL_ROBINHOOD, VM_ADDRESS_ROBINHOOD (yield-shell manager = the operating VM)
///
/// Usage:
///   forge script script/robinhood/EnableLendingRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract EnableLendingRobinhood is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev Target loan-to-value the manager runs the vault's pool position at (70%). Must be < BPS
    ///      and <= the pool's ltvBps (85%).
    uint256 constant TARGET_LTV_BPS = 7000;

    /// @dev Treasury share of VM lending revenue distributed by the yield shell (10%).
    uint256 constant TREASURY_CUT_BPS = 1000;

    function run() external {
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD");
        address payable vaultAddr = payable(vm.envAddress("VAULT_ADDRESS_ROBINHOOD"));
        OwnLendingPool pool = OwnLendingPool(vm.envAddress("LENDING_POOL_ROBINHOOD"));
        address vmOperator = vm.envAddress("VM_ADDRESS_ROBINHOOD");
        address debtToken = pool.variableDebtToken();

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // Interest-rate curve premium: base 6%, optimal util 80%, slope1 2% (→8% at 80%), slope2 72%.
        // The pool's borrow rate is 0 by design, so this curve IS the full lending rate.
        BorrowManager borrowManager = new BorrowManager(
            vaultAddr,
            USDG,
            debtToken,
            address(pool),
            registryAddr,
            TARGET_LTV_BPS,
            InterestRateModel.Params({basePremiumBps: 600, optimalUtilBps: 8000, slope1Bps: 200, slope2Bps: 7200})
        );
        console.log("BorrowManager:", address(borrowManager));

        OwnVault vault = OwnVault(vaultAddr);
        // 1:1 permanent bind (one-shot — no rotation).
        vault.setBorrowManager(address(borrowManager));
        // Delegate USDG borrowing power to the manager (collateral cannot be moved by this).
        vault.grantCreditDelegation(debtToken);
        // Compatibility wiring parity with Base; OwnLendingPool always counts collateral.
        vault.enableAaveCollateral(address(pool), USDG);

        // Yield shell: revenue lands here (it becomes vault.manager), distribute() is permissionless.
        VaultYieldManager yieldManager =
            new VaultYieldManager(registryAddr, vaultAddr, address(pool), vmOperator, TREASURY_CUT_BPS);
        vault.setManager(address(yieldManager));
        pool.setSupplierAllowed(address(yieldManager), true);
        console.log("VaultYieldManager:", address(yieldManager));

        vm.stopBroadcast();

        console.log("=== Lending + Yield Automation Enabled ===");
        console.log("Vault:", vaultAddr);
        console.log("BorrowManager bound + credit delegated + collateral wiring set.");
        console.log("VaultYieldManager installed as vault.manager; VM drives the deposit queue through it.");
    }
}
