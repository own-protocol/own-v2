// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

/// @title ProtocolRegistry Unit Tests
/// @notice Tests first-time initialization, timelocked updates (propose/execute/cancel),
///         getter correctness, access control, and edge cases.
contract ProtocolRegistryTest is BaseTest {
    ProtocolRegistry public reg;

    uint256 constant TIMELOCK_DELAY = 2 days;

    address public addr1 = makeAddr("addr1");
    address public addr2 = makeAddr("addr2");
    address public addr3 = makeAddr("addr3");

    function setUp() public override {
        super.setUp();

        vm.prank(Actors.ADMIN);
        reg = new ProtocolRegistry(Actors.ADMIN, TIMELOCK_DELAY);
        vm.label(address(reg), "ProtocolRegistry");
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
        assertEq(reg.feeAccrual(), address(0));
        assertEq(reg.market(), address(0));
        assertEq(reg.vaultManager(), address(0));
        assertEq(reg.liquidationEngine(), address(0));
        assertEq(reg.assetRegistry(), address(0));
        assertEq(reg.paymentTokenRegistry(), address(0));
        assertEq(reg.treasury(), address(0));
    }

    // ══════════════════════════════════════════════════════════
    //  Constants — slot keys
    // ══════════════════════════════════════════════════════════

    function test_constants_correctHashes() public view {
        assertEq(reg.ORACLE_VERIFIER(), keccak256("ORACLE_VERIFIER"));
        assertEq(reg.MARKET(), keccak256("MARKET"));
        assertEq(reg.VAULT_MANAGER(), keccak256("VAULT_MANAGER"));
        assertEq(reg.TREASURY(), keccak256("TREASURY"));
    }

    // ══════════════════════════════════════════════════════════
    //  First-time initialization (setAddress)
    // ══════════════════════════════════════════════════════════

    function test_setAddress_setsValueImmediately() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        assertEq(reg.market(), addr1);
    }

    function test_setAddress_emitsContractInitialized() public {
        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.ContractInitialized(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);
    }

    function test_setAddress_allSlots() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(reg.ORACLE_VERIFIER(), addr1);
        reg.setAddress(reg.FEE_CALCULATOR(), addr2);
        reg.setAddress(reg.FEE_ACCRUAL(), addr3);
        reg.setAddress(reg.MARKET(), makeAddr("market"));
        reg.setAddress(reg.VAULT_MANAGER(), makeAddr("vm"));
        reg.setAddress(reg.LIQUIDATION_ENGINE(), makeAddr("le"));
        reg.setAddress(reg.ASSET_REGISTRY(), makeAddr("ar"));
        reg.setAddress(reg.PAYMENT_TOKEN_REGISTRY(), makeAddr("ptr"));
        reg.setAddress(reg.TREASURY(), makeAddr("treasury"));
        vm.stopPrank();

        assertEq(reg.oracleVerifier(), addr1);
        assertEq(reg.feeCalculator(), addr2);
        assertEq(reg.feeAccrual(), addr3);
        assertEq(reg.market(), makeAddr("market"));
        assertEq(reg.vaultManager(), makeAddr("vm"));
        assertEq(reg.liquidationEngine(), makeAddr("le"));
        assertEq(reg.assetRegistry(), makeAddr("ar"));
        assertEq(reg.paymentTokenRegistry(), makeAddr("ptr"));
        assertEq(reg.treasury(), makeAddr("treasury"));
    }

    function test_setAddress_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.ZeroAddress.selector);
        reg.setAddress(reg.MARKET(), address(0));
    }

    function test_setAddress_alreadyInitialized_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.AlreadyInitialized.selector);
        reg.setAddress(reg.MARKET(), addr2);
    }

    function test_setAddress_notOwner_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, Actors.ATTACKER));
        reg.setAddress(reg.MARKET(), addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  Timelocked updates — proposeAddress
    // ══════════════════════════════════════════════════════════

    function test_proposeAddress_createsProposal() public {
        // First init
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        // Propose change
        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(reg.MARKET());
        assertEq(newAddr, addr2);
        assertEq(effectiveAt, block.timestamp + TIMELOCK_DELAY);
    }

    function test_proposeAddress_emitsTimelockProposed() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        uint256 expectedEffectiveAt = block.timestamp + TIMELOCK_DELAY;
        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.TimelockProposed(reg.MARKET(), addr2, expectedEffectiveAt);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);
    }

    function test_proposeAddress_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.ZeroAddress.selector);
        reg.proposeAddress(reg.MARKET(), address(0));
    }

    function test_proposeAddress_sameAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.SameAddress.selector);
        reg.proposeAddress(reg.MARKET(), addr1);
    }

    function test_proposeAddress_notOwner_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, Actors.ATTACKER));
        reg.proposeAddress(reg.MARKET(), addr2);
    }

    function test_proposeAddress_overwritesPendingProposal() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        // Overwrite with addr3
        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr3);

        (address newAddr,) = reg.pendingTimelockOf(reg.MARKET());
        assertEq(newAddr, addr3);
    }

    function test_proposeAddress_uninitializedSlot_succeeds() public {
        // Propose on a slot that was never initialized (current = address(0))
        // This should succeed since addr1 != address(0)
        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr1);

        (address newAddr,) = reg.pendingTimelockOf(reg.MARKET());
        assertEq(newAddr, addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  Timelocked updates — executeTimelock
    // ══════════════════════════════════════════════════════════

    function test_executeTimelock_updatesAddress() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        // Warp past timelock
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        reg.executeTimelock(reg.MARKET());

        assertEq(reg.market(), addr2);
    }

    function test_executeTimelock_emitsTimelockExecuted() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.TimelockExecuted(reg.MARKET(), addr1, addr2);

        reg.executeTimelock(reg.MARKET());
    }

    function test_executeTimelock_clearsProposal() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        reg.executeTimelock(reg.MARKET());

        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(reg.MARKET());
        assertEq(newAddr, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_executeTimelock_callableByAnyone() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Anyone can execute
        vm.prank(Actors.ATTACKER);
        reg.executeTimelock(reg.MARKET());

        assertEq(reg.market(), addr2);
    }

    function test_executeTimelock_notProposed_reverts() public {
        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.executeTimelock(reg.MARKET());
    }

    function test_executeTimelock_beforeDelay_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        // Warp to 1 second before timelock
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);

        vm.expectRevert(IProtocolRegistry.TimelockNotReady.selector);
        reg.executeTimelock(reg.MARKET());
    }

    function test_executeTimelock_exactlyAtDelay_succeeds() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        uint256 proposeTime = block.timestamp;
        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        // Warp to exactly the effectiveAt timestamp
        vm.warp(proposeTime + TIMELOCK_DELAY);

        reg.executeTimelock(reg.MARKET());
        assertEq(reg.market(), addr2);
    }

    function test_executeTimelock_doubleExecute_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        reg.executeTimelock(reg.MARKET());

        // Second execute should fail (proposal cleared)
        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.executeTimelock(reg.MARKET());
    }

    // ══════════════════════════════════════════════════════════
    //  Timelocked updates — cancelTimelock
    // ══════════════════════════════════════════════════════════

    function test_cancelTimelock_clearsProposal() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.prank(Actors.ADMIN);
        reg.cancelTimelock(reg.MARKET());

        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(reg.MARKET());
        assertEq(newAddr, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_cancelTimelock_emitsTimelockCancelled() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.expectEmit(true, false, false, false);
        emit IProtocolRegistry.TimelockCancelled(reg.MARKET());

        vm.prank(Actors.ADMIN);
        reg.cancelTimelock(reg.MARKET());
    }

    function test_cancelTimelock_addressUnchanged() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.prank(Actors.ADMIN);
        reg.cancelTimelock(reg.MARKET());

        // Original address should remain
        assertEq(reg.market(), addr1);
    }

    function test_cancelTimelock_notProposed_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.cancelTimelock(reg.MARKET());
    }

    function test_cancelTimelock_notOwner_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, Actors.ATTACKER));
        reg.cancelTimelock(reg.MARKET());
    }

    function test_cancelTimelock_thenExecute_reverts() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);

        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        vm.prank(Actors.ADMIN);
        reg.cancelTimelock(reg.MARKET());

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(IProtocolRegistry.TimelockNotProposed.selector);
        reg.executeTimelock(reg.MARKET());
    }

    // ══════════════════════════════════════════════════════════
    //  Full lifecycle — propose → cancel → re-propose → execute
    // ══════════════════════════════════════════════════════════

    function test_fullLifecycle_proposeCancelRepropose() public {
        // Init
        vm.prank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), addr1);
        assertEq(reg.market(), addr1);

        // Propose addr2
        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr2);

        // Cancel
        vm.prank(Actors.ADMIN);
        reg.cancelTimelock(reg.MARKET());

        // Re-propose addr3
        vm.prank(Actors.ADMIN);
        reg.proposeAddress(reg.MARKET(), addr3);

        // Execute
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        reg.executeTimelock(reg.MARKET());

        assertEq(reg.market(), addr3);
    }

    function test_fullLifecycle_multipleSlots() public {
        vm.startPrank(Actors.ADMIN);

        // Init multiple slots
        reg.setAddress(reg.MARKET(), addr1);
        reg.setAddress(reg.ORACLE_VERIFIER(), addr2);

        // Propose changes on both
        reg.proposeAddress(reg.MARKET(), addr3);
        reg.proposeAddress(reg.ORACLE_VERIFIER(), addr1);

        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Execute both
        reg.executeTimelock(reg.MARKET());
        reg.executeTimelock(reg.ORACLE_VERIFIER());

        assertEq(reg.market(), addr3);
        assertEq(reg.oracleVerifier(), addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  pendingTimelockOf
    // ══════════════════════════════════════════════════════════

    function test_pendingTimelockOf_noProposal_returnsZeros() public view {
        (address newAddr, uint256 effectiveAt) = reg.pendingTimelockOf(reg.MARKET());
        assertEq(newAddr, address(0));
        assertEq(effectiveAt, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Fuzz
    // ══════════════════════════════════════════════════════════

    function testFuzz_setAddress_anyKey(bytes32 key) public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(key, addr1);
    }

    function testFuzz_timelockLifecycle(uint256 delay) public {
        delay = bound(delay, 1, 365 days);

        // Deploy with custom delay
        vm.prank(Actors.ADMIN);
        ProtocolRegistry customReg = new ProtocolRegistry(Actors.ADMIN, delay);

        // Init
        vm.prank(Actors.ADMIN);
        customReg.setAddress(customReg.MARKET(), addr1);

        // Propose
        vm.prank(Actors.ADMIN);
        customReg.proposeAddress(customReg.MARKET(), addr2);

        // Before delay — should revert
        vm.warp(block.timestamp + delay - 1);
        vm.expectRevert(IProtocolRegistry.TimelockNotReady.selector);
        customReg.executeTimelock(customReg.MARKET());

        // At delay — should succeed
        vm.warp(block.timestamp + 1);
        customReg.executeTimelock(customReg.MARKET());
        assertEq(customReg.market(), addr2);
    }
}
