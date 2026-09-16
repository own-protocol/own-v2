// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LinearBoostCalculator} from "../../src/core/LinearBoostCalculator.sol";
import {OwnStakingV2} from "../../src/core/OwnStakingV2.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {IOwnStakeZap} from "../../src/interfaces/IOwnStakeZap.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {OwnStakeZap} from "../../src/periphery/OwnStakeZap.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployMoneyStakingRobinhood — $MONEY staking (OwnStakingV2 + zap + boost calculator)
/// @notice Deploys the LinearBoostCalculator, OwnStakingV2 (UUPS) and OwnStakeZap (UUPS), each
///         proxy initialized atomically in its constructor call (never deploy-then-initialize —
///         a two-step deploy is front-runnable). Wires the zap whitelists (staking.setZap,
///         eusdManager.setStakeZap) and registry slots directly when the deployer holds the
///         roles, otherwise prints a ready-to-paste Safe batch. Run after the eUSD module and the
///         SPY PSM wrapper are live.
///
/// @dev Post-deploy checklist:
///        1. Verify staking.boostCalculator() == the LinearBoostCalculator and
///           previewBoost(0, 1e18) == FLOOR_BPS.
///        2. Verify SPY_COLLATERAL is the ACTIVE eToken for SPY_TICKER (the zap pins it).
///        3. Execute the Safe batch if printed; verify staking.zap() and
///           eusdManager.stakeZap() both equal the zap.
///        4. Treasury Safe: approve SPY to the staking contract (the allowance is the
///           notifyRewardAmount spending cap), then OPERATOR notifies the first weekly batch —
///           budget per docs/staking-apr-launch.md.
///        5. Calculator swaps are security-critical: review any replacement for
///           splitting-neutrality before setBoostCalculator (docs/audit-report-5.md, A5-M-05).
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD,
///      EUSD_ROBINHOOD, EUSD_MANAGER_ROBINHOOD, OWN_MARKET_ROBINHOOD, STAKED_EUSD_ROBINHOOD,
///      MONEY_TOKEN_ROBINHOOD, SPY_TOKEN_ROBINHOOD (Gen-2 wrapper the zap swaps/mints from),
///      SPY_COLLATERAL_ROBINHOOD (active eToken for SPY_TICKER), SWAP_ROUTER_ROBINHOOD,
///      REWARD_SOURCE_ROBINHOOD (treasury Safe holding SPY).
///
/// Usage:
///   forge script script/robinhood/DeployMoneyStakingRobinhood.s.sol --rpc-url robinhood \
///     --broadcast --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployMoneyStakingRobinhood is Script {
    /// @dev Registry slots for the new module addresses (write-only; event-tracked for ops).
    bytes32 constant MONEY_STAKING_KEY = keccak256("MONEY_STAKING");
    bytes32 constant STAKE_ZAP_KEY = keccak256("STAKE_ZAP");

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 constant SPY_TICKER = bytes32("SPY");

    /// @dev Launch boost line: 0.1x floor rising linearly to 3.6x at 3.0 coverage
    ///      (docs/staking-apr-launch.md). Reshape later = new calculator + setBoostCalculator.
    uint256 constant FLOOR_BPS = 1000;
    uint256 constant MAX_BOOST_BPS = 36_000;
    uint256 constant MAX_COVERAGE_BPS = 30_000;

    struct Cfg {
        IProtocolRegistry registry;
        address eusd;
        address eusdManager;
        address market;
        address sEusd;
        address money;
        address spy;
        address collateral;
        address swapRouter;
        address rewardSource;
        address deployer;
    }

    function _readCfg() private view returns (Cfg memory c) {
        c.registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        c.eusd = vm.envAddress("EUSD_ROBINHOOD");
        c.eusdManager = vm.envAddress("EUSD_MANAGER_ROBINHOOD");
        c.market = vm.envAddress("OWN_MARKET_ROBINHOOD");
        c.sEusd = vm.envAddress("STAKED_EUSD_ROBINHOOD");
        c.money = vm.envAddress("MONEY_TOKEN_ROBINHOOD");
        c.spy = vm.envAddress("SPY_TOKEN_ROBINHOOD");
        c.collateral = vm.envAddress("SPY_COLLATERAL_ROBINHOOD");
        c.swapRouter = vm.envAddress("SWAP_ROUTER_ROBINHOOD");
        c.rewardSource = vm.envAddress("REWARD_SOURCE_ROBINHOOD");
        c.deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));
    }

    function _deployStaking(Cfg memory c, address calc) private returns (OwnStakingV2) {
        return OwnStakingV2(
            address(
                new ERC1967Proxy(
                    address(new OwnStakingV2()),
                    abi.encodeCall(
                        OwnStakingV2.initialize, (address(c.registry), c.eusd, c.money, c.spy, c.rewardSource, calc)
                    )
                )
            )
        );
    }

    function _deployZap(Cfg memory c, address staking) private returns (OwnStakeZap) {
        return OwnStakeZap(
            address(
                new ERC1967Proxy(
                    address(new OwnStakeZap()),
                    abi.encodeCall(
                        OwnStakeZap.initialize,
                        (
                            IOwnStakeZap.InitConfig({
                                registry: address(c.registry),
                                eusdManager: c.eusdManager,
                                staking: staking,
                                market: c.market,
                                sEusd: c.sEusd,
                                eusd: c.eusd,
                                money: c.money,
                                spy: c.spy,
                                collateral: c.collateral,
                                collateralTicker: SPY_TICKER,
                                swapRouter: c.swapRouter
                            })
                        )
                    )
                )
            )
        );
    }

    function run() external {
        Cfg memory c = _readCfg();

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // 1. Launch boost calculator — immutable pure pricing, nothing to initialize.
        LinearBoostCalculator calc = new LinearBoostCalculator(FLOOR_BPS, MAX_BOOST_BPS, MAX_COVERAGE_BPS);

        // 2/3. Staking and zap — UUPS proxies, each initialized atomically in its constructor.
        OwnStakingV2 staking = _deployStaking(c, address(calc));
        OwnStakeZap zap = _deployZap(c, address(staking));

        // 4. Whitelist the zap on both protocol surfaces (ADMIN), else defer to the Safe.
        bool needsSafeWiring;
        if (c.registry.hasRole(ADMIN_ROLE, c.deployer)) {
            staking.setZap(address(zap));
            IEUSDManager(c.eusdManager).setStakeZap(address(zap));
        } else {
            needsSafeWiring = true;
        }

        // 5. Registry slots — direct if the deployer holds PROTOCOL_ADMIN, otherwise via the Safe.
        bool needsSafeRegistry;
        if (c.registry.hasRole(0x00, c.deployer)) {
            c.registry.setAddress(MONEY_STAKING_KEY, address(staking));
            c.registry.setAddress(STAKE_ZAP_KEY, address(zap));
        } else {
            needsSafeRegistry = true;
        }

        vm.stopBroadcast();

        require(address(staking.boostCalculator()) == address(calc), "calculator not wired");
        require(staking.previewBoost(0, 1e18) == FLOOR_BPS, "floor boost mismatch");

        // Pending governance calls, printed as a ready-to-paste Safe batch.
        if (needsSafeWiring || needsSafeRegistry) {
            console.log("=== Safe batch required ===");
            if (needsSafeWiring) {
                console.log("target:", address(staking));
                console.log("  setZap calldata:");
                console.logBytes(abi.encodeCall(OwnStakingV2.setZap, (address(zap))));
                console.log("target:", c.eusdManager);
                console.log("  setStakeZap calldata:");
                console.logBytes(abi.encodeCall(IEUSDManager.setStakeZap, (address(zap))));
            }
            if (needsSafeRegistry) {
                console.log("target:", address(c.registry));
                console.log("  setAddress(MONEY_STAKING, staking) calldata:");
                console.logBytes(abi.encodeCall(IProtocolRegistry.setAddress, (MONEY_STAKING_KEY, address(staking))));
                console.log("  setAddress(STAKE_ZAP, zap) calldata:");
                console.logBytes(abi.encodeCall(IProtocolRegistry.setAddress, (STAKE_ZAP_KEY, address(zap))));
            }
        }

        console.log("LinearBoostCalculator:", address(calc));
        console.log("OwnStakingV2:         ", address(staking));
        console.log("OwnStakeZap:          ", address(zap));
        console.log("Reward source (Safe): ", c.rewardSource);
    }
}
