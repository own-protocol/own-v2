// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundCurators} from "../../src/interfaces/IFundCurators.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";

contract FundCuratorsTest is FundTestBase {
    address internal curatorC = makeAddr("curatorC");

    function setUp() public override {
        super.setUp();
        _launchDefault();
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
        assertApproxEqAbs(a, pot / 2, 1);

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
        assertApproxEqAbs(curators.claimable(curatorA, address(fund)), pot / 2, 1);
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
        assertApproxEqAbs(curators.claimable(curatorC, address(usdg)), fresh / 3, 1);
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

    function test_noCompliantCurators_feesWaitForTheNextOne() public {
        vm.startPrank(admin);
        curators.removeCurator(curatorA);
        curators.removeCurator(curatorB);
        vm.stopPrank();
        _poolSwap(bob, true, -int256(10_000e6));
        uint256 pot = usdg.balanceOf(address(curators));
        vm.prank(admin);
        curators.addCurator(curatorC);
        _poolSwap(bob, false, -int256(10e18));
        assertGe(curators.claimable(curatorC, address(usdg)), pot);
    }

    function test_setMinStake_adminOnlyAndCapped() public {
        vm.prank(curatorA);
        vm.expectRevert(IFundCurators.NotAdmin.selector);
        curators.setMinStake(100);
        vm.prank(admin);
        vm.expectRevert(IFundCurators.InvalidMinStake.selector);
        curators.setMinStake(1001);
        vm.prank(admin);
        curators.setMinStake(100);
        assertEq(curators.minStakeBps(), 100);
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
