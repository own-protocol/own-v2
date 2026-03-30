// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {BPS, PRECISION} from "../../src/interfaces/types/Types.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract OracleVerifierTest is BaseTest {
    OracleVerifier public verifier;

    uint256 internal constant SIGNER_PK = 0xBEEF;
    address internal signer;

    bytes32 constant ASSET = bytes32("TSLA");
    uint256 constant MAX_STALENESS = 300; // 5 minutes
    uint256 constant MAX_DEVIATION = 1000; // 10%

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);

        signer = vm.addr(SIGNER_PK);

        vm.startPrank(Actors.ADMIN);
        verifier = new OracleVerifier(Actors.ADMIN);
        verifier.addSigner(signer);
        verifier.setAssetOracleConfig(ASSET, MAX_STALENESS, MAX_DEVIATION);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _signPrice(bytes32 asset, uint256 price, uint256 timestamp) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(asset, price, timestamp, block.chainid, address(verifier)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        return abi.encode(price, timestamp, v, r, s);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — happy path
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_validSignature_succeeds() public {
        bytes memory priceData = _signPrice(ASSET, 250e18, block.timestamp);
        (uint256 retPrice, uint256 retTs) = verifier.verifyPrice(ASSET, priceData);
        assertEq(retPrice, 250e18);
        assertEq(retTs, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  updatePrice — stores price and emits event
    // ──────────────────────────────────────────────────────────

    function test_updatePrice_storesAndEmits() public {
        uint256 price = 250e18;
        uint256 timestamp = block.timestamp;
        bytes memory priceData = _signPrice(ASSET, price, timestamp);

        vm.expectEmit(true, false, false, true);
        emit IOracleVerifier.PriceUpdated(ASSET, price, timestamp);

        verifier.updatePrice(ASSET, priceData);

        (uint256 storedPrice, uint256 storedTs) = verifier.getPrice(ASSET);
        assertEq(storedPrice, price);
        assertEq(storedTs, timestamp);
    }

    function test_updatePrice_consecutivePrices_succeed() public {
        verifier.updatePrice(ASSET, _signPrice(ASSET, 250e18, block.timestamp));

        vm.warp(block.timestamp + 60);

        verifier.updatePrice(ASSET, _signPrice(ASSET, 255e18, block.timestamp));

        (uint256 lastPrice,) = verifier.getPrice(ASSET);
        assertEq(lastPrice, 255e18);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — signature failures
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_invalidSigner_reverts() public {
        uint256 wrongPk = 0xDEAD;
        bytes32 messageHash = keccak256(abi.encode(ASSET, 250e18, block.timestamp, block.chainid, address(verifier)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, ethSignedHash);
        bytes memory priceData = abi.encode(250e18, block.timestamp, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnauthorizedSigner.selector, vm.addr(wrongPk)));
        verifier.verifyPrice(ASSET, priceData);
    }

    function test_verifyPrice_tamperedPrice_reverts() public {
        bytes32 messageHash = keccak256(abi.encode(ASSET, 250e18, block.timestamp, block.chainid, address(verifier)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        bytes memory priceData = abi.encode(999e18, block.timestamp, v, r, s);

        vm.expectRevert();
        verifier.verifyPrice(ASSET, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  updatePrice — staleness
    // ──────────────────────────────────────────────────────────

    function test_updatePrice_stalePrice_reverts() public {
        uint256 staleTimestamp = block.timestamp - MAX_STALENESS - 1;
        bytes memory priceData = _signPrice(ASSET, 250e18, staleTimestamp);

        vm.expectRevert(
            abi.encodeWithSelector(IOracleVerifier.StalePrice.selector, ASSET, staleTimestamp, MAX_STALENESS)
        );
        verifier.updatePrice(ASSET, priceData);
    }

    function test_updatePrice_exactStalenessLimit_succeeds() public {
        uint256 timestamp = block.timestamp - MAX_STALENESS;
        verifier.updatePrice(ASSET, _signPrice(ASSET, 250e18, timestamp));

        (uint256 retPrice,) = verifier.getPrice(ASSET);
        assertEq(retPrice, 250e18);
    }

    // ──────────────────────────────────────────────────────────
    //  updatePrice — deviation
    // ──────────────────────────────────────────────────────────

    function test_updatePrice_deviationExceeded_reverts() public {
        verifier.updatePrice(ASSET, _signPrice(ASSET, 250e18, block.timestamp));

        vm.warp(block.timestamp + 60);

        uint256 deviatedPrice = 300e18;
        bytes memory priceData = _signPrice(ASSET, deviatedPrice, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.PriceDeviationExceeded.selector, ASSET, deviatedPrice, 250e18, MAX_DEVIATION
            )
        );
        verifier.updatePrice(ASSET, priceData);
    }

    function test_updatePrice_withinDeviationLimit_succeeds() public {
        verifier.updatePrice(ASSET, _signPrice(ASSET, 250e18, block.timestamp));

        vm.warp(block.timestamp + 60);

        verifier.updatePrice(ASSET, _signPrice(ASSET, 262.5e18, block.timestamp));

        (uint256 retPrice,) = verifier.getPrice(ASSET);
        assertEq(retPrice, 262.5e18);
    }

    function test_updatePrice_firstPrice_skipsDeviationCheck() public {
        verifier.updatePrice(ASSET, _signPrice(ASSET, 1_000_000e18, block.timestamp));

        (uint256 retPrice,) = verifier.getPrice(ASSET);
        assertEq(retPrice, 1_000_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  updatePrice — older timestamp ignored
    // ──────────────────────────────────────────────────────────

    function test_updatePrice_olderTimestamp_ignored() public {
        verifier.updatePrice(ASSET, _signPrice(ASSET, 250e18, block.timestamp));

        uint256 firstTs = block.timestamp;
        vm.warp(block.timestamp + 60);

        verifier.updatePrice(ASSET, _signPrice(ASSET, 251e18, firstTs));

        (uint256 retPrice,) = verifier.getPrice(ASSET);
        assertEq(retPrice, 250e18); // unchanged
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — zero price
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_zeroPrice_reverts() public {
        bytes memory priceData = _signPrice(ASSET, 0, block.timestamp);
        vm.expectRevert(IOracleVerifier.ZeroPrice.selector);
        verifier.verifyPrice(ASSET, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  verifyPrice — chain ID replay
    // ──────────────────────────────────────────────────────────

    function test_verifyPrice_wrongChainId_reverts() public {
        bytes32 messageHash = keccak256(abi.encode(ASSET, 250e18, block.timestamp, uint256(999), address(verifier)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        bytes memory priceData = abi.encode(250e18, block.timestamp, v, r, s);

        vm.expectRevert();
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

        bytes memory priceData = _signPrice(ASSET, 250e18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnauthorizedSigner.selector, signer));
        verifier.verifyPrice(ASSET, priceData);
    }

    // ──────────────────────────────────────────────────────────
    //  Per-asset config
    // ──────────────────────────────────────────────────────────

    function test_setAssetOracleConfig_admin_succeeds() public {
        vm.prank(Actors.ADMIN);
        verifier.setAssetOracleConfig(bytes32("GOLD"), 600, 500);
    }

    function test_setAssetOracleConfig_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        verifier.setAssetOracleConfig(ASSET, 600, 500);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_verifyPrice_validPrices(
        uint256 price
    ) public {
        price = bound(price, 1, type(uint128).max);
        bytes memory priceData = _signPrice(ASSET, price, block.timestamp);
        (uint256 retPrice,) = verifier.verifyPrice(ASSET, priceData);
        assertEq(retPrice, price);
    }
}
