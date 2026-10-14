// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchConfig} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";

/// @dev Mints and redeems read the pool position at whichever of the TWAP and spot costs the caller
///      (A6-M-01, A6-M-02, A6-L-03). Depositors are unlocked at the close so they can trade at once,
///      and issuance is off so the pool's supply only moves with the swaps.
contract FundPoolReadingTest is FundTestBase {
    address internal carol = makeAddr("carol");
    uint256 internal constant DUMP = 30_000e18;
    uint256 internal constant REDEEM = 5000e18;

    function setUp() public override {
        super.setUp();
        LaunchConfig memory lc = factory.launchConfig();
        lc.depositorLock = 0;
        vm.prank(admin);
        factory.setLaunchConfig(lc);
        _launchDefault();
        vm.prank(alice);
        launch.claim(false);
        _noIssuance();
        vm.startPrank(alice);
        fund.transfer(attacker, DUMP);
        fund.transfer(carol, REDEEM);
        vm.stopPrank();
    }

    /// @dev Dumps into the pool now and keeps the TWAP checkpoints coming while the low price holds.
    function _dumpAndHold(
        uint256 hold
    ) internal {
        _poolSwap(attacker, false, -int256(DUMP));
        for (uint256 t; t < hold; t += 5 minutes) {
            vm.warp(block.timestamp + 5 minutes);
            hook.poke(address(fund));
        }
        _refreshFeeds();
    }

    function _buyBack() internal {
        _poolSwap(attacker, true, int256(DUMP));
    }

    function _redeemAsCarol() internal returns (uint256[] memory out, uint256 usdgOut) {
        vm.prank(carol);
        (out, usdgOut) = fund.redeem(REDEEM, carol, new uint256[](0), 0);
    }

    function _assertNoMoreThan(
        uint256[] memory out,
        uint256 usdgOut,
        uint256[] memory fair,
        uint256 fairUsdg
    ) internal pure {
        for (uint256 i; i < out.length; ++i) {
            assertLe(out[i], fair[i] * 10_001 / 10_000);
        }
        assertLe(usdgOut, fairUsdg * 10_001 / 10_000);
    }

    /// @dev A6-M-01: a crash held past the TWAP window and reversed before the redeem.
    function test_redeem_crashHeldThenReversed_paysNoMoreThanFair() public {
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 35 minutes);
        _refreshFeeds();
        (uint256[] memory fair, uint256 fairUsdg) = _redeemAsCarol();
        vm.revertToState(snap);

        _dumpAndHold(35 minutes);
        _buyBack();
        (, uint256 twapTokens) = fund.positionAmounts();
        (, uint256 spotTokens) = hook.positionBounds(address(fund), false);
        assertGt(twapTokens, spotTokens * 2); // the TWAP still sees the crash
        (uint256[] memory out, uint256 usdgOut) = _redeemAsCarol();
        _assertNoMoreThan(out, usdgOut, fair, fairUsdg);
    }

    /// @dev A6-M-02: one second at a low price right after seeding, when the TWAP has no history.
    function test_redeem_youngPoolOneBlockPush_paysNoMoreThanFair() public {
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 1);
        (uint256[] memory fair, uint256 fairUsdg) = _redeemAsCarol();
        vm.revertToState(snap);

        _poolSwap(attacker, false, -int256(DUMP));
        vm.warp(block.timestamp + 1);
        _buyBack();
        (uint256[] memory out, uint256 usdgOut) = _redeemAsCarol();
        _assertNoMoreThan(out, usdgOut, fair, fairUsdg);
    }

    /// @dev A dump in the same block moves spot only; the redeem keeps the TWAP reading.
    function test_redeem_sameBlockDump_paysNoMoreThanFair() public {
        vm.warp(block.timestamp + 1 hours);
        hook.poke(address(fund));
        _refreshFeeds();
        uint256 snap = vm.snapshotState();
        (uint256[] memory fair, uint256 fairUsdg) = _redeemAsCarol();
        vm.revertToState(snap);

        _poolSwap(attacker, false, -int256(DUMP));
        (uint256[] memory out, uint256 usdgOut) = _redeemAsCarol();
        _assertNoMoreThan(out, usdgOut, fair, fairUsdg);
    }

    /// @dev A6-L-03: a dump toward NAV held past the TWAP window, reversed before a mint at NAV.
    function test_mintAtNav_dumpHeldThenReversed_chargesNoLessThanFair() public {
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 35 minutes);
        _refreshFeeds();
        (,, uint256[] memory fair, uint256 fairUsdg,) = fund.previewMint(10_000e18, true);
        vm.revertToState(snap);

        _dumpAndHold(35 minutes);
        _buyBack();
        (,, uint256[] memory amounts, uint256 usdgAmount,) = fund.previewMint(10_000e18, true);
        for (uint256 i; i < amounts.length; ++i) {
            assertGe(amounts[i] * 10_001 / 10_000, fair[i]);
        }
        assertGe(usdgAmount * 10_001 / 10_000, fairUsdg);
    }

    function test_positionBounds_takeLowerForRedeemHigherForMint() public {
        _dumpAndHold(35 minutes);
        _buyBack();
        (uint256 twapUsdg, uint256 twapTokens) = fund.positionAmounts();
        (uint256 lowUsdg, uint256 lowTokens) = hook.positionBounds(address(fund), false);
        (uint256 highUsdg, uint256 highTokens) = hook.positionBounds(address(fund), true);
        assertLe(lowUsdg, twapUsdg);
        assertLe(lowTokens, twapTokens);
        assertGe(highUsdg, twapUsdg);
        assertGe(highTokens, twapTokens);
        assertLt(lowTokens, highTokens);
        assertLt(lowUsdg, highUsdg);
    }
}
