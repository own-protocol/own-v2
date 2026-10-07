// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../src/funds/Fund.sol";
import {FundBribes} from "../../src/funds/FundBribes.sol";
import {FundCurators} from "../../src/funds/FundCurators.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {IFundCurators} from "../../src/interfaces/IFundCurators.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {
    CreateFundParams,
    GovernanceConfig,
    LaunchConfig,
    PlatformMetadata,
    YieldPoint
} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract FundV2Mock is Fund {
    constructor(
        address usdg_
    ) Fund(usdg_) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract FundFactoryTest is FundTestBase {
    function test_initialize_defaults() public view {
        assertEq(factory.registry(), address(registry));
        assertEq(factory.protocolCurator(), protocolCurator);
        assertEq(factory.protocolCuratorShareBps(), 3333);
        assertTrue(factory.whitelistEnabled());
        assertEq(factory.maxRebalanceSlippageBps(), 200);
        assertEq(factory.hook(), address(hook));
        assertEq(factory.maxYieldRateBpsPerYear(), 300 * 365);
        assertEq(factory.curatorCap(), 10);
        assertEq(factory.bribeCutBps(), 1500);

        LaunchConfig memory cfg = factory.launchConfig();
        assertEq(cfg.duration, 7 days);
        assertEq(cfg.finalizeGrace, 7 days);
        assertEq(cfg.poolUsdgBps, 1000);
        assertEq(cfg.launchPremiumBps, 3000); // FundTestBase's; see test_initialize_launchesAtNav
        assertEq(cfg.earlyYieldBpsPerDay, 50);
        assertEq(cfg.overweightHaircutBps, 500);
        assertEq(cfg.depositorLock, 7 days);

        GovernanceConfig memory gov = factory.governanceConfig();
        assertEq(gov.curatorShareBps, 3000);
        assertEq(gov.minVoteBps, 200);
        assertEq(gov.maxWeightBps, 2500);
        assertEq(gov.maxWeeklyShiftBps, 500);
        assertEq(gov.dropAfterEpochs, 4);
        assertEq(gov.quorumBps, 2000);
        assertEq(gov.curatorQuorumBps, 2000);
        assertEq(gov.votingPeriod, 3 days);
        assertEq(gov.vetoPeriod, 1 days);
        assertEq(gov.executionWindow, 7 days);
        assertEq(gov.bribeLock, 28 days);
        assertEq(gov.proposalThresholdUsd, 5000e18);
    }

    function test_createFund_wiresEveryModule() public {
        _createFund();
        assertTrue(factory.isFund(address(fund)));
        assertEq(factory.fundCount(), 1);
        assertEq(factory.fundAt(0), address(fund));

        IFundFactory.FundModules memory m = factory.modulesOf(address(fund));
        assertEq(m.fund, address(fund));
        assertEq(m.launch, address(launch));
        assertEq(m.staking, address(staking));
        assertEq(m.governor, address(governor));
        assertEq(m.curators, address(curators));
        assertEq(m.bribes, address(bribes));

        assertEq(fund.launch(), address(launch));
        assertEq(fund.staking(), address(staking));
        assertEq(fund.governor(), address(governor));
        assertEq(fund.curators(), address(curators));
        assertEq(fund.manager(), keeper);
        assertEq(fund.feeBps(), 100);
        assertEq(governor.fund(), address(fund));
        assertEq(curators.fund(), address(fund));
        assertEq(bribes.fund(), address(fund));
        assertEq(governor.config().curatorShareBps, 3000);

        assertEq(curators.curatorCount(), 2);
        assertTrue(curators.isCurator(curatorA));
        assertTrue(curators.isCurator(curatorB));
        assertEq(curators.minStakeBps(), 50);

        assertEq(launch.launchSupply(), 130_000e18);
        assertEq(launch.endTime(), block.timestamp + 7 days);
        assertEq(address(hook.poolKeyOf(address(fund)).hooks), address(hook));
    }

    function test_createFund_defaultsSupplyAndWindow() public {
        CreateFundParams memory p = _defaultParams();
        p.launchSupply = 0;
        p.launchDuration = 0;
        _createFund(p);
        assertEq(launch.launchSupply(), 100_000_000e18);
        assertEq(launch.endTime(), block.timestamp + 7 days);
    }

    function test_createFund_customWindow() public {
        CreateFundParams memory p = _defaultParams();
        p.launchDuration = 3 days;
        _createFund(p);
        assertEq(launch.endTime(), block.timestamp + 3 days);
        assertEq(launch.config().duration, 3 days);
    }

    function test_createFund_poolShareAndTarget() public {
        CreateFundParams memory p = _defaultParams();
        p.poolUsdgBps = 0;
        p.targetRaiseUsd = 50_000e18;
        _createFund(p);
        assertEq(launch.config().poolUsdgBps, 1000);
        assertEq(launch.targetRaiseUsd(), 50_000e18);
        assertEq(launch.minRaiseUsd(), 10_000e18);

        p.poolUsdgBps = 2500;
        _createFund(p);
        assertEq(launch.config().poolUsdgBps, 2500);
    }

    function test_createFund_poolShareAboveCap_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.poolUsdgBps = 5001;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.createFund(p);
    }

    function test_createFund_targetBelowMinimum_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.targetRaiseUsd = p.minRaiseUsd - 1;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.createFund(p);
    }

    function test_createFund_windowOutOfRange_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.launchDuration = 12 hours;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.createFund(p);
        p.launchDuration = 31 days;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.createFund(p);
    }

    function test_createFund_moreCuratorsThanCap_reverts() public {
        vm.prank(admin);
        factory.setCuratorCap(1);
        CreateFundParams memory p = _defaultParams();
        vm.prank(admin);
        vm.expectRevert(IFundCurators.CuratorCapReached.selector);
        factory.createFund(p);
    }

    function test_createFund_duplicateCurator_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.curators[1] = curatorA;
        vm.prank(admin);
        vm.expectRevert(IFundCurators.AlreadyCurator.selector);
        factory.createFund(p);
    }

    function test_createFund_minCuratorStakeAboveCap_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.minCuratorStakeBps = 1001;
        vm.prank(admin);
        vm.expectRevert(IFundCurators.InvalidMinStake.selector);
        factory.createFund(p);
    }

    function test_createFund_tierAboveYieldCap_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.yieldCurve[2] = YieldPoint({premiumBps: 10_000, rateBpsPerYear: 301 * 365});
        vm.prank(admin);
        vm.expectRevert();
        factory.createFund(p);
    }

    function test_createFund_whitelistedLauncher() public {
        CreateFundParams memory p = _defaultParams();
        vm.prank(launcher);
        IFundFactory.FundModules memory m = factory.createFund(p);
        assertTrue(factory.isFund(m.fund));
    }

    function test_createFund_notWhitelisted_reverts() public {
        CreateFundParams memory p = _defaultParams();
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotLauncher.selector);
        factory.createFund(p);
    }

    function test_createFund_openToAnyoneOnceWhitelistOff() public {
        vm.prank(admin);
        factory.setWhitelistEnabled(false);
        CreateFundParams memory p = _defaultParams();
        vm.prank(attacker);
        IFundFactory.FundModules memory m = factory.createFund(p);
        assertTrue(factory.isFund(m.fund));
    }

    function test_createFund_feeAboveTenPercent_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.feeBps = 1001;
        vm.prank(admin);
        vm.expectRevert();
        factory.createFund(p);
    }

    function test_createFund_assetWithoutFeed_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.assets[2] = makeAddr("noFeed");
        vm.prank(admin);
        vm.expectRevert();
        factory.createFund(p);
    }

    function test_createFund_usdgInBasket_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.assets[2] = address(usdg);
        _setFeed(address(usdg), 1e8);
        vm.prank(admin);
        vm.expectRevert();
        factory.createFund(p);
    }

    function test_initialize_launchesAtNav() public {
        assertEq(_bareFactory().launchConfig().launchPremiumBps, 0);
    }

    function test_createFund_hookNotSet_reverts() public {
        FundFactory bare = _bareFactory();
        CreateFundParams memory p = _defaultParams();
        vm.prank(admin);
        vm.expectRevert(FundFactory.HookNotSet.selector);
        bare.createFund(p);
    }

    function _bareFactory() internal returns (FundFactory bare) {
        address[6] memory impls = [
            address(new Fund(address(usdg))),
            address(new FundLaunch()),
            address(new FundStaking(positionManager)),
            address(new FundGovernor()),
            address(new FundCurators()),
            address(new FundBribes())
        ];
        bare = FundFactory(
            address(
                new ERC1967Proxy(
                    address(new FundFactory()),
                    abi.encodeCall(
                        FundFactory.initialize,
                        (address(registry), address(oracle), address(usdg), protocolCurator, impls)
                    )
                )
            )
        );
    }

    function test_setHook_once() public {
        vm.prank(admin);
        vm.expectRevert(FundFactory.HookAlreadySet.selector);
        factory.setHook(address(1));
    }

    function test_setCuratorCap_bounded() public {
        vm.startPrank(admin);
        vm.expectRevert(IFundFactory.InvalidCuratorCap.selector);
        factory.setCuratorCap(0);
        vm.expectRevert(IFundFactory.InvalidCuratorCap.selector);
        factory.setCuratorCap(51);
        factory.setCuratorCap(3);
        vm.stopPrank();
        assertEq(factory.curatorCap(), 3);
    }

    function test_setBribeCut_cappedAtTwentyFivePercent() public {
        vm.startPrank(admin);
        factory.setBribeCut(2500);
        assertEq(factory.bribeCutBps(), 2500);
        vm.expectRevert(IFundFactory.FeeTooHigh.selector);
        factory.setBribeCut(2501);
        vm.stopPrank();
    }

    function test_setBribeTokenAndEligibleAsset() public {
        vm.startPrank(admin);
        factory.setBribeToken(address(usdg), true);
        factory.setEligibleAsset(address(spare), true);
        vm.expectRevert(IFundFactory.ZeroAddress.selector);
        factory.setBribeToken(address(0), true);
        vm.expectRevert(IFundFactory.ZeroAddress.selector);
        factory.setEligibleAsset(address(0), true);
        vm.stopPrank();
        assertTrue(factory.isBribeToken(address(usdg)));
        assertTrue(factory.isEligibleAsset(address(spare)));
    }

    function test_setMaxYieldRate_ownerOnlyAndBounded() public {
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setMaxYieldRate(100);
        vm.startPrank(admin);
        vm.expectRevert(IFundFactory.InvalidYieldCap.selector);
        factory.setMaxYieldRate(10_000 * 365 + 1);
        factory.setMaxYieldRate(900);
        vm.stopPrank();
        assertEq(factory.maxYieldRateBpsPerYear(), 900);
    }

    function test_setGovernanceConfig_appliesToNewFunds() public {
        GovernanceConfig memory c = factory.governanceConfig();
        c.curatorShareBps = 2000;
        c.votingPeriod = 5 days;
        vm.prank(admin);
        factory.setGovernanceConfig(c);
        _createFund();
        assertEq(governor.config().curatorShareBps, 2000);
        assertEq(governor.config().votingPeriod, 5 days);
    }

    function test_setGovernanceConfig_invalid_reverts() public {
        GovernanceConfig memory c = factory.governanceConfig();
        c.votingPeriod = 10 minutes;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidGovernanceConfig.selector);
        factory.setGovernanceConfig(c);

        c = factory.governanceConfig();
        c.curatorShareBps = 5001;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidGovernanceConfig.selector);
        factory.setGovernanceConfig(c);

        c = factory.governanceConfig();
        c.maxWeightBps = 999;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidGovernanceConfig.selector);
        factory.setGovernanceConfig(c);

        c = factory.governanceConfig();
        c.bribeLock = 365 days + 1;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidGovernanceConfig.selector);
        factory.setGovernanceConfig(c);
    }

    function test_setPlatformMetadata_ownerOnly() public {
        PlatformMetadata memory m =
            PlatformMetadata({name: "Own Curated Funds", description: "About Own.", url: "https://own.money"});
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setPlatformMetadata(m);
        vm.prank(admin);
        factory.setPlatformMetadata(m);
        assertEq(factory.platformMetadata().name, "Own Curated Funds");
    }

    function test_setProtocolCurator() public {
        address next = makeAddr("nextProtocolCurator");
        vm.startPrank(admin);
        vm.expectRevert(IFundFactory.ZeroAddress.selector);
        factory.setProtocolCurator(address(0));
        vm.expectEmit(address(factory));
        emit IFundFactory.ProtocolCuratorSet(next);
        factory.setProtocolCurator(next);
        vm.stopPrank();
        assertEq(factory.protocolCurator(), next);
    }

    function test_setOracle() public {
        address next = makeAddr("nextOracle");
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setOracle(next);

        vm.startPrank(admin);
        vm.expectRevert(IFundFactory.ZeroAddress.selector);
        factory.setOracle(address(0));
        vm.expectEmit(address(factory));
        emit IFundFactory.OracleSet(next);
        factory.setOracle(next);
        vm.stopPrank();
        assertEq(factory.oracle(), next);
    }

    function test_setProtocolCuratorShare_capped() public {
        vm.startPrank(admin);
        factory.setProtocolCuratorShare(5000);
        assertEq(factory.protocolCuratorShareBps(), 5000);
        vm.expectRevert(IFundFactory.FeeTooHigh.selector);
        factory.setProtocolCuratorShare(5001);
        vm.stopPrank();
    }

    function test_adminSetters_onlyOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setProtocolCuratorShare(10);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setProtocolCurator(attacker);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setWhitelistEnabled(false);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setLauncher(attacker, true);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setRouter(attacker, true);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setMaxRebalanceSlippage(10);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setCuratorCap(5);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setBribeCut(100);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setBribeToken(attacker, true);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setEligibleAsset(attacker, true);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.upgradeModule(IFundFactory.Module.Fund, address(1));
        vm.stopPrank();
    }

    function test_setLaunchConfig_appliesToNewFundsOnly() public {
        _createFund();
        address firstLaunch = address(launch);
        LaunchConfig memory cfg = factory.launchConfig();
        cfg.launchPremiumBps = 2000;
        cfg.earlyYieldBpsPerDay = 25;
        vm.prank(admin);
        factory.setLaunchConfig(cfg);
        assertEq(launch.config().launchPremiumBps, 3000);
        _createFund();
        assertTrue(address(launch) != firstLaunch);
        assertEq(launch.config().launchPremiumBps, 2000);
        assertEq(launch.config().earlyYieldBpsPerDay, 25);
    }

    function test_setLaunchConfig_invalid_reverts() public {
        LaunchConfig memory base = factory.launchConfig();
        LaunchConfig memory cfg = base;

        cfg.duration = 10 minutes;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.setLaunchConfig(cfg);

        cfg = factory.launchConfig();
        cfg.poolUsdgBps = 0;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.setLaunchConfig(cfg);

        cfg = factory.launchConfig();
        cfg.poolUsdgBps = 5001;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.setLaunchConfig(cfg);

        cfg = factory.launchConfig();
        cfg.overweightHaircutBps = 5001;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.setLaunchConfig(cfg);

        cfg = factory.launchConfig();
        cfg.depositorLock = 31 days;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.setLaunchConfig(cfg);
    }

    function test_setRebalanceVolumeCap() public {
        assertEq(factory.rebalanceVolumeCapBps(), 1000);
        vm.startPrank(admin);
        factory.setRebalanceVolumeCap(2500);
        assertEq(factory.rebalanceVolumeCapBps(), 2500);
        vm.expectRevert(IFundFactory.InvalidSlippage.selector);
        factory.setRebalanceVolumeCap(10_001);
        vm.stopPrank();
    }

    function test_setMaxRebalanceSlippage_capped() public {
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidSlippage.selector);
        factory.setMaxRebalanceSlippage(1001);
    }

    function test_upgradeModule_upgradesExistingFunds() public {
        _createFund();
        FundV2Mock v2 = new FundV2Mock(address(usdg));
        vm.prank(admin);
        factory.upgradeModule(IFundFactory.Module.Fund, address(v2));
        assertEq(UpgradeableBeacon(factory.beacon(IFundFactory.Module.Fund)).implementation(), address(v2));
        assertEq(FundV2Mock(address(fund)).version(), 2);
        assertEq(fund.symbol(), "OCF1"); // storage intact
    }

    function test_upgradeModule_curatorsAndBribes() public {
        address impl = address(new FundCurators());
        vm.prank(admin);
        factory.upgradeModule(IFundFactory.Module.Curators, impl);
        assertEq(UpgradeableBeacon(factory.beacon(IFundFactory.Module.Curators)).implementation(), impl);
        impl = address(new FundBribes());
        vm.prank(admin);
        factory.upgradeModule(IFundFactory.Module.Bribes, impl);
        assertEq(UpgradeableBeacon(factory.beacon(IFundFactory.Module.Bribes)).implementation(), impl);
    }

    function test_roles_followRegistry() public {
        assertTrue(factory.isAdmin(admin));
        assertTrue(factory.isOperator(admin));
        assertTrue(factory.isOperator(operator));
        assertFalse(factory.isAdmin(operator));
        assertFalse(factory.isOperator(alice));

        vm.startPrank(admin);
        registry.grantRole(keccak256("ADMIN"), alice);
        registry.revokeRole(keccak256("ADMIN"), admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setCuratorCap(5);
        vm.prank(alice);
        factory.setCuratorCap(5);
        assertEq(factory.curatorCap(), 5);
    }

    function test_operator_cannotAdmin() public {
        vm.prank(operator);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.setCuratorCap(5);
    }

    function test_upgradeFactory_onlyAdmin() public {
        address impl = address(new FundFactory());
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotAdmin.selector);
        factory.upgradeToAndCall(impl, "");
        vm.prank(admin);
        factory.upgradeToAndCall(impl, "");
    }
}
