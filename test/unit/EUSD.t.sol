// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEUSD} from "../../src/interfaces/IEUSD.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {Actors} from "../helpers/Actors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Test} from "forge-std/Test.sol";

contract EUSDTest is Test {
    EUSD internal eusd;

    address internal admin = Actors.ADMIN;
    address internal manager = address(uint160(uint256(keccak256("eusdManager"))));
    address internal user = Actors.MINTER1;
    address internal attacker = Actors.ATTACKER;

    uint256 internal constant USER_PK = 0xA11CE;
    address internal permitUser;

    function setUp() public {
        permitUser = vm.addr(USER_PK);
        eusd = new EUSD(admin);
        bytes32 minterRole = eusd.MINTER_ROLE();
        vm.prank(admin);
        eusd.grantRole(minterRole, manager);
    }

    // ──────────────────────────────────────────────────────────
    //  Metadata
    // ──────────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(eusd.name(), "eUSD");
        assertEq(eusd.symbol(), "eUSD");
        assertEq(eusd.decimals(), 18);
    }

    function test_constructor_zeroAdmin_reverts() public {
        vm.expectRevert(IEUSD.ZeroAddress.selector);
        new EUSD(address(0));
    }

    function test_constructor_grantsDefaultAdmin() public view {
        assertTrue(eusd.hasRole(eusd.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(eusd.hasRole(eusd.MINTER_ROLE(), admin));
    }

    // ──────────────────────────────────────────────────────────
    //  Mint
    // ──────────────────────────────────────────────────────────

    function test_mint_byMinter_succeeds() public {
        vm.prank(manager);
        eusd.mint(user, 100e18);
        assertEq(eusd.balanceOf(user), 100e18);
        assertEq(eusd.totalSupply(), 100e18);
    }

    function test_mint_byNonMinter_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, eusd.MINTER_ROLE()
            )
        );
        vm.prank(attacker);
        eusd.mint(attacker, 1e18);
    }

    function test_mint_byAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, eusd.MINTER_ROLE())
        );
        vm.prank(admin);
        eusd.mint(admin, 1e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Burn
    // ──────────────────────────────────────────────────────────

    function test_burn_byMinter_noAllowanceNeeded() public {
        vm.prank(manager);
        eusd.mint(user, 100e18);
        vm.prank(manager);
        eusd.burn(user, 40e18);
        assertEq(eusd.balanceOf(user), 60e18);
        assertEq(eusd.totalSupply(), 60e18);
    }

    function test_burn_byNonMinter_reverts() public {
        vm.prank(manager);
        eusd.mint(user, 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, eusd.MINTER_ROLE()
            )
        );
        vm.prank(attacker);
        eusd.burn(user, 1e18);
    }

    function test_burn_exceedsBalance_reverts() public {
        vm.prank(manager);
        eusd.mint(user, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 100e18, 101e18));
        vm.prank(manager);
        eusd.burn(user, 101e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Role administration
    // ──────────────────────────────────────────────────────────

    function test_grantMinterRole_byNonAdmin_reverts() public {
        bytes32 minterRole = eusd.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, eusd.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        eusd.grantRole(minterRole, attacker);
    }

    function test_revokeMinterRole_stopsMinting() public {
        bytes32 minterRole = eusd.MINTER_ROLE();
        vm.prank(admin);
        eusd.revokeRole(minterRole, manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, manager, eusd.MINTER_ROLE()
            )
        );
        vm.prank(manager);
        eusd.mint(user, 1e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Permit (ERC-2612)
    // ──────────────────────────────────────────────────────────

    function test_permit_setsAllowance() public {
        vm.prank(manager);
        eusd.mint(permitUser, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                permitUser,
                user,
                50e18,
                eusd.nonces(permitUser),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", eusd.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, digest);

        eusd.permit(permitUser, user, 50e18, deadline, v, r, s);
        assertEq(eusd.allowance(permitUser, user), 50e18);
        assertEq(eusd.nonces(permitUser), 1);
    }
}
