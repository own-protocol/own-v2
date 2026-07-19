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
    uint32 constant CL_FRESH_WINDOW = 43_200; // 12h — beyond this, reads report the raw timestamp
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
            ASSET, address(feed), address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, INHOUSE_MAX_STALENESS, BAND_BPS
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
        _ageChainlink(10 hours);
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
            abi.encodeWithSelector(
                IOracleVerifier.StalePrice.selector, ASSET, signedTs, uint256(INHOUSE_MAX_STALENESS)
            )
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
        _ageChainlink(10 hours);
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
            ASSET, address(feed), address(0), CL_SILENCE, CL_FRESH_WINDOW, MAX_ANCHOR_AGE, INHOUSE_MAX_STALENESS, BAND_BPS
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
}
