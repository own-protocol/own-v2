// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {OwnIncentives} from "../../src/core/OwnIncentives.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {StakedEUSD} from "../../src/tokens/StakedEUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployEusdStakingRobinhood — sEUSD staking vault (+ optional OWN incentives controller)
/// @notice Deploys StakedEUSD (UUPS) and seeds permanently-locked dead shares. If
///         OWN_TOKEN_ROBINHOOD is set, also deploys OwnIncentives and attaches it; if unset, the
///         vault launches controller-less (address(0) hook — fully functional, no OWN emissions)
///         and incentives wire in later via setIncentivesController once OWN exists. Run after
///         DeployEusdRobinhood.s.sol (pass its logged EUSD address as EUSD_ROBINHOOD).
///         Touches no existing contract beyond the new registry slots and the controller wiring.
///         Calls needing roles the deployer lacks are printed as a Safe batch instead.
///
/// @dev Order matters: the vault is seeded (so totalSupply never returns to 0) and the controller
///      is attached BEFORE any emission is set. Emissions and reserve funding are deliberately left
///      to a later ADMIN/Safe action (setDistribution + fund), once an OWN budget is decided —
///      attach controller -> fund(reserve) -> setDistribution(rate, end). Decommission order is the
///      reverse: setDistribution(0, .) -> settle -> recoverReserve -> detach.
///
/// @dev Post-deploy checklist:
///        1. Verify sEusd.asset() == EUSD; if OwnIncentives was deployed, verify
///           sEusd.incentivesController() == the OwnIncentives (or execute the printed Safe call).
///        2. Verify sEusd.totalSupply() > 0 (the dead-share seed landed).
///        3. Deposit a small amount of eUSD, transferInRewards, confirm the share price vests up.
///        4. When OWN exists (if skipped here): deploy OwnIncentives, attach, register, then
///           fund(OWN budget) and setDistribution(emissionPerSecond, end) via ADMIN.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD,
///      PROTOCOL_REGISTRY_ROBINHOOD, EUSD_ROBINHOOD (the EUSD address logged by DeployEusdRobinhood),
///      OWN_TOKEN_ROBINHOOD (the OWN reward token; unset/zero = skip incentives),
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
        address own = vm.envOr("OWN_TOKEN_ROBINHOOD", address(0));
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

        // 3. Controller (only if OWN exists) — plain contract bound to this vault and the OWN
        //    token. Skipped = vault runs controller-less; wire later via setIncentivesController.
        OwnIncentives incentives;
        bool needsSafeAttach;
        if (own != address(0)) {
            incentives = new OwnIncentives(address(registry), address(sEusd), own);

            // 4. Attach the controller (ADMIN only) before any emission is ever set.
            if (registry.hasRole(ADMIN_ROLE, deployer)) {
                sEusd.setIncentivesController(address(incentives));
                require(address(sEusd.incentivesController()) == address(incentives), "controller not attached");
            } else {
                needsSafeAttach = true;
            }
        }

        // 5. Registry slots — direct if the deployer holds PROTOCOL_ADMIN, otherwise via the Safe.
        bool needsSafeRegistry;
        if (registry.hasRole(0x00, deployer)) {
            registry.setAddress(STAKED_EUSD_KEY, address(sEusd));
            if (address(incentives) != address(0)) registry.setAddress(OWN_INCENTIVES_KEY, address(incentives));
        } else {
            needsSafeRegistry = true;
        }

        vm.stopBroadcast();

        require(sEusd.asset() == eusd, "asset mismatch");

        // Pending governance calls, printed as a ready-to-paste Safe batch.
        if (needsSafeAttach || needsSafeRegistry) {
            console.log("=== Safe batch required ===");
            if (needsSafeAttach) {
                console.log("target:", address(sEusd));
                console.log("  setIncentivesController calldata:");
                console.logBytes(abi.encodeCall(StakedEUSD.setIncentivesController, (address(incentives))));
            }
            if (needsSafeRegistry) {
                console.log("target:", address(registry));
                console.log("  setAddress(STAKED_EUSD, vault) calldata:");
                console.logBytes(abi.encodeCall(IProtocolRegistry.setAddress, (STAKED_EUSD_KEY, address(sEusd))));
                if (address(incentives) != address(0)) {
                    console.log("  setAddress(OWN_INCENTIVES, controller) calldata:");
                    console.logBytes(
                        abi.encodeCall(IProtocolRegistry.setAddress, (OWN_INCENTIVES_KEY, address(incentives)))
                    );
                }
            }
        }

        console.log("StakedEUSD:    ", address(sEusd));
        console.log("OwnIncentives: ", address(incentives));
        console.log("OWN token:     ", own);
        console.log("Seed (dead):   ", seed);
    }
}
