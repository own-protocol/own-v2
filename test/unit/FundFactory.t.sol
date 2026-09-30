// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../src/funds/Fund.sol";
import {FundFactory} from "../../src/funds/FundFactory.sol";
import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {FundLaunch} from "../../src/funds/FundLaunch.sol";
import {FundStaking} from "../../src/funds/FundStaking.sol";
import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {
    CreateFundParams,
    GovernanceConfig,
    LaunchConfig,
    PlatformMetadata,
    YieldTier
} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract FundV2Mock is Fund {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract FundFactoryTest is FundTestBase {
    function test_initialize_defaults() public view {
        assertEq(factory.owner(), admin);
        assertEq(factory.protocolFeeBps(), 50);
        assertEq(factory.protocolFeeRecipient(), protocolTreasury);
        assertEq(factory.lpFeeRecipient(), lpTreasury);
        assertTrue(factory.whitelistEnabled());
        assertEq(factory.maxRebalanceSlippageBps(), 200);
        LaunchConfig memory cfg = factory.launchConfig();
        assertEq(cfg.duration, 36 hours);
        assertEq(cfg.usdgRatioBps, 3000);
        assertEq(cfg.launchPremiumBps, 3000);
        assertEq(cfg.finalizeGrace, 7 days);
        assertEq(factory.hook(), address(hook));
        assertEq(factory.maxYieldRateBpsPerDay(), 300);
        GovernanceConfig memory gov = factory.governanceConfig();
        assertEq(gov.creatorPowerBps, 3000);
        assertEq(gov.passThresholdBps, 5000);
        assertEq(gov.minUserSupportBps, 2000);
        assertEq(gov.votingPeriod, 3 days);
        assertEq(gov.executionDelay, 1 days);
        assertEq(gov.executionWindow, 7 days);
    }

    function test_createFund_wiresGovernor() public {
        _createFund();
        assertEq(fund.governor(), address(governor));
        assertEq(governor.fund(), address(fund));
        assertEq(governor.config().creatorPowerBps, 3000);
    }

    function test_createFund_tierAboveYieldCap_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.yieldTiers[2] = YieldTier({minPremiumBps: 10_000, rateBpsPerDay: 301});
        vm.prank(launcher);
        vm.expectRevert();
        factory.createFund(p);
    }

    function test_setMaxYieldRate_ownerOnlyAndBounded() public {
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setMaxYieldRate(100);
        vm.startPrank(admin);
        vm.expectRevert(IFundFactory.InvalidYieldCap.selector);
        factory.setMaxYieldRate(10_001);
        factory.setMaxYieldRate(100);
        vm.stopPrank();
        assertEq(factory.maxYieldRateBpsPerDay(), 100);
    }

    function test_setGovernanceConfig_appliesToNewFunds() public {
        GovernanceConfig memory c = factory.governanceConfig();
        c.creatorPowerBps = 2000;
        c.votingPeriod = 5 days;
        vm.prank(admin);
        factory.setGovernanceConfig(c);
        _createFund();
        assertEq(governor.config().creatorPowerBps, 2000);
        assertEq(governor.config().votingPeriod, 5 days);
    }

    function test_setGovernanceConfig_invalid_reverts() public {
        GovernanceConfig memory c = factory.governanceConfig();
        c.votingPeriod = 10 minutes;
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidGovernanceConfig.selector);
        factory.setGovernanceConfig(c);
    }

    function test_setPlatformMetadata_ownerOnly() public {
        PlatformMetadata memory m =
            PlatformMetadata({name: "MONEY Market Funds by Own", description: "About Own.", url: "https://own.money"});
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setPlatformMetadata(m);
        vm.prank(admin);
        factory.setPlatformMetadata(m);
        assertEq(factory.platformMetadata().description, "About Own.");
    }

    function test_upgradeModule_governor() public {
        address impl = address(new FundGovernor());
        vm.prank(admin);
        factory.upgradeModule(IFundFactory.Module.Governor, impl);
        assertEq(UpgradeableBeacon(factory.beacon(IFundFactory.Module.Governor)).implementation(), impl);
    }

    function test_createFund_whitelistedLauncher() public {
        _createFund();
        assertTrue(factory.isFund(address(fund)));
        assertEq(factory.fundCount(), 1);
        assertEq(factory.fundAt(0), address(fund));
        assertEq(fund.launch(), address(launch));
        assertEq(fund.staking(), address(staking));
        assertEq(fund.manager(), creator);
        assertEq(fund.creatorFeeBps(), 100);
        assertEq(launch.endTime(), block.timestamp + 36 hours);
        assertEq(address(hook.poolKeyOf(address(fund)).hooks), address(hook));
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
        (address f,,,) = factory.createFund(p);
        assertTrue(factory.isFund(f));
    }

    function test_createFund_creatorFeeAboveTenPercent_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.creatorFeeBps = 1001;
        vm.prank(launcher);
        vm.expectRevert();
        factory.createFund(p);
    }

    function test_createFund_assetWithoutFeed_reverts() public {
        CreateFundParams memory p = _defaultParams();
        p.assets[2] = makeAddr("noFeed");
        vm.prank(launcher);
        vm.expectRevert();
        factory.createFund(p);
    }

    function test_createFund_hookNotSet_reverts() public {
        FundFactory bare = FundFactory(
            address(
                new ERC1967Proxy(
                    address(new FundFactory()),
                    abi.encodeCall(
                        FundFactory.initialize,
                        (
                            admin,
                            address(oracle),
                            address(usdg),
                            protocolTreasury,
                            lpTreasury,
                            address(new Fund()),
                            address(new FundLaunch()),
                            address(new FundStaking()),
                            address(new FundGovernor())
                        )
                    )
                )
            )
        );
        vm.prank(admin);
        bare.setLauncher(launcher, true);
        CreateFundParams memory p = _defaultParams();
        vm.prank(launcher);
        vm.expectRevert(FundFactory.HookNotSet.selector);
        bare.createFund(p);
    }

    function test_setHook_once() public {
        vm.prank(admin);
        vm.expectRevert(FundFactory.HookAlreadySet.selector);
        factory.setHook(address(1));
    }

    function test_setProtocolFee_capped() public {
        vm.startPrank(admin);
        factory.setProtocolFee(500);
        assertEq(factory.protocolFeeBps(), 500);
        vm.expectRevert(IFundFactory.FeeTooHigh.selector);
        factory.setProtocolFee(501);
        vm.stopPrank();
    }

    function test_adminSetters_onlyOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setProtocolFee(10);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setProtocolFeeRecipient(attacker);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setLpFeeRecipient(attacker);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setWhitelistEnabled(false);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setLauncher(attacker, true);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setRouter(attacker, true);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.setMaxRebalanceSlippage(10);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.upgradeModule(IFundFactory.Module.Fund, address(1));
        vm.stopPrank();
    }

    function test_setLaunchConfig_appliesToNewFundsOnly() public {
        _createFund();
        address firstLaunch = address(launch);
        vm.prank(admin);
        factory.setLaunchConfig(
            LaunchConfig({duration: 48 hours, finalizeGrace: 3 days, usdgRatioBps: 2000, launchPremiumBps: 5000})
        );
        assertEq(launch.config().duration, 36 hours);
        _createFund();
        assertTrue(address(launch) != firstLaunch);
        assertEq(launch.config().duration, 48 hours);
        assertEq(launch.config().usdgRatioBps, 2000);
    }

    function test_setLaunchConfig_invalid_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IFundFactory.InvalidLaunchConfig.selector);
        factory.setLaunchConfig(
            LaunchConfig({duration: 10 minutes, finalizeGrace: 3 days, usdgRatioBps: 2000, launchPremiumBps: 5000})
        );
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
        FundV2Mock v2 = new FundV2Mock();
        vm.prank(admin);
        factory.upgradeModule(IFundFactory.Module.Fund, address(v2));
        assertEq(UpgradeableBeacon(factory.beacon(IFundFactory.Module.Fund)).implementation(), address(v2));
        assertEq(FundV2Mock(address(fund)).version(), 2);
        assertEq(fund.symbol(), "MF1"); // storage intact
    }

    function test_ownership_twoStep() public {
        vm.prank(admin);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), admin);
        vm.prank(bob);
        vm.expectRevert(IFundFactory.NotPendingOwner.selector);
        factory.acceptOwnership();
        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
    }

    function test_upgradeFactory_onlyOwner() public {
        address impl = address(new FundFactory());
        vm.prank(attacker);
        vm.expectRevert(IFundFactory.NotOwner.selector);
        factory.upgradeToAndCall(impl, "");
        vm.prank(admin);
        factory.upgradeToAndCall(impl, "");
    }
}
