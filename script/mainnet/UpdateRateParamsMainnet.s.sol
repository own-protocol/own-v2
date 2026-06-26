// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";

/// @title UpdateRateParamsMainnet — Retune the live BorrowManager interest curve (admin, deployer key)
/// @notice Calls setRateParams on the bound BorrowManager. New curve: premium 3% at 0% util rising
///         linearly to 4% at 80% util (base 3% + slope1 1%); >80% penalty slope (slope2 72%) unchanged.
///
/// Env: DEPLOYER_PRIVATE_KEY_MAINNET
///
/// Usage:
///   forge script script/mainnet/UpdateRateParamsMainnet.s.sol --rpc-url base --broadcast
contract UpdateRateParamsMainnet is Script {
    address constant BORROW_MANAGER = 0xfc9BBa82bC0cc8E9B5A1847847A2F89D5458443f;

    function run() external {
        InterestRateModel.Params memory p =
            InterestRateModel.Params({basePremiumBps: 300, optimalUtilBps: 8000, slope1Bps: 100, slope2Bps: 7200});

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET"));
        IBorrowManager(BORROW_MANAGER).setRateParams(p);
        vm.stopBroadcast();

        (uint64 base, uint64 opt, uint64 s1, uint64 s2) = IBorrowManager(BORROW_MANAGER).rateParams();
        console.log("Updated rate params (bps): base, optimal, slope1, slope2");
        console.log(base, opt);
        console.log(s1, s2);
    }
}
