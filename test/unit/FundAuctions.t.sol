// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundAuctions} from "../../src/funds/FundAuctions.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundAuctions} from "../../src/interfaces/IFundAuctions.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FundAuctionsTest is FundTestBase {
    FundAuctions internal auctions;
    address internal filler = makeAddr("filler");

    uint16 internal constant PREMIUM = 200;
    uint16 internal constant FLOOR = 300;
    uint32 internal constant DURATION = 4 hours;

    // 1e18 NET units (1e9 NET) priced in TSLA units: $300 / $400 per whole token.
    uint256 internal constant RATE = 0.75e27;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        auctions = new FundAuctions(address(factory), PREMIUM, FLOOR, DURATION);
        vm.prank(admin);
        factory.setAuctions(address(auctions));
        tsla.mint(filler, 1000e18);
        vm.prank(filler);
        tsla.approve(address(auctions), type(uint256).max);
    }

    function _open(
        uint256 amount
    ) internal returns (uint256 id) {
        vm.prank(keeper);
        id = auctions.openLot(address(fund), address(net), address(tsla), amount);
    }

    function test_openLot_pricesFromOracle() public {
        uint256 id = _open(10e9);
        IFundAuctions.Lot memory l = auctions.lot(id);
        assertEq(l.fund, address(fund));
        assertEq(l.remaining, 10e9);
        assertEq(l.endTime, block.timestamp + DURATION);
        assertEq(l.startPrice, RATE * 10_200 / 10_000);
        assertEq(l.floorPrice, RATE * 9700 / 10_000);
        assertEq(auctions.currentPrice(id), l.startPrice);
    }

    function test_fill_paysFundAndFiller() public {
        uint256 id = _open(10e9);
        uint256 netBefore = net.balanceOf(address(fund));
        uint256 tslaBefore = tsla.balanceOf(address(fund));

        vm.prank(filler);
        uint256 paid = auctions.fill(id, 4e9, type(uint256).max);

        // 4 NET at the start price: 3 TSLA plus the 2% premium.
        assertEq(paid, 3.06e18);
        assertEq(net.balanceOf(filler), 4e9);
        assertEq(net.balanceOf(address(fund)), netBefore - 4e9);
        assertEq(tsla.balanceOf(address(fund)), tslaBefore + paid);
        assertEq(auctions.lot(id).remaining, 6e9);
    }

    function test_price_fallsLinearlyToFloor() public {
        uint256 id = _open(10e9);
        IFundAuctions.Lot memory l = auctions.lot(id);
        vm.warp(block.timestamp + DURATION / 2);
        _refreshFeeds();
        assertEq(auctions.currentPrice(id), l.startPrice - (l.startPrice - l.floorPrice) / 2);
        vm.warp(l.endTime - 1);
        assertApproxEqAbs(auctions.currentPrice(id), l.floorPrice, (l.startPrice - l.floorPrice) / DURATION + 1);
    }

    function test_fill_afterEnd_reverts() public {
        uint256 id = _open(10e9);
        vm.warp(block.timestamp + DURATION);
        _refreshFeeds();
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(IFundAuctions.LotNotActive.selector, id));
        auctions.fill(id, 1e9, type(uint256).max);
    }

    function test_fill_moreThanLeft_reverts() public {
        uint256 id = _open(10e9);
        vm.prank(filler);
        vm.expectRevert(IFundAuctions.ExceedsLot.selector);
        auctions.fill(id, 10e9 + 1, type(uint256).max);
    }

    function test_fill_aboveMaxPayment_reverts() public {
        uint256 id = _open(10e9);
        vm.prank(filler);
        vm.expectRevert(IFundAuctions.Slippage.selector);
        auctions.fill(id, 4e9, 3.06e18 - 1);
    }

    function test_fill_oracleMovedAgainstLot_reverts() public {
        uint256 id = _open(10e9);
        vm.warp(block.timestamp + DURATION - 1);
        _setFeed(address(net), 330e8); // NET up 10%: the floor no longer covers it
        _refreshFeeds();
        vm.prank(filler);
        vm.expectRevert(IFundAuctions.BelowOracleBound.selector);
        auctions.fill(id, 1e9, type(uint256).max);
    }

    function test_fill_dailyVolumeCapped() public {
        // About $100k tradable: the 10% cap is about $10k, so 30 NET ($9k) fits and 5 more do not.
        uint256 id = _open(40e9);
        vm.startPrank(filler);
        auctions.fill(id, 30e9, type(uint256).max);
        vm.expectRevert(IFundAuctions.VolumeExceeded.selector);
        auctions.fill(id, 5e9, type(uint256).max);
        vm.stopPrank();
        assertGt(auctions.volumeOf(address(fund)), 0);
    }

    function test_cancelLot_stopsFills() public {
        uint256 id = _open(10e9);
        vm.prank(keeper);
        auctions.cancelLot(id);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(IFundAuctions.LotNotActive.selector, id));
        auctions.fill(id, 1e9, type(uint256).max);
    }

    function test_cancelLot_notManager_reverts() public {
        uint256 id = _open(10e9);
        vm.prank(attacker);
        vm.expectRevert(IFundAuctions.NotManager.selector);
        auctions.cancelLot(id);
    }

    function test_openLot_notManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IFundAuctions.NotManager.selector);
        auctions.openLot(address(fund), address(net), address(tsla), 1e9);
    }

    function test_openLot_adminCanOpen() public {
        vm.prank(admin);
        auctions.openLot(address(fund), address(net), address(tsla), 1e9);
        assertEq(auctions.lotCount(), 1);
    }

    function test_openLot_invalidAssets_reverts() public {
        vm.startPrank(keeper);
        vm.expectRevert(IFundAuctions.InvalidAssets.selector);
        auctions.openLot(address(fund), address(net), address(net), 1e9);
        vm.expectRevert(IFundAuctions.InvalidAssets.selector);
        auctions.openLot(address(fund), address(net), address(spare), 1e9);
        vm.expectRevert(IFundAuctions.InvalidAssets.selector);
        auctions.openLot(address(fund), address(spare), address(net), 1e9);
        vm.stopPrank();
    }

    function test_openLot_moreThanHeld_reverts() public {
        uint256 held = net.balanceOf(address(fund));
        vm.prank(keeper);
        vm.expectRevert(IFundAuctions.ZeroAmount.selector);
        auctions.openLot(address(fund), address(net), address(tsla), held + 1);
    }

    function test_openLot_notFund_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(IFundAuctions.NotFund.selector);
        auctions.openLot(address(net), address(net), address(tsla), 1e9);
    }

    function test_openLot_beforeSeeding_reverts() public {
        _createFund();
        vm.prank(keeper);
        vm.expectRevert(IFundAuctions.NotSeeded.selector);
        auctions.openLot(address(fund), address(net), address(tsla), 1);
    }

    function test_openLot_sellsIdleUsdg() public {
        uint128 tenth = hook.positionLiquidity(address(fund)) / 10;
        vm.prank(admin);
        hook.withdrawPosition(address(fund), tenth);
        vm.prank(keeper);
        uint256 id = auctions.openLot(address(fund), address(usdg), address(tsla), 1000e6);
        vm.prank(filler);
        uint256 paid = auctions.fill(id, 1000e6, type(uint256).max);
        // $1,000 for 2.5 TSLA plus the premium.
        assertEq(paid, Math.mulDiv(1000e6, uint256(0.0025e30) * 10_200 / 10_000, 1e18, Math.Rounding.Ceil));
        assertEq(usdg.balanceOf(filler), 1000e6);
    }

    function test_auctionPayout_onlyAuctions() public {
        vm.prank(attacker);
        vm.expectRevert(IFund.NotAuctions.selector);
        fund.auctionPayout(address(net), attacker, 1);
    }

    function test_setConfig_adminOnlyAndBounded() public {
        vm.prank(attacker);
        vm.expectRevert(IFundAuctions.NotAdmin.selector);
        auctions.setConfig(100, 500, 1 hours);

        vm.startPrank(admin);
        vm.expectRevert(IFundAuctions.InvalidConfig.selector);
        auctions.setConfig(5001, 500, 1 hours);
        vm.expectRevert(IFundAuctions.InvalidConfig.selector);
        auctions.setConfig(100, 1001, 1 hours);
        vm.expectRevert(IFundAuctions.InvalidConfig.selector);
        auctions.setConfig(100, 500, 14 minutes);
        auctions.setConfig(100, 500, 1 hours);
        vm.stopPrank();
        assertEq(auctions.startPremiumBps(), 100);
        assertEq(auctions.floorDiscountBps(), 500);
        assertEq(auctions.duration(), 1 hours);
    }

    function test_floorDiscount_setsFloorAndFillBound() public {
        vm.prank(admin);
        auctions.setConfig(PREMIUM, 500, DURATION);
        uint256 id = _open(10e9);
        assertEq(auctions.lot(id).floorPrice, RATE * 9500 / 10_000);

        // NET up 6%: a start-price fill is 3.8% under the live oracle, inside the 5% bound but
        // outside the default 3%.
        _setFeed(address(net), 318e8);
        vm.prank(filler);
        auctions.fill(id, 1e9, type(uint256).max);
    }
}
