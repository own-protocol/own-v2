// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockPositionManager} from "../helpers/MockPositionManager.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract FundStakingLpTest is FundTestBase {
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    MockPositionManager internal posm;
    PoolKey internal key;
    int24 internal lower;
    int24 internal upper;
    uint128 internal liq;
    uint256 internal staked;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        launch.claim(true);
        staked = staking.totalAssets();
        posm = MockPositionManager(positionManager);
        key = hook.poolKeyOf(address(fund));
        lower = TickMath.minUsableTick(key.tickSpacing);
        upper = TickMath.maxUsableTick(key.tickSpacing);
        // Same liquidity as the fund's own position, so it holds the same fund tokens.
        liq = hook.positionLiquidity(address(fund));
    }

    function _mint(address to, uint128 liquidity) internal returns (uint256) {
        return posm.mint(to, key, lower, upper, liquidity);
    }

    function _stake(address who, uint128 liquidity) internal returns (uint256 id) {
        id = _mint(who, liquidity);
        vm.startPrank(who);
        posm.approve(address(staking), id);
        staking.stakePosition(id);
        vm.stopPrank();
    }

    function _accrueAfter(
        uint256 secs
    ) internal returns (uint256 minted) {
        vm.warp(block.timestamp + secs);
        _refreshFeeds();
        minted = staking.accrue();
    }

    function _fundTokensIn(
        uint128 liquidity
    ) internal view returns (uint256 tokens) {
        (, tokens) = hook.liquidityAmounts(address(fund), liquidity);
    }

    // ── Staking ───────────────────────────────────────────────

    function test_stakePosition_takesCustody() public {
        uint256 id = _stake(carol, liq);
        assertEq(posm.ownerOf(id), address(staking));
        (address owner, uint128 liquidity) = staking.positionOf(id);
        assertEq(owner, carol);
        assertEq(liquidity, liq);
        assertEq(staking.lpLiquidity(), liq);
    }

    function test_safeTransfer_stakesForSender() public {
        uint256 id = _mint(carol, liq);
        vm.prank(carol);
        posm.safeTransferFrom(carol, address(staking), id);
        (address owner,) = staking.positionOf(id);
        assertEq(owner, carol);
        assertEq(staking.lpLiquidity(), liq);
    }

    function test_stakePosition_notOwner_reverts() public {
        uint256 id = _mint(carol, liq);
        vm.prank(carol);
        posm.approve(address(staking), id);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, dave, id, carol));
        staking.stakePosition(id);
    }

    function test_stakePosition_otherPool_reverts() public {
        PoolKey memory other = key;
        other.fee = 3000;
        uint256 id = posm.mint(carol, other, lower, upper, liq);
        vm.startPrank(carol);
        posm.approve(address(staking), id);
        vm.expectRevert(IFundStaking.NotFundPosition.selector);
        staking.stakePosition(id);
        vm.stopPrank();
    }

    function test_stakePosition_notFullRange_reverts() public {
        uint256 id = posm.mint(carol, key, lower + key.tickSpacing, upper, liq);
        vm.startPrank(carol);
        posm.approve(address(staking), id);
        vm.expectRevert(IFundStaking.NotFullRange.selector);
        staking.stakePosition(id);
        vm.stopPrank();

        id = posm.mint(carol, key, lower, upper - key.tickSpacing, liq);
        vm.startPrank(carol);
        posm.approve(address(staking), id);
        vm.expectRevert(IFundStaking.NotFullRange.selector);
        staking.stakePosition(id);
        vm.stopPrank();
    }

    function test_stakePosition_zeroLiquidity_reverts() public {
        uint256 id = _mint(carol, 0);
        vm.startPrank(carol);
        posm.approve(address(staking), id);
        vm.expectRevert(IFundStaking.ZeroAmount.selector);
        staking.stakePosition(id);
        vm.stopPrank();
    }

    function test_onERC721Received_notPositionManager_reverts() public {
        vm.prank(carol);
        vm.expectRevert(IFundStaking.NotPositionManager.selector);
        staking.onERC721Received(carol, carol, 1, "");
    }

    // ── Yield ─────────────────────────────────────────────────

    function test_yield_stakingRateOnFundTokenSide() public {
        uint256 id = _stake(carol, liq);
        uint256 tokens = _fundTokensIn(liq);
        (, uint256 ownTokens) = fund.positionAmounts();
        assertEq(tokens, ownTokens);
        uint256 minted = _accrueAfter(8 hours);
        uint256 pending = staking.pendingPositionYield(id);
        // Premium is ~30%: 0.15% a day, the same rate stakers get on their fund tokens.
        assertApproxEqRel(pending, tokens * 15 * 8 hours / (10_000 * 1 days), 0.001e18);
        // LP yield carries no curator share on top.
        assertApproxEqRel(pending * 1e18 / tokens, minted * 1e18 / staked * 100 / 115, 1e9);
    }

    function test_yield_stakersUnaffected() public {
        _stake(carol, liq);
        uint256 minted = _accrueAfter(8 hours);
        // Stakers' yield plus the curators' 15% on top.
        assertApproxEqRel(minted, staked * 15 * 8 hours / (10_000 * 1 days) * 115 / 100, 0.001e18);
        assertApproxEqAbs(staking.totalAssets(), staked + minted, 1);
    }

    function test_yield_splitByLiquidity() public {
        uint256 a = _stake(carol, liq);
        uint256 b = _stake(dave, liq * 3);
        _accrueAfter(8 hours);
        assertApproxEqAbs(staking.pendingPositionYield(b), staking.pendingPositionYield(a) * 3, 3);
    }

    function test_yield_lateStakerGetsNothingEarlier() public {
        uint256 a = _stake(carol, liq);
        _accrueAfter(8 hours);
        uint256 first = staking.pendingPositionYield(a);
        uint256 b = _stake(dave, liq);
        assertEq(staking.pendingPositionYield(b), 0);
        _accrueAfter(8 hours);
        assertApproxEqAbs(staking.pendingPositionYield(a) - first, staking.pendingPositionYield(b), 1);
    }

    function test_yield_noneWithoutPremium() public {
        uint256 id = _stake(carol, liq);
        _setFeed(address(fund), _navPrice());
        _accrueAfter(8 hours);
        assertEq(staking.pendingPositionYield(id), 0);
    }

    function _unstakeEveryone() internal {
        vm.prank(bob);
        launch.claim(false);
        uint256 shares = staking.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(shares, alice);
        assertLe(staking.totalAssets(), 1);
    }

    function test_yield_noneWhenNothingStaked() public {
        _unstakeEveryone();
        uint256 supply = fund.totalSupply();
        _accrueAfter(8 hours);
        assertLe(fund.totalSupply() - supply, 1);
    }

    function test_yield_lpOnlyStillAccrues() public {
        _unstakeEveryone();
        uint256 id = _stake(carol, liq);
        _accrueAfter(8 hours);
        assertApproxEqRel(
            staking.pendingPositionYield(id), _fundTokensIn(liq) * 15 * 8 hours / (10_000 * 1 days), 0.001e18
        );
    }

    // ── Claims ────────────────────────────────────────────────

    function test_claimPositionYield_paysFundTokens() public {
        uint256 id = _stake(carol, liq);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        vm.prank(carol);
        uint256 paid = staking.claimPositionYield(id, carol);
        assertGt(paid, 0);
        assertEq(fund.balanceOf(carol), paid);
        assertEq(staking.pendingPositionYield(id), 0);
        // Fund tokens paid out never come out of the stakers' assets.
        assertGe(fund.balanceOf(address(staking)), staking.totalAssets());
    }

    function test_claimPositionYield_notOwner_reverts() public {
        uint256 id = _stake(carol, liq);
        vm.prank(dave);
        vm.expectRevert(IFundStaking.NotPositionOwner.selector);
        staking.claimPositionYield(id, dave);
    }

    function test_unstakePosition_returnsNftWithYield() public {
        uint256 id = _stake(carol, liq);
        vm.warp(block.timestamp + 8 hours);
        _refreshFeeds();
        vm.prank(carol);
        uint256 paid = staking.unstakePosition(id, carol);
        assertGt(paid, 0);
        assertEq(posm.ownerOf(id), carol);
        assertEq(fund.balanceOf(carol), paid);
        assertEq(staking.lpLiquidity(), 0);
        (address owner,) = staking.positionOf(id);
        assertEq(owner, address(0));

        uint256 supply = fund.totalSupply();
        uint256 minted = _accrueAfter(8 hours);
        assertEq(fund.totalSupply() - supply, minted);
    }

    function test_unstakePosition_notOwner_reverts() public {
        uint256 id = _stake(carol, liq);
        vm.prank(dave);
        vm.expectRevert(IFundStaking.NotPositionOwner.selector);
        staking.unstakePosition(id, dave);
    }

    function test_restake_startsFresh() public {
        uint256 id = _stake(carol, liq);
        _accrueAfter(8 hours);
        vm.startPrank(carol);
        staking.unstakePosition(id, carol);
        posm.approve(address(staking), id);
        staking.stakePosition(id);
        vm.stopPrank();
        assertEq(staking.pendingPositionYield(id), 0);
    }

    function test_payoutsNeverExceedMinted() public {
        uint256 a = _stake(carol, liq);
        uint256 b = _stake(dave, liq / 7 + 13);
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 5 hours + i);
            _refreshFeeds();
            vm.prank(carol);
            staking.claimPositionYield(a, carol);
        }
        vm.prank(dave);
        staking.unstakePosition(b, dave);
        vm.prank(carol);
        staking.unstakePosition(a, carol);
        assertGe(fund.balanceOf(address(staking)), staking.totalAssets());
    }

    // ── Fees ──────────────────────────────────────────────────

    function test_collectPositionFees_paysOwnerChoice() public {
        uint256 id = _stake(carol, liq);
        usdg.mint(address(posm), 50e6);
        // Fund tokens for the fee leg come from a pool purchase.
        _poolSwap(dave, true, -int256(1000e6));
        uint256 fundFees = fund.balanceOf(dave) / 10;
        vm.prank(dave);
        fund.transfer(address(posm), fundFees);
        bool usdgIs0 = address(usdg) < address(fund);
        posm.setFees(id, usdgIs0 ? 50e6 : fundFees, usdgIs0 ? fundFees : 50e6);

        vm.prank(carol);
        staking.collectPositionFees(id, bob);
        assertEq(usdg.balanceOf(bob), 50e6);
        assertEq(fund.balanceOf(bob), fundFees);
        assertEq(posm.ownerOf(id), address(staking));
        (, uint128 liquidity) = staking.positionOf(id);
        assertEq(liquidity, liq);
    }

    function test_collectPositionFees_notOwner_reverts() public {
        uint256 id = _stake(carol, liq);
        vm.prank(dave);
        vm.expectRevert(IFundStaking.NotPositionOwner.selector);
        staking.collectPositionFees(id, dave);
    }

    // ── Recovery ──────────────────────────────────────────────

    function test_recoverPosition_returnsUnregisteredNft() public {
        uint256 id = _mint(address(staking), liq);
        vm.prank(admin);
        staking.recoverPosition(id, carol);
        assertEq(posm.ownerOf(id), carol);
    }

    function test_recoverPosition_stakedOrNotAdmin_reverts() public {
        uint256 id = _stake(carol, liq);
        vm.prank(admin);
        vm.expectRevert(IFundStaking.PositionIsStaked.selector);
        staking.recoverPosition(id, admin);
        vm.prank(carol);
        vm.expectRevert(IFundStaking.NotAdmin.selector);
        staking.recoverPosition(id, carol);
    }
}
