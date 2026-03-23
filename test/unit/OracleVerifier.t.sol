// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {Actors} from "../helpers/Actors.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {PRECISION, BPS} from "../../src/interfaces/types/Types.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title OracleVerifier Unit Tests
/// @notice Tests ECDSA signature verification, staleness, deviation, sequence
///         numbers, chain ID validation, and signer management.
contract OracleVerifierTest is BaseTest {
    OracleVerifier public verifier;

    uint256 internal constant SIGNER_PK = 0xBEEF;
    address internal signer;

    bytes32 constant ASSET = bytes32("TSLA");
    uint256 constant MAX_STALENESS = 300; // 5 minutes
    uint256 constant MAX_DEVIATION = 1000; // 10%

    function setUp() public override {
        super.setUp();

        signer = vm.addr(SIGNER_PK);

        vm.startPrank(Actors.ADMIN);
        verifier = new OracleVerifier(Actors.ADMIN);
        verifier.addSigner(signer);
        verifier.setAssetOracleConfig(ASSET, MAX_STALENESS, MAX_DEVIATION);
        vm.stopPrank();

        vm.label(address(verifier), "OracleVerifier");
        vm.label(signer, "signer");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @notice Build a signed price payload matching the expected format.
    /// @dev The message format: abi.encode(asset, price, timestamp, marketOpen, sequenceNumber, chainId, verifierAddress)
    function _signPrice(
        bytes32 asset,
        uint256 price,
        uint256 timestamp,
        bool marketOpen,
        uint256 sequenceNumber
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encode(asset, price, timestamp, marketOpen, sequenceNumber, block.chainid, address(verifier))
        );
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        return abi.encode(price, timestamp, marketOpen, sequenceNumber, v, r, s);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — happy path
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_validSignature_succeeds() public {
        uint256 price = 250e18;
        uint256 timestamp = block.timestamp;
        uint256 seq = 1;

        bytes memory priceData = _signPrice(ASSET, price, timestamp, true, seq);

        vm.expectEmit(true, false, false, true);
        emit IOracleVerifier.PriceVerified(ASSET, price, timestamp, true);

        (uint256 retPrice, uint256 retTs, bool retOpen) = verifier.verifyPrice(ASSET, priceData);

        assertEq(retPrice, price);
        assertEq(retTs, timestamp);
        assertTrue(retOpen);
    }

    function test_verifyPrice_marketClosed_returnsCorrectFlag() public {
        bytes memory priceData = _signPrice(ASSET, 250e18, block.timestamp, false, 1);

        (, , bool marketOpen) = verifier.verifyPrice(ASSET, priceData);

        assertFalse(marketOpen);
    }

    function test_verifyPrice_updatesSequenceNumber() public {
        bytes memory priceData = _signPrice(ASSET, 250e18, block.timestamp, true, 1);
        verifier.verifyPrice(ASSET, priceData);

        assertEq(verifier.getSequenceNumber(ASSET), 1);
    }

    function test_verifyPrice_updatesLastPrice() public {
        bytes memory priceData = _signPrice(ASSET, 250e18, block.timestamp, true, 1);
        verifier.verifyPrice(ASSET, priceData);

        (uint256 lastPrice, uint256 lastTs) = verifier.getLastPrice(ASSET);
        assertEq(lastPrice, 250e18);
        assertEq(lastTs, block.timestamp);
    }

    function test_verifyPrice_consecutivePrices_succeed() public {
        bytes memory pd1 = _signPrice(ASSET, 250e18, block.timestamp, true, 1);
        verifier.verifyPrice(ASSET, pd1);

        vm.warp(block.timestamp + 60);

        bytes memory pd2 = _signPrice(ASSET, 255e18, block.timestamp, true, 2);
        verifier.verifyPrice(ASSET, pd2);

        (uint256 lastPrice,) = verifier.getLastPrice(ASSET);
        assertEq(lastPrice, 255e18);
        assertEq(verifier.getSequenceNumber(ASSET), 2);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — signature failures
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_invalidSigner_reverts() public {
        // Sign with wrong key
        uint256 wrongPk = 0xDEAD;
        bytes32 messageHash =
            keccak256(abi.encode(ASSET, 250e18, block.timestamp, true, uint256(1), block.chainid, address(verifier)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, ethSignedHash);
        bytes memory priceData = abi.encode(250e18, block.timestamp, true, uint256(1), v, r, s);

        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnauthorizedSigner.selector, vm.addr(wrongPk)));
        verifier.verifyPrice(ASSET, priceData);
    }

    function test_verifyPrice_tamperedPrice_reverts() public {
        // Sign with correct price but submit different price
        bytes32 messageHash =
            keccak256(abi.encode(ASSET, 250e18, block.timestamp, true, uint256(1), block.chainid, address(verifier)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);

        // Tamper: submit 999e18 instead of 250e18
        bytes memory priceData = abi.encode(999e18, block.timestamp, true, uint256(1), v, r, s);

        vm.expectRevert(); // Recovered signer won't match
        verifier.verifyPrice(ASSET, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — staleness
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_stalePrice_reverts() public {
        uint256 staleTimestamp = block.timestamp - MAX_STALENESS - 1;
        bytes memory priceData = _signPrice(ASSET, 250e18, staleTimestamp, true, 1);

        vm.expectRevert(
            abi.encodeWithSelector(IOracleVerifier.StalePrice.selector, ASSET, staleTimestamp, MAX_STALENESS)
        );
        verifier.verifyPrice(ASSET, priceData);
    }

    function test_verifyPrice_exactStalenessLimit_succeeds() public {
        uint256 timestamp = block.timestamp - MAX_STALENESS;
        bytes memory priceData = _signPrice(ASSET, 250e18, timestamp, true, 1);

        (uint256 retPrice,,) = verifier.verifyPrice(ASSET, priceData);
        assertEq(retPrice, 250e18);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — deviation
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_deviationExceeded_reverts() public {
        // First price establishes baseline
        bytes memory pd1 = _signPrice(ASSET, 250e18, block.timestamp, true, 1);
        verifier.verifyPrice(ASSET, pd1);

        vm.warp(block.timestamp + 60);

        // Price jumps 20% (> 10% max deviation)
        uint256 deviatedPrice = 300e18;
        bytes memory pd2 = _signPrice(ASSET, deviatedPrice, block.timestamp, true, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.PriceDeviationExceeded.selector, ASSET, deviatedPrice, 250e18, MAX_DEVIATION
            )
        );
        verifier.verifyPrice(ASSET, pd2);
    }

    function test_verifyPrice_withinDeviationLimit_succeeds() public {
        // First price
        bytes memory pd1 = _signPrice(ASSET, 250e18, block.timestamp, true, 1);
        verifier.verifyPrice(ASSET, pd1);

        vm.warp(block.timestamp + 60);

        // Price moves 5% (within 10% limit)
        bytes memory pd2 = _signPrice(ASSET, 262.5e18, block.timestamp, true, 2);
        (uint256 retPrice,,) = verifier.verifyPrice(ASSET, pd2);
        assertEq(retPrice, 262.5e18);
    }

    function test_verifyPrice_firstPrice_skipsDeviationCheck() public {
        // First price for an asset should succeed regardless of value
        bytes memory priceData = _signPrice(ASSET, 1_000_000e18, block.timestamp, true, 1);
        (uint256 retPrice,,) = verifier.verifyPrice(ASSET, priceData);
        assertEq(retPrice, 1_000_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — sequence numbers
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_sameSequenceNumber_reverts() public {
        bytes memory pd1 = _signPrice(ASSET, 250e18, block.timestamp, true, 1);
        verifier.verifyPrice(ASSET, pd1);

        vm.warp(block.timestamp + 60);

        bytes memory pd2 = _signPrice(ASSET, 251e18, block.timestamp, true, 1); // same seq
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSequenceNumber.selector, ASSET, 1, 2));
        verifier.verifyPrice(ASSET, pd2);
    }

    function test_verifyPrice_lowerSequenceNumber_reverts() public {
        bytes memory pd1 = _signPrice(ASSET, 250e18, block.timestamp, true, 5);
        verifier.verifyPrice(ASSET, pd1);

        vm.warp(block.timestamp + 60);

        bytes memory pd2 = _signPrice(ASSET, 251e18, block.timestamp, true, 3); // lower seq
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSequenceNumber.selector, ASSET, 3, 6));
        verifier.verifyPrice(ASSET, pd2);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — zero price
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_zeroPrice_reverts() public {
        bytes memory priceData = _signPrice(ASSET, 0, block.timestamp, true, 1);

        vm.expectRevert(IOracleVerifier.ZeroPrice.selector);
        verifier.verifyPrice(ASSET, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — chain ID and contract address replay
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_wrongChainId_reverts() public {
        // Sign with wrong chain ID
        bytes32 messageHash =
            keccak256(abi.encode(ASSET, 250e18, block.timestamp, true, uint256(1), uint256(999), address(verifier)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        bytes memory priceData = abi.encode(250e18, block.timestamp, true, uint256(1), v, r, s);

        vm.expectRevert(); // Recovered signer won't match due to different message
        verifier.verifyPrice(ASSET, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  Signer management
    // ──────────────────────────────────────────────────────────

    function test_addSigner_admin_succeeds() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, false, false, false);
        emit IOracleVerifier.SignerAdded(newSigner);

        vm.prank(Actors.ADMIN);
        verifier.addSigner(newSigner);

        assertTrue(verifier.isSigner(newSigner));
    }

    function test_addSigner_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.addSigner(makeAddr("newSigner"));
    }

    function test_addSigner_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IOracleVerifier.ZeroAddress.selector);
        verifier.addSigner(address(0));
    }

    function test_removeSigner_admin_succeeds() public {
        vm.expectEmit(true, false, false, false);
        emit IOracleVerifier.SignerRemoved(signer);

        vm.prank(Actors.ADMIN);
        verifier.removeSigner(signer);

        assertFalse(verifier.isSigner(signer));
    }

    function test_removeSigner_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.removeSigner(signer);
    }

    function test_removeSigner_priceFromRemovedSigner_reverts() public {
        vm.prank(Actors.ADMIN);
        verifier.removeSigner(signer);

        bytes memory priceData = _signPrice(ASSET, 250e18, block.timestamp, true, 1);

        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnauthorizedSigner.selector, signer));
        verifier.verifyPrice(ASSET, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  Per-asset config
    // ──────────────────────────────────────────────────────────

    function test_setAssetOracleConfig_admin_succeeds() public {
        bytes32 newAsset = bytes32("GOLD");

        vm.expectEmit(true, false, false, true);
        emit IOracleVerifier.AssetOracleConfigUpdated(newAsset, 600, 500);

        vm.prank(Actors.ADMIN);
        verifier.setAssetOracleConfig(newAsset, 600, 500);
    }

    function test_setAssetOracleConfig_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.setAssetOracleConfig(ASSET, 600, 500);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_verifyPrice_validPrices(uint256 price) public {
        price = bound(price, 1, type(uint128).max);
        bytes memory priceData = _signPrice(ASSET, price, block.timestamp, true, 1);

        (uint256 retPrice,,) = verifier.verifyPrice(ASSET, priceData);
        assertEq(retPrice, price);
    }
}
