// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundOracle} from "../../src/funds/FundOracle.sol";
import {FundPriceFeed} from "../../src/funds/FundPriceFeed.sol";
import {FundPriceHub} from "../../src/funds/FundPriceHub.sol";
import {IFundPriceHub} from "../../src/interfaces/IFundPriceHub.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract FundPriceHubTest is Test {
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    ProtocolRegistry internal registry;
    FundOracle internal oracle;
    FundPriceHub internal hub;
    MockERC20 internal pons;
    MockERC20 internal cat;

    function setUp() public {
        vm.warp(1_000_000);
        registry = new ProtocolRegistry(admin, 2 days, 2 minutes);
        vm.prank(admin);
        registry.grantRole(keccak256("FUND_ADMIN"), admin);
        oracle = new FundOracle(address(registry));
        hub = new FundPriceHub(address(registry), keeper, 0);
        pons = new MockERC20("Pons", "PONS", 18);
        cat = new MockERC20("Cash Cat", "CASHCAT", 18);
    }

    function _push(address a, uint256 pa, address b, uint256 pb) internal {
        address[] memory assets = new address[](2);
        uint256[] memory prices = new uint256[](2);
        (assets[0], assets[1], prices[0], prices[1]) = (a, b, pa, pb);
        vm.prank(keeper);
        hub.pushPrices(assets, prices);
    }

    function test_pushPrices_batchFeedsTheOracle() public {
        vm.startPrank(admin);
        address ponsFeed = hub.createFeed(address(pons));
        address catFeed = hub.createFeed(address(cat));
        oracle.setFeed(address(pons), ponsFeed, 1 hours);
        oracle.setFeed(address(cat), catFeed, 1 hours);
        vm.stopPrank();

        (bool ok,) = oracle.tryPrice(address(pons));
        assertFalse(ok); // nothing pushed yet

        _push(address(pons), 0.02e18, address(cat), 0.0005e18);
        assertEq(oracle.price(address(pons)), 0.02e18);
        assertEq(oracle.price(address(cat)), 0.0005e18);
        (uint256 price, uint256 at) = hub.priceOf(address(cat));
        assertEq(price, 0.0005e18);
        assertEq(at, block.timestamp);
        assertEq(FundPriceFeed(ponsFeed).description(), "PONS / USD (Own push)");

        vm.warp(block.timestamp + 1 hours + 1);
        (ok,) = oracle.tryPrice(address(pons));
        assertFalse(ok); // stale
    }

    function test_pushPrices_notKeeper_reverts() public {
        address[] memory assets = new address[](1);
        uint256[] memory prices = new uint256[](1);
        (assets[0], prices[0]) = (address(pons), 1e18);
        vm.prank(attacker);
        vm.expectRevert(IFundPriceHub.NotKeeper.selector);
        hub.pushPrices(assets, prices);
        vm.prank(admin);
        vm.expectRevert(IFundPriceHub.NotKeeper.selector);
        hub.pushPrices(assets, prices);
    }

    function test_pushPrices_badInput_reverts() public {
        address[] memory assets = new address[](1);
        uint256[] memory prices = new uint256[](2);
        assets[0] = address(pons);
        vm.startPrank(keeper);
        vm.expectRevert(IFundPriceHub.LengthMismatch.selector);
        hub.pushPrices(assets, prices);
        prices = new uint256[](1);
        vm.expectRevert(IFundPriceHub.InvalidPrice.selector);
        hub.pushPrices(assets, prices);
        vm.stopPrank();
    }

    function _pushOne(address who, uint256 price) internal returns (uint256 stored) {
        address[] memory assets = new address[](1);
        uint256[] memory prices = new uint256[](1);
        (assets[0], prices[0]) = (address(pons), price);
        vm.prank(who);
        hub.pushPrices(assets, prices);
        (stored,) = hub.priceOf(address(pons));
    }

    /// @dev A6-M-13: the bound is per hour since the last push, so repeated pushes in one block
    ///      gain nothing.
    function test_moveBound_repeatPushesGainNothing() public {
        vm.prank(admin);
        hub.setMaxMove(3000);
        _pushOne(keeper, 1e18);

        vm.expectEmit(address(hub));
        emit IFundPriceHub.PriceClamped(address(pons), 10e18, 1e18);
        _pushOne(keeper, 10e18);
        for (uint256 i; i < 8; ++i) {
            assertEq(_pushOne(keeper, 10e18), 1e18);
        }

        vm.warp(block.timestamp + 1 hours);
        assertEq(_pushOne(keeper, 10e18), 1.3e18);
    }

    function test_moveBound_realJumpCatchesUpHourly() public {
        vm.prank(admin);
        hub.setMaxMove(3000);
        _pushOne(keeper, 1e18);
        uint256 expected = 1e18;
        for (uint256 h = 1; h <= 8; ++h) {
            vm.warp(block.timestamp + 1 hours);
            expected = expected * 13_000 / 10_000;
            assertEq(_pushOne(keeper, 10e18), expected);
        }
        vm.warp(block.timestamp + 1 hours); // 1.3^9 is past 10x
        assertEq(_pushOne(keeper, 10e18), 10e18);
        (, uint256 at) = hub.priceOf(address(pons));
        assertEq(at, block.timestamp);
    }

    function test_moveBound_fallsSymmetricallyAndProRataWithinTheHour() public {
        vm.prank(admin);
        hub.setMaxMove(3000);
        _pushOne(keeper, 1.3e18);
        vm.warp(block.timestamp + 1 hours);
        assertEq(_pushOne(keeper, 0.1e18), 1e18);

        vm.warp(block.timestamp + 30 minutes);
        assertEq(_pushOne(keeper, 2e18), 1.15e18);
        vm.warp(block.timestamp + 30 minutes);
        assertEq(_pushOne(keeper, 1.2e18), 1.2e18); // within the bound: stored as pushed
    }

    function test_moveBound_offOrLongSilenceIsUnbounded() public {
        _pushOne(keeper, 1e18);
        assertEq(_pushOne(keeper, 50e18), 50e18); // no bound set

        vm.prank(admin);
        hub.setMaxMove(3000);
        vm.warp(block.timestamp + 200 hours); // 1.3^200 is past any real move
        assertEq(_pushOne(keeper, 1e40), 1e40);
    }

    function test_createFeed_adminOnlyOnce() public {
        vm.prank(attacker);
        vm.expectRevert(IFundPriceHub.NotAdmin.selector);
        hub.createFeed(address(pons));

        vm.startPrank(admin);
        address feed = hub.createFeed(address(pons));
        assertEq(hub.feedOf(address(pons)), feed);
        assertEq(address(FundPriceFeed(feed).hub()), address(hub));
        vm.expectRevert(IFundPriceHub.FeedExists.selector);
        hub.createFeed(address(pons));
        vm.stopPrank();
    }

    function test_setKeeper_adminOnly() public {
        vm.prank(attacker);
        vm.expectRevert(IFundPriceHub.NotAdmin.selector);
        hub.setKeeper(attacker);
        vm.prank(admin);
        hub.setKeeper(attacker);
        assertEq(hub.keeper(), attacker);
    }
}
