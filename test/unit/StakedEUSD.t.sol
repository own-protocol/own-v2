// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";

import {EUSD} from "../../src/tokens/EUSD.sol";
import {StakedEUSD} from "../../src/tokens/StakedEUSD.sol";
import {Actors} from "../helpers/Actors.sol";
import {deployStakedEUSD} from "../helpers/DeployEusdModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
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
        sEusd = deployStakedEUSD(address(registry), address(eusd), VEST);

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

    // ── Access & top-up ───────────────────────────────────────

    function test_onlyOperatorStreams() public {
        vm.prank(alice);
        vm.expectRevert(StakedEUSD.OnlyOperator.selector);
        sEusd.transferInRewards(1e18);
    }

    // Mid-vest top-up: allowed, continuous (no share-price jump), and rolls the remainder forward.
    function test_topUpMidVestRollsForward() public {
        uint256 taStart = sEusd.totalAssets();

        vm.prank(rewarder);
        sEusd.transferInRewards(100e18);

        vm.warp(block.timestamp + VEST / 2); // ~50e18 of the first batch has vested
        uint256 taMid = sEusd.totalAssets();
        uint256 unvestedMid = sEusd.getUnvestedAmount(); // ~50e18

        // Top up mid-vest — no revert, and totalAssets does not jump at the call.
        vm.prank(rewarder);
        sEusd.transferInRewards(100e18);
        assertApproxEqAbs(sEusd.totalAssets(), taMid, 1, "no jump on top-up");
        // Combined batch = leftover + new, re-vesting from now.
        assertApproxEqAbs(sEusd.getUnvestedAmount(), unvestedMid + 100e18, 1e6, "rolled forward");
        _solvent();

        // After a full fresh window, both batches are fully accrued.
        vm.warp(block.timestamp + VEST);
        assertEq(sEusd.getUnvestedAmount(), 0);
        assertApproxEqAbs(sEusd.totalAssets(), taStart + 200e18, 1e6, "both batches accrued");
        _solvent();
    }

    function test_vaultHoldsNoMinterRole() public view {
        // Solvency guarantee rests on the vault being unable to mint eUSD.
        assertFalse(eusd.hasRole(eusd.MINTER_ROLE(), address(sEusd)));
    }

    // ── Settable vesting period ───────────────────────────────

    // Changing the window mid-vest must not jump totalAssets, and the remainder re-vests over the
    // new window from now.
    function test_setVestingPeriodMidVestIsContinuous() public {
        vm.prank(rewarder);
        sEusd.transferInRewards(800e18);

        vm.warp(block.timestamp + VEST / 2); // ~400e18 vested, ~400e18 unvested
        uint256 taMid = sEusd.totalAssets();
        uint256 unvestedMid = sEusd.getUnvestedAmount();

        vm.prank(admin);
        sEusd.setVestingPeriod(7 days);
        assertEq(sEusd.vestingPeriod(), 7 days);
        assertApproxEqAbs(sEusd.totalAssets(), taMid, 1, "no jump on period change");
        assertApproxEqAbs(sEusd.getUnvestedAmount(), unvestedMid, 1, "remainder re-anchored");

        // Remainder now vests over the NEW 7-day window: half-remaining after 3.5 days.
        vm.warp(block.timestamp + 3.5 days);
        assertApproxEqAbs(sEusd.getUnvestedAmount(), unvestedMid / 2, 1e6, "re-vests over new window");
        vm.warp(block.timestamp + 3.5 days);
        assertEq(sEusd.getUnvestedAmount(), 0, "fully vested over new window");
        _solvent();
    }

    function test_setVestingPeriodOnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(StakedEUSD.OnlyAdmin.selector);
        sEusd.setVestingPeriod(1 days);

        vm.prank(admin);
        vm.expectRevert(StakedEUSD.ZeroAmount.selector);
        sEusd.setVestingPeriod(0);
    }

    // ──────────────────────────────────────────────────────────
    //  UUPS lifecycle
    // ──────────────────────────────────────────────────────────

    function test_metadata_visibleThroughProxy() public view {
        // name/symbol are pinned overrides — constructor-set metadata lives in implementation
        // storage a proxy never sees.
        assertEq(sEusd.name(), "Staked eUSD");
        assertEq(sEusd.symbol(), "sEUSD");
        assertEq(sEusd.asset(), address(eusd));
        assertEq(sEusd.decimals(), 18);
    }

    function test_initialize_bareImplementation_reverts() public {
        StakedEUSD impl = new StakedEUSD(address(eusd));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(registry), VEST);
    }

    function test_initialize_secondCall_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        sEusd.initialize(address(registry), VEST);
    }

    function test_initialize_zeroRegistry_reverts() public {
        StakedEUSD impl = new StakedEUSD(address(eusd));
        bytes memory initData = abi.encodeCall(StakedEUSD.initialize, (address(0), VEST));
        vm.expectRevert(StakedEUSD.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_zeroVestingPeriod_reverts() public {
        StakedEUSD impl = new StakedEUSD(address(eusd));
        bytes memory initData = abi.encodeCall(StakedEUSD.initialize, (address(registry), 0));
        vm.expectRevert(StakedEUSD.ZeroAmount.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_constructor_zeroEusd_reverts() public {
        vm.expectRevert(StakedEUSD.ZeroAddress.selector);
        new StakedEUSD(address(0));
    }

    function test_upgrade_byAdmin_preservesState() public {
        vm.prank(alice);
        sEusd.deposit(1000e18, alice);
        uint256 sharesBefore = sEusd.balanceOf(alice);
        uint256 assetsBefore = sEusd.totalAssets();

        StakedEUSDV2 newImpl = new StakedEUSDV2(address(eusd));
        vm.prank(admin);
        UUPSUpgradeable(address(sEusd)).upgradeToAndCall(address(newImpl), "");

        assertEq(StakedEUSDV2(address(sEusd)).version(), 2);
        assertEq(sEusd.balanceOf(alice), sharesBefore);
        assertEq(sEusd.totalAssets(), assetsBefore);
        assertEq(sEusd.vestingPeriod(), VEST);
    }

    function test_upgrade_byNonAdmin_reverts() public {
        StakedEUSDV2 newImpl = new StakedEUSDV2(address(eusd));
        vm.expectRevert(StakedEUSD.OnlyAdmin.selector);
        vm.prank(attacker);
        UUPSUpgradeable(address(sEusd)).upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_assetMismatch_reverts() public {
        // An implementation built with a different asset must be rejected — the asset is an
        // implementation immutable, so a mismatched build would corrupt the vault's accounting.
        EUSD otherAsset = new EUSD(admin);
        StakedEUSDV2 newImpl = new StakedEUSDV2(address(otherAsset));
        vm.expectRevert(StakedEUSD.UpgradeAssetMismatch.selector);
        vm.prank(admin);
        UUPSUpgradeable(address(sEusd)).upgradeToAndCall(address(newImpl), "");
    }
}

/// @dev Minimal upgraded implementation used only to prove UUPS upgrade wiring works and storage
///      is preserved. Appends no storage; adds one pure function.
contract StakedEUSDV2 is StakedEUSD {
    constructor(
        address eusd_
    ) StakedEUSD(eusd_) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}
