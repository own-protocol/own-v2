// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundGovernor} from "../../src/funds/FundGovernor.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundGovernor} from "../../src/interfaces/IFundGovernor.sol";
import {GovernanceConfig} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract WrappedStake is ERC4626 {
    constructor(
        IERC20 staked
    ) ERC20("Wrapped sMF1", "wsMF1") ERC4626(staked) {}
}

contract FundGovernorTest is FundTestBase {
    // Holders' base: 130k supply minus the 30k pool position.
    uint256 internal constant ELIGIBLE = 100_000e18;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        launch.claim(true); // 60k sMF1
        vm.prank(bob);
        launch.claim(false); // 40k MF1
    }

    // ──────────────────────────────────────────────────────────
    //  propose
    // ──────────────────────────────────────────────────────────

    function test_propose_snapshotsHolderBase() public {
        uint256 id = _propose();
        IFundGovernor.Proposal memory p = governor.getProposal(id);
        assertEq(p.proposer, creator);
        assertApproxEqAbs(p.eligibleSupply, ELIGIBLE, 1e8);
        assertEq(p.endTime, block.timestamp + 3 days);
        assertEq(p.config.creatorPowerBps, 3000);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Active));
        (uint256 creatorBps, uint256 holderBps) = governor.support(id);
        assertEq(creatorBps, 3000);
        assertEq(holderBps, 0);
    }

    function test_propose_notCreator_reverts() public {
        (address[] memory a, uint16[] memory w) = _newBasket();
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.NotCreator.selector);
        governor.propose(a, w);
    }

    function test_propose_beforeLaunch_reverts() public {
        _createFund();
        (address[] memory a, uint16[] memory w) = _newBasket();
        vm.prank(creator);
        vm.expectRevert(IFundGovernor.NotLaunched.selector);
        governor.propose(a, w);
    }

    function test_propose_badSum_reverts() public {
        (address[] memory a, uint16[] memory w) = _newBasket();
        w[0] += 1;
        vm.prank(creator);
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(a, w);
    }

    function test_propose_lengthMismatch_reverts() public {
        (address[] memory a,) = _newBasket();
        vm.prank(creator);
        vm.expectRevert(IFundGovernor.InvalidProposal.selector);
        governor.propose(a, new uint16[](1));
    }

    function test_propose_whileOpen_reverts() public {
        _propose();
        (address[] memory a, uint16[] memory w) = _newBasket();
        vm.prank(creator);
        vm.expectRevert(IFundGovernor.ProposalOpen.selector);
        governor.propose(a, w);
    }

    function test_propose_afterDefeat_allowed() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Defeated));
        assertEq(_propose(), 1);
    }

    // ──────────────────────────────────────────────────────────
    //  voting and tally
    // ──────────────────────────────────────────────────────────

    function test_pass_creatorPlusTwentyEightPercentOfHolders() public {
        _escrow(bob, address(fund), 40_000e18);
        uint256 id = _propose();
        _vote(bob, id, true); // 70% * 40% = 28 points

        (, uint256 holderBps) = governor.support(id);
        assertApproxEqAbs(holderBps, 2800, 1);

        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Queued));
        vm.expectRevert(abi.encodeWithSelector(IFundGovernor.WrongState.selector, IFundGovernor.ProposalState.Queued));
        governor.execute(id);

        vm.warp(block.timestamp + 1 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Executable));
        governor.execute(id);

        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Executed));
        assertTrue(fund.isAsset(address(spare)));
        assertEq(fund.targetWeightBps(address(pons)), 2000);
        assertEq(fund.targetWeightBps(address(spare)), 1000);
    }

    function test_fail_holdersBelowTwentyPercent() public {
        // 28,000 MF1 = 19.6 points: with the creator's 30 that is 49.6, below both bars.
        _escrow(bob, address(fund), 28_000e18);
        uint256 id = _propose();
        _vote(bob, id, true);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Defeated));
    }

    function test_pass_exactlyTwentyHolderPoints() public {
        // 20 / 70 of the base, rounded up to clear the floor.
        uint256 needed = (governor.eligibleSupply() * 2000 + 6999) / 7000;
        _escrow(bob, address(fund), needed);
        uint256 id = _propose();
        assertEq(governor.getProposal(id).eligibleSupply, governor.eligibleSupply());
        _vote(bob, id, true);
        (, uint256 holderBps) = governor.support(id);
        assertEq(holderBps, 2000);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Queued));
    }

    function test_holderAgainstVotesDoNotBlockAtFiftyPercent() public {
        _escrow(bob, address(fund), 30_000e18);
        _escrow(alice, address(staking), 60_000e18);
        uint256 id = _propose();
        _vote(bob, id, true); // 21 points
        _vote(alice, id, false);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Queued));
        assertEq(governor.getProposal(id).againstVotes, 60_000e18);
    }

    function test_stakedTokensVoteAtTheirFundTokenValue() public {
        // Accrue yield so one sMF1 is worth more than one MF1.
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        staking.accrue();
        uint256 value = staking.convertToAssets(60_000e18);
        assertGt(value, 60_000e18);

        _escrow(alice, address(staking), 60_000e18);
        uint256 id = _propose();
        uint256 weight = _vote(alice, id, true);
        assertEq(weight, value);
    }

    function test_wrappedStakeCounts() public {
        WrappedStake wrapper = new WrappedStake(IERC20(address(staking)));
        vm.prank(admin);
        governor.setWrapper(address(wrapper), true);
        assertTrue(governor.isVoteToken(address(wrapper)));

        vm.startPrank(alice);
        staking.approve(address(wrapper), 30_000e18);
        uint256 wrapped = wrapper.deposit(30_000e18, alice);
        vm.stopPrank();

        _escrow(alice, address(wrapper), wrapped);
        uint256 id = _propose();
        uint256 weight = _vote(alice, id, true);
        assertApproxEqAbs(weight, 30_000e18, 1);
    }

    function test_setWrapper_wrongAsset_reverts() public {
        WrappedStake wrapper = new WrappedStake(IERC20(address(fund)));
        vm.prank(admin);
        vm.expectRevert(IFundGovernor.InvalidWrapper.selector);
        governor.setWrapper(address(wrapper), true);
    }

    function test_setWrapper_removeStopsCounting() public {
        WrappedStake wrapper = new WrappedStake(IERC20(address(staking)));
        vm.startPrank(admin);
        governor.setWrapper(address(wrapper), true);
        governor.setWrapper(address(wrapper), false);
        vm.stopPrank();
        assertFalse(governor.isVoteToken(address(wrapper)));
        assertEq(governor.wrappers().length, 0);
    }

    function test_castVote_creator_reverts() public {
        uint256 id = _propose();
        vm.prank(creator);
        vm.expectRevert(IFundGovernor.CreatorCannotVote.selector);
        governor.castVote(id, true);
    }

    function test_castVote_noEscrow_reverts() public {
        uint256 id = _propose();
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.NoVotingPower.selector);
        governor.castVote(id, true);
    }

    function test_castVote_twice_reverts() public {
        _escrow(bob, address(fund), 1000e18);
        uint256 id = _propose();
        _vote(bob, id, true);
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.AlreadyVoted.selector);
        governor.castVote(id, false);
    }

    function test_castVote_afterEnd_reverts() public {
        uint256 id = _propose();
        _escrow(bob, address(fund), 1000e18);
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IFundGovernor.WrongState.selector, IFundGovernor.ProposalState.Defeated));
        governor.castVote(id, true);
    }

    function test_sameTokensCannotVoteTwiceThroughAnotherWallet() public {
        _escrow(bob, address(fund), 40_000e18);
        uint256 id = _propose();
        _vote(bob, id, true);

        vm.prank(bob);
        vm.expectRevert(IFundGovernor.TokensLocked.selector);
        governor.withdraw(address(fund), 40_000e18, attacker);
    }

    // ──────────────────────────────────────────────────────────
    //  escrow
    // ──────────────────────────────────────────────────────────

    function test_withdraw_afterVotingEnds() public {
        _escrow(bob, address(fund), 40_000e18);
        uint256 id = _propose();
        _vote(bob, id, true);
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        governor.withdraw(address(fund), 40_000e18, bob);
        assertEq(fund.balanceOf(bob), 40_000e18);
        assertEq(governor.escrowOf(bob, address(fund)), 0);
    }

    function test_withdraw_withoutVoting_anytime() public {
        _propose();
        _escrow(bob, address(fund), 1000e18);
        vm.prank(bob);
        governor.withdraw(address(fund), 1000e18, bob);
        assertEq(fund.balanceOf(bob), 40_000e18);
    }

    function test_withdraw_moreThanEscrowed_reverts() public {
        _escrow(bob, address(fund), 1000e18);
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.InsufficientEscrow.selector);
        governor.withdraw(address(fund), 1001e18, bob);
    }

    function test_deposit_notVoteToken_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.NotVoteToken.selector);
        governor.deposit(address(usdg), 1);
    }

    // ──────────────────────────────────────────────────────────
    //  veto, cancel, expiry
    // ──────────────────────────────────────────────────────────

    function test_veto_adminDuringQueue() public {
        _escrow(bob, address(fund), 40_000e18);
        uint256 id = _propose();
        _vote(bob, id, true);
        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        governor.veto(id);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Vetoed));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(IFundGovernor.WrongState.selector, IFundGovernor.ProposalState.Vetoed));
        governor.execute(id);
    }

    function test_veto_notAdmin_reverts() public {
        uint256 id = _propose();
        vm.prank(creator);
        vm.expectRevert(IFundGovernor.NotAdmin.selector);
        governor.veto(id);
    }

    function test_cancel_creatorOnly() public {
        uint256 id = _propose();
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.NotCreator.selector);
        governor.cancel(id);
        vm.prank(creator);
        governor.cancel(id);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Cancelled));
        assertEq(_propose(), 1);
    }

    function test_expiry_unblocksNewProposals() public {
        _escrow(bob, address(fund), 40_000e18);
        uint256 id = _propose();
        _vote(bob, id, true);
        vm.warp(block.timestamp + 3 days + 1 days + 7 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Expired));
        assertEq(_propose(), 1);
    }

    function test_configSnapshottedPerProposal() public {
        _escrow(bob, address(fund), 40_000e18);
        uint256 id = _propose();
        GovernanceConfig memory c = governor.config();
        c.passThresholdBps = 9000;
        vm.prank(admin);
        governor.setConfig(c);
        _vote(bob, id, true);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Queued));
    }

    function test_setConfig_invalid_reverts() public {
        GovernanceConfig memory c = governor.config();
        c.minUserSupportBps = 7001; // unreachable with a 30% creator share
        vm.prank(admin);
        vm.expectRevert(IFundGovernor.InvalidConfig.selector);
        governor.setConfig(c);
    }

    function test_setConfig_notAdmin_reverts() public {
        GovernanceConfig memory c = governor.config();
        vm.prank(creator);
        vm.expectRevert(IFundGovernor.NotAdmin.selector);
        governor.setConfig(c);
    }

    // ──────────────────────────────────────────────────────────
    //  eligible supply and swapping the governor
    // ──────────────────────────────────────────────────────────

    function test_eligibleSupply_excludesCreatorHoldings() public {
        uint256 before = governor.eligibleSupply();
        vm.prank(bob);
        fund.transfer(creator, 5000e18);
        assertEq(governor.eligibleSupply(), before - 5000e18);
    }

    function test_eligibleSupply_countsLockedMints() public {
        uint256 before = governor.eligibleSupply();
        uint256 supplyBefore = fund.totalSupply();
        _mintAsset(bob, tsla, 10e18);
        vm.prank(bob);
        fund.mint(address(tsla), 10e18, 1, 0, bob); // locked, held by the fund
        assertEq(governor.eligibleSupply(), before + fund.totalSupply() - supplyBefore);
    }

    function test_castVote_depositAfterProposal_reverts() public {
        vm.prank(bob);
        fund.transfer(creator, 30_000e18);
        uint256 id = _propose();
        // The creator's tokens were outside the count; handing them to a friend must not add votes.
        vm.prank(creator);
        fund.transfer(attacker, 30_000e18);
        _escrow(attacker, address(fund), 30_000e18);
        vm.prank(attacker);
        vm.expectRevert(IFundGovernor.DepositedAfterProposal.selector);
        governor.castVote(id, true);
    }

    function test_castVote_topUpAfterProposal_reverts() public {
        _escrow(bob, address(fund), 20_000e18);
        uint256 id = _propose();
        _escrow(bob, address(fund), 20_000e18);
        vm.prank(bob);
        vm.expectRevert(IFundGovernor.DepositedAfterProposal.selector);
        governor.castVote(id, true);
        assertEq(governor.lastDepositAt(bob), block.timestamp);
    }

    function test_swapGovernor_oldOneCannotExecuteButRefunds() public {
        _escrow(bob, address(fund), 40_000e18);
        uint256 id = _propose();
        _vote(bob, id, true);
        vm.warp(block.timestamp + 4 days);

        FundGovernor replacement = FundGovernor(makeAddr("quadraticGovernor"));
        vm.prank(creator);
        vm.expectRevert(IFund.NotAdmin.selector);
        fund.setGovernor(address(replacement));
        vm.prank(admin);
        fund.setGovernor(address(replacement));
        assertEq(fund.governor(), address(replacement));

        vm.expectRevert(IFund.NotGovernor.selector);
        governor.execute(id);

        vm.prank(bob);
        governor.withdraw(address(fund), 40_000e18, bob);
        assertEq(fund.balanceOf(bob), 40_000e18);
    }

    function test_initialize_implementation_reverts() public {
        FundGovernor impl = new FundGovernor();
        GovernanceConfig memory c = governor.config();
        vm.expectRevert();
        impl.initialize(address(fund), c);
    }

    // ──────────────────────────────────────────────────────────
    //  helpers
    // ──────────────────────────────────────────────────────────

    function _newBasket() internal view returns (address[] memory a, uint16[] memory w) {
        a = new address[](4);
        a[0] = address(net);
        a[1] = address(pons);
        a[2] = address(tsla);
        a[3] = address(spare);
        w = new uint16[](4);
        w[0] = 4000;
        w[1] = 2000;
        w[2] = 3000;
        w[3] = 1000;
    }

    // One second on, so escrow set up just before counts for the proposal.
    function _propose() internal returns (uint256 id) {
        vm.warp(block.timestamp + 1);
        (address[] memory a, uint16[] memory w) = _newBasket();
        vm.prank(creator);
        id = governor.propose(a, w);
    }

    function _escrow(
        address who,
        address token,
        uint256 amount
    ) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(governor), amount);
        governor.deposit(token, amount);
        vm.stopPrank();
    }

    function _vote(
        address who,
        uint256 id,
        bool inFavour
    ) internal returns (uint256 weight) {
        vm.prank(who);
        weight = governor.castVote(id, inFavour);
    }
}

contract FundGovernorLaunchTest is FundTestBase {
    function setUp() public override {
        super.setUp();
        _launchDefault();
    }

    function test_eligibleSupply_countsUnclaimedLaunchTokens() public view {
        // Nobody has claimed: the base is still the depositors' 100k, not zero.
        assertApproxEqAbs(governor.eligibleSupply(), 100_000e18, 1e8);
    }

    function test_earlyClaimerCannotPassAlone() public {
        vm.prank(bob);
        launch.claim(false); // 40k of the 100k
        vm.startPrank(bob);
        fund.approve(address(governor), 10_000e18);
        governor.deposit(address(fund), 10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        address[] memory a = fund.assets();
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 3000;
        vm.prank(creator);
        uint256 id = governor.propose(a, w);
        vm.prank(bob);
        governor.castVote(id, true);

        (, uint256 holderBps) = governor.support(id);
        assertApproxEqAbs(holderBps, 700, 1); // 10k of 100k, not all 70 points
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(governor.state(id)), uint8(IFundGovernor.ProposalState.Defeated));
    }
}
