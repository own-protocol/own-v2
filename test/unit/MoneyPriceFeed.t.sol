// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMoneyPriceFeed} from "../../src/interfaces/IMoneyPriceFeed.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {ChainlinkOracleVerifier} from "../../src/oracle/ChainlinkOracleVerifier.sol";
import {MoneyPriceFeed} from "../../src/oracle/MoneyPriceFeed.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

contract MoneyPriceFeedTest is BaseTest {
    MoneyPriceFeed public feed;

    address internal keeper = address(uint160(uint256(keccak256("moneyKeeper"))));

    bytes32 constant MONEY = bytes32("MONEY");
    uint32 constant CL_SILENCE = 900;
    uint32 constant CL_FRESH_WINDOW = 3600; // 1h — TWAP marks are pushed continuously
    uint32 constant MAX_ANCHOR_AGE = 86_400; // 1 day

    function setUp() public override {
        super.setUp();
        vm.warp(10_000_000);
        feed = new MoneyPriceFeed(address(protocolRegistry), keeper);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsRegistryAndKeeper() public view {
        assertEq(address(feed.registry()), address(protocolRegistry));
        assertEq(feed.keeper(), keeper);
        assertEq(feed.decimals(), 18);
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(IMoneyPriceFeed.ZeroAddress.selector);
        new MoneyPriceFeed(address(0), keeper);
    }

    function test_constructor_revertsOnZeroKeeper() public {
        vm.expectRevert(IMoneyPriceFeed.ZeroAddress.selector);
        new MoneyPriceFeed(address(protocolRegistry), address(0));
    }

    function test_initialRoundData_isEmpty() public view {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(roundId, 0);
        assertEq(answer, 0);
        assertEq(updatedAt, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  pushPrice
    // ──────────────────────────────────────────────────────────

    function test_pushPrice_storesMarkAndTimestamp() public {
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit IMoneyPriceFeed.PricePushed(1, 0.42e18);
        feed.pushPrice(0.42e18);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 0.42e18);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function test_pushPrice_incrementsRound() public {
        vm.startPrank(keeper);
        feed.pushPrice(1e18);
        vm.warp(block.timestamp + 60);
        feed.pushPrice(2e18);
        vm.stopPrank();

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answer, 2e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_pushPrice_revertsForNonKeeper() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IMoneyPriceFeed.OnlyKeeper.selector);
        feed.pushPrice(1e18);

        // ADMIN configures; it does not push.
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IMoneyPriceFeed.OnlyKeeper.selector);
        feed.pushPrice(1e18);
    }

    function test_pushPrice_revertsOnZeroPrice() public {
        vm.prank(keeper);
        vm.expectRevert(IMoneyPriceFeed.InvalidPrice.selector);
        feed.pushPrice(0);
    }

    function test_pushPrice_revertsAboveInt256Max() public {
        vm.prank(keeper);
        vm.expectRevert(IMoneyPriceFeed.InvalidPrice.selector);
        feed.pushPrice(uint256(type(int256).max) + 1);
    }

    // ──────────────────────────────────────────────────────────
    //  setKeeper
    // ──────────────────────────────────────────────────────────

    function test_setKeeper_rotates() public {
        address newKeeper = address(uint160(uint256(keccak256("newKeeper"))));

        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, false, false, true);
        emit IMoneyPriceFeed.KeeperSet(newKeeper);
        feed.setKeeper(newKeeper);
        assertEq(feed.keeper(), newKeeper);

        vm.prank(newKeeper);
        feed.pushPrice(1e18);

        vm.prank(keeper);
        vm.expectRevert(IMoneyPriceFeed.OnlyKeeper.selector);
        feed.pushPrice(1e18);
    }

    function test_setKeeper_revertsForNonAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IMoneyPriceFeed.OnlyAdmin.selector);
        feed.setKeeper(Actors.ATTACKER);
    }

    function test_setKeeper_revertsOnZeroAddress() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IMoneyPriceFeed.ZeroAddress.selector);
        feed.setKeeper(address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Wired into ChainlinkOracleVerifier as the MONEY aggregator
    // ──────────────────────────────────────────────────────────

    uint256 internal constant SIGNER_PK = 0xBEEF;

    function _wiredVerifier() internal returns (ChainlinkOracleVerifier verifier) {
        vm.startPrank(Actors.ADMIN);
        verifier = new ChainlinkOracleVerifier(address(protocolRegistry));
        verifier.addSigner(vm.addr(SIGNER_PK));
        // bandBps = 0: the in-house signer leg is disabled — the pushed mark is the only source.
        verifier.setChainlinkConfig(MONEY, address(feed), address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, 0, 0);
        vm.stopPrank();
    }

    function test_verifier_readsPushedMark() public {
        ChainlinkOracleVerifier verifier = _wiredVerifier();

        vm.prank(keeper);
        feed.pushPrice(0.42e18);

        // Fresh (within clFreshWindow): 18-dec passthrough, timestamp reported as now.
        vm.warp(block.timestamp + CL_FRESH_WINDOW / 2);
        (uint256 price, uint256 timestamp) = verifier.getPrice(MONEY);
        assertEq(price, 0.42e18);
        assertEq(timestamp, block.timestamp);
    }

    function test_verifier_reportsRawTimestampBeyondFreshWindow() public {
        ChainlinkOracleVerifier verifier = _wiredVerifier();

        vm.prank(keeper);
        feed.pushPrice(0.42e18);
        uint256 pushedAt = block.timestamp;

        vm.warp(pushedAt + CL_FRESH_WINDOW + 1);
        (uint256 price, uint256 timestamp) = verifier.getPrice(MONEY);
        assertEq(price, 0.42e18);
        assertEq(timestamp, pushedAt);
    }

    function test_verifier_revertsBeforeFirstPush() public {
        ChainlinkOracleVerifier verifier = _wiredVerifier();
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.PriceNotAvailable.selector, MONEY));
        verifier.getPrice(MONEY);
    }

    function test_verifier_revertsBeyondMaxAnchorAge() public {
        ChainlinkOracleVerifier verifier = _wiredVerifier();

        vm.prank(keeper);
        feed.pushPrice(0.42e18);

        vm.warp(block.timestamp + MAX_ANCHOR_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.PriceNotAvailable.selector, MONEY));
        verifier.getPrice(MONEY);
    }

    function test_verifier_inhouseLegDisabled() public {
        ChainlinkOracleVerifier verifier = _wiredVerifier();

        // Even a validly-signed in-house price is rejected: bandBps = 0 keeps the pushed mark
        // as the only source for MONEY.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, verifier.priceDigest(MONEY, 0.42e18, block.timestamp));
        bytes memory priceData = abi.encode(uint256(0.42e18), block.timestamp, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleVerifier.InhouseDisabled.selector, MONEY));
        verifier.updatePrice(MONEY, priceData);
    }
}
