// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fund} from "../../../src/funds/Fund.sol";
import {IFund} from "../../../src/interfaces/IFund.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @title FundHandler — random mints, redeems, lock claims and market-price moves on one fund
contract FundHandler is Test {
    Fund internal fund;
    MockERC20[3] internal assets;
    MockERC20 internal usdg;
    address[3] internal actors;

    uint256 public mints;
    uint256 public redeems;

    constructor(Fund fund_, MockERC20[3] memory assets_, address[3] memory actors_) {
        fund = fund_;
        assets = assets_;
        usdg = MockERC20(IFundFactory(fund_.factory()).usdg());
        actors = actors_;
    }

    function mint(uint256 actorSeed, uint256 navShares, uint256 lockSeed) external {
        address actor = actors[actorSeed % 3];
        navShares = bound(navShares, 1e15, 10_000e18);
        (,, uint256[] memory amounts, uint256 usdgAmount) = fund.previewMint(navShares, lockSeed % 3);
        vm.startPrank(actor);
        for (uint256 i; i < 3; ++i) {
            assets[i].mint(actor, amounts[i]);
            assets[i].approve(address(fund), amounts[i]);
        }
        usdg.mint(actor, usdgAmount);
        usdg.approve(address(fund), usdgAmount);
        fund.mint(navShares, lockSeed % 3, 0, actor);
        vm.stopPrank();
        ++mints;
    }

    function redeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = fund.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        fund.redeem(amount, actor, new uint256[](0), 0);
        ++redeems;
    }

    function claimLocks(uint256 actorSeed, uint256 warpBy) external {
        address actor = actors[actorSeed % 3];
        vm.warp(block.timestamp + bound(warpBy, 0, 2 hours));
        IFund.Lock[] memory locks = fund.locksOf(actor);
        uint256 n;
        for (uint256 i; i < locks.length; ++i) {
            if (locks[i].amount != 0 && locks[i].unlockAt <= block.timestamp) ++n;
        }
        uint256[] memory ids = new uint256[](n);
        n = 0;
        for (uint256 i; i < locks.length; ++i) {
            if (locks[i].amount != 0 && locks[i].unlockAt <= block.timestamp) ids[n++] = i;
        }
        vm.prank(actor);
        fund.claimLocks(ids);
    }
}
