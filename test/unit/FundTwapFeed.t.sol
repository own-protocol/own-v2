// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundTwapFeed} from "../../src/funds/FundTwapFeed.sol";
import {IFundHook} from "../../src/interfaces/IFundHook.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract FundTwapFeedTest is FundTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolSwapTest internal swapRouter;
    PoolKey internal key;
    bool internal usdgIs0;
    FundTwapFeed internal feed;
    address internal trader = makeAddr("trader");

    uint32 internal constant WINDOW = 30 minutes;
    uint256 internal launchPrice;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        key = hook.poolKeyOf(address(fund));
        usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        swapRouter = new PoolSwapTest(poolManager);
        feed = new FundTwapFeed(IFundHook(address(hook)), address(fund), WINDOW);

        launchPrice = fund.navPerShare() * 13 / 10;
        usdg.mint(trader, 1_000_000e6);
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), type(uint256).max);
        fund.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_noAnswerUntilWindowOfHistory() public view {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, 0);
        assertEq(updatedAt, 0);
        (bool ok,,) = hook.consult(address(fund), WINDOW);
        assertFalse(ok);
    }

    function test_quietPool_reportsLaunchPrice() public {
        vm.warp(block.timestamp + WINDOW);
        (, int256 answer, uint256 startedAt, uint256 updatedAt,) = feed.latestRoundData();
        assertApproxEqRel(uint256(answer), launchPrice, 2e15); // 1.3x NAV within a tick's rounding
        assertEq(updatedAt, block.timestamp);
        assertEq(startedAt, block.timestamp - WINDOW);
    }

    function test_twapLagsSpot() public {
        vm.warp(block.timestamp + 1 hours);
        _swap(true, -int256(10_000e6)); // buy: spot jumps
        uint256 spot = _spotUsd();
        assertGt(spot, launchPrice * 11 / 10);

        vm.warp(block.timestamp + 15 minutes);
        (, int256 answer,,,) = feed.latestRoundData();
        // Half the window at the launch price, half at the new spot: well below spot, above launch.
        assertGt(uint256(answer), launchPrice * 101 / 100);
        assertLt(uint256(answer), spot);

        vm.warp(block.timestamp + 1 hours);
        (, answer,,,) = feed.latestRoundData();
        assertApproxEqRel(uint256(answer), spot, 2e15);
    }

    function test_sameBlockRoundTripDoesNotMoveTwap() public {
        vm.warp(block.timestamp + 1 hours);
        (, int256 before,,,) = feed.latestRoundData();
        _swap(true, -int256(200_000e6));
        _swap(false, -int256(fund.balanceOf(trader)));
        (, int256 afterAnswer,,,) = feed.latestRoundData();
        assertApproxEqRel(uint256(afterAnswer), uint256(before), 1e15);
    }

    function test_ringKeepsCheckpointsForMaxWindow() public {
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + 6 minutes);
            _swap(i % 2 == 0, i % 2 == 0 ? -int256(100e6) : -int256(50e18));
        }
        (bool ok,, uint32 period) = hook.consult(address(fund), hook.MAX_TWAP_WINDOW());
        assertTrue(ok);
        assertGe(period, hook.MAX_TWAP_WINDOW());
        assertLt(period, hook.MAX_TWAP_WINDOW() + 6 minutes);
    }

    function test_poke_keepsWindowTight() public {
        vm.warp(block.timestamp + 10 hours);
        (bool ok,, uint32 period) = hook.consult(address(fund), WINDOW);
        assertTrue(ok);
        assertEq(period, 10 hours); // no checkpoint since launch

        for (uint256 i; i < 8; ++i) {
            vm.warp(block.timestamp + 5 minutes);
            hook.poke(address(fund));
        }
        (ok,, period) = hook.consult(address(fund), WINDOW);
        assertTrue(ok);
        assertEq(period, WINDOW); // a checkpoint sits exactly one window back
    }

    function test_consult_windowTooLong() public {
        vm.warp(block.timestamp + 10 hours);
        (bool ok,,) = hook.consult(address(fund), hook.MAX_TWAP_WINDOW() + 1);
        assertFalse(ok);
    }

    function test_constructor_badWindow_reverts() public {
        vm.expectRevert(FundTwapFeed.InvalidWindow.selector);
        new FundTwapFeed(IFundHook(address(hook)), address(fund), 0);
        uint32 tooLong = hook.MAX_TWAP_WINDOW() + 1;
        vm.expectRevert(FundTwapFeed.InvalidWindow.selector);
        new FundTwapFeed(IFundHook(address(hook)), address(fund), tooLong);
    }

    function test_constructor_unknownFund_reverts() public {
        vm.expectRevert(FundTwapFeed.NotRegistered.selector);
        new FundTwapFeed(IFundHook(address(hook)), address(spare), WINDOW);
    }

    function test_poke_unseeded_reverts() public {
        vm.expectRevert(IFundHook.NotRegistered.selector);
        hook.poke(address(spare));
    }

    function test_drivesOraclePremiumAndMint() public {
        vm.prank(admin);
        oracle.setFeed(address(fund), address(feed), 1 hours);
        vm.warp(block.timestamp + WINDOW);
        _refreshAssetFeeds();

        (bool ok, int256 premium) = fund.premiumBps();
        assertTrue(ok);
        assertApproxEqAbs(premium, 3000, 5);

        _mintAsset(bob, tsla, 1e18);
        vm.prank(bob);
        uint256 shares = fund.mint(address(tsla), 1e18, 0, 0, bob);
        assertApproxEqRel(shares, 400e18 * 9850 / 10_000 * 1e18 / launchPrice, 2e15); // $400 at the TWAP, less 1.5% fees
    }

    function test_description() public view {
        assertEq(feed.description(), "OCF1 / USD pool TWAP");
        assertEq(feed.decimals(), 18);
    }

    function _refreshAssetFeeds() internal {
        address[3] memory list = [address(net), address(pons), address(tsla)];
        for (uint256 i; i < list.length; ++i) {
            _setFeed(list[i], feeds[list[i]].answer());
        }
    }

    function _swap(bool buy, int256 amountSpecified) internal {
        bool zeroForOne = buy == usdgIs0;
        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _spotUsd() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        // raw USDG per raw fund token, scaled to USD per fund token with 18 decimals
        return usdgIs0 ? Math.mulDiv(1e30, 1 << 192, priceX192) : Math.mulDiv(priceX192, 1e30, 1 << 192);
    }
}
