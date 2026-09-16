// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {IOwnStakeZap} from "../../src/interfaces/IOwnStakeZap.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {LinearBoostCalculator} from "../../src/staking/LinearBoostCalculator.sol";
import {OwnStakeZap} from "../../src/staking/OwnStakeZap.sol";
import {OwnStakingV2} from "../../src/staking/OwnStakingV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployMoneyStakingRobinhood — $MONEY staking (OwnStakingV2 + zap + boost calculator)
/// @notice Deploys the LinearBoostCalculator, OwnStakingV2 (UUPS) and OwnStakeZap (UUPS), each
///         proxy initialized atomically in its constructor call (never deploy-then-initialize —
///         a two-step deploy is front-runnable). Wires the zap whitelists (staking.setZap,
///         eusdManager.setStakeZap) directly when the deployer holds ADMIN, otherwise prints the
///         calldata for the governance Safe batch. No registry writes —
///         module addresses are recorded in docs/contracts-robinhood.md. Run after the eUSD
///         module and the SPY PSM wrapper are live.
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
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD. All live addresses are pinned as constants below
///      (docs/contracts-robinhood.md is the source of truth).
///
/// Usage:
///   forge script script/robinhood/DeployMoneyStakingRobinhood.s.sol --rpc-url robinhood \
///     --broadcast --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployMoneyStakingRobinhood is Script {
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 constant SPY_TICKER = bytes32("SPY");

    // ── Live Robinhood Chain (4663) addresses — docs/contracts-robinhood.md ──
    address constant PROTOCOL_REGISTRY = 0x93e08ca467046737F75AAD4C936356c196AaA36F;
    address constant EUSD = 0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7;
    address constant EUSD_MANAGER = 0x9748964d733Ff5d47F1d7E3fea620aF014dA5a9b;
    address constant OWN_MARKET = 0x5feC69cB6ADC42031570735c3B61Dc2CfEd4ee64;
    address constant STAKED_EUSD = 0x4fefDd560c076CfE9EA0b8f4d21E60Af5A39fE96;
    /// @dev $MONEY (own.money).
    address constant MONEY_TOKEN = 0x0a8B4763C71aC39101b3B8a97e62Da0B81549a4f;
    /// @dev R.SPY — Gen-2 SPY token the zap swaps and PSM-mints from.
    address constant SPY_TOKEN = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    /// @dev eSPY — the active eToken for SPY_TICKER; the zap pins it.
    address constant SPY_COLLATERAL = 0xb9D2F8A79F59b84269Adf7d82Fe44ad41139FcF5;
    /// @dev Treasury Safe holding SPY — the notifyRewardAmount pull source.
    address constant REWARD_SOURCE = 0x8f974d82EEaa9725ecC40600f12093B14080dA54;
    /// @dev Pons V2 swap venue (SPY↔$MONEY) — same target MoneyFeeCollector allow-lists.
    address constant SWAP_ROUTER = 0x65050A9b7E5075A2bA5cED7b1b64EE66262c40Dc;

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
        c.registry = IProtocolRegistry(PROTOCOL_REGISTRY);
        c.eusd = EUSD;
        c.eusdManager = EUSD_MANAGER;
        c.market = OWN_MARKET;
        c.sEusd = STAKED_EUSD;
        c.money = MONEY_TOKEN;
        c.spy = SPY_TOKEN;
        c.collateral = SPY_COLLATERAL;
        c.swapRouter = SWAP_ROUTER;
        c.rewardSource = REWARD_SOURCE;
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

        vm.stopBroadcast();

        require(address(staking.boostCalculator()) == address(calc), "calculator not wired");
        require(staking.previewBoost(0, 1e18) == FLOOR_BPS, "floor boost mismatch");

        // Pending governance calls, printed as a ready-to-paste Safe batch.
        if (needsSafeWiring) {
            console.log("=== Safe batch required ===");
            console.log("target:", address(staking));
            console.log("  setZap calldata:");
            console.logBytes(abi.encodeCall(OwnStakingV2.setZap, (address(zap))));
            console.log("target:", c.eusdManager);
            console.log("  setStakeZap calldata:");
            console.logBytes(abi.encodeCall(IEUSDManager.setStakeZap, (address(zap))));
        }

        console.log("LinearBoostCalculator:", address(calc));
        console.log("OwnStakingV2:         ", address(staking));
        console.log("OwnStakeZap:          ", address(zap));
        console.log("Reward source (Safe): ", c.rewardSource);
    }
}
