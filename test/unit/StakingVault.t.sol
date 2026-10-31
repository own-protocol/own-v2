// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStakingVault} from "../../src/interfaces/IStakingVault.sol";
import {StakingVault} from "../../src/staking/StakingVault.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract StakingVaultTest is BaseTest {
    MockERC20 internal eusd;
    StakingVault internal vault;

    address internal admin = Actors.ADMIN;
    address internal alice = address(uint160(uint256(keccak256("alice"))));
    address internal bob = address(uint160(uint256(keccak256("bob"))));
    address internal funder = address(uint160(uint256(keccak256("funder"))));
    address internal attacker = Actors.ATTACKER;

    uint256 internal constant YEAR = 365 days;
    uint256 internal constant APR = 2000; // 20%
    uint256 internal constant CAP = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
        eusd = new MockERC20("eUSD", "eUSD", 18);
        vault = new StakingVault(eusd, "Staked eUSD", "seUSD", address(protocolRegistry), APR, CAP);
        _fund(100_000e18);
    }

    // ── Helpers ───────────────────────────────────────────────

    function _fund(
        uint256 amount
    ) internal {
        eusd.mint(funder, amount);
        vm.startPrank(funder);
        eusd.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal returns (uint256 shares) {
        eusd.mint(who, amount);
        vm.startPrank(who);
        eusd.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _exit(
        address who
    ) internal returns (uint256 assets) {
        uint256 shares = vault.balanceOf(who);
        vm.prank(who);
        assets = vault.redeem(shares, who, who);
    }

    // ── Construction ──────────────────────────────────────────

    function test_constructor_setsParams() public view {
        assertEq(vault.asset(), address(eusd));
        assertEq(vault.name(), "Staked eUSD");
        assertEq(vault.symbol(), "seUSD");
        assertEq(vault.decimals(), 18);
        assertEq(vault.aprBps(), APR);
        assertEq(vault.cap(), CAP);
        assertEq(address(vault.registry()), address(protocolRegistry));
    }

    function test_constructor_invalidApr_reverts() public {
        vm.expectRevert(IStakingVault.InvalidApr.selector);
        new StakingVault(eusd, "x", "x", address(protocolRegistry), 10_001, CAP);
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IStakingVault.ZeroAddress.selector);
        new StakingVault(eusd, "x", "x", address(0), APR, CAP);
    }

    // ── Fixed APR ─────────────────────────────────────────────

    function test_deposit_isOneToOne() public {
        uint256 shares = _stake(alice, 1000e18);
        assertEq(shares, 1000e18);
        assertEq(vault.totalAssets(), 1000e18);
    }

    function test_fixedApr_oneYear() public {
        _stake(alice, 1000e18);
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.totalAssets(), 1200e18);
        assertApproxEqAbs(_exit(alice), 1200e18, 2);
        assertEq(vault.rewardReserve(), 100_000e18 - 200e18);
    }

    function test_fixedApr_holdsWhenOthersJoin() public {
        _stake(alice, 1000e18);
        vm.warp(block.timestamp + YEAR / 2);
        _stake(bob, 9000e18);
        vm.warp(block.timestamp + YEAR / 2);

        // Each staker earns 20% simple interest on what they held over each period.
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1100e18 * 110 / 100, 1e6);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 9000e18 * 110 / 100, 1e6);
    }

    function test_fixedApr_holdsWhenOthersLeave() public {
        _stake(alice, 1000e18);
        _stake(bob, 1000e18);
        vm.warp(block.timestamp + YEAR / 2);
        _exit(bob);
        vm.warp(block.timestamp + YEAR / 2);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1100e18 * 110 / 100, 1e6);
    }

    function test_aboveCap_aprFalls() public {
        vm.prank(admin);
        vault.setCap(1000e18);
        _stake(alice, 4000e18);

        assertEq(vault.currentAprBps(), APR / 4);
        assertEq(vault.rewardRate(), 1000e18 * APR / 10_000 / YEAR);

        vm.warp(block.timestamp + YEAR);
        // Drip stays at 20% of the cap: 200 eUSD for the year.
        assertEq(vault.totalAssets(), 4200e18);
    }

    function test_atOrBelowCap_currentAprIsTarget() public {
        _stake(alice, 1000e18);
        assertEq(vault.currentAprBps(), APR);
    }

    function test_noAccrualWithoutStakers() public {
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.rewardReserve(), 100_000e18);
        _stake(alice, 1000e18);
        assertEq(vault.totalAssets(), 1000e18);
    }

    // ── Reserve ───────────────────────────────────────────────

    function test_reserveExhausted_dripStops() public {
        vm.prank(admin);
        vault.withdrawReserve(admin, 100_000e18 - 50e18);
        _stake(alice, 1000e18);

        vm.warp(block.timestamp + YEAR);
        assertEq(vault.totalAssets(), 1050e18);
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.rewardRate(), 0);
        assertEq(vault.currentAprBps(), 0);
    }

    function test_refund_doesNotBackPayEmptyTime() public {
        vm.prank(admin);
        vault.withdrawReserve(admin, 100_000e18);
        _stake(alice, 1000e18);

        vm.warp(block.timestamp + YEAR / 2);
        _fund(1000e18);
        assertEq(vault.totalAssets(), 1000e18);

        vm.warp(block.timestamp + YEAR / 2);
        assertEq(vault.totalAssets(), 1100e18);
    }

    function test_fund_emitsAndTracks() public {
        eusd.mint(funder, 5e18);
        vm.startPrank(funder);
        eusd.approve(address(vault), 5e18);
        vm.expectEmit(address(vault));
        emit IStakingVault.ReserveFunded(funder, 5e18);
        vault.fund(5e18);
        vm.stopPrank();
        assertEq(vault.rewardReserve(), 100_005e18);
    }

    function test_fund_zero_reverts() public {
        vm.expectRevert(IStakingVault.ZeroAmount.selector);
        vault.fund(0);
    }

    function test_pullFromTreasury_fundsReserve() public {
        address treasury = makeAddr("treasury");
        vm.prank(admin);
        protocolRegistry.setTreasury(treasury);
        eusd.mint(treasury, 3000e18);
        vm.prank(treasury);
        eusd.approve(address(vault), type(uint256).max);

        vm.expectEmit(address(vault));
        emit IStakingVault.ReserveFunded(treasury, 3000e18);
        vm.prank(admin);
        vault.pullFromTreasury(3000e18);

        assertEq(vault.rewardReserve(), 103_000e18);
        assertEq(eusd.balanceOf(treasury), 0);
    }

    function test_pullFromTreasury_onlyOperator() public {
        vm.expectRevert(IStakingVault.OnlyOperator.selector);
        vm.prank(attacker);
        vault.pullFromTreasury(1);
    }

    function test_withdrawReserve_onlyAdmin() public {
        vm.expectRevert(IStakingVault.OnlyAdmin.selector);
        vm.prank(attacker);
        vault.withdrawReserve(attacker, 1);
    }

    function test_withdrawReserve_neverTouchesStake() public {
        _stake(alice, 1000e18);
        vm.warp(block.timestamp + YEAR);
        uint256 unspent = 100_000e18 - 200e18;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IStakingVault.InsufficientReserve.selector, unspent + 1, unspent));
        vault.withdrawReserve(admin, unspent + 1);

        vm.prank(admin);
        vault.withdrawReserve(admin, unspent);
        assertEq(eusd.balanceOf(admin), unspent);
        assertApproxEqAbs(_exit(alice), 1200e18, 2);
    }

    function test_donation_doesNotMoveSharePrice() public {
        _stake(alice, 1000e18);
        eusd.mint(address(vault), 1_000_000e18);
        assertEq(vault.totalAssets(), 1000e18);
        assertEq(_stake(bob, 1000e18), 1000e18);
    }

    // ── Admin ─────────────────────────────────────────────────

    function test_setApr_accruesAtOldRateFirst() public {
        _stake(alice, 1000e18);
        vm.warp(block.timestamp + YEAR / 2);
        vm.prank(admin);
        vault.setApr(800);
        vm.warp(block.timestamp + YEAR / 2);
        // 10% for the first half (20% APR), then 4% on 1100 for the second half (8% APR).
        assertEq(vault.totalAssets(), 1100e18 + 44e18);
    }

    function test_setApr_invalid_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IStakingVault.InvalidApr.selector);
        vault.setApr(10_001);
    }

    function test_setCap_accruesAtOldCapFirst() public {
        _stake(alice, 2000e18);
        vm.warp(block.timestamp + YEAR / 2);
        vm.prank(admin);
        vault.setCap(1000e18);
        vm.warp(block.timestamp + YEAR / 2);
        // 200 on 2000 for the first half, then 100 (20% of the 1000 cap for half a year).
        assertEq(vault.totalAssets(), 2200e18 + 100e18);
    }

    function test_admin_onlyAdmin() public {
        vm.startPrank(attacker);
        vm.expectRevert(IStakingVault.OnlyAdmin.selector);
        vault.setApr(100);
        vm.expectRevert(IStakingVault.OnlyAdmin.selector);
        vault.setCap(1);
        vm.stopPrank();
    }

    // ── Fuzz ──────────────────────────────────────────────────

    /// @dev Stakers can never take out more than they put in plus what was funded.
    function testFuzz_payoutBoundedByStakeAndReserve(uint96 a, uint96 b, uint32 t1, uint32 t2) public {
        uint256 amountA = bound(a, 1e18, 10_000_000e18);
        uint256 amountB = bound(b, 1e18, 10_000_000e18);
        _stake(alice, amountA);
        vm.warp(block.timestamp + bound(t1, 0, 2 * YEAR));
        _stake(bob, amountB);
        vm.warp(block.timestamp + bound(t2, 0, 2 * YEAR));

        uint256 out = _exit(alice) + _exit(bob);
        assertLe(out, amountA + amountB + 100_000e18);
        assertLe(vault.totalAssets(), 2);
        assertEq(eusd.balanceOf(address(vault)), vault.totalAssets() + vault.rewardReserve());
    }
}
