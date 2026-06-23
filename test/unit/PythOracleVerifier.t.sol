// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PythOracleVerifier} from "../../src/core/PythOracleVerifier.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {PRECISION} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockPyth} from "../helpers/MockPyth.sol";
import {PythStructs} from "@pythnetwork/PythStructs.sol";

contract PythOracleVerifierTest is BaseTest {
    PythOracleVerifier public verifier;
    MockPyth public mockPyth;

    bytes32 constant TSLA_FEED_ID = bytes32(uint256(1));
    bytes32 constant GOLD_FEED_ID = bytes32(uint256(2));
    uint256 constant MAX_PRICE_AGE = 120; // 2 minutes
    uint256 constant MAX_CONF_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);

        mockPyth = new MockPyth();
        vm.label(address(mockPyth), "MockPyth");

        vm.startPrank(Actors.ADMIN);
        verifier = new PythOracleVerifier(address(protocolRegistry), address(mockPyth), MAX_PRICE_AGE, MAX_CONF_BPS);
        verifier.setFeedId(TSLA, 0, TSLA_FEED_ID);
        verifier.setFeedId(GOLD, 0, GOLD_FEED_ID);
        vm.stopPrank();

        vm.label(address(verifier), "PythOracleVerifier");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Set a price in the mock Pyth with given expo.
    function _setPythPrice(bytes32 feedId, int64 price, int32 expo) internal {
        mockPyth.setPrice(feedId, price, expo, block.timestamp);
    }

    /// @dev Encode a single feed update for updatePriceFeeds / parsePriceFeedUpdates.
    function _encodeFeedUpdate(
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint256 publishTime
    ) internal pure returns (bytes memory) {
        return abi.encode(feedId, price, expo, publishTime);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(verifier.pyth()), address(mockPyth));
        assertEq(verifier.maxPriceAge(), MAX_PRICE_AGE);
        assertEq(verifier.maxConfBps(), MAX_CONF_BPS);
    }

    function test_constructor_zeroMaxConfBps_reverts() public {
        vm.expectRevert(PythOracleVerifier.InvalidMaxConfBps.selector);
        new PythOracleVerifier(address(protocolRegistry), address(mockPyth), MAX_PRICE_AGE, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin: setFeedId
    // ──────────────────────────────────────────────────────────

    function test_setFeedId_succeeds() public {
        bytes32 newFeedId = bytes32(uint256(99));
        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, false, false, true);
        emit PythOracleVerifier.FeedIdSet(TSLA, 0, newFeedId);
        verifier.setFeedId(TSLA, 0, newFeedId);

        assertEq(verifier.getFeedId(TSLA, 0), newFeedId);
    }

    function test_setFeedId_notOwner_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.setFeedId(TSLA, 0, bytes32(uint256(99)));
    }

    // ──────────────────────────────────────────────────────────
    //  Admin: setMaxPriceAge
    // ──────────────────────────────────────────────────────────

    function test_setMaxPriceAge_succeeds() public {
        vm.prank(Actors.ADMIN);
        vm.expectEmit(false, false, false, true);
        emit PythOracleVerifier.MaxPriceAgeUpdated(MAX_PRICE_AGE, 300);
        verifier.setMaxPriceAge(300);

        assertEq(verifier.maxPriceAge(), 300);
    }

    function test_setMaxPriceAge_notOwner_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.setMaxPriceAge(300);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin: setMaxConfBps
    // ──────────────────────────────────────────────────────────

    function test_setMaxConfBps_succeeds() public {
        vm.prank(Actors.ADMIN);
        vm.expectEmit(false, false, false, true);
        emit PythOracleVerifier.MaxConfBpsUpdated(MAX_CONF_BPS, 200);
        verifier.setMaxConfBps(200);

        assertEq(verifier.maxConfBps(), 200);
    }

    function test_setMaxConfBps_zero_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(PythOracleVerifier.InvalidMaxConfBps.selector);
        verifier.setMaxConfBps(0);
    }

    function test_setMaxConfBps_notOwner_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.setMaxConfBps(200);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin: no-op signer methods
    // ──────────────────────────────────────────────────────────

    function test_addSigner_reverts() public {
        vm.expectRevert("PythOracle: no signers");
        verifier.addSigner(Actors.ADMIN);
    }

    function test_removeSigner_reverts() public {
        vm.expectRevert("PythOracle: no signers");
        verifier.removeSigner(Actors.ADMIN);
    }

    function test_isSigner_returnsFalse() public view {
        assertFalse(verifier.isSigner(Actors.ADMIN));
    }

    function test_setAssetOracleConfig_reverts() public {
        vm.expectRevert("PythOracle: use setFeedId/setMaxPriceAge");
        verifier.setAssetOracleConfig(TSLA, 0, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  getPrice: normal flow
    // ──────────────────────────────────────────────────────────

    function test_getPrice_typicalExponent_neg8() public {
        // TSLA at $250.00 with expo=-8 → rawPrice=25000000000
        _setPythPrice(TSLA_FEED_ID, 25_000_000_000, -8);

        (uint256 price, uint256 ts) = verifier.getPrice(TSLA);

        // Normalized: 25_000_000_000 * 10^(18-8) = 25_000_000_000 * 10^10 = 250e18
        assertEq(price, 250e18);
        assertEq(ts, block.timestamp);
    }

    function test_getPrice_exponent_neg6() public {
        // GOLD at $2000.50 with expo=-6 → rawPrice=2000500000
        _setPythPrice(GOLD_FEED_ID, 2_000_500_000, -6);

        (uint256 price,) = verifier.getPrice(GOLD);

        // Normalized: 2_000_500_000 * 10^(18-6) = 2_000_500_000 * 10^12 = 2000.5e18
        assertEq(price, 2_000_500_000 * 1e12);
    }

    function test_getPrice_exponent_neg18() public {
        // Edge case: expo=-18 → multiplier is 10^0 = 1
        _setPythPrice(TSLA_FEED_ID, 100, -18);

        (uint256 price,) = verifier.getPrice(TSLA);
        assertEq(price, 100);
    }

    function test_getPrice_exponent_zero() public {
        // expo=0 → rawPrice * 10^18
        _setPythPrice(TSLA_FEED_ID, 250, 0);

        (uint256 price,) = verifier.getPrice(TSLA);
        assertEq(price, 250e18);
    }

    function test_getPrice_exponent_positive() public {
        // expo=2 → rawPrice * 10^(18+2) = rawPrice * 10^20
        _setPythPrice(TSLA_FEED_ID, 3, 2);

        (uint256 price,) = verifier.getPrice(TSLA);
        assertEq(price, 3 * 10 ** 20);
    }

    function test_getPrice_exponent_neg20_truncates() public {
        // expo=-20, absExpo > 18 → division path: rawPrice / 10^(20-18) = rawPrice / 100
        _setPythPrice(TSLA_FEED_ID, 25_000, -20);

        (uint256 price,) = verifier.getPrice(TSLA);
        // 25_000 / 100 = 250
        assertEq(price, 250);
    }

    // ──────────────────────────────────────────────────────────
    //  getPrice: error cases
    // ──────────────────────────────────────────────────────────

    function test_getPrice_feedNotConfigured_reverts() public {
        bytes32 unknownAsset = bytes32("UNKNOWN");
        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.FeedNotConfigured.selector, unknownAsset));
        verifier.getPrice(unknownAsset);
    }

    function test_getPrice_negativePrice_reverts() public {
        _setPythPrice(TSLA_FEED_ID, -100, -8);

        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.NegativePrice.selector, TSLA, int64(-100)));
        verifier.getPrice(TSLA);
    }

    function test_getPrice_zeroPrice_reverts() public {
        _setPythPrice(TSLA_FEED_ID, 0, -8);

        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.NegativePrice.selector, TSLA, int64(0)));
        verifier.getPrice(TSLA);
    }

    function test_getPrice_stalePrice_reverts() public {
        // Set price in the past beyond maxPriceAge
        mockPyth.setPrice(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp - MAX_PRICE_AGE - 1);

        vm.expectRevert(); // MockPyth enforces age check
        verifier.getPrice(TSLA);
    }

    // ──────────────────────────────────────────────────────────
    //  Confidence interval (M-01)
    // ──────────────────────────────────────────────────────────

    function test_getPrice_wideConfidence_reverts() public {
        // TSLA $250, conf ±$5 (2%) — wider than the 1% bound.
        mockPyth.setPriceWithConf(TSLA_FEED_ID, 25_000_000_000, 500_000_000, -8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracleVerifier.ConfidenceTooWide.selector, TSLA, 500_000_000, 25_000_000_000, MAX_CONF_BPS
            )
        );
        verifier.getPrice(TSLA);
    }

    function test_getPrice_confidenceAtBound_succeeds() public {
        // conf exactly 1% of price passes (strict-greater check).
        mockPyth.setPriceWithConf(TSLA_FEED_ID, 25_000_000_000, 250_000_000, -8, block.timestamp);

        (uint256 price,) = verifier.getPrice(TSLA);
        assertEq(price, 250e18);
    }

    function test_verifyPrice_wideConfidence_reverts() public {
        mockPyth.setParseConf(500_000_000); // ±2% on a $250 price
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp);
        bytes memory priceData = abi.encode(updates, uint64(block.timestamp - 60), uint64(block.timestamp + 60));

        vm.expectRevert(
            abi.encodeWithSelector(
                PythOracleVerifier.ConfidenceTooWide.selector, TSLA, 500_000_000, 25_000_000_000, MAX_CONF_BPS
            )
        );
        verifier.verifyPrice{value: 1}(TSLA, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  updatePriceFeeds
    // ──────────────────────────────────────────────────────────

    function test_updatePriceFeeds_succeeds() public {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp);
        bytes memory updateData = abi.encode(updates);

        verifier.updatePriceFeeds{value: 1}(updateData);

        (uint256 price,) = verifier.getPrice(TSLA);
        assertEq(price, 250e18);
    }

    function test_updatePriceFeeds_multipleFeeds() public {
        bytes[] memory updates = new bytes[](2);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp);
        updates[1] = _encodeFeedUpdate(GOLD_FEED_ID, 2_000_000_000, -6, block.timestamp);
        bytes memory updateData = abi.encode(updates);

        verifier.updatePriceFeeds{value: 2}(updateData);

        (uint256 tslaPrice,) = verifier.getPrice(TSLA);
        (uint256 goldPrice,) = verifier.getPrice(GOLD);
        assertEq(tslaPrice, 250e18);
        assertEq(goldPrice, 2_000_000_000 * 1e12);
    }

    function test_updatePriceFeeds_insufficientFee_reverts() public {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp);
        bytes memory updateData = abi.encode(updates);

        vm.expectRevert(); // MockPyth: insufficient fee
        verifier.updatePriceFeeds{value: 0}(updateData);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice (inline proof for force execution)
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_succeeds() public {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp);
        uint64 minTime = uint64(block.timestamp - 60);
        uint64 maxTime = uint64(block.timestamp + 60);

        bytes memory priceData = abi.encode(updates, minTime, maxTime);

        (uint256 price, uint256 ts) = verifier.verifyPrice{value: 1}(TSLA, priceData);
        assertEq(price, 250e18);
        assertEq(ts, block.timestamp);
    }

    function test_verifyPrice_feedNotConfigured_reverts() public {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(bytes32(uint256(999)), 100, -8, block.timestamp);
        bytes memory priceData = abi.encode(updates, uint64(block.timestamp - 60), uint64(block.timestamp + 60));

        bytes32 unknownAsset = bytes32("UNKNOWN");
        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.FeedNotConfigured.selector, unknownAsset));
        verifier.verifyPrice{value: 1}(unknownAsset, priceData);
    }

    function test_verifyPrice_negativePrice_reverts() public {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, -100, -8, block.timestamp);
        bytes memory priceData = abi.encode(updates, uint64(block.timestamp - 60), uint64(block.timestamp + 60));

        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.NegativePrice.selector, TSLA, int64(-100)));
        verifier.verifyPrice{value: 1}(TSLA, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyFee
    // ──────────────────────────────────────────────────────────

    function test_verifyFee_returnsCorrectFee() public view {
        bytes[] memory updates = new bytes[](3);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 100, -8, block.timestamp);
        updates[1] = _encodeFeedUpdate(GOLD_FEED_ID, 200, -8, block.timestamp);
        updates[2] = _encodeFeedUpdate(TSLA_FEED_ID, 300, -8, block.timestamp);
        bytes memory priceData = abi.encode(updates, uint64(0), uint64(0));

        uint256 fee = verifier.verifyFee(priceData);
        assertEq(fee, 3); // 1 wei per feed * 3 feeds
    }

    // ──────────────────────────────────────────────────────────
    //  getFeedId
    // ──────────────────────────────────────────────────────────

    function test_getFeedId_returnsConfigured() public view {
        assertEq(verifier.getFeedId(TSLA, 0), TSLA_FEED_ID);
        assertEq(verifier.getFeedId(GOLD, 0), GOLD_FEED_ID);
    }

    function test_getFeedId_unconfigured_returnsZero() public view {
        assertEq(verifier.getFeedId(bytes32("UNKNOWN"), 0), bytes32(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Normalization edge cases (via getPrice)
    // ──────────────────────────────────────────────────────────

    function test_normalization_maxInt64Price() public {
        // Max int64 positive = 9_223_372_036_854_775_807
        int64 maxPrice = type(int64).max;
        _setPythPrice(TSLA_FEED_ID, maxPrice, -18);

        (uint256 price,) = verifier.getPrice(TSLA);
        // expo=-18, multiplier=1 → price = uint64(maxPrice)
        assertEq(price, uint256(uint64(maxPrice)));
    }

    function test_normalization_smallPrice_largeNegativeExpo_truncates() public {
        // rawPrice=1, expo=-20 → 1 / 10^2 = 0 (truncates)
        _setPythPrice(TSLA_FEED_ID, 1, -20);

        (uint256 price,) = verifier.getPrice(TSLA);
        assertEq(price, 0); // Truncated to zero
    }

    function testFuzz_normalization_typicalRange(uint64 rawPrice, uint8 absExpo) public {
        // Bound to realistic ranges
        rawPrice = uint64(bound(rawPrice, 1, 1_000_000_000_000)); // positive prices
        absExpo = uint8(bound(absExpo, 0, 18)); // typical Pyth exponents (negative)
        int32 expo = -int32(int8(absExpo));
        int64 signedPrice = int64(rawPrice);

        _setPythPrice(TSLA_FEED_ID, signedPrice, expo);

        (uint256 price,) = verifier.getPrice(TSLA);

        // Price should be positive
        assertGt(price, 0);

        // Verify the math: rawPrice * 10^(18 - absExpo)
        uint256 expected = uint256(rawPrice) * (10 ** (18 - uint256(absExpo)));
        assertEq(price, expected);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor + session / disable / config branch coverage
    // ──────────────────────────────────────────────────────────

    function test_constructor_zeroRegistry_reverts() public {
        vm.expectRevert(IOracleVerifier.ZeroAddress.selector);
        new PythOracleVerifier(address(0), address(mockPyth), MAX_PRICE_AGE, MAX_CONF_BPS);
    }

    function test_setFeedId_invalidSession_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.InvalidSessionId.selector, uint8(4)));
        verifier.setFeedId(TSLA, 4, bytes32(uint256(99)));
    }

    function test_verifyPriceForSession_validSession_succeeds() public {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp);
        bytes memory priceData = abi.encode(updates, uint64(block.timestamp - 60), uint64(block.timestamp + 60));

        (uint256 price, uint256 ts) = verifier.verifyPriceForSession{value: 1}(TSLA, priceData, 0);
        assertEq(price, 250e18);
        assertEq(ts, block.timestamp);
    }

    function test_verifyPriceForSession_invalidSession_reverts() public {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _encodeFeedUpdate(TSLA_FEED_ID, 25_000_000_000, -8, block.timestamp);
        bytes memory priceData = abi.encode(updates, uint64(block.timestamp - 60), uint64(block.timestamp + 60));

        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.InvalidSessionId.selector, uint8(4)));
        verifier.verifyPriceForSession{value: 1}(TSLA, priceData, 4);
    }

    function test_getAssetOracleConfig_reverts() public {
        vm.expectRevert("PythOracle: use getFeedId/maxPriceAge");
        verifier.getAssetOracleConfig(TSLA);
    }

    /// @dev Emergency kill-switch: operator clears all session feeds; reads then revert FeedNotConfigured.
    function test_disableFeed_operator_succeeds() public {
        vm.prank(Actors.ADMIN); // ADMIN also holds the OPERATOR role in the test bootstrap
        vm.expectEmit(true, false, false, false);
        emit PythOracleVerifier.FeedDisabled(TSLA);
        verifier.disableFeed(TSLA);

        vm.expectRevert(abi.encodeWithSelector(PythOracleVerifier.FeedNotConfigured.selector, TSLA));
        verifier.getPrice(TSLA);
    }

    function test_disableFeed_nonOperator_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.disableFeed(TSLA);
    }
}
