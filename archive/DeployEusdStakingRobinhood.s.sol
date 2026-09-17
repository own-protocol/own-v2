// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";
import {StakedEUSD} from "./StakedEUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployEusdStakingRobinhood — sEUSD staking vault
/// @notice Deploys StakedEUSD (UUPS) controller-less and seeds permanently-locked dead shares.
///         Run after DeployEusdRobinhood.s.sol (pass its logged EUSD address as EUSD_ROBINHOOD).
///         Touches no existing contract beyond the new registry slot.
///         Calls needing roles the deployer lacks are printed as a Safe batch instead.
///
/// @dev Post-deploy checklist:
///        1. Verify sEusd.asset() == EUSD.
///        2. Verify sEusd.totalSupply() > 0 (the dead-share seed landed).
///        3. Deposit a small amount of eUSD, transferInRewards, confirm the share price vests up.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD,
///      PROTOCOL_REGISTRY_ROBINHOOD, EUSD_ROBINHOOD (the EUSD address logged by DeployEusdRobinhood),
///      SEED_EUSD_ROBINHOOD (eUSD the deployer already holds, deposited as locked dead shares).
///
/// Usage:
///   forge script script/robinhood/DeployEusdStakingRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployEusdStakingRobinhood is Script {
    /// @dev Registry slot for the new module address (write-only; event-tracked for ops).
    bytes32 constant STAKED_EUSD_KEY = keccak256("STAKED_EUSD");

    /// @dev Linear vesting window per reward batch (sUSDe-style). Tunable later via setVestingPeriod;
    ///      keep the streaming cadence at or below this for continuous accrual.
    uint256 constant VESTING_PERIOD = 8 hours;

    /// @dev Seed shares are minted to a burn address so totalSupply can never return to 0 while a
    ///      reward batch is mid-vest.
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        uint256 seed = vm.envUint("SEED_EUSD_ROBINHOOD");
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        address eusd = vm.envAddress("EUSD_ROBINHOOD");
        require(eusd != address(0), "EUSD address unset (from DeployEusdRobinhood)");
        require(seed > 0, "seed amount is zero");
        require(IERC20(eusd).balanceOf(deployer) >= seed, "deployer lacks seed eUSD");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // 1. Vault — UUPS implementation (eUSD is an implementation immutable) behind a proxy,
        //    initialized atomically in the proxy constructor.
        StakedEUSD sEusdImpl = new StakedEUSD(eusd);
        StakedEUSD sEusd = StakedEUSD(
            address(
                new ERC1967Proxy(
                    address(sEusdImpl), abi.encodeCall(StakedEUSD.initialize, (address(registry), VESTING_PERIOD))
                )
            )
        );

        // 2. Seed permanently-locked dead shares before anyone else can enter.
        IERC20(eusd).approve(address(sEusd), seed);
        sEusd.deposit(seed, DEAD);
        require(sEusd.totalSupply() > 0, "seed failed");

        // 3. Registry slot — direct if the deployer holds PROTOCOL_ADMIN, otherwise via the Safe.
        bool needsSafeRegistry;
        if (registry.hasRole(0x00, deployer)) {
            registry.setAddress(STAKED_EUSD_KEY, address(sEusd));
        } else {
            needsSafeRegistry = true;
        }

        vm.stopBroadcast();

        require(sEusd.asset() == eusd, "asset mismatch");

        if (needsSafeRegistry) {
            console.log("=== Safe batch required ===");
            console.log("target:", address(registry));
            console.log("  setAddress(STAKED_EUSD, vault) calldata:");
            console.logBytes(abi.encodeCall(IProtocolRegistry.setAddress, (STAKED_EUSD_KEY, address(sEusd))));
        }

        console.log("StakedEUSD:    ", address(sEusd));
        console.log("Seed (dead):   ", seed);
    }
}
