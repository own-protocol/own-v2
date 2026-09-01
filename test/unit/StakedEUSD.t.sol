// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";

import {EUSD} from "../../src/tokens/EUSD.sol";
import {StakedEUSD} from "../../src/tokens/StakedEUSD.sol";
import {Actors} from "../helpers/Actors.sol";
import {Test} from "forge-std/Test.sol";

contract StakedEUSDTest is Test {
    ProtocolRegistry internal registry;
    EUSD internal eusd;
    StakedEUSD internal sEusd;

    address internal admin = Actors.ADMIN;
    address internal rewarder = address(uint160(uint256(keccak256("rewarder")))); // OPERATOR
    address internal alice = Actors.MINTER1;
    address internal bob = Actors.MINTER2;
    address internal attacker = Actors.ATTACKER;

    uint256 internal constant VEST = 8 hours;

    function setUp() public {
        vm.warp(1_000_000);

        registry = new ProtocolRegistry(admin, 2 days, 300);
        vm.startPrank(admin);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), rewarder);
        vm.stopPrank();

        eusd = new EUSD(admin);
        sEusd = new StakedEUSD(address(registry), address(eusd), VEST);

        bytes32 minterRole = eusd.MINTER_ROLE();
        vm.prank(admin);
        eusd.grantRole(minterRole, address(this));

        address[4] memory users = [alice, bob, attacker, rewarder];
        for (uint256 i; i < users.length; i++) {
            eusd.mint(users[i], 1_000_000e18);
            vm.prank(users[i]);
            eusd.approve(address(sEusd), type(uint256).max);
        }

        // Seed dead shares to harden first-depositor inflation.
        eusd.mint(address(this), 1e18);
        eusd.approve(address(sEusd), type(uint256).max);
        sEusd.deposit(1e18, address(0xdead));
    }

    function _solvent() internal view {
        // Redemptions can never exceed the vault's eUSD balance.
        assertLe(sEusd.totalAssets(), eusd.balanceOf(address(sEusd)), "totalAssets <= balance");
    }

    // ── Rewards vest linearly into totalAssets ────────────────

    function test_rewardsVestLinearly() public {
        uint256 taBefore = sEusd.totalAssets();

        vm.prank(rewarder);
        sEusd.transferInRewards(800e18);

        // t=0: whole batch unvested, totalAssets unchanged.
        assertApproxEqAbs(sEusd.getUnvestedAmount(), 800e18, 1, "all unvested at t0");
        assertApproxEqAbs(sEusd.totalAssets(), taBefore, 1, "no jump at t0");
        _solvent();

        // Halfway: half vested.
        vm.warp(block.timestamp + VEST / 2);
        assertApproxEqAbs(sEusd.getUnvestedAmount(), 400e18, 1e6, "half unvested");
        assertApproxEqAbs(sEusd.totalAssets(), taBefore + 400e18, 1e6, "half accrued");
        _solvent();

        // Fully vested.
        vm.warp(block.timestamp + VEST / 2);
        assertEq(sEusd.getUnvestedAmount(), 0, "fully vested");
        assertApproxEqAbs(sEusd.totalAssets(), taBefore + 800e18, 1, "all accrued");
        _solvent();
    }

    // ── Share price rises continuously; yield realized on redeem ──

    function test_sharePriceAppreciatesAndRedeems() public {
        vm.prank(alice);
        uint256 shares = sEusd.deposit(1000e18, alice);

        uint256 assets0 = sEusd.convertToAssets(shares);

        vm.prank(rewarder);
        sEusd.transferInRewards(100e18);
        vm.warp(block.timestamp + VEST);

        uint256 assets1 = sEusd.convertToAssets(shares);
        assertGt(assets1, assets0, "share price rose");

        uint256 balBefore = eusd.balanceOf(alice);
        vm.prank(alice);
        uint256 redeemed = sEusd.redeem(shares, alice, alice);
        assertEq(eusd.balanceOf(alice) - balBefore, redeemed);
        assertGt(redeemed, 1000e18, "redeemed principal + yield");
        _solvent();
    }

    // ── Instant redemption, no cooldown ───────────────────────

    function test_instantRedeemNoCooldown() public {
        vm.startPrank(alice);
        uint256 shares = sEusd.deposit(1000e18, alice);
        uint256 out = sEusd.redeem(shares, alice, alice); // same block
        vm.stopPrank();
        assertApproxEqAbs(out, 1000e18, 1, "full principal back instantly");
        _solvent();
    }

    // ── Sandwich resistance: deposit-before / redeem-after nets ~0 ──

    function test_vestingBlocksRewardSandwich() public {
        vm.prank(alice);
        sEusd.deposit(1000e18, alice);

        vm.prank(rewarder);
        sEusd.transferInRewards(1000e18); // large reward begins vesting

        // Attacker tries to capture it atomically at t=0.
        uint256 balBefore = eusd.balanceOf(attacker);
        vm.startPrank(attacker);
        uint256 shares = sEusd.deposit(1000e18, attacker);
        uint256 out = sEusd.redeem(shares, attacker, attacker);
        vm.stopPrank();

        assertLe(out, 1000e18 + 1, "no reward captured by sandwich");
        assertLe(eusd.balanceOf(attacker), balBefore, "attacker not profitable");
        _solvent();

        // The reward accrues to the honest staker after vesting.
        vm.warp(block.timestamp + VEST);
        assertGt(sEusd.convertToAssets(sEusd.balanceOf(alice)), 1000e18, "alice earned the reward");
    }

    // ── Access & vesting guards ───────────────────────────────

    function test_onlyOperatorStreams() public {
        vm.prank(alice);
        vm.expectRevert(StakedEUSD.OnlyOperator.selector);
        sEusd.transferInRewards(1e18);
    }

    function test_rejectStreamWhileVesting() public {
        vm.prank(rewarder);
        sEusd.transferInRewards(100e18);

        vm.warp(block.timestamp + VEST / 2);
        uint256 unvested = sEusd.getUnvestedAmount();
        vm.prank(rewarder);
        vm.expectRevert(abi.encodeWithSelector(StakedEUSD.StillVesting.selector, unvested));
        sEusd.transferInRewards(100e18);

        // Allowed once fully vested.
        vm.warp(block.timestamp + VEST / 2);
        vm.prank(rewarder);
        sEusd.transferInRewards(100e18);
        assertApproxEqAbs(sEusd.getUnvestedAmount(), 100e18, 1);
    }

    function test_vaultHoldsNoMinterRole() public view {
        // Solvency guarantee rests on the vault being unable to mint eUSD.
        assertFalse(eusd.hasRole(eusd.MINTER_ROLE(), address(sEusd)));
    }
}
