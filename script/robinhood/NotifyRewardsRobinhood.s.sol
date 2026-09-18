// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOwnStakingV2} from "../../src/interfaces/IOwnStakingV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title NotifyRewardsRobinhood — one-off reward funding (OwnStakingV2 SPY)
/// @notice From the OPERATOR key: notifies ~SPY_USD_BUDGET of R.SPY into the OwnStakingV2
///         stream, pulled from the treasury Safe within its live allowance. Amount is sized
///         from the live oracle mark and reverts if the mark is stale.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (holds OPERATOR).
///
/// Usage:
///   forge script script/robinhood/NotifyRewardsRobinhood.s.sol --rpc-url robinhood --broadcast
contract NotifyRewardsRobinhood is Script {
    bytes32 constant RSPY_TICKER = bytes32("R.SPY");

    // ── Live Robinhood Chain (4663) addresses — docs/contracts-robinhood.md ──
    address constant ORACLE = 0x72158ca9C5Dab08f3c470188a34c6e609fa6af9b;
    address constant RSPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant STAKING_V2 = 0xfD1CC0751D5d9C0D5f9eAd6b8525FdEe22423b76;
    address constant TREASURY_SAFE = 0x8f974d82EEaa9725ecC40600f12093B14080dA54;

    uint256 constant SPY_USD_BUDGET = 2_000e18;
    uint256 constant MAX_PRICE_AGE = 90 minutes;

    function run() external {
        (uint256 price, uint256 ts) = IOracleVerifier(ORACLE).getPrice(RSPY_TICKER);
        require(price != 0 && block.timestamp - ts <= MAX_PRICE_AGE, "stale R.SPY price");
        uint256 spyAmount = SPY_USD_BUDGET * 1e18 / price;

        require(
            IERC20(RSPY).allowance(TREASURY_SAFE, STAKING_V2) >= spyAmount,
            "treasury allowance too low"
        );
        require(
            IERC20(RSPY).balanceOf(TREASURY_SAFE) >= spyAmount,
            "treasury balance too low"
        );

        console.log("R.SPY mark (1e18 USD):", price);
        console.log("SPY notify amount    :", spyAmount);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
        IOwnStakingV2(STAKING_V2).notifyRewardAmount(spyAmount);
        vm.stopBroadcast();

        console.log("staking R.SPY balance:", IERC20(RSPY).balanceOf(STAKING_V2));
    }
}
