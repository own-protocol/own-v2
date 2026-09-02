// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnIncentives} from "../../src/core/OwnIncentives.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";

import {IOwnIncentives} from "../../src/interfaces/IOwnIncentives.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {StakedEUSD} from "../../src/tokens/StakedEUSD.sol";

import {Actors} from "../helpers/Actors.sol";
import {deployStakedEUSD} from "../helpers/DeployEusdModule.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @dev A controller whose hook always reverts — must never brick sEUSD transfers.
contract RevertingController {
    function handleAction(address, uint256, uint256) external pure {
        revert("boom");
    }
}

contract OwnIncentivesTest is Test {
    ProtocolRegistry internal registry;
    EUSD internal eusd;
    StakedEUSD internal sEusd;
    MockERC20 internal own;
    OwnIncentives internal incentives;

    address internal admin = Actors.ADMIN;
    address internal funder = address(uint160(uint256(keccak256("funder"))));
    address internal alice = Actors.MINTER1;
    address internal bob = Actors.MINTER2;

    uint256 internal constant RATE = 1e18; // 1 OWN/sec
    uint256 internal constant VEST = 8 hours;

    function setUp() public {
        vm.warp(1_000_000);

        registry = new ProtocolRegistry(admin, 2 days, 300);
        vm.prank(admin);
        registry.grantRole(keccak256("ADMIN"), admin);

        eusd = new EUSD(admin);
        sEusd = deployStakedEUSD(address(registry), address(eusd), VEST);
        own = new MockERC20("Own", "OWN", 18);
        incentives = new OwnIncentives(address(registry), address(sEusd), address(own));

        vm.prank(admin);
        sEusd.setIncentivesController(address(incentives));

        bytes32 minterRole = eusd.MINTER_ROLE();
        vm.prank(admin);
        eusd.grantRole(minterRole, address(this));

        // Fund an infinite-ish campaign and give users eUSD to deposit into the vault.
        own.mint(funder, 100_000_000e18);
        vm.prank(funder);
        own.approve(address(incentives), type(uint256).max);
        vm.prank(funder);
        incentives.fund(50_000_000e18);
        vm.prank(admin);
        incentives.setDistribution(RATE, block.timestamp + 3650 days);

        address[2] memory users = [alice, bob];
        for (uint256 i; i < users.length; i++) {
            eusd.mint(users[i], 1_000_000e18);
            vm.prank(users[i]);
            eusd.approve(address(sEusd), type(uint256).max);
        }
    }

    // Holding sEUSD earns OWN — no staking step.
    function test_holdersEarnWithoutStaking() public {
        vm.prank(alice);
        sEusd.deposit(1000e18, alice);

        vm.warp(block.timestamp + 100);
        // Sole holder earns the full emission for the window.
        assertApproxEqAbs(incentives.earned(alice), RATE * 100, 1e6, "alice earns whole emission");

        uint256 balBefore = own.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = incentives.claim(alice);
        assertApproxEqAbs(paid, RATE * 100, 1e6);
        assertEq(own.balanceOf(alice) - balBefore, paid);
    }

    // Emission splits pro-rata by sEUSD balance; the transfer hook re-checkpoints both sides.
    function test_proRataAndTransferCheckpoints() public {
        vm.prank(alice);
        sEusd.deposit(300e18, alice); // 75%
        vm.prank(bob);
        sEusd.deposit(100e18, bob); // 25%

        vm.warp(block.timestamp + 100);
        uint256 total = RATE * 100;
        assertApproxEqAbs(incentives.earned(alice), (total * 3) / 4, 1e6, "alice 75%");
        assertApproxEqAbs(incentives.earned(bob), total / 4, 1e6, "bob 25%");

        // Alice sends half her sEUSD to bob; the hook checkpoints both at transfer.
        uint256 aliceEarnedAtXfer = incentives.earned(alice);
        uint256 bobEarnedAtXfer = incentives.earned(bob);
        vm.prank(alice);
        sEusd.transfer(bob, 150e18); // now alice 150, bob 250

        vm.warp(block.timestamp + 100);
        // New split: alice 150/400 = 37.5%, bob 250/400 = 62.5% of the next window.
        assertApproxEqAbs(incentives.earned(alice), aliceEarnedAtXfer + (total * 3) / 8, 1e6, "alice new share");
        assertApproxEqAbs(incentives.earned(bob), bobEarnedAtXfer + (total * 5) / 8, 1e6, "bob new share");
    }

    // Redeeming (burn) stops accrual; the burn hook checkpoints the final balance.
    function test_redeemStopsAccrual() public {
        vm.prank(alice);
        uint256 shares = sEusd.deposit(1000e18, alice);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        sEusd.redeem(shares, alice, alice); // burns all sEUSD
        uint256 earnedAtExit = incentives.earned(alice);

        vm.warp(block.timestamp + 100);
        assertEq(incentives.earned(alice), earnedAtExit, "no accrual after full exit");
    }

    // Claims are capped by the funded budget; remainder stays owed.
    function test_claimCappedByReserve() public {
        uint256 toDrain = incentives.rewardReserve();
        vm.prank(admin);
        incentives.recoverReserve(toDrain, admin); // drain budget
        vm.prank(funder);
        incentives.fund(30e18); // small budget

        vm.prank(alice);
        sEusd.deposit(1000e18, alice);
        vm.warp(block.timestamp + 100); // 100 OWN owed vs 30 funded

        vm.prank(alice);
        uint256 paid = incentives.claim(alice);
        assertEq(paid, 30e18, "paid what budget allowed");
        assertApproxEqAbs(incentives.earned(alice), 70e18, 1e6, "remainder still owed");
    }

    function test_handleActionOnlyFromToken() public {
        vm.prank(alice);
        vm.expectRevert(IOwnIncentives.OnlyStakedToken.selector);
        incentives.handleAction(alice, 1e18, 1e18);
    }

    function test_setDistributionOnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IOwnIncentives.OnlyAdmin.selector);
        incentives.setDistribution(1, block.timestamp + 1 days);
    }

    // ── Partner sweep (pooled holders like Morpho) ────────────

    // A pooled holder (Morpho-like) accrues OWN on-chain; the admin registers it as a partner and
    // anyone can sweep its accrued OWN to Morpho's distributor for onward distribution.
    function test_partnerSweepForwardsPooledAccrual() public {
        address morpho = address(uint160(uint256(keccak256("morpho")))); // pooled sEUSD holder
        address morphoDistributor = address(uint160(uint256(keccak256("merkl"))));

        // Simulate loopers: sEUSD ends up held by the Morpho contract (deposit then transfer in).
        vm.startPrank(alice);
        sEusd.deposit(1000e18, alice);
        sEusd.transfer(morpho, 1000e18); // now Morpho is the holder of record
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        assertApproxEqAbs(incentives.earned(morpho), RATE * 100, 1e6, "pooled address accrues");

        // Morpho cannot self-claim; admin registers it as a partner pointing at its distributor.
        vm.prank(admin);
        incentives.setPartner(morpho, morphoDistributor);
        assertEq(incentives.partnerDestination(morpho), morphoDistributor);

        // Permissionless sweep pushes the pooled OWN to the fixed destination.
        uint256 before = own.balanceOf(morphoDistributor);
        vm.prank(bob); // anyone can call; destination is fixed by admin
        uint256 paid = incentives.sweepPartner(morpho);
        assertApproxEqAbs(paid, RATE * 100, 1e6);
        assertEq(own.balanceOf(morphoDistributor) - before, paid, "OWN forwarded to distributor");
        assertApproxEqAbs(incentives.earned(morpho), 0, 1e6, "partner accrual cleared");
    }

    function test_sweepUnregisteredReverts() public {
        vm.prank(bob);
        vm.expectRevert(IOwnIncentives.NotPartner.selector);
        incentives.sweepPartner(address(0xBEEF));
    }

    function test_setPartnerOnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IOwnIncentives.OnlyAdmin.selector);
        incentives.setPartner(address(0xBEEF), address(0xCAFE));
    }

    // A reverting controller must never brick sEUSD transfers (hook is wrapped in try/catch).
    function test_transfersSurviveBrokenController() public {
        RevertingController broken = new RevertingController();
        vm.prank(admin);
        sEusd.setIncentivesController(address(broken));

        vm.prank(alice);
        sEusd.deposit(1000e18, alice); // must still succeed despite the hook reverting
        assertEq(sEusd.balanceOf(alice), 1000e18);

        vm.prank(alice);
        sEusd.transfer(bob, 400e18); // transfers too
        assertEq(sEusd.balanceOf(bob), 400e18);
    }
}
