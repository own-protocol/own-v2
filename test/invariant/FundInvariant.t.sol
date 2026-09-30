// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFund} from "../../src/interfaces/IFund.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {FundHandler} from "./handlers/FundHandler.sol";

/// @title FundInvariant — mints and redeems never dilute a fund
/// @notice With oracle prices held fixed, every mint is priced at or above NAV and every redeem pays
///         at most NAV, so NAV per token can only rise. Also checks that locked mints are always fully
///         held by the fund.
contract FundInvariant is FundTestBase {
    FundHandler internal handler;
    uint256 internal navAtStart;
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        _launchDefault();
        _setFeed(address(fund), 1.2e8);
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
        vm.stopPrank();

        vm.prank(alice);
        fund.transfer(carol, 20_000e18);
        handler = new FundHandler(fund, [net, pons, tsla], [alice, bob, carol]);
        navAtStart = fund.navPerShare();
        targetContract(address(handler));
    }

    function invariant_navPerShareNeverFalls() public view {
        assertGe(fund.navPerShare() + 1, navAtStart);
    }

    function invariant_locksFullyHeld() public view {
        address[3] memory actors = [alice, bob, carol];
        uint256 locked;
        for (uint256 a; a < 3; ++a) {
            IFund.Lock[] memory locks = fund.locksOf(actors[a]);
            for (uint256 i; i < locks.length; ++i) {
                locked += locks[i].amount;
            }
        }
        assertGe(fund.balanceOf(address(fund)), locked);
    }
}
