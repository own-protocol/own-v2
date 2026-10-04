// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundCurators} from "../../src/interfaces/IFundCurators.sol";
import {IFundGovernor} from "../../src/interfaces/IFundGovernor.sol";
import {GovernanceConfig} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract WrappedStake is ERC4626 {
    constructor(
        IERC20 staked
    ) ERC20("Wrapped sOCF1", "wsOCF1") ERC4626(staked) {}
}

contract FundGovernorTest is FundTestBase {
    uint256 internal constant WAD = 1e18;

    /// @dev Alice's staked shares from her launch claim; the only staked tokens at the start.
    uint256 internal aliceStake;
    address internal newCurator = makeAddr("newCurator");

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        aliceStake = launch.claim(true);
        vm.prank(bob);
        launch.claim(false);
        vm.prank(admin);
        factory.setEligibleAsset(address(spare), true);
    }

    // ──────────────────────────────────────────────────────────
    //  Escrow
    // ──────────────────────────────────────────────────────────

    function test_deposit_countsFromNextEpoch() public {
        _escrow(alice, 1000e18);
        uint256 e = governor.currentEpoch();
        assertEq(governor.powerAt(alice, e), 0);
        assertEq(governor.powerAt(alice, e + 1), 1000e18);
        assertEq(governor.totalPowerAt(e + 1), 1000e18);
        assertEq(governor.escrowOf(alice, address(staking)), 1000e18);
        assertEq(governor.lastDepositAt(alice), block.timestamp);
    }

    function test_deposit_notVoteToken_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.NotVoteToken.selector);
        governor.deposit(address(fund), 1e18);
    }

    function test_requestWithdrawal_stopsCountingAtOnceAndUnlocksAtFlip() public {
        _escrow(alice, 1000e18);
        _toNextEpoch();
        uint256 e = governor.currentEpoch();
        assertEq(governor.powerAt(alice, e), 1000e18);

        vm.prank(alice);
        governor.requestWithdrawal(address(staking), 400e18);
        assertEq(governor.powerAt(alice, e), 600e18);
        assertEq(governor.powerAt(alice, e + 1), 600e18);
        assertEq(governor.unlockAt(alice), (e + 1) * 1 weeks);
        assertEq(governor.escrowOf(alice, address(staking)), 1000e18);

        vm.prank(alice);
        vm.expectRevert(IFundGovernor.TokensLocked.selector);
        governor.withdraw(address(staking));

        _toNextEpoch();
        uint256 before = staking.balanceOf(alice);
        vm.prank(alice);
        governor.withdraw(address(staking));
        assertEq(staking.balanceOf(alice), before + 400e18);
        assertEq(governor.escrowOf(alice, address(staking)), 600e18);
    }

    function test_requestWithdrawal_pendingPowerGoesFirst() public {
        _escrow(alice, 1000e18);
        _toNextEpoch();
        _escrow(alice, 500e18);
        uint256 e = governor.currentEpoch();
        vm.prank(alice);
        governor.requestWithdrawal(address(staking), 700e18);
        // The 500 deposited this epoch go first; only 200 of the active 1000 stop counting.
        assertEq(governor.powerAt(alice, e), 800e18);
        assertEq(governor.powerAt(alice, e + 1), 800e18);
    }

    function test_requestWithdrawal_moreThanEscrowed_reverts() public {
        _escrow(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.InsufficientEscrow.selector);
        governor.requestWithdrawal(address(staking), 1001e18);
    }

    function test_withdraw_waitsForVotedProposalToEnd() public {
        _escrow(alice, aliceStake);
        vm.warp(block.timestamp + 1);
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(alice);
        governor.castVote(id, true);
        // Move to the last day of the epoch, so the vote ends after the next flip.
        uint256 e = governor.currentEpoch();
        vm.warp((e + 1) * 1 weeks - 1 days);
        vm.prank(alice);
        governor.requestWithdrawal(address(staking), 1e18);
        assertEq(governor.unlockAt(alice), governor.getProposal(id).endTime);
    }

    // ──────────────────────────────────────────────────────────
    //  Bribe lock
    // ──────────────────────────────────────────────────────────

    function test_lockForBribes_setsEpochAndRevertsTwice() public {
        uint256 e = governor.currentEpoch();
        vm.expectEmit(address(governor));
        emit IFundGovernor.BribeLocked(alice, e);
        vm.prank(alice);
        governor.lockForBribes();
        assertEq(governor.bribeLockedFrom(alice), e);

        vm.prank(alice);
        vm.expectRevert(IFundGovernor.AlreadyBribeLocked.selector);
        governor.lockForBribes();
    }

    function test_requestWithdrawal_lockedWaitsBribeLock() public {
        _escrow(alice, 1000e18);
        vm.prank(alice);
        governor.lockForBribes();
        _toNextEpoch();
        _toNextEpoch();

        vm.prank(alice);
        governor.requestWithdrawal(address(staking), 400e18);
        assertEq(governor.unlockAt(alice), block.timestamp + 28 days);
        // Stops counting at once, as for any withdrawal.
        assertEq(governor.powerAt(alice, governor.currentEpoch()), 600e18);

        _toNextEpoch();
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.TokensLocked.selector);
        governor.withdraw(address(staking));

        vm.warp(governor.unlockAt(alice));
        vm.prank(alice);
        assertEq(governor.withdraw(address(staking)), 400e18);
    }

    function test_requestWithdrawal_lockIsRolling() public {
        _escrow(alice, 1000e18);
        vm.prank(alice);
        governor.lockForBribes();
        // Months later the exit still takes the full lock.
        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        governor.requestWithdrawal(address(staking), 1000e18);
        assertEq(governor.unlockAt(alice), block.timestamp + 28 days);
    }

    function test_bribeVotes_followLockedStake() public {
        _escrow(alice, 1000e18);
        _voteAll(alice, address(tsla));
        uint256 e = governor.currentEpoch() + 1;
        assertEq(governor.bribeVotes(address(tsla), e), 0);
        assertEq(governor.bribeVotesOf(alice, address(tsla), e), 0);

        vm.prank(alice);
        governor.lockForBribes();
        assertEq(governor.bribeVotes(address(tsla), e), 1000e18);
        assertEq(governor.bribeVotesOf(alice, address(tsla), e), 1000e18);

        // Splitting the vote and adding stake move the bribe tally with it.
        address[] memory t = new address[](2);
        uint16[] memory w = new uint16[](2);
        (t[0], t[1], w[0], w[1]) = (address(tsla), address(pons), 6000, 4000);
        vm.prank(alice);
        governor.vote(t, w);
        _escrow(alice, 500e18);
        assertEq(governor.bribeVotes(address(tsla), e), 900e18);
        assertEq(governor.bribeVotes(address(pons), e), 600e18);

        vm.prank(alice);
        governor.requestWithdrawal(address(staking), 1500e18);
        assertEq(governor.bribeVotes(address(tsla), e), 0);
        assertEq(governor.bribeVotes(address(pons), e), 0);
    }

    function test_bribeVotesOf_zeroBeforeLockEpoch() public {
        _escrow(alice, 1000e18);
        _voteAll(alice, address(tsla));
        _toNextEpoch();
        uint256 before = governor.currentEpoch();
        _toNextEpoch();
        vm.prank(alice);
        governor.lockForBribes();
        uint256 e = governor.currentEpoch();
        assertEq(governor.bribeVotesOf(alice, address(tsla), before), 0);
        assertEq(governor.bribeVotes(address(tsla), before), 0);
        assertEq(governor.bribeVotesOf(alice, address(tsla), e), 1000e18);
        assertEq(governor.bribeVotes(address(tsla), e), 1000e18);
    }

    function test_castVote_curatorSliceNeverCountsForListingBribes() public {
        _escrow(alice, aliceStake);
        vm.prank(alice);
        governor.lockForBribes();
        vm.warp(block.timestamp + 1);
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(curatorA);
        governor.castVote(id, true);
        vm.prank(alice);
        governor.castVote(id, true);
        assertEq(governor.proposalVote(id, curatorA).bribeVotes, 0);
        assertEq(governor.proposalVote(id, alice).bribeVotes, aliceStake);
        assertEq(governor.getProposal(id).bribeYesVotes, aliceStake);
    }

    function test_escrowedStakeKeepsEarningYield() public {
        _escrow(alice, aliceStake);
        uint256 e = governor.currentEpoch() + 1;
        uint256 before = governor.stakedAssetsAt(alice, e);
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        staking.accrue();
        assertGt(governor.stakedAssetsAt(alice, e), before);
    }

    function test_wrapper_depositCountsInStakedShares() public {
        WrappedStake w = new WrappedStake(IERC20(address(staking)));
        vm.prank(keeper);
        vm.expectRevert(IFundGovernor.NotAdmin.selector);
        governor.setWrapper(address(w), true);
        vm.prank(admin);
        governor.setWrapper(address(w), true);
        assertTrue(governor.isVoteToken(address(w)));

        _passDepositorLock();
        vm.startPrank(alice);
        staking.approve(address(w), 1000e18);
        uint256 wrapped = w.deposit(1000e18, alice);
        w.approve(address(governor), wrapped);
        governor.deposit(address(w), wrapped);
        vm.stopPrank();
        assertEq(governor.powerAt(alice, governor.currentEpoch() + 1), 1000e18);
    }

    function test_setWrapper_wrongAsset_reverts() public {
        WrappedStake w = new WrappedStake(IERC20(address(fund)));
        vm.prank(admin);
        vm.expectRevert(IFundGovernor.InvalidWrapper.selector);
        governor.setWrapper(address(w), true);
    }

    // ──────────────────────────────────────────────────────────
    //  Gauge: votes
    // ──────────────────────────────────────────────────────────

    function test_vote_invalidAllocations_revert() public {
        address[] memory t = new address[](2);
        uint16[] memory w = new uint16[](2);
        t[0] = address(net);
        t[1] = address(tsla);
        w[0] = 5000;
        w[1] = 4999;
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.InvalidAllocation.selector);
        governor.vote(t, w); // sum

        w[1] = 5000;
        t[1] = address(net);
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.InvalidAllocation.selector);
        governor.vote(t, w); // duplicate

        t[1] = address(spare);
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.InvalidAllocation.selector);
        governor.vote(t, w); // not in the basket

        t[1] = address(tsla);
        w[0] = 10_000;
        w[1] = 0;
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.InvalidAllocation.selector);
        governor.vote(t, w); // zero weight

        vm.prank(admin);
        governor.setDelisted(address(tsla), true);
        w[0] = 5000;
        w[1] = 5000;
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.InvalidAllocation.selector);
        governor.vote(t, w); // delisted
    }

    function test_vote_beforeLaunch_reverts() public {
        _createFund();
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.NotLaunched.selector);
        governor.vote(new address[](0), new uint16[](0));
    }

    function test_vote_carriesOverAndCanGoSilent() public {
        _escrow(alice, 1000e18);
        _voteAll(alice, address(tsla));
        uint256 e = governor.currentEpoch();
        (address[] memory t,) = governor.allocationAt(alice, e + 5);
        assertEq(t[0], address(tsla));

        _toNextEpoch();
        vm.prank(alice);
        governor.vote(new address[](0), new uint16[](0));
        (t,) = governor.allocationAt(alice, e);
        assertEq(t.length, 1);
        (t,) = governor.allocationAt(alice, e + 1);
        assertEq(t.length, 0);
    }

    function test_votesOf_curatorSliceAndStakeOnTop() public {
        _escrow(alice, aliceStake);
        _voteAll(alice, address(tsla));
        _voteAll(curatorA, address(tsla));
        uint256 e = governor.currentEpoch() + 1;
        _toNextEpoch();
        _toNextEpoch();
        governor.flip(); // tallies e

        // curatorA: half of the curators' 30%. Alice: all the staked tokens, so the stakers' 70%.
        assertEq(governor.votesOf(curatorA, address(tsla), e), 0.15e18);
        assertApproxEqAbs(governor.votesOf(alice, address(tsla), e), 0.7e18, 1);
        assertApproxEqAbs(governor.tokenVotes(address(tsla), e), 0.85e18, 1);
        assertEq(governor.votesOf(curatorB, address(tsla), e), 0);
        assertEq(governor.votesOf(alice, address(net), e), 0);
    }

    function test_votesOf_unescrowedStakeIsSilent() public {
        // Alice escrows a fifth of the staked tokens: a fifth of the stakers' 70%.
        _escrow(alice, aliceStake / 5);
        _voteAll(alice, address(tsla));
        uint256 e = governor.currentEpoch() + 1;
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        assertApproxEqRel(governor.votesOf(alice, address(tsla), e), 0.14e18, 1e12);
    }

    function test_votesOf_silentStakersFollowCurators() public {
        // Nobody stakes a vote: the stakers' 70% follows the two curators, 35% each.
        _voteAll(curatorA, address(tsla));
        _voteAll(curatorB, address(pons));
        uint256 e = governor.currentEpoch();
        _toNextEpoch();
        governor.flip();
        assertEq(governor.votesOf(curatorA, address(tsla), e), 0.5e18);
        assertEq(governor.votesOf(curatorB, address(pons), e), 0.5e18);
        assertEq(governor.tokenVotes(address(tsla), e), 0.5e18);
        assertEq(governor.tokenVotes(address(pons), e), 0.5e18);
        assertEq(governor.tokenVotes(address(net), e), 0);
    }

    function test_votesOf_votingStakersKeepTheirShare() public {
        // Alice votes a fifth of the staked tokens (14%); the silent 56% follows the curators.
        _escrow(alice, aliceStake / 5);
        _voteAll(alice, address(net));
        _voteAll(curatorA, address(tsla));
        _voteAll(curatorB, address(tsla));
        uint256 e = governor.currentEpoch() + 1;
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        assertApproxEqRel(governor.tokenVotes(address(net), e), 0.14e18, 1e12);
        assertApproxEqRel(governor.tokenVotes(address(tsla), e), 0.86e18, 1e12);
        assertApproxEqRel(governor.votesOf(curatorA, address(tsla), e), 0.43e18, 1e12);
    }

    function test_votesOf_silentCuratorsPartHoldsWeights() public {
        // CuratorB is silent: its slice and its half of the silent stakers keep the weights.
        _voteAll(curatorA, address(tsla));
        uint256 e = governor.currentEpoch();
        _toNextEpoch();
        governor.flip();
        assertEq(governor.tokenVotes(address(tsla), e), 0.5e18);
        assertEq(governor.votesOf(curatorB, address(tsla), e), 0);
    }

    function test_flip_curatorsSteerSilentMajorityWithinGuardrails() public {
        _liftCap();
        _voteAll(curatorA, address(tsla));
        _voteAll(curatorB, address(tsla));
        _toNextEpoch();
        governor.flip();
        // Every vote is for TSLA, but it still moves only 5 points a week.
        assertApproxEqAbs(fund.targetWeightBps(address(tsla)), 3500, 1);
        _assertSum();
    }

    // ──────────────────────────────────────────────────────────
    //  Gauge: flip
    // ──────────────────────────────────────────────────────────

    function test_flip_noVotes_keepsWeights() public {
        _liftCap();
        _toNextEpoch();
        governor.flip();
        assertEq(fund.targetWeightBps(address(net)), 4000);
        assertEq(fund.targetWeightBps(address(pons)), 3000);
        assertEq(fund.targetWeightBps(address(tsla)), 3000);
    }

    function test_flip_noVotes_weightAboveCapStillComesDown() public {
        // With three tokens the cap is a third; NET starts at 40% and moves toward it.
        _toNextEpoch();
        governor.flip();
        assertEq(fund.targetWeightBps(address(net)), 3502);
        for (uint256 i; i < 3; ++i) {
            _toNextEpoch();
            governor.flip();
        }
        assertApproxEqAbs(fund.targetWeightBps(address(net)), 3334, 1);
        _assertSum();
    }

    function test_flip_oncePerEpoch() public {
        _toNextEpoch();
        governor.flip();
        vm.expectRevert(IFundGovernor.NothingToTally.selector);
        governor.flip();
        assertEq(governor.nextEpochToTally(), governor.currentEpoch());
    }

    function test_flip_catchesUpSkippedEpochsInOrder() public {
        _toNextEpoch();
        governor.flip();
        uint256 first = governor.nextEpochToTally();
        vm.warp(block.timestamp + 3 weeks);
        _refreshFeeds();
        governor.flip();
        governor.flip();
        governor.flip();
        assertTrue(governor.isTallied(first));
        assertTrue(governor.isTallied(first + 2));
        vm.expectRevert(IFundGovernor.NothingToTally.selector);
        governor.flip();
    }

    function test_flip_beforeLaunch_reverts() public {
        _createFund();
        vm.expectRevert(IFundGovernor.NotLaunched.selector);
        governor.flip();
    }

    /// @dev The spec's example: no curator votes and 15% of the staked tokens vote all for a newly
    ///      listed token (the cap is lifted here, as the example ignores it).
    function test_flip_specExample_newTokenMovesFivePointsAWeek() public {
        _listSpare();
        _liftCap();

        _escrow(alice, aliceStake * 15 / 100);
        _voteAll(alice, address(spare));
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();

        // Target: spare 10.5%, the rest keep 89.5% of their weights. Everything moves the same
        // fraction (5 / 10.5) of the way, so spare gets 5 points (less a rounding unit).
        assertApproxEqAbs(fund.targetWeightBps(address(spare)), 500, 1);
        assertApproxEqAbs(fund.targetWeightBps(address(net)), 3800, 3); // takes the rounding dust
        assertApproxEqAbs(fund.targetWeightBps(address(pons)), 2850, 1);
        assertApproxEqAbs(fund.targetWeightBps(address(tsla)), 2850, 1);
        _assertSum();

        // Silent votes then hold spare's new 5% as well, so the target keeps growing:
        // 10.5% + 89.5% x 5% = 14.975%, and spare moves another 5 points.
        _toNextEpoch();
        governor.flip();
        assertApproxEqAbs(fund.targetWeightBps(address(spare)), 1000, 2);
        _toNextEpoch();
        governor.flip();
        assertApproxEqAbs(fund.targetWeightBps(address(spare)), 1500, 3);
        _assertSum();
    }

    function test_flip_noWeekMovesMoreThanFivePoints() public {
        _voteAll(curatorA, address(tsla));
        _voteAll(curatorB, address(tsla));
        uint16[3] memory old = [uint16(4000), 3000, 3000];
        _toNextEpoch();
        for (uint256 i; i < 6; ++i) {
            governor.flip();
            uint16[3] memory now_ = _weights3();
            for (uint256 j; j < 3; ++j) {
                uint256 d = now_[j] > old[j] ? now_[j] - old[j] : old[j] - now_[j];
                assertLe(d, 500);
            }
            _assertSum();
            old = now_;
            _toNextEpoch();
        }
        assertGt(fund.targetWeightBps(address(tsla)), 3000);
    }

    function test_flip_capsEveryTokenAtTwentyFivePercent() public {
        _listSpare();
        _escrow(alice, aliceStake);
        _voteAll(alice, address(spare));
        _toNextEpoch();
        for (uint256 i; i < 12; ++i) {
            _toNextEpoch();
            governor.flip();
        }
        address[] memory a = fund.assets();
        for (uint256 i; i < a.length; ++i) {
            assertLe(fund.targetWeightBps(a[i]), 2500);
        }
        assertEq(fund.targetWeightBps(address(spare)), 2500);
        _assertSum();
    }

    function test_flip_underMinimumVoteForFourWeeks_dropsDustToken() public {
        _listSpare(); // joins at weight 0 with no balance
        _toNextEpoch();
        for (uint256 i; i < 3; ++i) {
            governor.flip();
            assertTrue(fund.isAsset(address(spare)));
            _toNextEpoch();
        }
        assertEq(governor.lowStreak(address(spare)), 3);
        governor.flip();
        assertFalse(fund.isAsset(address(spare)));
        assertEq(fund.assets().length, 3);
        _assertSum();
    }

    function test_flip_delistedTokenGoesToZeroButStaysWhileHeld() public {
        vm.prank(admin);
        governor.setDelisted(address(pons), true);
        _toNextEpoch();
        for (uint256 i; i < 10; ++i) {
            governor.flip();
            _toNextEpoch();
        }
        assertEq(fund.targetWeightBps(address(pons)), 0);
        assertTrue(fund.isAsset(address(pons))); // still holds $30k of PONS
        _assertSum();
    }

    function test_flip_curatorBelowMinimumStake_losesSliceAfterGrace() public {
        _liftCap();
        _voteAll(curatorA, address(tsla));
        _voteAll(curatorB, address(tsla));
        _toNextEpoch();
        governor.flip(); // first miss: a week of grace
        assertTrue(curators.isCompliant(curatorA));
        uint16[3] memory afterFirst = _weights3();
        assertGt(afterFirst[2], 3000);

        _toNextEpoch();
        governor.flip(); // second miss: out
        assertFalse(curators.isCompliant(curatorA));
        assertFalse(curators.isCompliant(curatorB));
        uint16[3] memory afterSecond = _weights3();
        // Their slices now count as silent: the weights hold.
        for (uint256 j; j < 3; ++j) {
            assertEq(afterSecond[j], afterFirst[j]);
        }
    }

    function test_flip_curatorWithMinimumStake_staysCompliant() public {
        _stakeAndEscrow(curatorA, 3000e6);
        uint256 required = fund.totalSupply() * 50 / 10_000;
        assertGe(governor.stakedAssetsAt(curatorA, governor.currentEpoch() + 1), required);
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        _toNextEpoch();
        governor.flip();
        assertTrue(curators.isCompliant(curatorA));
        assertFalse(curators.isCompliant(curatorB));
    }

    // ──────────────────────────────────────────────────────────
    //  Proposals
    // ──────────────────────────────────────────────────────────

    function test_propose_curatorCanPropose() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        IFundGovernor.Proposal memory p = governor.getProposal(id);
        assertEq(p.proposer, curatorA);
        assertEq(p.target, address(spare));
        assertEq(p.endTime, block.timestamp + 3 days);
        assertEq(p.curatorShareBps, 3000);
        assertEq(p.stakerShareBps, 7000);
        assertEq(p.totalStake, aliceStake);
        assertEq(p.quorumBps, 2000);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Active));
    }

    function test_propose_stakerNeedsThreshold() public {
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.NotEligibleToPropose.selector);
        governor.propose(IFundGovernor.ProposalKind.List, address(spare), address(0));

        _escrow(alice, 4000e18); // ~$4.7k at NAV ~$1.18
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.NotEligibleToPropose.selector);
        governor.propose(IFundGovernor.ProposalKind.List, address(spare), address(0));

        _escrow(alice, 1000e18); // ~$5.9k
        vm.prank(alice);
        governor.propose(IFundGovernor.ProposalKind.List, address(spare), address(0));
    }

    function test_propose_oneOpenAtATime() public {
        _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(curatorA);
        vm.expectRevert(IFundGovernor.ProposalOpen.selector);
        governor.propose(IFundGovernor.ProposalKind.Delist, address(pons), address(0));
    }

    function test_propose_invalidTargets_revert() public {
        address other = makeAddr("other");
        vm.startPrank(curatorA);
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(IFundGovernor.ProposalKind.List, address(net), address(0)); // already listed
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(IFundGovernor.ProposalKind.List, other, address(0)); // not eligible
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(IFundGovernor.ProposalKind.Delist, address(spare), address(0)); // not listed
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(IFundGovernor.ProposalKind.AddCurator, curatorB, address(0)); // already one
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(IFundGovernor.ProposalKind.RemoveCurator, other, address(0)); // not one
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(IFundGovernor.ProposalKind.ReplaceCurator, curatorB, curatorA); // replacement is one
        vm.stopPrank();

        vm.prank(admin);
        factory.setCuratorCap(2);
        vm.prank(curatorA);
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(IFundGovernor.ProposalKind.AddCurator, other, address(0)); // over the cap
    }

    function test_list_curatorsAloneClearQuorum_joinsAtWeightZero() public {
        uint256 id = _listSpare();
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Executed));
        assertTrue(fund.isAsset(address(spare)));
        assertEq(fund.targetWeightBps(address(spare)), 0);
        assertEq(fund.targetWeightBps(address(net)), 4000);
        IFundGovernor.Proposal memory p = governor.getProposal(id);
        assertEq(p.yesVotes, 0.3e18);
    }

    function test_list_oneCuratorBelowQuorum_defeated() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(curatorA);
        governor.castVote(id, true); // 15% < 20%
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Defeated));
        vm.expectRevert(abi.encodeWithSelector(IFundGovernor.WrongState.selector, IFundGovernor.ProposalState.Defeated));
        governor.execute(id);
    }

    function test_list_stakersOutvoteCurators() public {
        _escrow(alice, aliceStake);
        vm.warp(block.timestamp + 1);
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(curatorA);
        governor.castVote(id, true);
        vm.prank(curatorB);
        governor.castVote(id, true);
        vm.prank(alice);
        uint256 votes = governor.castVote(id, false);
        assertEq(votes, 0.7e18);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Defeated));
    }

    function test_castVote_depositAfterProposal_reverts() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        _escrow(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(IFundGovernor.DepositedAfterProposal.selector);
        governor.castVote(id, true);
    }

    function test_castVote_twice_reverts() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(curatorA);
        governor.castVote(id, true);
        vm.prank(curatorA);
        vm.expectRevert(IFundGovernor.AlreadyVoted.selector);
        governor.castVote(id, false);
    }

    function test_castVote_noPower_reverts() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.NoVotingPower.selector);
        governor.castVote(id, true);
    }

    function test_veto_adminOnly() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(curatorA);
        vm.expectRevert(IFundGovernor.NotAdmin.selector);
        governor.veto(id);
        _curatorsYes(id);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Queued));
        vm.prank(admin);
        governor.veto(id);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Vetoed));
    }

    function test_execute_onlyAfterVetoPeriodAndWithinWindow() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.Delist, address(pons));
        _curatorsYes(id);
        vm.warp(block.timestamp + 3 days + 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IFundGovernor.WrongState.selector, IFundGovernor.ProposalState.Queued));
        governor.execute(id);
        vm.warp(block.timestamp + 1 + 7 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Expired));
    }

    function test_delist_proposalSetsFlag() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.Delist, address(pons));
        _curatorsYes(id);
        vm.warp(block.timestamp + 4 days);
        governor.execute(id);
        assertTrue(governor.delisted(address(pons)));
    }

    function test_cancel_byProposerOnly() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        vm.prank(curatorB);
        vm.expectRevert(IFundGovernor.NotProposer.selector);
        governor.cancel(id);
        vm.prank(curatorA);
        governor.cancel(id);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Cancelled));
        // A cancelled proposal frees the proposer to raise another.
        _propose(curatorA, IFundGovernor.ProposalKind.Delist, address(pons));
    }

    function test_curatorChange_stakersDecideAlone() public {
        _escrow(alice, aliceStake / 2);
        vm.warp(block.timestamp + 1);
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.AddCurator, newCurator);
        IFundGovernor.Proposal memory p = governor.getProposal(id);
        assertEq(p.curatorShareBps, 0);
        assertEq(p.stakerShareBps, 10_000);

        vm.prank(curatorB);
        vm.expectRevert(IFundGovernor.NoVotingPower.selector);
        governor.castVote(id, true);

        vm.prank(alice);
        uint256 votes = governor.castVote(id, true);
        assertEq(votes, 0.5e18); // half of all staked tokens
        vm.warp(block.timestamp + 4 days);
        governor.execute(id);
        assertTrue(curators.isCurator(newCurator));
        assertEq(curators.curatorCount(), 3);
    }

    function test_curatorChange_removeAndReplace() public {
        _escrow(alice, aliceStake);
        vm.warp(block.timestamp + 1);
        uint256 id = _propose(alice, IFundGovernor.ProposalKind.ReplaceCurator, curatorB, newCurator);
        vm.prank(alice);
        governor.castVote(id, true);
        vm.warp(block.timestamp + 4 days);
        governor.execute(id);
        assertFalse(curators.isCurator(curatorB));
        assertTrue(curators.isCurator(newCurator));

        id = _propose(alice, IFundGovernor.ProposalKind.RemoveCurator, newCurator);
        vm.prank(alice);
        governor.castVote(id, true);
        vm.warp(block.timestamp + 4 days);
        governor.execute(id);
        assertFalse(curators.isCurator(newCurator));
        assertEq(curators.curatorCount(), 1);
    }

    function test_execute_revalidates() public {
        uint256 id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        _curatorsYes(id);
        vm.prank(admin);
        factory.setEligibleAsset(address(spare), false);
        vm.warp(block.timestamp + 4 days);
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.execute(id);
    }

    function test_noCurators_stakersHoldTheWholeVote() public {
        vm.startPrank(admin);
        curators.removeCurator(curatorA);
        curators.removeCurator(curatorB);
        vm.stopPrank();
        _escrow(alice, aliceStake);
        _voteAll(alice, address(tsla));
        uint256 e = governor.currentEpoch() + 1;
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        assertApproxEqAbs(governor.votesOf(alice, address(tsla), e), WAD, 1);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function test_adminSetters_onlyAdmin() public {
        GovernanceConfig memory c = governor.config();
        vm.startPrank(curatorA);
        vm.expectRevert(IFundGovernor.NotAdmin.selector);
        governor.setDelisted(address(net), true);
        vm.expectRevert(IFundGovernor.NotAdmin.selector);
        governor.setConfig(c);
        vm.stopPrank();

        c.minVoteBps = 1001;
        vm.prank(admin);
        vm.expectRevert(IFundGovernor.InvalidConfig.selector);
        governor.setConfig(c);
    }

    function test_curators_adminOrGovernorOnly() public {
        vm.prank(curatorA);
        vm.expectRevert(IFundCurators.NotAdminOrGovernor.selector);
        curators.addCurator(newCurator);
        vm.prank(admin);
        curators.addCurator(newCurator);
        assertTrue(curators.isCurator(newCurator));
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _propose(address who, IFundGovernor.ProposalKind kind, address target) internal returns (uint256) {
        return _propose(who, kind, target, address(0));
    }

    function _propose(
        address who,
        IFundGovernor.ProposalKind kind,
        address target,
        address replacement
    ) internal returns (uint256 id) {
        _refreshFeeds();
        vm.prank(who);
        id = governor.propose(kind, target, replacement);
    }

    function _curatorsYes(
        uint256 id
    ) internal {
        vm.prank(curatorA);
        governor.castVote(id, true);
        vm.prank(curatorB);
        governor.castVote(id, true);
    }

    function _listSpare() internal returns (uint256 id) {
        id = _propose(curatorA, IFundGovernor.ProposalKind.List, address(spare));
        _curatorsYes(id);
        vm.warp(block.timestamp + 4 days);
        _refreshFeeds();
        governor.execute(id);
    }

    function _liftCap() internal {
        GovernanceConfig memory c = governor.config();
        c.maxWeightBps = 10_000;
        vm.prank(admin);
        governor.setConfig(c);
    }

    function _weights3() internal view returns (uint16[3] memory w) {
        w[0] = fund.targetWeightBps(address(net));
        w[1] = fund.targetWeightBps(address(pons));
        w[2] = fund.targetWeightBps(address(tsla));
    }

    function _assertSum() internal view {
        address[] memory a = fund.assets();
        uint256 sum;
        for (uint256 i; i < a.length; ++i) {
            sum += fund.targetWeightBps(a[i]);
        }
        assertEq(sum, 10_000);
    }
}
