// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundCurators} from "../../src/interfaces/IFundCurators.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";

contract FundCuratorsTest is FundTestBase {
    address internal curatorC = makeAddr("curatorC");
    uint256 internal constant PROTOCOL_BPS = 3333;

    /// @dev The curators' part of `pot` after the protocol curator's third, split `n` ways.
    function _curatorPart(uint256 pot, uint256 n) internal pure returns (uint256) {
        return (pot - pot * PROTOCOL_BPS / 10_000) / n;
    }

    function setUp() public override {
        super.setUp();
        _launchDefault();
        // Governance starts the epoch after launch.
        _toNextEpoch();
    }

    function test_initialize_setsCuratorsAllCompliant() public view {
        address[] memory cs = curators.curators();
        assertEq(cs.length, 2);
        assertEq(cs[0], curatorA);
        assertEq(cs[1], curatorB);
        assertTrue(curators.isCompliant(curatorA));
        assertTrue(curators.isCompliant(curatorB));
        assertEq(fund.curators(), address(curators));
    }

    function test_fees_splitEquallyAmongCurators() public {
        _poolSwap(bob, true, -int256(10_000e6));
        uint256 pot = usdg.balanceOf(address(curators));
        assertGt(pot, 0);
        uint256 a = curators.claimable(curatorA, address(usdg));
        assertEq(a, curators.claimable(curatorB, address(usdg)));
        assertApproxEqAbs(a, _curatorPart(pot, 2), 1);
        assertEq(curators.claimable(protocolCurator, address(usdg)), pot * PROTOCOL_BPS / 10_000);

        vm.prank(curatorA);
        uint256 got = curators.claim(address(usdg));
        assertEq(got, a);
        assertEq(usdg.balanceOf(curatorA), a);
        assertEq(curators.claimable(curatorA, address(usdg)), 0);
        assertEq(curators.claimable(curatorB, address(usdg)), a);
    }

    function test_fees_inFundTokensFromMintAndRedeem() public {
        _passDepositorLock();
        vm.prank(alice);
        launch.claim(false);
        uint256 shares = fund.balanceOf(alice);
        vm.prank(alice);
        fund.redeem(shares / 2, alice, new uint256[](0), 0);
        uint256 pot = fund.balanceOf(address(curators));
        assertGt(pot, 0);
        assertApproxEqAbs(curators.claimable(curatorA, address(fund)), _curatorPart(pot, 2), 1);
    }

    function test_fees_nonCompliantCuratorStopsEarning() public {
        _stakeAndEscrow(curatorA, 3000e6);
        _toNextEpoch();
        _toNextEpoch();
        governor.flip(); // grace for B
        _toNextEpoch();
        governor.flip(); // B out
        assertTrue(curators.isCompliant(curatorA));
        assertFalse(curators.isCompliant(curatorB));

        uint256 bBefore = curators.claimable(curatorB, address(usdg));
        uint256 aBefore = curators.claimable(curatorA, address(usdg));
        _poolSwap(bob, true, -int256(10_000e6));
        assertEq(curators.claimable(curatorB, address(usdg)), bBefore);
        assertGt(curators.claimable(curatorA, address(usdg)), aBefore);

        // B keeps what it earned while compliant.
        if (bBefore != 0) {
            vm.prank(curatorB);
            assertEq(curators.claim(address(usdg)), bBefore);
        }
    }

    function test_fees_backInComplianceEarnsAgain() public {
        _toNextEpoch();
        governor.flip();
        _toNextEpoch();
        governor.flip();
        assertFalse(curators.isCompliant(curatorB));
        _stakeAndEscrow(curatorB, 3000e6);
        _toNextEpoch();
        _toNextEpoch();
        governor.flip(); // tallies the epoch where B's stake counts
        governor.flip();
        assertTrue(curators.isCompliant(curatorB));
    }

    function test_addCurator_onlyNewFees() public {
        _poolSwap(bob, true, -int256(10_000e6));
        uint256 aBefore = curators.claimable(curatorA, address(usdg));
        vm.prank(admin);
        curators.addCurator(curatorC);
        assertEq(curators.claimable(curatorC, address(usdg)), 0);
        assertEq(curators.claimable(curatorA, address(usdg)), aBefore);

        uint256 potBefore = usdg.balanceOf(address(curators));
        _poolSwap(bob, false, -int256(1000e18));
        uint256 fresh = usdg.balanceOf(address(curators)) - potBefore;
        assertApproxEqAbs(curators.claimable(curatorC, address(usdg)), _curatorPart(fresh, 3), 1);
    }

    function test_addCurator_capReached_reverts() public {
        vm.prank(admin);
        factory.setCuratorCap(2);
        vm.prank(admin);
        vm.expectRevert(IFundCurators.CuratorCapReached.selector);
        curators.addCurator(curatorC);
    }

    function test_removeCurator_keepsOwedFees() public {
        _poolSwap(bob, true, -int256(10_000e6));
        uint256 owed = curators.claimable(curatorB, address(usdg));
        vm.prank(admin);
        curators.removeCurator(curatorB);
        assertFalse(curators.isCurator(curatorB));
        assertEq(curators.claimable(curatorB, address(usdg)), owed);
        vm.prank(curatorB);
        assertEq(curators.claim(address(usdg)), owed);
    }

    function test_replaceCurator_ignoresCap() public {
        vm.prank(admin);
        factory.setCuratorCap(2);
        vm.prank(admin);
        curators.replaceCurator(curatorB, curatorC);
        assertTrue(curators.isCurator(curatorC));
        assertFalse(curators.isCurator(curatorB));
        assertEq(curators.curatorCount(), 2);
    }

    function test_noCompliantCurators_protocolCuratorTakesAll() public {
        vm.startPrank(admin);
        curators.removeCurator(curatorA);
        curators.removeCurator(curatorB);
        vm.stopPrank();
        uint256 before = curators.claimable(protocolCurator, address(usdg));
        _poolSwap(bob, true, -int256(10_000e6));
        uint256 pot = usdg.balanceOf(address(curators)) - before;
        assertGt(pot, 0);
        assertEq(curators.claimable(protocolCurator, address(usdg)), before + pot);
        vm.prank(admin);
        curators.addCurator(curatorC);
        assertEq(curators.claimable(curatorC, address(usdg)), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Protocol curator
    // ──────────────────────────────────────────────────────────

    function test_protocolCurator_alwaysACompliantCurator() public {
        assertEq(curators.protocolCurator(), protocolCurator);
        assertTrue(curators.isCurator(protocolCurator));
        assertTrue(curators.isCompliant(protocolCurator));
        assertEq(curators.curatorCount(), 2); // not counted against the cap
        _toNextEpoch();
        governor.flip();
        _toNextEpoch();
        governor.flip();
        assertTrue(curators.isCompliant(protocolCurator)); // no minimum stake
    }

    function test_protocolCurator_cannotBeAddedOrRemoved() public {
        vm.startPrank(admin);
        vm.expectRevert(IFundCurators.AlreadyCurator.selector);
        curators.addCurator(protocolCurator);
        vm.expectRevert(IFundCurators.NotCurator.selector);
        curators.removeCurator(protocolCurator);
        vm.expectRevert(IFundCurators.NotCurator.selector);
        curators.replaceCurator(protocolCurator, curatorC);
        vm.stopPrank();
    }

    function test_protocolCurator_claimsItsThird() public {
        _poolSwap(bob, true, -int256(10_000e6));
        uint256 pot = usdg.balanceOf(address(curators));
        vm.prank(protocolCurator);
        assertEq(curators.claim(address(usdg)), pot * PROTOCOL_BPS / 10_000);
        assertEq(usdg.balanceOf(protocolCurator), pot * PROTOCOL_BPS / 10_000);
        assertEq(curators.claimable(protocolCurator, address(usdg)), 0);
    }

    function test_protocolCurator_followsTheFactory() public {
        address next = makeAddr("nextProtocol");
        vm.prank(admin);
        factory.setProtocolCurator(next);
        assertTrue(curators.isCurator(next));
        assertFalse(curators.isCurator(protocolCurator));
        (address[] memory accounts, uint256[] memory baseBps,) = curators.voteShares();
        assertEq(accounts[0], next);
        assertEq(baseBps[0], PROTOCOL_BPS);
        assertEq(baseBps[1], (10_000 - PROTOCOL_BPS) / 2);
    }

    // ──────────────────────────────────────────────────────────
    //  Curator yield: staked fund tokens, unlocked every 30 days
    // ──────────────────────────────────────────────────────────

    /// @dev Stakes alice's launch tokens and accrues 8 hours of yield at the ~30% premium.
    function _earnYield() internal returns (uint256 pot) {
        vm.prank(alice);
        launch.claim(true);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        staking.accrue();
        pot = staking.balanceOf(address(curators));
        assertGt(pot, 0);
    }

    function test_curatorYield_lockedUntilPeriodEnds() public {
        uint256 pot = _earnYield();
        (uint256 locked, uint256 unlockAt) = curators.lockedYieldOf(curatorA);
        assertApproxEqAbs(locked, _curatorPart(pot, 2), 1);
        assertEq(unlockAt, (block.timestamp / 30 days + 1) * 30 days);
        assertEq(curators.claimable(curatorA, address(staking)), 0);
        vm.prank(curatorA);
        assertEq(curators.claim(address(staking)), 0);
        // The protocol curator's share is not locked.
        assertEq(curators.claimable(protocolCurator, address(staking)), pot * PROTOCOL_BPS / 10_000);

        vm.warp(unlockAt);
        assertEq(curators.claimable(curatorA, address(staking)), locked);
        (uint256 stillLocked,) = curators.lockedYieldOf(curatorA);
        assertEq(stillLocked, 0);
        vm.prank(curatorA);
        assertEq(curators.claim(address(staking)), locked);
        assertEq(staking.balanceOf(curatorA), locked);
    }

    function test_curatorYield_eachPeriodUnlocksOnItsOwn() public {
        _earnYield();
        (uint256 first, uint256 unlockAt) = curators.lockedYieldOf(curatorA);
        vm.warp(unlockAt + 8 hours);
        _refreshFeeds();
        staking.accrue();
        (uint256 second, uint256 nextUnlock) = curators.lockedYieldOf(curatorA);
        assertGt(second, 0);
        assertEq(nextUnlock, unlockAt + 30 days);
        assertEq(curators.claimable(curatorA, address(staking)), first);
    }

    function test_removeCurator_forfeitsCurrentPeriodAndBurns() public {
        _earnYield();
        (uint256 locked,) = curators.lockedYieldOf(curatorB);
        uint256 supplyBefore = fund.totalSupply();
        uint256 navBefore = fund.navPerShare();
        uint256 potBefore = staking.balanceOf(address(curators));

        vm.expectEmit(true, false, false, false, address(curators));
        emit IFundCurators.YieldForfeited(curatorB, locked, 0);
        vm.prank(admin);
        curators.removeCurator(curatorB);

        assertEq(staking.balanceOf(address(curators)), potBefore - locked);
        assertLt(fund.totalSupply(), supplyBefore);
        assertGt(fund.navPerShare(), navBefore);
        assertEq(curators.claimable(curatorB, address(staking)), 0);
        (uint256 left,) = curators.lockedYieldOf(curatorB);
        assertEq(left, 0);
    }

    function test_removeCurator_keepsUnlockedPeriods() public {
        _earnYield();
        (uint256 locked, uint256 unlockAt) = curators.lockedYieldOf(curatorB);
        vm.warp(unlockAt);
        vm.prank(admin);
        curators.removeCurator(curatorB);
        assertEq(curators.claimable(curatorB, address(staking)), locked);
        vm.prank(curatorB);
        assertEq(curators.claim(address(staking)), locked);
    }

    /// @dev A6-H-03: a boosted module accrues inside the claim's transfer; the claimed shares must
    ///      not be shared out again as fresh income.
    function test_claim_boostedModule_doesNotRecountClaimedShares() public {
        _earnYield();
        address carol = makeAddr("carol");
        _fundSlice(carol, 1e18);
        vm.prank(carol);
        fund.mint(1e18, 0, address(curators), false);
        assertGt(staking.boostOf(address(curators)).usdLeft, 0);

        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        uint256 owed = curators.claimable(protocolCurator, address(staking));
        assertGt(owed, 0);
        vm.prank(protocolCurator);
        assertEq(curators.claim(address(staking)), owed);

        (uint256 lockedA,) = curators.lockedYieldOf(curatorA);
        (uint256 lockedB,) = curators.lockedYieldOf(curatorB);
        uint256 promised = curators.claimable(protocolCurator, address(staking))
            + curators.claimable(curatorA, address(staking)) + curators.claimable(curatorB, address(staking)) + lockedA
            + lockedB;
        assertApproxEqAbs(promised, staking.balanceOf(address(curators)), 4);
    }

    // ──────────────────────────────────────────────────────────
    //  Bribe cut split and income below what is owed
    // ──────────────────────────────────────────────────────────

    function test_bribeSplit_protocolFirstThenCompliantCurators() public view {
        (address[] memory to, uint256[] memory amounts) = curators.bribeSplit(1000);
        assertEq(to.length, 3);
        assertEq(to[0], protocolCurator);
        assertEq(to[1], curatorA);
        assertEq(to[2], curatorB);
        assertEq(amounts[1], _curatorPart(1000, 2));
        assertEq(amounts[2], amounts[1]);
        assertEq(amounts[0] + amounts[1] + amounts[2], 1000);
    }

    function test_bribeSplit_noCompliantCurator_allToProtocol() public {
        vm.startPrank(admin);
        curators.removeCurator(curatorA);
        curators.removeCurator(curatorB);
        vm.stopPrank();
        (address[] memory to, uint256[] memory amounts) = curators.bribeSplit(1000);
        assertEq(to.length, 1);
        assertEq(amounts[0], 1000);
    }

    function test_incomeBelowReserved_doesNotBlock() public {
        usdg.mint(address(curators), 1000e6);
        // Adding a curator shares out the balance, reserving all of it.
        vm.prank(admin);
        curators.addCurator(curatorC);
        uint256 owed = curators.claimable(curatorA, address(usdg));
        assertApproxEqAbs(owed, _curatorPart(1000e6, 2), 1);

        // The balance drops below what is reserved: no new income, and nothing reverts.
        usdg.burn(address(curators), 400e6);
        assertEq(curators.claimable(curatorA, address(usdg)), owed);
        vm.prank(admin);
        curators.removeCurator(curatorC);
        _toNextEpoch();
        governor.flip();
        vm.prank(curatorA);
        assertEq(curators.claim(address(usdg)), owed);
    }

    function test_setMinStake_adminOnly() public {
        vm.prank(curatorA);
        vm.expectRevert(IFundCurators.NotAdmin.selector);
        curators.setMinStake(5000e18);
        vm.prank(admin);
        curators.setMinStake(5000e18);
        assertEq(curators.minStakeUsd(), 5000e18);
    }

    /// @dev A6-M-04: the minimum is a dollar value at NAV, and mints and redeems happen at NAV, so a
    ///      mint just before the flip no longer raises what an honest curator needs.
    function test_checkCompliance_mintBeforeFlipDoesNotFailCurator() public {
        _stakeAndEscrow(curatorA, 3000e6);
        _toNextEpoch();
        uint256 e = governor.currentEpoch();
        uint256 value = governor.stakedAssetsAt(curatorA, e) * fund.navPerShare() / 1e18;
        // Set the minimum just under curatorA's stake.
        vm.prank(admin);
        curators.setMinStake(value * 99 / 100);
        _toNextEpoch();
        // A large mint right before the flip.
        address whale = makeAddr("whale");
        _fundSlice(whale, 500_000e18);
        vm.prank(whale);
        fund.mint(500_000e18, 0, whale, true);
        governor.flip();
        _toNextEpoch();
        _fundSlice(whale, 500_000e18);
        vm.prank(whale);
        fund.mint(500_000e18, 0, whale, true);
        governor.flip();
        assertTrue(curators.isCompliant(curatorA));
        assertFalse(curators.isCompliant(curatorB)); // no stake at all
    }

    function test_checkCompliance_noNavPrice_changesNobody() public {
        _toNextEpoch();
        governor.flip(); // grace for both
        _toNextEpoch();
        vm.warp(block.timestamp + 30 days); // every feed stale
        governor.flip(); // would remove both with a price
        assertTrue(curators.isCompliant(curatorA));
        assertTrue(curators.isCompliant(curatorB));

        _refreshFeeds();
        governor.flip();
        assertFalse(curators.isCompliant(curatorA));
        assertFalse(curators.isCompliant(curatorB));
    }

    function test_checkCompliance_governorOnly() public {
        vm.prank(admin);
        vm.expectRevert(IFundCurators.NotGovernor.selector);
        curators.checkCompliance(1);
    }

    function test_claim_notFeeToken_reverts() public {
        vm.prank(curatorA);
        vm.expectRevert(IFundCurators.NotFeeToken.selector);
        curators.claim(address(net));
    }

    function test_zeroMinStake_alwaysCompliant() public {
        vm.prank(admin);
        curators.setMinStake(0);
        _toNextEpoch();
        governor.flip();
        _toNextEpoch();
        governor.flip();
        assertTrue(curators.isCompliant(curatorA));
        assertTrue(curators.isCompliant(curatorB));
    }
}
