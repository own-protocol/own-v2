// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestRepayGoogMainnet — Partial repay of the GOOG borrow (VM key)
/// @notice Broadcast by the VM. Repays $5 of the $10 GOOG debt. repay() releases collateral pro-rata
///         (collateralReleased = eTokenCollateral * repayAmount / currentDebt), so a $5 repay on a $10
///         debt returns ~half the eGOOG collateral (~$10 worth at $340) to the VM. Position stays open
///         with ~$5 debt + ~$10 eGOOG collateral.
///
/// Env: VM_PRIVATE_KEY_MAINNET
///
/// Usage:
///   forge script script/mainnet/TestRepayGoogMainnet.s.sol --rpc-url base --broadcast
contract TestRepayGoogMainnet is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BORROW_MANAGER = 0xfc9BBa82bC0cc8E9B5A1847847A2F89D5458443f;
    address constant EGOOG = 0x46E9257BD72012F7814Ae67D95095342d5439C7A;

    bytes32 constant GOOG = bytes32("GOOG");
    uint256 constant REPAY_USDC = 5_000_000; // $5 (6 dec)

    function run() external {
        uint256 vmPk = vm.envUint("VM_PRIVATE_KEY_MAINNET");
        address vmAddr = vm.addr(vmPk);

        uint256 debtBefore = IBorrowManager(BORROW_MANAGER).debtOf(vmAddr, GOOG);

        vm.startBroadcast(vmPk);
        IERC20(USDC).approve(BORROW_MANAGER, REPAY_USDC);
        uint256 released = IBorrowManager(BORROW_MANAGER).repay(GOOG, REPAY_USDC);
        vm.stopBroadcast();

        console.log("Debt before (USDC 6dec):", debtBefore);
        console.log("Repaid (USDC 6dec):", REPAY_USDC);
        console.log("eGOOG collateral released (1e18):", released);
        console.log("Debt remaining (USDC 6dec):", IBorrowManager(BORROW_MANAGER).debtOf(vmAddr, GOOG));
        console.log("VM eGOOG balance now (1e18):", IERC20(EGOOG).balanceOf(vmAddr));
        console.log("VM USDC balance now (6dec):", IERC20(USDC).balanceOf(vmAddr));
    }
}
