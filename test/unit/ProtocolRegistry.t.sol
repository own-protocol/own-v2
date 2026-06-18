// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

/// @title ProtocolRegistry Unit Tests
/// @notice Tests the registry as the protocol's AccessControl authority: `setAddress`/`setPriceMaxAge`
///         gated by PROTOCOL_ADMIN (the OZ DEFAULT_ADMIN_ROLE), ADMIN/OPERATOR role administration,
///         getters, and the 2-step delayed PROTOCOL_ADMIN transfer (AccessControlDefaultAdminRules).
contract ProtocolRegistryTest is BaseTest {
    ProtocolRegistry public reg;

    /// @dev Delay (seconds) enforced on transferring PROTOCOL_ADMIN. Fits uint48.
    uint48 constant ADMIN_TRANSFER_DELAY = 2 days;
    uint256 constant PRICE_MAX_AGE = 2 minutes;

    bytes32 constant PROTOCOL_ADMIN = 0x00; // == DEFAULT_ADMIN_ROLE

    // Cache key constants to avoid external calls consuming vm.prank
    bytes32 MARKET_KEY;
    bytes32 ASSET_REGISTRY_KEY;

    address public addr1 = makeAddr("addr1");
    address public addr2 = makeAddr("addr2");
    address public addr3 = makeAddr("addr3");

    function setUp() public override {
        super.setUp();

        reg = new ProtocolRegistry(Actors.ADMIN, ADMIN_TRANSFER_DELAY, PRICE_MAX_AGE);
        vm.label(address(reg), "ProtocolRegistry");

        MARKET_KEY = reg.MARKET();
        ASSET_REGISTRY_KEY = reg.ASSET_REGISTRY();
    }

    // ══════════════════════════════════════════════════════════
    //  Constructor
    // ══════════════════════════════════════════════════════════

    function test_constructor_setsAdmin() public view {
        assertEq(reg.owner(), Actors.ADMIN);
        assertTrue(reg.hasRole(PROTOCOL_ADMIN, Actors.ADMIN));
    }

    function test_constructor_allGettersReturnZero() public view {
        assertEq(reg.market(), address(0));
        assertEq(reg.assetRegistry(), address(0));
    }

    function test_constructor_setsPriceMaxAge() public view {
        assertEq(reg.priceMaxAge(), PRICE_MAX_AGE);
    }

    function test_constructor_zeroPriceMaxAge_reverts() public {
        vm.expectRevert(IProtocolRegistry.InvalidPriceMaxAge.selector);
        new ProtocolRegistry(Actors.ADMIN, ADMIN_TRANSFER_DELAY, 0);
    }

    function test_constants_correctHashes() public view {
        assertEq(MARKET_KEY, keccak256("MARKET"));
    }

    // ══════════════════════════════════════════════════════════
    //  setAddress (PROTOCOL_ADMIN-gated; set + overwrite)
    // ══════════════════════════════════════════════════════════

    function test_setAddress_setsValueImmediately() public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
        assertEq(reg.market(), addr1);
    }

    function test_setAddress_emitsAddressSet() public {
        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.AddressSet(MARKET_KEY, address(0), addr1);
        vm.prank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);
    }

    /// @dev The bespoke slot-timelock was removed; setAddress now overwrites (the delay comes from
    ///      PROTOCOL_ADMIN being held by a timelock in production, not from the registry).
    function test_setAddress_overwritesExisting() public {
        vm.startPrank(Actors.ADMIN);
        reg.setAddress(MARKET_KEY, addr1);

        vm.expectEmit(true, false, false, true);
        emit IProtocolRegistry.AddressSet(MARKET_KEY, addr1, addr2);
        reg.setAddress(MARKET_KEY, addr2);
        vm.stopPrank();

        assertEq(reg.market(), addr2);
    }

    /// @dev Every getter must resolve its OWN slot — guards against a mis-wired getter or a duplicated
    ///      slot-key constant (7 distinct addresses written, 7 distinct getters read back).
    function test_getters_allSevenSlotsWiredCorrectly() public {
        address mkt = makeAddr("mkt");
        address ar = makeAddr("ar");
        address pyth = makeAddr("pyth");
        address inhouse = makeAddr("inhouse");
        address factory = makeAddr("factory");
        address vmgr = makeAddr("vmgr");
        address treasury_ = makeAddr("treasury");

        vm.startPrank(Actors.ADMIN);
        reg.setAddress(reg.MARKET(), mkt);
        reg.setAddress(reg.ASSET_REGISTRY(), ar);
        reg.setAddress(reg.PYTH_ORACLE(), pyth);
        reg.setAddress(reg.INHOUSE_ORACLE(), inhouse);
        reg.setAddress(reg.ETOKEN_FACTORY(), factory);
        reg.setAddress(reg.VAULT_MANAGER(), vmgr);
        reg.setAddress(reg.TREASURY(), treasury_);
        vm.stopPrank();

        assertEq(reg.market(), mkt);
        assertEq(reg.assetRegistry(), ar);
        assertEq(reg.pythOracle(), pyth);
        assertEq(reg.inhouseOracle(), inhouse);
        assertEq(reg.etokenFactory(), factory);
        assertEq(reg.vaultManager(), vmgr);
        assertEq(reg.treasury(), treasury_);
    }

    function test_setAddress_zeroAddress_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.ZeroAddress.selector);
        reg.setAddress(MARKET_KEY, address(0));
    }

    function test_setAddress_notProtocolAdmin_reverts() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, Actors.ATTACKER, PROTOCOL_ADMIN
            )
        );
        reg.setAddress(MARKET_KEY, addr1);
    }

    // ══════════════════════════════════════════════════════════
    //  setPriceMaxAge
    // ══════════════════════════════════════════════════════════

    function test_setPriceMaxAge_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit IProtocolRegistry.PriceMaxAgeUpdated(PRICE_MAX_AGE, 5 minutes);
        vm.prank(Actors.ADMIN);
        reg.setPriceMaxAge(5 minutes);
        assertEq(reg.priceMaxAge(), 5 minutes);
    }

    function test_setPriceMaxAge_notProtocolAdmin_reverts() public {
        vm.prank(addr1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, addr1, PROTOCOL_ADMIN)
        );
        reg.setPriceMaxAge(5 minutes);
    }

    function test_setPriceMaxAge_zero_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IProtocolRegistry.InvalidPriceMaxAge.selector);
        reg.setPriceMaxAge(0);
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

    // ══════════════════════════════════════════════════════════
    //  Fuzz
    // ══════════════════════════════════════════════════════════

    function testFuzz_setAddress_anyKey(
        bytes32 key
    ) public {
        vm.prank(Actors.ADMIN);
        reg.setAddress(key, addr1);
    }
}
