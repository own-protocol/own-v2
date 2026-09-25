// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {ITieredBoostCalculator} from "../../src/interfaces/ITieredBoostCalculator.sol";
import {OwnStakingV2} from "../../src/staking/OwnStakingV2.sol";
import {TieredBoostCalculator} from "../../src/staking/TieredBoostCalculator.sol";

/// @title DeployTieredBoostCalculatorRobinhood — size-tiered boost curve for OwnStakingV2
/// @notice Deploys the TieredBoostCalculator and swaps it into the live staking proxy directly when
///         the deployer holds ADMIN, otherwise prints the setBoostCalculator calldata for the
///         governance Safe. No staking upgrade: the calculator is a drop-in {IBoostCalculator}.
///
/// @dev Post-deploy checklist:
///        1. Execute the Safe call if printed; verify staking.boostCalculator() == the new calculator.
///        2. refreshBoost(all stakers) — every tier needs no more coverage than the 3:1 launch
///           line, so a refresh only ever raises or holds a snapshot.
///        3. Record the address in docs/contracts-robinhood.md; ship the app's tier-aware curve.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD.
///
/// Usage:
///   forge script script/robinhood/DeployTieredBoostCalculatorRobinhood.s.sol --rpc-url robinhood \
///     --broadcast --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployTieredBoostCalculatorRobinhood is Script {
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN");

    // ── Live Robinhood Chain (4663) addresses — docs/contracts-robinhood.md ──
    address constant PROTOCOL_REGISTRY = 0x93e08ca467046737F75AAD4C936356c196AaA36F;
    address constant STAKING_V2 = 0xfD1CC0751D5d9C0D5f9eAd6b8525FdEe22423b76;

    /// @dev Same 0.1x floor and 3.6x max as the launch line; only the full-boost coverage tiers.
    uint256 constant FLOOR_BPS = 1000;
    uint256 constant MAX_BOOST_BPS = 36_000;

    /// @dev Staked eUSD → $MONEY value needed for full boost: <$10k 3x, $10k 2x, $25k 1x,
    ///      $50k 0.2x, $100k+ 0.1x.
    function _tiers() private pure returns (ITieredBoostCalculator.Tier[] memory t) {
        t = new ITieredBoostCalculator.Tier[](5);
        t[0] = ITieredBoostCalculator.Tier({minEusd: 0, maxCoverageBps: 30_000});
        t[1] = ITieredBoostCalculator.Tier({minEusd: 10_000e18, maxCoverageBps: 20_000});
        t[2] = ITieredBoostCalculator.Tier({minEusd: 25_000e18, maxCoverageBps: 10_000});
        t[3] = ITieredBoostCalculator.Tier({minEusd: 50_000e18, maxCoverageBps: 2000});
        t[4] = ITieredBoostCalculator.Tier({minEusd: 100_000e18, maxCoverageBps: 1000});
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        address deployer = vm.addr(pk);
        OwnStakingV2 staking = OwnStakingV2(STAKING_V2);
        require(staking.maxBoostBps() >= MAX_BOOST_BPS, "staking clamps below calculator max");

        vm.startBroadcast(pk);
        TieredBoostCalculator calc = new TieredBoostCalculator(FLOOR_BPS, MAX_BOOST_BPS, _tiers());
        bool wired = IProtocolRegistry(PROTOCOL_REGISTRY).hasRole(ADMIN_ROLE, deployer);
        if (wired) staking.setBoostCalculator(address(calc));
        vm.stopBroadcast();

        require(calc.boostBps(0, 1e18) == FLOOR_BPS, "floor mismatch");
        require(calc.boostBps(10_000e18, 100_000e18) == MAX_BOOST_BPS, "top tier mismatch");

        if (wired) {
            require(address(staking.boostCalculator()) == address(calc), "calculator not wired");
        } else {
            console.log("=== Safe call required ===");
            console.log("target:", address(staking));
            console.log("  setBoostCalculator calldata:");
            console.logBytes(abi.encodeCall(OwnStakingV2.setBoostCalculator, (address(calc))));
        }

        console.log("TieredBoostCalculator:", address(calc));
    }
}
