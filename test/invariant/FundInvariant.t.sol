// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundStaking} from "../../src/interfaces/IFundStaking.sol";
import {YieldPoint} from "../../src/interfaces/types/FundTypes.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {FundHandler} from "./handlers/FundHandler.sol";

/// @title FundInvariant — mints, redeems and boosts never dilute a fund
/// @notice With oracle prices held fixed and only buys in the pool (each issues above NAV, keeps a
///         quarter of the premium as backing, and lifts the TWAP the position is valued at), every
///         mint is priced at or above NAV,
///         every redeem (basket, idle USDG and its slice of the pool position, less the reserve's
///         part) pays at most NAV, and every boost payout or forfeit moves reserve into backing at
///         NAV or better, so NAV per token can only rise. Also checks that the reserve always equals
///         the boost budgets still owed. Tier yield is switched off: it dilutes by design.
contract FundInvariant is FundTestBase {
    FundHandler internal handler;
    uint256 internal navAtStart;
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(alice);
        launch.claim(false);
        vm.prank(bob);
        launch.claim(false);

        // Keep every feed fresh however far the handler warps.
        vm.startPrank(admin);
        oracle.setFeed(address(net), address(feeds[address(net)]), type(uint32).max);
        oracle.setFeed(address(pons), address(feeds[address(pons)]), type(uint32).max);
        oracle.setFeed(address(tsla), address(feeds[address(tsla)]), type(uint32).max);
        oracle.setFeed(address(fund), address(feeds[address(fund)]), type(uint32).max);
        staking.setYieldCurve(new YieldPoint[](0));
        vm.stopPrank();

        _passDepositorLock();
        vm.prank(alice);
        fund.transfer(carol, 20_000e18);
        handler = new FundHandler(fund, [net, pons, tsla], [alice, bob, carol]);
        navAtStart = fund.navPerShare();
        targetContract(address(handler));
    }

    /// @dev The pool position is valued by rounding its amounts down, so a redeem can lower the
    ///      reported value by up to one USDG unit more than it pays out; allow that drift.
    function invariant_navPerShareNeverFalls() public view {
        assertGe(fund.navPerShare() + navAtStart / 1e9, navAtStart);
    }

    function invariant_stakingHoldsStakesAndPayoutsOwed() public view {
        address[3] memory actors = [alice, bob, carol];
        uint256 owed = staking.totalAssets() + staking.potLeft() + staking.potPending();
        for (uint256 a; a < 3; ++a) {
            owed += staking.boostOf(actors[a]).left;
        }
        assertEq(fund.balanceOf(address(staking)), owed);
    }
}
