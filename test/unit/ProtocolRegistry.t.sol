// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {ProtocolRegistry} from "../../src/registry/ProtocolRegistry.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

/// @title ProtocolRegistry Unit Tests
/// @notice Oracle and treasury setters gated by PROTOCOL_ADMIN (the OZ DEFAULT_ADMIN_ROLE),
///         ADMIN/OPERATOR role administration, and the 2-step delayed PROTOCOL_ADMIN transfer.
contract ProtocolRegistryTest is BaseTest {
    ProtocolRegistry public reg;

    /// @dev Delay (seconds) enforced on transferring PROTOCOL_ADMIN. Fits uint48.
    uint48 constant ADMIN_TRANSFER_DELAY = 2 days;

    bytes32 constant PROTOCOL_ADMIN = 0x00; // == DEFAULT_ADMIN_ROLE

    address public addr1 = makeAddr("addr1");
    address public addr2 = makeAddr("addr2");

    function setUp() public override {
        super.setUp();
        reg = new ProtocolRegistry(Actors.ADMIN, ADMIN_TRANSFER_DELAY);
        vm.label(address(reg), "ProtocolRegistry");
    }

    // ══════════════════════════════════════════════════════════
    //  Constructor
    // ══════════════════════════════════════════════════════════

    function test_constructor_setsAdmin() public view {
        assertEq(reg.owner(), Actors.ADMIN);
        assertTrue(reg.hasRole(PROTOCOL_ADMIN, Actors.ADMIN));
        assertEq(reg.oracle(), address(0));
        assertEq(reg.treasury(), address(0));
    }

    // ══════════════════════════════════════════════════════════
    //  Oracle / treasury
    // ══════════════════════════════════════════════════════════

    function test_setOracle_setsAndEmits() public {
        vm.expectEmit(true, false, false, false);
        emit IProtocolRegistry.OracleSet(addr1);
        vm.prank(Actors.ADMIN);
        reg.setOracle(addr1);
        assertEq(reg.oracle(), addr1);
    }

    function test_setTreasury_setsAndEmits() public {
        vm.expectEmit(true, false, false, false);
        emit IProtocolRegistry.TreasurySet(addr2);
        vm.prank(Actors.ADMIN);
        reg.setTreasury(addr2);
        assertEq(reg.treasury(), addr2);
    }

    function test_setters_zeroAddress_revert() public {
        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.ZeroAddress.selector);
        reg.setOracle(address(0));
        vm.expectRevert(IProtocolRegistry.ZeroAddress.selector);
        reg.setTreasury(address(0));
        vm.stopPrank();
    }

    function test_setters_notProtocolAdmin_revert() public {
        vm.startPrank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, PROTOCOL_ADMIN
            )
        );
        reg.setOracle(addr1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, PROTOCOL_ADMIN
            )
        );
        reg.setTreasury(addr1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Role administration (ADMIN / OPERATOR)
    // ══════════════════════════════════════════════════════════

    function test_roles_administeredByProtocolAdmin() public view {
        assertEq(reg.getRoleAdmin(ADMIN_ROLE), PROTOCOL_ADMIN);
        assertEq(reg.getRoleAdmin(OPERATOR_ROLE), PROTOCOL_ADMIN);
    }

    function test_grantRole_byProtocolAdmin() public {
        vm.startPrank(Actors.ADMIN);
        reg.grantRole(ADMIN_ROLE, addr1);
        reg.grantRole(OPERATOR_ROLE, addr2);
        vm.stopPrank();

        assertTrue(reg.hasRole(ADMIN_ROLE, addr1));
        assertTrue(reg.hasRole(OPERATOR_ROLE, addr2));
    }

    function test_revokeRole_byProtocolAdmin() public {
        vm.startPrank(Actors.ADMIN);
        reg.grantRole(ADMIN_ROLE, addr1);
        reg.revokeRole(ADMIN_ROLE, addr1);
        vm.stopPrank();

        assertFalse(reg.hasRole(ADMIN_ROLE, addr1));
    }

    function test_grantRole_notProtocolAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, PROTOCOL_ADMIN
            )
        );
        reg.grantRole(ADMIN_ROLE, addr1);
    }

    /// @dev PROTOCOL_ADMIN (DEFAULT_ADMIN_ROLE) can never be handed out via grantRole — not even by the
    ///      current admin. It only moves through the delayed 2-step transfer below. This is the guarantee
    ///      that a timelocked PROTOCOL_ADMIN can't be instantly bypassed.
    function test_grantRole_defaultAdmin_directGrant_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        reg.grantRole(PROTOCOL_ADMIN, addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  PROTOCOL_ADMIN transfer — 2-step + delayed (AccessControlDefaultAdminRules)
    // ══════════════════════════════════════════════════════════

    function test_adminTransfer_isTwoStepAndDelayed() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(Actors.ADMIN);
        reg.beginDefaultAdminTransfer(newAdmin);

        // Accepting before the delay elapses reverts.
        vm.prank(newAdmin);
        vm.expectRevert();
        reg.acceptDefaultAdminTransfer();

        // After the delay, the pending admin can accept.
        vm.warp(block.timestamp + ADMIN_TRANSFER_DELAY + 1);
        vm.prank(newAdmin);
        reg.acceptDefaultAdminTransfer();

        assertEq(reg.owner(), newAdmin);
        assertTrue(reg.hasRole(PROTOCOL_ADMIN, newAdmin));
        assertFalse(reg.hasRole(PROTOCOL_ADMIN, Actors.ADMIN));
    }

    function test_adminTransfer_canBeCancelled() public {
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(Actors.ADMIN);
        reg.beginDefaultAdminTransfer(newAdmin);
        reg.cancelDefaultAdminTransfer();
        vm.stopPrank();

        (address pending,) = reg.pendingDefaultAdmin();
        assertEq(pending, address(0));
        assertEq(reg.owner(), Actors.ADMIN); // admin unchanged after cancel
    }
}
