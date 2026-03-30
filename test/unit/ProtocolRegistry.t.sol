// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ProtocolRegistry Unit Tests
/// @notice Tests first-time initialization, timelocked updates (propose/execute/cancel),
///         getter correctness, access control, and edge cases.
contract ProtocolRegistryTest is BaseTest {
    ProtocolRegistry public reg;

    uint256 constant TIMELOCK_DELAY = 2 days;

    // Cache key constants to avoid external calls consuming vm.prank
    bytes32 MARKET_KEY;
    bytes32 ORACLE_VERIFIER_KEY;
    bytes32 FEE_CALCULATOR_KEY;
    bytes32 LIQUIDATION_ENGINE_KEY;
    bytes32 ASSET_REGISTRY_KEY;
    bytes32 TREASURY_KEY;

    address public addr1 = makeAddr("addr1");
    address public addr2 = makeAddr("addr2");
    address public addr3 = makeAddr("addr3");

    function setUp() public override {
        super.setUp();

        reg = new ProtocolRegistry(Actors.ADMIN, TIMELOCK_DELAY);
        vm.label(address(reg), "ProtocolRegistry");

        // Cache keys
        MARKET_KEY = reg.MARKET();
        ORACLE_VERIFIER_KEY = reg.ORACLE_VERIFIER();
        FEE_CALCULATOR_KEY = reg.FEE_CALCULATOR();
        LIQUIDATION_ENGINE_KEY = reg.LIQUIDATION_ENGINE();
        ASSET_REGISTRY_KEY = reg.ASSET_REGISTRY();
        TREASURY_KEY = reg.TREASURY();
    }

    // ══════════════════════════════════════════════════════════
    //  Constructor
    // ══════════════════════════════════════════════════════════

    function test_constructor_setsOwner() public view {
        assertEq(reg.owner(), Actors.ADMIN);
    }

    function test_constructor_setsTimelockDelay() public view {
        assertEq(reg.timelockDelay(), TIMELOCK_DELAY);
    }

    function test_constructor_allGettersReturnZero() public view {
        assertEq(reg.oracleVerifier(), address(0));
        assertEq(reg.feeCalculator(), address(0));
        assertEq(reg.market(), address(0));
        assertEq(reg.liquidationEngine(), address(0));
        assertEq(reg.assetRegistry(), address(0));
        assertEq(reg.treasury(), address(0));
    }

    // ══════════════════════════════════════════════════════════
    //  Constants — slot keys
    // ══════════════════════════════════════════════════════════

    function test_constants_correctHashes() public view {
        assertEq(ORACLE_VERIFIER_KEY, keccak256("ORACLE_VERIFIER"));
        assertEq(MARKET_KEY, keccak256("MARKET"));
        assertEq(TREASURY_KEY, keccak256("TREASURY"));
    }

    // ══════════════════════════════════════════════════════════
    //  First-time initialization (setAddress)
    // ══════════════════════════════════════════════════════════

    function test_setAddress_setsValueImmediately() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);

        assertEq(reg.market(), addr1);
    }

    function test_setAddress_emitsContractInitialized() public {
        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.ContractInitialized(MARKET_KEY, addr1);

        vm.prank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
    }

    function test_setAddress_allSlots() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(ORACLE_VERIFIER_KEY, addr1);
        reg.setAddress(FEE_CALCULATOR_KEY, addr2);
        reg.setAddress(MARKET_KEY, makeAddr("market"));
        reg.setAddress(LIQUIDATION_ENGINE_KEY, makeAddr("le"));
        reg.setAddress(ASSET_REGISTRY_KEY, makeAddr("ar"));
        reg.setAddress(TREASURY_KEY, makeAddr("treasury"));
        vm.stopPrank();

        assertEq(reg.oracleVerifier(), addr1);
        assertEq(reg.feeCalculator(), addr2);
        assertEq(reg.market(), makeAddr("market"));
        assertEq(reg.liquidationEngine(), makeAddr("le"));
        assertEq(reg.assetRegistry(), makeAddr("ar"));
        assertEq(reg.treasury(), makeAddr("treasury"));
    }

    function test_setAddress_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.ZeroAddress.selector);
        reg.setAddress(MARKET_KEY, address(0));
    }

    function test_setAddress_alreadyInitialized_reverts() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);

        vm.expectRevert(IProtocolRegistry.AlreadyInitialized.selector);
        reg.setAddress(MARKET_KEY, addr2);
        vm.stopPrank();
    }

    function test_setAddress_notOwner_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, Actors.ATTACKER));
        reg.setAddress(MARKET_KEY, addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  Timelocked updates — proposeAddress
    // ══════════════════════════════════════════════════════════

    function test_proposeAddress_createsProposal() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(MARKET_KEY);
        assertEq(newAddr, addr2);
        assertEq(effectiveAt, block.timestamp + TIMELOCK_DELAY);
    }

    function test_proposeAddress_emitsTimelockProposed() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        vm.stopPrank();

        uint256 expectedEffectiveAt = block.timestamp + TIMELOCK_DELAY;
        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.TimelockProposed(MARKET_KEY, addr2, expectedEffectiveAt);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(MARKET_KEY, addr2);
    }

    function test_proposeAddress_zeroAddress_reverts() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);

        vm.expectRevert(IProtocolRegistry.ZeroAddress.selector);
        reg.proposeAddress(MARKET_KEY, address(0));
        vm.stopPrank();
    }

    function test_proposeAddress_sameAddress_reverts() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);

        vm.expectRevert(IProtocolRegistry.SameAddress.selector);
        reg.proposeAddress(MARKET_KEY, addr1);
        vm.stopPrank();
    }

    function test_proposeAddress_notOwner_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, Actors.ATTACKER));
        reg.proposeAddress(MARKET_KEY, addr2);
    }

    function test_proposeAddress_overwritesPendingProposal() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        reg.proposeAddress(MARKET_KEY, addr3);
        vm.stopPrank();

        (address newAddr,) = reg.pendingTimelockOf(MARKET_KEY);
        assertEq(newAddr, addr3);
    }

    function test_proposeAddress_uninitializedSlot_succeeds() public {
        vm.prank(Actors.ADMIN);
        reg.proposeAddress(MARKET_KEY, addr1);

        (address newAddr,) = reg.pendingTimelockOf(MARKET_KEY);
        assertEq(newAddr, addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  Timelocked updates — executeTimelock
    // ══════════════════════════════════════════════════════════

    function test_executeTimelock_updatesAddress() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        reg.executeTimelock(MARKET_KEY);

        assertEq(reg.market(), addr2);
    }

    function test_executeTimelock_emitsTimelockExecuted() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.TimelockExecuted(MARKET_KEY, addr1, addr2);

        reg.executeTimelock(MARKET_KEY);
    }

    function test_executeTimelock_clearsProposal() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        reg.executeTimelock(MARKET_KEY);

        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(MARKET_KEY);
        assertEq(newAddr, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_executeTimelock_callableByAnyone() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(Actors.ATTACKER);
        reg.executeTimelock(MARKET_KEY);

        assertEq(reg.market(), addr2);
    }

    function test_executeTimelock_notProposed_reverts() public {
        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.executeTimelock(MARKET_KEY);
    }

    function test_executeTimelock_beforeDelay_reverts() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);

        vm.expectRevert(IProtocolRegistry.TimelockNotReady.selector);
        reg.executeTimelock(MARKET_KEY);
    }

    function test_executeTimelock_exactlyAtDelay_succeeds() public {
        uint256 proposeTime = block.timestamp;

        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.warp(proposeTime + TIMELOCK_DELAY);
        reg.executeTimelock(MARKET_KEY);

        assertEq(reg.market(), addr2);
    }

    function test_executeTimelock_doubleExecute_reverts() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        reg.executeTimelock(MARKET_KEY);

        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.executeTimelock(MARKET_KEY);
    }

    // ══════════════════════════════════════════════════════════
    //  Timelocked updates — cancelTimelock
    // ══════════════════════════════════════════════════════════

    function test_cancelTimelock_clearsProposal() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        reg.cancelTimelock(MARKET_KEY);
        vm.stopPrank();

        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(MARKET_KEY);
        assertEq(newAddr, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_cancelTimelock_emitsTimelockCancelled() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.expectEmit(true, false, false, false);
        emit IProtocolRegistry.TimelockCancelled(MARKET_KEY);

        vm.prank(Actors.ADMIN);
        reg.cancelTimelock(MARKET_KEY);
    }

    function test_cancelTimelock_addressUnchanged() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        reg.cancelTimelock(MARKET_KEY);
        vm.stopPrank();

        assertEq(reg.market(), addr1);
    }

    function test_cancelTimelock_notProposed_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.cancelTimelock(MARKET_KEY);
    }

    function test_cancelTimelock_notOwner_reverts() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, Actors.ATTACKER));
        reg.cancelTimelock(MARKET_KEY);
    }

    function test_cancelTimelock_thenExecute_reverts() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.proposeAddress(MARKET_KEY, addr2);
        reg.cancelTimelock(MARKET_KEY);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.executeTimelock(MARKET_KEY);
    }

    // ══════════════════════════════════════════════════════════
    //  Full lifecycle — propose → cancel → re-propose → execute
    // ══════════════════════════════════════════════════════════

    function test_fullLifecycle_proposeCancelRepropose() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        assertEq(reg.market(), addr1);

        reg.proposeAddress(MARKET_KEY, addr2);
        reg.cancelTimelock(MARKET_KEY);
        reg.proposeAddress(MARKET_KEY, addr3);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        reg.executeTimelock(MARKET_KEY);

        assertEq(reg.market(), addr3);
    }

    function test_fullLifecycle_multipleSlots() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        reg.setAddress(ORACLE_VERIFIER_KEY, addr2);

        reg.proposeAddress(MARKET_KEY, addr3);
        reg.proposeAddress(ORACLE_VERIFIER_KEY, addr1);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        reg.executeTimelock(MARKET_KEY);
        reg.executeTimelock(ORACLE_VERIFIER_KEY);

        assertEq(reg.market(), addr3);
        assertEq(reg.oracleVerifier(), addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  pendingTimelockOf
    // ══════════════════════════════════════════════════════════

    function test_pendingTimelockOf_noProposal_returnsZeros() public view {
        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(MARKET_KEY);
        assertEq(newAddr, address(0));
        assertEq(effectiveAt, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Fuzz
    // ══════════════════════════════════════════════════════════

    function testFuzz_setAddress_anyKey(
        bytes32 key
    ) public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(key, addr1);
    }

    function testFuzz_timelockLifecycle(
        uint256 delay
    ) public {
        delay = bound(delay, 1, 365 days);

        ProtocolRegistry customReg = new ProtocolRegistry(Actors.ADMIN, delay);
        bytes32 key = customReg.MARKET();

        vm.startPrank(Actors.ADMIN);
        customReg.setAddress(key, addr1);
        customReg.proposeAddress(key, addr2);
        vm.stopPrank();

        // Before delay — should revert
        vm.warp(block.timestamp + delay - 1);
        vm.expectRevert(IProtocolRegistry.TimelockNotReady.selector);
        customReg.executeTimelock(key);

        // At delay — should succeed
        vm.warp(block.timestamp + 1);
        customReg.executeTimelock(key);
        assertEq(customReg.market(), addr2);
    }
}
