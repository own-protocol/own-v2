// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundBribes} from "../../src/interfaces/IFundBribes.sol";
import {IFundGovernor} from "../../src/interfaces/IFundGovernor.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";

contract FundBribesTest is FundTestBase {
    address internal briber = makeAddr("briber");
    uint256 internal aliceStake;
    uint256 internal epoch;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        aliceStake = launch.claim(true);
        vm.startPrank(admin);
        factory.setBribeToken(address(usdg), true);
        factory.setEligibleAsset(address(spare), true);
        vm.stopPrank();
        usdg.mint(briber, 1_000_000e6);
        vm.prank(briber);
        usdg.approve(address(bribes), type(uint256).max);

        _escrow(alice, aliceStake);
        _voteAll(alice, address(tsla));
        _voteAll(curatorA, address(tsla));
        epoch = governor.currentEpoch() + 1; // alice's stake counts from here
    }

    // ──────────────────────────────────────────────────────────
    //  Weight-vote bribes
    // ──────────────────────────────────────────────────────────

    function test_postBribe_takesFivePercentCut() public {
        uint256 treasuryBefore = usdg.balanceOf(protocolTreasury);
        vm.prank(briber);
        uint256 net = bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
        assertEq(net, 950e6);
        assertEq(bribes.bribeOf(address(tsla), epoch, address(usdg)), 950e6);
        assertEq(usdg.balanceOf(protocolTreasury) - treasuryBefore, 50e6);
        assertEq(usdg.balanceOf(address(bribes)), 950e6);
    }

    function test_postBribe_inTheBribedToken() public {
        tsla.mint(briber, 1e18);
        vm.startPrank(briber);
        tsla.approve(address(bribes), 1e18);
        bribes.postBribe(address(tsla), epoch, address(tsla), 1e18);
        vm.stopPrank();
        assertEq(bribes.bribeOf(address(tsla), epoch, address(tsla)), 0.95e18);
    }

    function test_postBribe_rewardNotAllowed_reverts() public {
        net.mint(briber, 1e9);
        vm.startPrank(briber);
        net.approve(address(bribes), 1e9);
        vm.expectRevert(IFundBribes.RewardNotAllowed.selector);
        bribes.postBribe(address(tsla), epoch, address(net), 1e9);
        vm.stopPrank();
    }

    function test_postBribe_pastOrTalliedEpoch_reverts() public {
        uint256 current = governor.currentEpoch();
        vm.prank(briber);
        vm.expectRevert(IFundBribes.EpochClosed.selector);
        bribes.postBribe(address(tsla), current - 1, address(usdg), 1000e6);

        _toNextEpoch();
        _toNextEpoch();
        governor.flip(); // tallies `epoch`
        vm.prank(briber);
        vm.expectRevert(IFundBribes.EpochClosed.selector);
        bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
    }

    function test_claimBribe_splitByShareOfTheTokensVote() public {
        vm.prank(briber);
        bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();

        // TSLA's vote: curatorA's 15% slice plus alice's 70% of stakers' votes.
        vm.prank(curatorA);
        uint256 toCurator = bribes.claimBribe(address(tsla), epoch, address(usdg));
        vm.prank(alice);
        uint256 toAlice = bribes.claimBribe(address(tsla), epoch, address(usdg));
        assertApproxEqAbs(toCurator, uint256(950e6) * 15 / 85, 1);
        assertApproxEqAbs(toAlice, uint256(950e6) * 70 / 85, 1);
        assertLe(toCurator + toAlice, 950e6);
        assertEq(usdg.balanceOf(curatorA), toCurator);
    }

    function test_claimBribe_twice_reverts() public {
        vm.prank(briber);
        bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        vm.prank(alice);
        bribes.claimBribe(address(tsla), epoch, address(usdg));
        vm.prank(alice);
        vm.expectRevert(IFundBribes.AlreadyClaimed.selector);
        bribes.claimBribe(address(tsla), epoch, address(usdg));
    }

    function test_claimBribe_beforeTally_reverts() public {
        vm.prank(briber);
        bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
        vm.prank(alice);
        vm.expectRevert(IFundBribes.EpochNotTallied.selector);
        bribes.claimBribe(address(tsla), epoch, address(usdg));
    }

    function test_claimBribe_silentOrOtherTokenVotersGetNothing() public {
        vm.prank(briber);
        bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        vm.prank(curatorB); // silent
        vm.expectRevert(IFundBribes.NothingToClaim.selector);
        bribes.claimBribe(address(tsla), epoch, address(usdg));
        assertEq(bribes.claimableBribe(curatorB, address(tsla), epoch, address(usdg)), 0);
    }

    function test_claimBribe_depositDuringEpochEarnsNothing() public {
        // Bob escrows during `epoch`: his stake counts only from the next one.
        _toNextEpoch();
        _stakeAndEscrow(bob, 10_000e6);
        _voteAll(bob, address(tsla));
        vm.prank(briber);
        bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
        _toNextEpoch();
        governor.flip();
        assertEq(bribes.claimableBribe(bob, address(tsla), epoch, address(usdg)), 0);
    }

    function test_refundBribe_whenNobodyVotedForTheToken() public {
        vm.prank(briber);
        bribes.postBribe(address(pons), epoch, address(usdg), 1000e6);
        vm.prank(briber);
        vm.expectRevert(IFundBribes.NotRefundable.selector);
        bribes.refundBribe(address(pons), epoch, address(usdg));

        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        uint256 before = usdg.balanceOf(briber);
        vm.prank(briber);
        uint256 back = bribes.refundBribe(address(pons), epoch, address(usdg));
        assertEq(back, 950e6);
        assertEq(usdg.balanceOf(briber), before + 950e6);
        assertEq(bribes.bribeOf(address(pons), epoch, address(usdg)), 0);
    }

    function test_refundBribe_votedToken_reverts() public {
        vm.prank(briber);
        bribes.postBribe(address(tsla), epoch, address(usdg), 1000e6);
        _toNextEpoch();
        _toNextEpoch();
        governor.flip();
        vm.prank(briber);
        vm.expectRevert(IFundBribes.NotRefundable.selector);
        bribes.refundBribe(address(tsla), epoch, address(usdg));
    }

    function test_refundBribe_skippedEpoch() public {
        uint256 current = governor.currentEpoch();
        vm.prank(briber);
        bribes.postBribe(address(tsla), current, address(usdg), 1000e6);
        // The first flip tallies the epoch before the flip, so `current` is never tallied.
        vm.warp((current + 2) * 1 weeks);
        _refreshFeeds();
        governor.flip();
        assertFalse(governor.isTallied(current));
        vm.prank(briber);
        assertEq(bribes.refundBribe(address(tsla), current, address(usdg)), 950e6);
    }

    // ──────────────────────────────────────────────────────────
    //  Listing bribes
    // ──────────────────────────────────────────────────────────

    function test_listingBribe_paidToYesVotersWhenListed() public {
        uint256 id = _proposeListing();
        vm.prank(briber);
        uint256 net = bribes.postListingBribe(id, address(usdg), 2000e6);
        assertEq(net, 1900e6);
        assertEq(bribes.listingBribeOf(id, address(usdg)), 1900e6);

        vm.prank(curatorA);
        governor.castVote(id, true);
        vm.prank(curatorB);
        governor.castVote(id, true);
        vm.prank(alice);
        governor.castVote(id, false);

        // Yes 30% against no 70%: defeated, nothing to claim.
        vm.warp(block.timestamp + 4 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Defeated));
        vm.prank(curatorA);
        vm.expectRevert(IFundBribes.NothingToClaim.selector);
        bribes.claimListingBribe(id, address(usdg));
        vm.prank(briber);
        assertEq(bribes.refundListingBribe(id, address(usdg)), 1900e6);
    }

    function test_listingBribe_claimedAfterExecution() public {
        uint256 id = _proposeListing();
        vm.prank(briber);
        bribes.postListingBribe(id, address(usdg), 2000e6);
        vm.prank(curatorA);
        governor.castVote(id, true);
        vm.prank(alice);
        governor.castVote(id, true);
        vm.prank(curatorB);
        governor.castVote(id, false);

        vm.prank(briber);
        vm.expectRevert(IFundBribes.NotRefundable.selector);
        bribes.refundListingBribe(id, address(usdg));

        vm.warp(block.timestamp + 4 days);
        _refreshFeeds();
        vm.prank(curatorA);
        vm.expectRevert(IFundBribes.NothingToClaim.selector); // not executed yet
        bribes.claimListingBribe(id, address(usdg));
        governor.execute(id);

        // Yes: curatorA 15% and alice 70%; curatorB voted no.
        vm.prank(curatorA);
        uint256 a = bribes.claimListingBribe(id, address(usdg));
        vm.prank(alice);
        uint256 b = bribes.claimListingBribe(id, address(usdg));
        assertApproxEqAbs(a, uint256(1900e6) * 15 / 85, 1);
        assertApproxEqAbs(b, uint256(1900e6) * 70 / 85, 1);
        vm.prank(curatorB);
        vm.expectRevert(IFundBribes.NothingToClaim.selector);
        bribes.claimListingBribe(id, address(usdg));
        vm.prank(alice);
        vm.expectRevert(IFundBribes.AlreadyClaimed.selector);
        bribes.claimListingBribe(id, address(usdg));
    }

    function test_listingBribe_refundedWhenVetoedOrCancelled() public {
        uint256 id = _proposeListing();
        vm.prank(briber);
        bribes.postListingBribe(id, address(usdg), 1000e6);
        vm.prank(admin);
        governor.veto(id);
        vm.prank(briber);
        assertEq(bribes.refundListingBribe(id, address(usdg)), 950e6);
        vm.prank(briber);
        vm.expectRevert(IFundBribes.NothingToClaim.selector);
        bribes.refundListingBribe(id, address(usdg));
    }

    function test_listingBribe_inTheListedToken() public {
        uint256 id = _proposeListing();
        spare.mint(briber, 100e18);
        vm.startPrank(briber);
        spare.approve(address(bribes), 100e18);
        bribes.postListingBribe(id, address(spare), 100e18);
        vm.stopPrank();
        assertEq(bribes.listingBribeOf(id, address(spare)), 95e18);
    }

    function test_listingBribe_notAListingOrClosed_reverts() public {
        vm.prank(curatorA);
        uint256 id = governor.propose(IFundGovernor.ProposalKind.Delist, address(pons), address(0));
        vm.prank(briber);
        vm.expectRevert(IFundBribes.NotOpenListing.selector);
        bribes.postListingBribe(id, address(usdg), 1000e6);

        uint256 listing = _proposeListingBy(curatorB);
        vm.warp(block.timestamp + 3 days);
        vm.prank(briber);
        vm.expectRevert(IFundBribes.NotOpenListing.selector);
        bribes.postListingBribe(listing, address(usdg), 1000e6);
    }

    function _proposeListing() internal returns (uint256) {
        vm.warp(block.timestamp + 1); // alice's deposit must predate the proposal
        return _proposeListingBy(curatorA);
    }

    function _proposeListingBy(
        address who
    ) internal returns (uint256 id) {
        _refreshFeeds();
        vm.prank(who);
        id = governor.propose(IFundGovernor.ProposalKind.List, address(spare), address(0));
    }
}
