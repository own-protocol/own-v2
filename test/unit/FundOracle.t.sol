// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundOracle} from "../../src/funds/FundOracle.sol";
import {IFundOracle} from "../../src/interfaces/IFundOracle.sol";
import {Actors} from "../helpers/Actors.sol";
import {MockAggregatorV3} from "../helpers/MockAggregatorV3.sol";
import {Test} from "forge-std/Test.sol";

contract FundOracleTest is Test {
    FundOracle internal oracle;
    MockAggregatorV3 internal feed8;
    MockAggregatorV3 internal feed20;
    address internal admin = Actors.ADMIN;
    address internal asset = makeAddr("asset");
    address internal asset2 = makeAddr("asset2");

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new FundOracle(admin);
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

    function test_setFeed_notOwner_reverts() public {
        vm.expectRevert(IFundOracle.NotOwner.selector);
        oracle.setFeed(asset, address(feed8), 1);
    }

    function test_ownership_twoStep() public {
        address next = makeAddr("next");
        vm.prank(admin);
        oracle.transferOwnership(next);
        vm.expectRevert(IFundOracle.NotPendingOwner.selector);
        oracle.acceptOwnership();
        vm.prank(next);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), next);
    }
}
