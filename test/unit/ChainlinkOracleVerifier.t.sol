// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainlinkOracleVerifier} from "../../src/core/ChainlinkOracleVerifier.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAggregatorV3, MockScaledUiToken} from "../helpers/MockAggregatorV3.sol";

contract ChainlinkOracleVerifierTest is BaseTest {
    ChainlinkOracleVerifier public verifier;
    MockAggregatorV3 public feed;
    MockScaledUiToken public token;

    uint256 internal constant SIGNER_PK = 0xBEEF;
    address internal signer;

    bytes32 constant ASSET = bytes32("TSLA");
    uint32 constant CL_SILENCE = 900; // 15 min
    uint32 constant CL_FRESH_WINDOW = 14_400; // 4h — beyond this, reads report the raw timestamp
    uint32 constant MAX_ANCHOR_AGE = 432_000; // 5 days
    uint32 constant INHOUSE_MAX_STALENESS = 3600; // 1h
    uint16 constant BAND_BPS = 500; // 5%

    int256 constant CL_ANSWER = 380e8; // $380, 8 decimals
    uint256 constant CL_PRICE_18 = 380e18;

    function setUp() public override {
        super.setUp();
        vm.warp(10_000_000);

        signer = vm.addr(SIGNER_PK);
        feed = new MockAggregatorV3(8);
        token = new MockScaledUiToken();
        feed.setAnswer(CL_ANSWER, block.timestamp);

        vm.startPrank(Actors.ADMIN);
        verifier = new ChainlinkOracleVerifier(address(protocolRegistry));
        verifier.addSigner(signer);
        verifier.setChainlinkConfig(
            ASSET,
            address(feed),
            address(0),
            CL_SILENCE,
            CL_FRESH_WINDOW,
            MAX_ANCHOR_AGE,
            INHOUSE_MAX_STALENESS,
            BAND_BPS
        );
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    bytes32 internal constant PRICE_ATTESTATION_TYPEHASH =
        keccak256("PriceAttestation(bytes32 asset,uint256 price,uint256 timestamp)");

    function _signPrice(bytes32 asset, uint256 price, uint256 timestamp) internal view returns (bytes memory) {
        bytes32 digest = verifier.priceDigest(asset, price, timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encode(price, timestamp, v, r, s);
    }

    /// @dev Age the Chainlink answer by `age` seconds (warp forward, answer unchanged).
    function _ageChainlink(
        uint256 age
    ) internal {
        vm.warp(block.timestamp + age);
    }

    // ──────────────────────────────────────────────────────────
    //  getPrice — Chainlink leg
    // ──────────────────────────────────────────────────────────

    function test_getPrice_clFresh_returnsClampedTimestamp() public {
        _ageChainlink(60);
        (uint256 price, uint256 ts) = verifier.getPrice(ASSET);
        assertEq(price, CL_PRICE_18);
        assertEq(ts, block.timestamp);
    }

    function test_getPrice_clWithinFreshWindow_returnsClampedTimestamp() public {
        _ageChainlink(3 hours);
        (uint256 price, uint256 ts) = verifier.getPrice(ASSET);
        assertEq(price, CL_PRICE_18);
        assertEq(ts, block.timestamp);
    }

    function test_getPrice_clBeyondFreshWindow_returnsRawTimestamp() public {
        uint256 updated = block.timestamp;
        _ageChainlink(30 hours);
        (uint256 price, uint256 ts) = verifier.getPrice(ASSET);
        assertEq(price, CL_PRICE_18);
        assertEq(ts, updated);
    }

    function test_getPrice_clDeadAndNoInhouse_reverts() public {
        _ageChainlink(MAX_ANCHOR_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.PriceNotAvailable.selector, ASSET));
        verifier.getPrice(ASSET);
    }

    function test_getPrice_noConfig_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.OracleConfigNotSet.selector, bytes32("NOPE")));
        verifier.getPrice(bytes32("NOPE"));
    }

    function test_getPrice_multiplierDividesFeed() public {
        vm.prank(Actors.ADMIN);
        verifier.setChainlinkConfig(
            ASSET,
            address(feed),
            address(token),
            CL_SILENCE,
            CL_FRESH_WINDOW,
            MAX_ANCHOR_AGE,
            INHOUSE_MAX_STALENESS,
            BAND_BPS
        );
        token.setUiMultiplier(2e18); // post 2:1 split: token price = 2x share price
        (uint256 price,) = verifier.getPrice(ASSET);
        assertEq(price, CL_PRICE_18 / 2);
    }

    // ──────────────────────────────────────────────────────────
    //  getPrice — in-house leg
    // ──────────────────────────────────────────────────────────

    function test_getPrice_inhouseWinsWhenNewerThanCl() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 pushPrice = CL_PRICE_18 * 102 / 100; // +2%, within 5% band
        verifier.updatePrice(ASSET, _signPrice(ASSET, pushPrice, block.timestamp));

        (uint256 price, uint256 ts) = verifier.getPrice(ASSET);
        assertEq(price, pushPrice);
        assertEq(ts, block.timestamp);
    }

    function test_getPrice_clWinsWhenNewerThanInhouse() public {
        _ageChainlink(CL_SILENCE + 1);
        verifier.updatePrice(ASSET, _signPrice(ASSET, CL_PRICE_18, block.timestamp));

        // Feed comes back with a newer answer (e.g. Monday open).
        vm.warp(block.timestamp + 60);
        feed.setAnswer(CL_ANSWER + 1e8, block.timestamp);

        (uint256 price, uint256 ts) = verifier.getPrice(ASSET);
        assertEq(price, 381e18);
        assertEq(ts, block.timestamp);
    }

    function test_getPrice_inhouseStaleAndClDead_revertsStale() public {
        _ageChainlink(CL_SILENCE + 1);
        verifier.updatePrice(ASSET, _signPrice(ASSET, CL_PRICE_18, block.timestamp));

        vm.warp(block.timestamp + MAX_ANCHOR_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.StalePrice.selector,
                ASSET,
                block.timestamp - MAX_ANCHOR_AGE - 1,
                uint256(INHOUSE_MAX_STALENESS)
            )
        );
        verifier.getPrice(ASSET);
    }

    // ──────────────────────────────────────────────────────────
    //  updatePrice — gates
    // ──────────────────────────────────────────────────────────

    function test_updatePrice_clSilent_withinBand_succeeds() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 pushPrice = CL_PRICE_18 * 104 / 100;

        vm.expectEmit(true, false, false, true);
        emit IOracleVerifier.PriceUpdated(ASSET, pushPrice, block.timestamp);
        verifier.updatePrice(ASSET, _signPrice(ASSET, pushPrice, block.timestamp));

        (uint256 price, uint256 ts) = verifier.getInhousePrice(ASSET);
        assertEq(price, pushPrice);
        assertEq(ts, block.timestamp);
    }

    function test_updatePrice_clFresh_reverts() public {
        uint256 updated = block.timestamp;
        _ageChainlink(CL_SILENCE); // exactly at threshold — still "fresh" (gate is strict >)
        bytes memory data = _signPrice(ASSET, CL_PRICE_18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleVerifier.ChainlinkFresh.selector, ASSET, updated));
        verifier.updatePrice(ASSET, data);
    }

    function test_updatePrice_bandExceeded_reverts() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 pushPrice = CL_PRICE_18 * 106 / 100; // +6% > 5% band
        bytes memory data = _signPrice(ASSET, pushPrice, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.PriceDeviationExceeded.selector, ASSET, pushPrice, CL_PRICE_18, uint256(BAND_BPS)
            )
        );
        verifier.updatePrice(ASSET, data);
    }

    function test_updatePrice_clDead_revertsNoAnchor() public {
        _ageChainlink(MAX_ANCHOR_AGE + 1);
        bytes memory data = _signPrice(ASSET, CL_PRICE_18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleVerifier.NoAnchor.selector, ASSET));
        verifier.updatePrice(ASSET, data);
    }

    function test_updatePrice_inhouseDisabled_reverts() public {
        vm.prank(Actors.ADMIN);
        verifier.setChainlinkConfig(
            ASSET, address(feed), address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, INHOUSE_MAX_STALENESS, 0
        );
        _ageChainlink(CL_SILENCE + 1);
        bytes memory data = _signPrice(ASSET, CL_PRICE_18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleVerifier.InhouseDisabled.selector, ASSET));
        verifier.updatePrice(ASSET, data);
    }

    function test_updatePrice_futureTimestamp_reverts() public {
        _ageChainlink(CL_SILENCE + 1);
        bytes memory data = _signPrice(ASSET, CL_PRICE_18, block.timestamp + 10);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracleVerifier.FutureTimestamp.selector, ASSET, block.timestamp + 10)
        );
        verifier.updatePrice(ASSET, data);
    }

    function test_updatePrice_staleTimestamp_reverts() public {
        _ageChainlink(CL_SILENCE + INHOUSE_MAX_STALENESS + 10);
        uint256 signedTs = block.timestamp - INHOUSE_MAX_STALENESS - 1;
        bytes memory data = _signPrice(ASSET, CL_PRICE_18, signedTs);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleVerifier.StalePrice.selector, ASSET, signedTs, uint256(INHOUSE_MAX_STALENESS))
        );
        verifier.updatePrice(ASSET, data);
    }

    function test_updatePrice_olderThanExisting_skipsSilently() public {
        _ageChainlink(CL_SILENCE + 100);
        uint256 firstTs = block.timestamp;
        verifier.updatePrice(ASSET, _signPrice(ASSET, CL_PRICE_18, firstTs));

        // Replay an older attestation — must not overwrite.
        uint256 newPrice = CL_PRICE_18 * 104 / 100;
        verifier.updatePrice(ASSET, _signPrice(ASSET, newPrice, firstTs - 50));

        (uint256 price,) = verifier.getInhousePrice(ASSET);
        assertEq(price, CL_PRICE_18);
    }

    function test_updatePrice_unauthorizedSigner_reverts() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 badPk = 0xBAD;
        bytes32 digest = verifier.priceDigest(ASSET, CL_PRICE_18, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badPk, digest);
        bytes memory data = abi.encode(CL_PRICE_18, block.timestamp, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnauthorizedSigner.selector, vm.addr(badPk)));
        verifier.updatePrice(ASSET, data);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_clFresh_ignoresProof() public {
        _ageChainlink(60);
        // Garbage proof must be ignored while Chainlink is fresh.
        (uint256 price, uint256 ts) = verifier.verifyPrice(ASSET, hex"deadbeef");
        assertEq(price, CL_PRICE_18);
        assertEq(ts, block.timestamp);
    }

    function test_verifyPrice_clSilent_validProof_succeeds() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 proofPrice = CL_PRICE_18 * 97 / 100; // -3%, within band
        uint256 proofTs = block.timestamp - 5;
        (uint256 price, uint256 ts) = verifier.verifyPrice(ASSET, _signPrice(ASSET, proofPrice, proofTs));
        assertEq(price, proofPrice);
        assertEq(ts, proofTs);
    }

    function test_verifyPrice_clSilent_proofOutOfBand_reverts() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 proofPrice = CL_PRICE_18 * 90 / 100; // -10% > 5% band
        bytes memory data = _signPrice(ASSET, proofPrice, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.PriceDeviationExceeded.selector, ASSET, proofPrice, CL_PRICE_18, uint256(BAND_BPS)
            )
        );
        verifier.verifyPrice(ASSET, data);
    }

    function test_verifyPrice_emptyProof_clWithinFreshWindow_succeeds() public {
        _ageChainlink(3 hours);
        (uint256 price, uint256 ts) = verifier.verifyPrice(ASSET, "");
        assertEq(price, CL_PRICE_18);
        assertEq(ts, block.timestamp);
    }

    function test_verifyPrice_emptyProof_clBeyondFreshWindow_reverts() public {
        _ageChainlink(uint256(CL_FRESH_WINDOW) + 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.PriceNotAvailable.selector, ASSET));
        verifier.verifyPrice(ASSET, "");
    }

    function test_verifyPriceForSession_delegates() public {
        _ageChainlink(60);
        (uint256 price,) = verifier.verifyPriceForSession(ASSET, "", 2);
        assertEq(price, CL_PRICE_18);
    }

    function test_verifyFee_isZero() public view {
        assertEq(verifier.verifyFee(hex"00"), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function test_setChainlinkConfig_invalidBounds_reverts() public {
        vm.startPrank(Actors.ADMIN);
        // clSilence == 0
        vm.expectRevert(ChainlinkOracleVerifier.InvalidConfig.selector);
        verifier.setChainlinkConfig(ASSET, address(feed), address(0), 0, 100, 200, 60, BAND_BPS);
        // freshWindow < silence
        vm.expectRevert(ChainlinkOracleVerifier.InvalidConfig.selector);
        verifier.setChainlinkConfig(ASSET, address(feed), address(0), 900, 800, 2000, 60, BAND_BPS);
        // anchorAge < freshWindow
        vm.expectRevert(ChainlinkOracleVerifier.InvalidConfig.selector);
        verifier.setChainlinkConfig(ASSET, address(feed), address(0), 900, 1800, 1000, 60, BAND_BPS);
        // band set but zero in-house staleness
        vm.expectRevert(ChainlinkOracleVerifier.InvalidConfig.selector);
        verifier.setChainlinkConfig(ASSET, address(feed), address(0), 900, 1800, 3600, 0, BAND_BPS);
        vm.stopPrank();
    }

    function test_setChainlinkConfig_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOracleVerifier.OnlyAdmin.selector);
        verifier.setChainlinkConfig(
            ASSET,
            address(feed),
            address(0),
            CL_SILENCE,
            CL_FRESH_WINDOW,
            MAX_ANCHOR_AGE,
            INHOUSE_MAX_STALENESS,
            BAND_BPS
        );
    }

    function test_disableAsset_clearsConfigAndPrice() public {
        _ageChainlink(CL_SILENCE + 1);
        verifier.updatePrice(ASSET, _signPrice(ASSET, CL_PRICE_18, block.timestamp));

        vm.prank(Actors.ADMIN);
        verifier.disableAsset(ASSET);

        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.OracleConfigNotSet.selector, ASSET));
        verifier.getPrice(ASSET);
        (uint256 price,) = verifier.getInhousePrice(ASSET);
        assertEq(price, 0);
    }

    function test_disableAsset_nonOperator_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IOracleVerifier.OnlyOperator.selector);
        verifier.disableAsset(ASSET);
    }

    function test_removeSigner_operator_succeeds() public {
        vm.prank(Actors.ADMIN); // holds OPERATOR in tests
        verifier.removeSigner(signer);
        assertFalse(verifier.isSigner(signer));

        _ageChainlink(CL_SILENCE + 1);
        bytes memory data = _signPrice(ASSET, CL_PRICE_18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnauthorizedSigner.selector, signer));
        verifier.updatePrice(ASSET, data);
    }

    function test_legacyConfigSetters_revert() public {
        vm.startPrank(Actors.ADMIN);
        vm.expectRevert("ChainlinkOracle: use setChainlinkConfig");
        verifier.setAssetOracleConfig(ASSET, 1, 1);
        vm.expectRevert("ChainlinkOracle: use getChainlinkConfig");
        verifier.getAssetOracleConfig(ASSET);
        vm.stopPrank();
    }

    function test_updatePriceFeeds_reverts() public {
        vm.expectRevert("ChainlinkOracle: use updatePrice + multicall");
        verifier.updatePriceFeeds(hex"00");
    }

    // ──────────────────────────────────────────────────────────
    //  Multiplier x band interaction
    // ──────────────────────────────────────────────────────────

    /// @dev With multiplierToken set, the anchor is the multiplier-adjusted (underlying) price —
    ///      signed prices band-check against feed/mult, not the raw feed.
    function test_updatePrice_multiplierAdjustedAnchor() public {
        vm.prank(Actors.ADMIN);
        verifier.setChainlinkConfig(
            ASSET,
            address(feed),
            address(token),
            CL_SILENCE,
            CL_FRESH_WINDOW,
            MAX_ANCHOR_AGE,
            INHOUSE_MAX_STALENESS,
            BAND_BPS
        );
        token.setUiMultiplier(2e18); // anchor = 380/2 = 190e18
        _ageChainlink(CL_SILENCE + 1);

        // Within band of the raw feed price but not of the adjusted anchor — must revert.
        bytes memory rawScale = _signPrice(ASSET, CL_PRICE_18, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.PriceDeviationExceeded.selector, ASSET, CL_PRICE_18, CL_PRICE_18 / 2, uint256(BAND_BPS)
            )
        );
        verifier.updatePrice(ASSET, rawScale);

        // Within band of the adjusted anchor — accepted.
        uint256 goodPrice = CL_PRICE_18 / 2 * 102 / 100;
        verifier.updatePrice(ASSET, _signPrice(ASSET, goodPrice, block.timestamp));
        (uint256 price,) = verifier.getPrice(ASSET);
        assertEq(price, goodPrice);
    }

    function test_verifyPrice_multiplierAdjustedAnchor() public {
        vm.prank(Actors.ADMIN);
        verifier.setChainlinkConfig(
            ASSET,
            address(feed),
            address(token),
            CL_SILENCE,
            CL_FRESH_WINDOW,
            MAX_ANCHOR_AGE,
            INHOUSE_MAX_STALENESS,
            BAND_BPS
        );
        token.setUiMultiplier(4e18);
        _ageChainlink(CL_SILENCE + 1);

        uint256 anchor = CL_PRICE_18 / 4;
        (uint256 price, uint256 ts) = verifier.verifyPrice(ASSET, _signPrice(ASSET, anchor, block.timestamp));
        assertEq(price, anchor);
        assertEq(ts, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  Non-8-decimal feed normalization
    // ──────────────────────────────────────────────────────────

    function test_getPrice_18DecimalFeed_normalizes() public {
        MockAggregatorV3 feed18 = new MockAggregatorV3(18);
        feed18.setAnswer(int256(CL_PRICE_18), block.timestamp);
        bytes32 asset18 = bytes32("EXCH");
        vm.prank(Actors.ADMIN);
        verifier.setChainlinkConfig(
            asset18, address(feed18), address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, INHOUSE_MAX_STALENESS, 0
        );
        (uint256 price,) = verifier.getPrice(asset18);
        assertEq(price, CL_PRICE_18);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPriceForSession — proof leg
    // ──────────────────────────────────────────────────────────

    function test_verifyPriceForSession_proofLeg() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 proofPrice = CL_PRICE_18 * 101 / 100;
        (uint256 price, uint256 ts) =
            verifier.verifyPriceForSession(ASSET, _signPrice(ASSET, proofPrice, block.timestamp), 3);
        assertEq(price, proofPrice);
        assertEq(ts, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  Multicall batch push
    // ──────────────────────────────────────────────────────────

    function test_multicall_batchUpdatePrice() public {
        bytes32 asset2 = bytes32("MSFT");
        MockAggregatorV3 feed2 = new MockAggregatorV3(8);
        feed2.setAnswer(500e8, block.timestamp);
        vm.prank(Actors.ADMIN);
        verifier.setChainlinkConfig(
            asset2,
            address(feed2),
            address(0),
            CL_SILENCE,
            CL_FRESH_WINDOW,
            MAX_ANCHOR_AGE,
            INHOUSE_MAX_STALENESS,
            BAND_BPS
        );
        _ageChainlink(CL_SILENCE + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(verifier.updatePrice, (ASSET, _signPrice(ASSET, CL_PRICE_18, block.timestamp)));
        calls[1] = abi.encodeCall(verifier.updatePrice, (asset2, _signPrice(asset2, 501e18, block.timestamp)));
        verifier.multicall(calls);

        (uint256 p1,) = verifier.getInhousePrice(ASSET);
        (uint256 p2,) = verifier.getInhousePrice(asset2);
        assertEq(p1, CL_PRICE_18);
        assertEq(p2, 501e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Remaining edges
    // ──────────────────────────────────────────────────────────

    function test_updatePrice_equalTimestamp_skipsSilently() public {
        _ageChainlink(CL_SILENCE + 1);
        uint256 ts = block.timestamp;
        verifier.updatePrice(ASSET, _signPrice(ASSET, CL_PRICE_18, ts));
        verifier.updatePrice(ASSET, _signPrice(ASSET, CL_PRICE_18 * 104 / 100, ts));
        (uint256 price,) = verifier.getInhousePrice(ASSET);
        assertEq(price, CL_PRICE_18);
    }

    function test_verifyPrice_clSilent_garbageProof_reverts() public {
        _ageChainlink(CL_SILENCE + 1);
        vm.expectRevert();
        verifier.verifyPrice(ASSET, hex"deadbeef");
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    /// @dev The band boundary is exact: accepted iff |price - anchor| * BPS <= anchor * bandBps.
    function testFuzz_updatePrice_bandBoundary(uint256 deltaBps, bool up) public {
        deltaBps = bound(deltaBps, 0, 2 * uint256(BAND_BPS));
        _ageChainlink(CL_SILENCE + 1);

        uint256 price = up ? CL_PRICE_18 * (10_000 + deltaBps) / 10_000 : CL_PRICE_18 * (10_000 - deltaBps) / 10_000;
        uint256 diff = price > CL_PRICE_18 ? price - CL_PRICE_18 : CL_PRICE_18 - price;
        bool shouldPass = diff * 10_000 <= CL_PRICE_18 * BAND_BPS;

        bytes memory data = _signPrice(ASSET, price, block.timestamp);
        if (!shouldPass) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IOracleVerifier.PriceDeviationExceeded.selector, ASSET, price, CL_PRICE_18, uint256(BAND_BPS)
                )
            );
        }
        verifier.updatePrice(ASSET, data);
        if (shouldPass) {
            (uint256 stored,) = verifier.getInhousePrice(ASSET);
            assertEq(stored, price);
        }
    }

    /// @dev Timestamp semantics across the three windows: clamped inside clFreshWindow, raw between
    ///      clFreshWindow and maxAnchorAge, unavailable beyond (no in-house price pushed).
    function testFuzz_getPrice_timestampWindows(
        uint256 age
    ) public {
        age = bound(age, 0, uint256(MAX_ANCHOR_AGE) + 2 days);
        uint256 updated = block.timestamp;
        vm.warp(block.timestamp + age);

        if (age > MAX_ANCHOR_AGE) {
            vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.PriceNotAvailable.selector, ASSET));
            verifier.getPrice(ASSET);
        } else {
            (uint256 price, uint256 ts) = verifier.getPrice(ASSET);
            assertEq(price, CL_PRICE_18);
            assertEq(ts, age <= CL_FRESH_WINDOW ? block.timestamp : updated);
        }
    }
}
