// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnIncentives} from "../../src/core/OwnIncentives.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {StakedEUSD} from "../../src/tokens/StakedEUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployEusdStakingRobinhood — sEUSD staking vault + OWN incentives controller
/// @notice Deploys StakedEUSD (UUPS) and OwnIncentives, seeds permanently-locked dead shares, and
///         attaches the controller. Run after DeployEusdRobinhood.s.sol (pass its logged EUSD address as EUSD_ROBINHOOD).
///         Touches no existing contract beyond the two new registry slots and the controller wiring.
///
/// @dev Order matters: the vault is seeded (so totalSupply never returns to 0) and the controller
///      is attached BEFORE any emission is set. Emissions and reserve funding are deliberately left
///      to a later ADMIN/Safe action (setDistribution + fund), once an OWN budget is decided —
///      attach controller -> fund(reserve) -> setDistribution(rate, end). Decommission order is the
///      reverse: setDistribution(0, .) -> settle -> recoverReserve -> detach.
///
/// @dev Post-deploy checklist:
///        1. Verify sEusd.asset() == EUSD and sEusd.incentivesController() == the OwnIncentives.
///        2. Verify sEusd.totalSupply() > 0 (the dead-share seed landed).
///        3. Deposit a small amount of eUSD, warp, confirm the share price rises smoothly.
///        4. When ready: fund(OWN budget) then setDistribution(emissionPerSecond, end) via ADMIN.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (deployer holds ADMIN and PROTOCOL_ADMIN to wire + register),
///      PROTOCOL_REGISTRY_ROBINHOOD, EUSD_ROBINHOOD (the EUSD address logged by DeployEusdRobinhood),
///      OWN_TOKEN_ROBINHOOD (the OWN reward token),
///      SEED_EUSD_ROBINHOOD (eUSD the deployer already holds, deposited as locked dead shares).
///
/// Usage:
///   forge script script/robinhood/DeployEusdStakingRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployEusdStakingRobinhood is Script {
    /// @dev Registry slots for the two new module addresses (write-only; event-tracked for ops).
    bytes32 constant STAKED_EUSD_KEY = keccak256("STAKED_EUSD");
    bytes32 constant OWN_INCENTIVES_KEY = keccak256("OWN_INCENTIVES");

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN");

    /// @dev Linear vesting window per reward batch (sUSDe-style). Tunable later via setVestingPeriod;
    ///      keep the streaming cadence at or below this for continuous accrual.
    uint256 constant VESTING_PERIOD = 8 hours;

    /// @dev Seed shares are minted to a burn address so totalSupply can never return to 0 while a
    ///      reward batch is mid-vest.
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        address own = vm.envAddress("OWN_TOKEN_ROBINHOOD");
        uint256 seed = vm.envUint("SEED_EUSD_ROBINHOOD");
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        address eusd = vm.envAddress("EUSD_ROBINHOOD");
        require(eusd != address(0), "EUSD address unset (from DeployEusdRobinhood)");
        require(own != address(0), "OWN token unset");
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

        // 3. Controller — plain contract bound to this vault and the OWN token.
        OwnIncentives incentives = new OwnIncentives(address(registry), address(sEusd), own);

        // 4. Attach the controller (ADMIN only) before any emission is ever set.
        if (registry.hasRole(ADMIN_ROLE, deployer)) {
            sEusd.setIncentivesController(address(incentives));
            require(address(sEusd.incentivesController()) == address(incentives), "controller not attached");
        } else {
            console.log("ADMIN not held by deployer - attach via ADMIN:");
            console.log("  sEUSD.setIncentivesController(", address(incentives), ")");
        }

        // 5. Registry slots — only while the deployer still holds PROTOCOL_ADMIN; else via timelock.
        if (registry.hasRole(0x00, deployer)) {
            registry.setAddress(STAKED_EUSD_KEY, address(sEusd));
            registry.setAddress(OWN_INCENTIVES_KEY, address(incentives));
        } else {
            console.log("PROTOCOL_ADMIN not held by deployer - register via timelock:");
            console.logBytes32(STAKED_EUSD_KEY);
            console.logBytes32(OWN_INCENTIVES_KEY);
        }

        vm.stopBroadcast();

        require(sEusd.asset() == eusd, "asset mismatch");

        console.log("StakedEUSD:    ", address(sEusd));
        console.log("OwnIncentives: ", address(incentives));
        console.log("OWN token:     ", own);
        console.log("Seed (dead):   ", seed);
    }
}
