// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundOracle} from "../../src/funds/FundOracle.sol";
import {IFundOracle} from "../../src/interfaces/IFundOracle.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";
import {Actors} from "../helpers/Actors.sol";
import {MockAggregatorV3} from "../helpers/MockAggregatorV3.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {Test} from "forge-std/Test.sol";

contract FundOracleTest is Test {
    ProtocolRegistry internal registry;
    FundOracle internal oracle;
    MockAggregatorV3 internal feed8;
    MockAggregatorV3 internal feed20;
    address internal admin = Actors.ADMIN;
    address internal asset = makeAddr("asset");
    address internal asset2 = makeAddr("asset2");

    function setUp() public {
        vm.warp(1_000_000);
        registry = new ProtocolRegistry(admin, 2 days, 2 minutes);
        vm.prank(admin);
        registry.grantRole(keccak256("FUND_ADMIN"), admin);
        oracle = new FundOracle(address(registry));
        feed8 = new MockAggregatorV3(8);
        feed20 = new MockAggregatorV3(20);
        feed8.setAnswer(300e8, block.timestamp);
        feed20.setAnswer(2e20, block.timestamp);
        vm.startPrank(admin);
        oracle.setFeed(asset, address(feed8), 1 hours);
        oracle.setFeed(asset2, address(feed20), 1 hours);
        vm.stopPrank();
    }

    function test_price_normalisesDecimals() public view {
        assertEq(oracle.price(asset), 300e18);
        assertEq(oracle.price(asset2), 2e18);
    }

    function test_price_stale_reverts() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(IFundOracle.StalePrice.selector, asset));
        oracle.price(asset);
        (bool ok,) = oracle.tryPrice(asset);
        assertFalse(ok);
    }

    function test_price_nonPositive_reverts() public {
        feed8.setAnswer(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IFundOracle.InvalidPrice.selector, asset));
        oracle.price(asset);
        (bool ok,) = oracle.tryPrice(asset);
        assertFalse(ok);
    }

    function test_price_noFeed_reverts() public {
        address none = makeAddr("none");
        vm.expectRevert(abi.encodeWithSelector(IFundOracle.NoFeed.selector, none));
        oracle.price(none);
        (bool ok, uint256 value) = oracle.tryPrice(none);
        assertFalse(ok);
        assertEq(value, 0);
    }

    function test_tryPrice_fresh() public view {
        (bool ok, uint256 value) = oracle.tryPrice(asset);
        assertTrue(ok);
        assertEq(value, 300e18);
    }

    function test_setFeed_readsDecimalsOnce() public {
        vm.mockCallRevert(address(feed8), abi.encodeWithSignature("decimals()"), "");
        assertEq(oracle.price(asset), 300e18);
        (bool ok, uint256 value) = oracle.tryPrice(asset);
        assertTrue(ok);
        assertEq(value, 300e18);
        IFundOracle.Feed memory f = oracle.feedOf(asset);
        assertEq(f.aggregator, address(feed8));
        assertEq(f.maxStaleness, 1 hours);
    }

    function test_setFeed_aggregatorWithoutDecimals_reverts() public {
        vm.prank(admin);
        vm.expectRevert();
        oracle.setFeed(asset, makeAddr("notAnAggregator"), 1 hours);
    }

    function test_setFeed_clear() public {
        vm.prank(admin);
        oracle.setFeed(asset, address(0), 0);
        assertFalse(oracle.hasFeed(asset));
    }

    function test_setFeed_zeroStaleness_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IFundOracle.InvalidStaleness.selector);
        oracle.setFeed(asset, address(feed8), 0);
    }

    function test_setFeed_notAdmin_reverts() public {
        vm.expectRevert(IFundOracle.NotAdmin.selector);
        oracle.setFeed(asset, address(feed8), 1);
    }

    function test_setFeed_followsRegistryAdmin() public {
        address next = makeAddr("next");
        vm.startPrank(admin);
        registry.grantRole(keccak256("FUND_ADMIN"), next);
        registry.revokeRole(keccak256("FUND_ADMIN"), admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(IFundOracle.NotAdmin.selector);
        oracle.setFeed(asset, address(feed8), 1);
        vm.prank(next);
        oracle.setFeed(asset, address(feed8), 1);
        assertEq(oracle.feedOf(asset).maxStaleness, 1);
        assertEq(oracle.registry(), address(registry));
    }

    // ──────────────────────────────────────────────────────────
    //  Verifier feeds
    // ──────────────────────────────────────────────────────────

    function _verifierFeed() internal returns (MockOracleVerifier v) {
        v = new MockOracleVerifier();
        vm.startPrank(admin);
        registry.setAddress(registry.INHOUSE_ORACLE(), address(v));
        oracle.setVerifierFeed(asset, bytes32("TSLA"), 2 hours);
        vm.stopPrank();
    }

    function test_verifierFeed_readsTheVerifier() public {
        MockOracleVerifier v = _verifierFeed();
        v.setPrice(bytes32("TSLA"), 250e18, block.timestamp - 1 hours);
        assertEq(oracle.price(asset), 250e18);
        (bool ok, uint256 value) = oracle.tryPrice(asset);
        assertTrue(ok);
        assertEq(value, 250e18);
        assertTrue(oracle.hasFeed(asset));
        IFundOracle.Feed memory f = oracle.feedOf(asset);
        assertEq(f.aggregator, address(0));
        assertEq(f.ticker, bytes32("TSLA"));
        assertEq(f.maxStaleness, 2 hours);
    }

    function test_verifierFeed_stale_reverts() public {
        MockOracleVerifier v = _verifierFeed();
        v.setPrice(bytes32("TSLA"), 250e18, block.timestamp - 2 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(IFundOracle.StalePrice.selector, asset));
        oracle.price(asset);
        (bool ok,) = oracle.tryPrice(asset);
        assertFalse(ok);
    }

    function test_verifierFeed_verifierReverts_tryPriceFalse() public {
        MockOracleVerifier v = _verifierFeed();
        v.setForceStale(true);
        vm.expectRevert();
        oracle.price(asset);
        (bool ok, uint256 value) = oracle.tryPrice(asset);
        assertFalse(ok);
        assertEq(value, 0);
    }

    function test_verifierFeed_noVerifier_tryPriceFalse() public {
        vm.prank(admin);
        oracle.setVerifierFeed(asset, bytes32("TSLA"), 2 hours);
        (bool ok,) = oracle.tryPrice(asset);
        assertFalse(ok);
    }

    function test_verifierFeed_followsTheRegistry() public {
        MockOracleVerifier v = _verifierFeed();
        v.setPrice(bytes32("TSLA"), 250e18, block.timestamp);
        MockOracleVerifier v2 = new MockOracleVerifier();
        v2.setPrice(bytes32("TSLA"), 260e18, block.timestamp);
        vm.startPrank(admin);
        registry.setAddress(registry.INHOUSE_ORACLE(), address(v2));
        vm.stopPrank();
        assertEq(oracle.price(asset), 260e18);
    }

    function test_setFeed_replacesVerifierFeed() public {
        _verifierFeed();
        vm.prank(admin);
        oracle.setFeed(asset, address(feed8), 1 hours);
        assertEq(oracle.price(asset), 300e18);
        assertEq(oracle.feedOf(asset).ticker, bytes32(0));
    }

    function test_setVerifierFeed_invalid_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(IFundOracle.InvalidTicker.selector);
        oracle.setVerifierFeed(asset, bytes32(0), 1 hours);
        vm.expectRevert(IFundOracle.InvalidStaleness.selector);
        oracle.setVerifierFeed(asset, bytes32("TSLA"), 0);
        vm.expectRevert(IFundOracle.ZeroAddress.selector);
        oracle.setVerifierFeed(address(0), bytes32("TSLA"), 1 hours);
        vm.stopPrank();
        vm.expectRevert(IFundOracle.NotAdmin.selector);
        oracle.setVerifierFeed(asset, bytes32("TSLA"), 1 hours);
    }

    function test_constructor_zeroRegistry_reverts() public {
        vm.expectRevert(IFundOracle.ZeroAddress.selector);
        new FundOracle(address(0));
    }
}
