// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {Actors} from "../helpers/Actors.sol";
import {IPaymentTokenRegistry} from "../../src/interfaces/IPaymentTokenRegistry.sol";
import {PaymentTokenRegistry} from "../../src/core/PaymentTokenRegistry.sol";

/// @title PaymentTokenRegistry Unit Tests
/// @notice Tests whitelist add/remove, access control, duplicate/not-found errors,
///         and view functions.
contract PaymentTokenRegistryTest is BaseTest {
    PaymentTokenRegistry public registry;

    function setUp() public override {
        super.setUp();

        vm.prank(Actors.ADMIN);
        registry = new PaymentTokenRegistry(Actors.ADMIN);
        vm.label(address(registry), "PaymentTokenRegistry");
    }

    // ──────────────────────────────────────────────────────────
    //  addPaymentToken
    // ──────────────────────────────────────────────────────────

    function test_addPaymentToken_admin_succeeds() public {
        vm.expectEmit(true, false, false, false);
        emit IPaymentTokenRegistry.PaymentTokenAdded(address(usdc));

        vm.prank(Actors.ADMIN);
        registry.addPaymentToken(address(usdc));

        assertTrue(registry.isWhitelisted(address(usdc)));
    }

    function test_addPaymentToken_multipleTokens() public {
        vm.startPrank(Actors.ADMIN);
        registry.addPaymentToken(address(usdc));
        registry.addPaymentToken(address(usdt));
        registry.addPaymentToken(address(usds));
        vm.stopPrank();

        assertTrue(registry.isWhitelisted(address(usdc)));
        assertTrue(registry.isWhitelisted(address(usdt)));
        assertTrue(registry.isWhitelisted(address(usds)));

        address[] memory tokens = registry.getPaymentTokens();
        assertEq(tokens.length, 3);
    }

    function test_addPaymentToken_nonAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.addPaymentToken(address(usdc));
    }

    function test_addPaymentToken_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IPaymentTokenRegistry.ZeroAddress.selector);
        registry.addPaymentToken(address(0));
    }

    function test_addPaymentToken_duplicate_reverts() public {
        vm.startPrank(Actors.ADMIN);
        registry.addPaymentToken(address(usdc));

        vm.expectRevert(abi.encodeWithSelector(IPaymentTokenRegistry.AlreadyWhitelisted.selector, address(usdc)));
        registry.addPaymentToken(address(usdc));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  removePaymentToken
    // ──────────────────────────────────────────────────────────

    function test_removePaymentToken_admin_succeeds() public {
        vm.startPrank(Actors.ADMIN);
        registry.addPaymentToken(address(usdc));

        vm.expectEmit(true, false, false, false);
        emit IPaymentTokenRegistry.PaymentTokenRemoved(address(usdc));

        registry.removePaymentToken(address(usdc));
        vm.stopPrank();

        assertFalse(registry.isWhitelisted(address(usdc)));
    }

    function test_removePaymentToken_nonAdmin_reverts() public {
        vm.prank(Actors.ADMIN);
        registry.addPaymentToken(address(usdc));

        vm.prank(Actors.ATTACKER);
        vm.expectRevert();
        registry.removePaymentToken(address(usdc));
    }

    function test_removePaymentToken_notWhitelisted_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IPaymentTokenRegistry.NotWhitelisted.selector, address(usdc)));
        registry.removePaymentToken(address(usdc));
    }

    function test_removePaymentToken_updatesGetPaymentTokens() public {
        vm.startPrank(Actors.ADMIN);
        registry.addPaymentToken(address(usdc));
        registry.addPaymentToken(address(usdt));
        registry.removePaymentToken(address(usdc));
        vm.stopPrank();

        address[] memory tokens = registry.getPaymentTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdt));
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    function test_isWhitelisted_defaultFalse() public view {
        assertFalse(registry.isWhitelisted(address(usdc)));
    }

    function test_getPaymentTokens_emptyInitially() public view {
        address[] memory tokens = registry.getPaymentTokens();
        assertEq(tokens.length, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_addRemove_roundtrip(address token) public {
        vm.assume(token != address(0));

        vm.startPrank(Actors.ADMIN);
        registry.addPaymentToken(token);
        assertTrue(registry.isWhitelisted(token));

        registry.removePaymentToken(token);
        assertFalse(registry.isWhitelisted(token));
        vm.stopPrank();
    }
}
