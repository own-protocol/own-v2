// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEUSD} from "../../src/interfaces/IEUSD.sol";
import {IERC7802} from "../../src/interfaces/external/IERC7802.sol";
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
        assertEq(eusd.name(), "Own eUSD");
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

    // ──────────────────────────────────────────────────────────
    //  ERC-7802 bridging — limits & authorization
    // ──────────────────────────────────────────────────────────

    address internal bridge = address(uint160(uint256(keccak256("bridge"))));

    uint256 internal constant MINT_LIMIT = 1000e18;
    uint256 internal constant BURN_LIMIT = 500e18;

    function _configureBridge() internal {
        vm.startPrank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        // Generous global cap so per-bridge-limit tests exercise the rate limiter, not the cap.
        eusd.setMaxNetBridgedIn(type(uint256).max / 2);
        vm.stopPrank();
    }

    function test_setBridgeLimits_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit IEUSD.BridgeLimitsSet(bridge, MINT_LIMIT, BURN_LIMIT);
        _configureBridge();

        IEUSD.BridgeConfig memory cfg = eusd.bridgeConfig(bridge);
        assertEq(cfg.mintMaxLimit, MINT_LIMIT);
        assertEq(cfg.burnMaxLimit, BURN_LIMIT);
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT);
        assertEq(eusd.bridgeBurnAvailable(bridge), BURN_LIMIT);
    }

    function test_setBridgeLimits_notAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, eusd.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
    }

    function test_setBridgeLimits_zeroAddress_reverts() public {
        vm.expectRevert(IEUSD.ZeroAddress.selector);
        vm.prank(admin);
        eusd.setBridgeLimits(address(0), MINT_LIMIT, BURN_LIMIT);
    }

    function test_crosschainMint_succeeds() public {
        _configureBridge();
        vm.expectEmit(true, true, false, true);
        emit IERC7802.CrosschainMint(user, 400e18, bridge);
        vm.prank(bridge);
        eusd.crosschainMint(user, 400e18);

        assertEq(eusd.balanceOf(user), 400e18);
        assertEq(eusd.totalSupply(), 400e18);
        assertEq(eusd.netBridgedIn(), 400e18);
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT - 400e18);
        // Burn capacity untouched by mints.
        assertEq(eusd.bridgeBurnAvailable(bridge), BURN_LIMIT);
    }

    function test_crosschainMint_unauthorized_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSD.BridgeLimitExceeded.selector, 1e18, 0));
        vm.prank(attacker);
        eusd.crosschainMint(attacker, 1e18);
    }

    function test_crosschainMint_managerRoleIsNotABridge_reverts() public {
        // MINTER_ROLE conveys no crosschain authority.
        vm.expectRevert(abi.encodeWithSelector(IEUSD.BridgeLimitExceeded.selector, 1e18, 0));
        vm.prank(manager);
        eusd.crosschainMint(user, 1e18);
    }

    function test_crosschainMint_atExactLimit_succeeds() public {
        _configureBridge();
        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT);
        assertEq(eusd.bridgeMintAvailable(bridge), 0);
    }

    function test_crosschainMint_exceedsLimit_reverts() public {
        _configureBridge();
        vm.expectRevert(abi.encodeWithSelector(IEUSD.BridgeLimitExceeded.selector, MINT_LIMIT + 1, MINT_LIMIT));
        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT + 1);
    }

    function test_crosschainMint_limitRefillsLinearly() public {
        _configureBridge();
        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT); // drain the window

        vm.warp(block.timestamp + eusd.LIMIT_DURATION() / 2);
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT / 2);

        vm.warp(block.timestamp + 10 * eusd.LIMIT_DURATION());
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT); // capped at max
    }

    /// @dev A4-I-09: zero-amount bridge calls must not emit spoofable bridge events.
    function test_crosschain_zeroAmount_reverts() public {
        _configureBridge();
        vm.prank(attacker); // any EOA, not even an authorized bridge
        vm.expectRevert(IEUSD.ZeroAmount.selector);
        eusd.crosschainMint(user, 0);
        vm.prank(attacker);
        vm.expectRevert(IEUSD.ZeroAmount.selector);
        eusd.crosschainBurn(user, 0);
        vm.prank(bridge);
        vm.expectRevert(IEUSD.ZeroAmount.selector);
        eusd.crosschainMint(user, 0);
    }

    /// @dev A4-I-10: lowering limits mid-window clamps what the bridge has, never refills it.
    function test_setBridgeLimits_lowerMidWindow_clampsNoRefill() public {
        _configureBridge();
        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT); // window drained
        vm.warp(block.timestamp + eusd.LIMIT_DURATION() / 4); // 250 refilled

        vm.prank(admin);
        eusd.setBridgeLimits(bridge, 100e18, BURN_LIMIT); // incident: cut to 100
        assertEq(eusd.bridgeMintAvailable(bridge), 100e18); // min(250, 100), not a fresh 100 on top
        assertEq(eusd.bridgeBurnAvailable(bridge), BURN_LIMIT); // untouched burn side stays full
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(IEUSD.BridgeLimitExceeded.selector, 100e18 + 1, 100e18));
        eusd.crosschainMint(user, 100e18 + 1);
    }

    function test_setBridgeLimits_raiseMidWindow_noRefill() public {
        _configureBridge();
        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT);
        vm.warp(block.timestamp + eusd.LIMIT_DURATION() / 4); // 250 available

        vm.prank(admin);
        eusd.setBridgeLimits(bridge, 2 * MINT_LIMIT, BURN_LIMIT);
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT / 4); // settled, not reset to 2000
        vm.warp(block.timestamp + eusd.LIMIT_DURATION() / 4); // refills at the new rate: +500
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT / 4 + MINT_LIMIT / 2);
    }

    function test_setBridgeLimits_reauthorizeAfterZero_fullWindow() public {
        _configureBridge();
        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT);
        vm.startPrank(admin);
        eusd.setBridgeLimits(bridge, 0, 0); // emergency de-authorize
        assertEq(eusd.bridgeMintAvailable(bridge), 0);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT); // fresh authorization: full window
        vm.stopPrank();
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT);
    }

    function test_crosschainBurn_succeeds() public {
        _configureBridge();
        vm.prank(manager);
        eusd.mint(user, 300e18);

        vm.expectEmit(true, true, false, true);
        emit IERC7802.CrosschainBurn(user, 300e18, bridge);
        vm.prank(bridge);
        eusd.crosschainBurn(user, 300e18);

        assertEq(eusd.balanceOf(user), 0);
        assertEq(eusd.totalSupply(), 0);
        assertEq(eusd.netBridgedIn(), -300e18);
        assertEq(eusd.bridgeBurnAvailable(bridge), BURN_LIMIT - 300e18);
        assertEq(eusd.bridgeMintAvailable(bridge), MINT_LIMIT);
    }

    function test_crosschainBurn_exceedsLimit_reverts() public {
        _configureBridge();
        vm.prank(manager);
        eusd.mint(user, BURN_LIMIT + 1);
        vm.expectRevert(abi.encodeWithSelector(IEUSD.BridgeLimitExceeded.selector, BURN_LIMIT + 1, BURN_LIMIT));
        vm.prank(bridge);
        eusd.crosschainBurn(user, BURN_LIMIT + 1);
    }

    function test_crosschainBurn_unauthorized_reverts() public {
        vm.prank(manager);
        eusd.mint(user, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSD.BridgeLimitExceeded.selector, 100e18, 0));
        vm.prank(attacker);
        eusd.crosschainBurn(user, 100e18);
    }

    function test_setBridgeLimits_zero_deauthorizesInstantly() public {
        _configureBridge();
        vm.prank(admin);
        eusd.setBridgeLimits(bridge, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSD.BridgeLimitExceeded.selector, 1e18, 0));
        vm.prank(bridge);
        eusd.crosschainMint(user, 1e18);
    }

    /// @dev A4-I-10: re-setting limits on a drained bridge is not a refill.
    function test_setBridgeLimits_drainedBridge_noRefill() public {
        _configureBridge();
        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT); // drained
        vm.prank(admin);
        eusd.setBridgeLimits(bridge, 200e18, BURN_LIMIT);
        assertEq(eusd.bridgeMintAvailable(bridge), 0); // settled 0, clamped — refills at 200/window
        vm.warp(block.timestamp + eusd.LIMIT_DURATION());
        assertEq(eusd.bridgeMintAvailable(bridge), 200e18);
    }

    function test_netBridgedIn_roundTripNetsToZero() public {
        _configureBridge();
        vm.prank(bridge);
        eusd.crosschainMint(user, 100e18);
        vm.prank(bridge);
        eusd.crosschainBurn(user, 100e18);
        assertEq(eusd.netBridgedIn(), 0);
        assertEq(eusd.totalSupply(), 0);
    }

    function test_supportsInterface() public view {
        assertTrue(eusd.supportsInterface(type(IERC7802).interfaceId));
        assertTrue(eusd.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(eusd.supportsInterface(0xffffffff));
    }

    // ──────────────────────────────────────────────────────────
    //  Global net-bridged-in cap
    // ──────────────────────────────────────────────────────────

    function test_maxNetBridgedIn_defaultsToZero() public view {
        assertEq(eusd.maxNetBridgedIn(), 0);
    }

    function test_setMaxNetBridgedIn_succeeds() public {
        vm.expectEmit(false, false, false, true);
        emit IEUSD.MaxNetBridgedInSet(0, 5000e18);
        vm.prank(admin);
        eusd.setMaxNetBridgedIn(5000e18);
        assertEq(eusd.maxNetBridgedIn(), 5000e18);
    }

    function test_setMaxNetBridgedIn_notAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, eusd.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        eusd.setMaxNetBridgedIn(5000e18);
    }

    function test_crosschainMint_defaultCapBlocksInbound() public {
        // Limits set, but cap left at its fail-closed default of 0.
        vm.prank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        vm.expectRevert(abi.encodeWithSelector(IEUSD.GlobalBridgeCapExceeded.selector, int256(1e18), uint256(0)));
        vm.prank(bridge);
        eusd.crosschainMint(user, 1e18);
    }

    function test_crosschainMint_atExactCap_succeeds() public {
        vm.startPrank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        eusd.setMaxNetBridgedIn(300e18);
        vm.stopPrank();

        vm.prank(bridge);
        eusd.crosschainMint(user, 300e18);
        assertEq(eusd.netBridgedIn(), 300e18);
    }

    function test_crosschainMint_exceedsCap_reverts() public {
        vm.startPrank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        eusd.setMaxNetBridgedIn(300e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IEUSD.GlobalBridgeCapExceeded.selector, int256(301e18), uint256(300e18)));
        vm.prank(bridge);
        eusd.crosschainMint(user, 301e18);
    }

    function test_cap_accumulatesAcrossWindows() public {
        // The rate limiter refills, but the global cap does not — a patient drain still stops.
        vm.startPrank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        eusd.setMaxNetBridgedIn(1500e18);
        vm.stopPrank();

        vm.prank(bridge);
        eusd.crosschainMint(user, MINT_LIMIT); // 1000, drains the window
        vm.warp(block.timestamp + eusd.LIMIT_DURATION()); // rate limit refills fully

        // Window allows another 1000, but the cap only allows 500 more.
        vm.expectRevert(
            abi.encodeWithSelector(IEUSD.GlobalBridgeCapExceeded.selector, int256(1501e18), uint256(1500e18))
        );
        vm.prank(bridge);
        eusd.crosschainMint(user, 501e18);

        vm.prank(bridge);
        eusd.crosschainMint(user, 500e18); // exactly reaches the cap
        assertEq(eusd.netBridgedIn(), 1500e18);
    }

    function test_cap_burnRelievesHeadroom() public {
        vm.startPrank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        eusd.setMaxNetBridgedIn(300e18);
        vm.stopPrank();

        vm.prank(bridge);
        eusd.crosschainMint(user, 300e18); // at cap
        vm.prank(bridge);
        eusd.crosschainBurn(user, 200e18); // net 100, frees 200 of headroom
        assertEq(eusd.netBridgedIn(), 100e18);

        vm.prank(bridge);
        eusd.crosschainMint(user, 200e18); // back to cap
        assertEq(eusd.netBridgedIn(), 300e18);
    }

    function test_cap_zero_stillAllowsReimportOfExports() public {
        // Home-chain semantics: cap 0, but a chain that exported eUSD can re-import it (net stays <= 0).
        vm.prank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        // Seed the user with local CDP eUSD, then export it (netBridgedIn goes negative).
        vm.prank(manager);
        eusd.mint(user, 400e18);
        vm.prank(bridge);
        eusd.crosschainBurn(user, 400e18);
        assertEq(eusd.netBridgedIn(), -400e18);

        // Re-importing up to the exported amount is allowed even with cap 0.
        vm.prank(bridge);
        eusd.crosschainMint(user, 400e18);
        assertEq(eusd.netBridgedIn(), 0);

        // But crossing into net-importer territory is blocked by the zero cap.
        vm.expectRevert(abi.encodeWithSelector(IEUSD.GlobalBridgeCapExceeded.selector, int256(1e18), uint256(0)));
        vm.prank(bridge);
        eusd.crosschainMint(user, 1e18);
    }

    function test_setMaxNetBridgedIn_belowCurrent_blocksFurtherInbound() public {
        vm.startPrank(admin);
        eusd.setBridgeLimits(bridge, MINT_LIMIT, BURN_LIMIT);
        eusd.setMaxNetBridgedIn(500e18);
        vm.stopPrank();
        vm.prank(bridge);
        eusd.crosschainMint(user, 400e18);

        // Lower the cap below current net; existing eUSD is undisturbed, new inbound is blocked.
        vm.prank(admin);
        eusd.setMaxNetBridgedIn(400e18);
        assertEq(eusd.netBridgedIn(), 400e18);
        assertEq(eusd.balanceOf(user), 400e18);

        vm.expectRevert(abi.encodeWithSelector(IEUSD.GlobalBridgeCapExceeded.selector, int256(401e18), uint256(400e18)));
        vm.prank(bridge);
        eusd.crosschainMint(user, 1e18);
    }
}
