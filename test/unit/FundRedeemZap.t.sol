// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundRedeemZap} from "../../src/funds/FundRedeemZap.sol";
import {IFundRedeemZap} from "../../src/interfaces/IFundRedeemZap.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";

contract FundRedeemZapTest is FundTestBase {
    FundRedeemZap internal zap;
    MockSwapRouter internal router;

    uint256 internal constant SHARES = 13_000e18; // 10% of supply

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(bob);
        launch.claim(false); // 40k MF1

        zap = new FundRedeemZap(address(factory));
        router = new MockSwapRouter();
        vm.prank(admin);
        factory.setRouter(address(router), true);
        usdg.mint(address(router), 1_000_000e6);

        vm.prank(bob);
        fund.approve(address(zap), type(uint256).max);
    }

    function test_redeemToUsdg_swapsWholeBasket() public {
        uint256[] memory amounts = fund.previewRedeem(SHARES);
        IFundRedeemZap.Route[] memory routes = _routes(amounts, [uint256(3600e6), 3000e6, 3400e6]);

        uint256 usdgBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 out = zap.redeemToUsdg(address(fund), SHARES, routes, 10_000e6, bob);

        assertEq(out, 10_000e6);
        assertEq(usdg.balanceOf(bob) - usdgBefore, 10_000e6);
        assertEq(fund.balanceOf(bob), 40_000e18 - SHARES);
        _assertZapEmpty();
    }

    function test_redeemToUsdg_unroutedAssetPaidInKind() public {
        uint256[] memory amounts = fund.previewRedeem(SHARES);
        IFundRedeemZap.Route[] memory routes = _routes(amounts, [uint256(3600e6), 3000e6, 3400e6]);
        routes[1].router = address(0); // keep PONS

        vm.prank(bob);
        uint256 out = zap.redeemToUsdg(address(fund), SHARES, routes, 0, bob);

        assertEq(out, 7000e6);
        assertEq(pons.balanceOf(bob), amounts[1]);
        _assertZapEmpty();
    }

    function test_redeemToUsdg_belowMinimum_reverts() public {
        uint256[] memory amounts = fund.previewRedeem(SHARES);
        IFundRedeemZap.Route[] memory routes = _routes(amounts, [uint256(3600e6), 3000e6, 3400e6]);
        vm.prank(bob);
        vm.expectRevert(IFundRedeemZap.Slippage.selector);
        zap.redeemToUsdg(address(fund), SHARES, routes, 10_000e6 + 1, bob);
    }

    function test_redeemToUsdg_routerNotAllowed_reverts() public {
        uint256[] memory amounts = fund.previewRedeem(SHARES);
        IFundRedeemZap.Route[] memory routes = _routes(amounts, [uint256(3600e6), 3000e6, 3400e6]);
        vm.prank(admin);
        factory.setRouter(address(router), false);
        vm.prank(bob);
        vm.expectRevert(IFundRedeemZap.RouterNotAllowed.selector);
        zap.redeemToUsdg(address(fund), SHARES, routes, 0, bob);
    }

    function test_redeemToUsdg_routerFails_reverts() public {
        uint256[] memory amounts = fund.previewRedeem(SHARES);
        IFundRedeemZap.Route[] memory routes = _routes(amounts, [uint256(3600e6), 3000e6, 3400e6]);
        routes[0].data = abi.encodeCall(MockSwapRouter.alwaysReverts, ());
        vm.prank(bob);
        vm.expectRevert(IFundRedeemZap.SwapFailed.selector);
        zap.redeemToUsdg(address(fund), SHARES, routes, 0, bob);
    }

    function test_redeemToUsdg_routerCannotPullMoreThanRedeemed() public {
        uint256[] memory amounts = fund.previewRedeem(SHARES);
        IFundRedeemZap.Route[] memory routes = _routes(amounts, [uint256(3600e6), 3000e6, 3400e6]);
        routes[0].data =
            abi.encodeCall(MockSwapRouter.swap, (address(net), amounts[0] + 1, address(usdg), uint256(3600e6)));
        vm.prank(bob);
        vm.expectRevert(IFundRedeemZap.SwapFailed.selector);
        zap.redeemToUsdg(address(fund), SHARES, routes, 0, bob);
    }

    function test_redeemToUsdg_lengthMismatch_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFundRedeemZap.LengthMismatch.selector);
        zap.redeemToUsdg(address(fund), SHARES, new IFundRedeemZap.Route[](2), 0, bob);
    }

    function test_redeemToUsdg_notFund_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFundRedeemZap.NotFund.selector);
        zap.redeemToUsdg(address(spare), SHARES, new IFundRedeemZap.Route[](3), 0, bob);
    }

    function _routes(
        uint256[] memory amounts,
        uint256[3] memory usdgOut
    ) internal view returns (IFundRedeemZap.Route[] memory routes) {
        address[] memory assets = fund.assets();
        routes = new IFundRedeemZap.Route[](3);
        for (uint256 i; i < 3; ++i) {
            routes[i] = IFundRedeemZap.Route({
                router: address(router),
                data: abi.encodeCall(MockSwapRouter.swap, (assets[i], amounts[i], address(usdg), usdgOut[i]))
            });
        }
    }

    function _assertZapEmpty() internal view {
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(fund.balanceOf(address(zap)), 0);
        assertEq(net.balanceOf(address(zap)), 0);
        assertEq(pons.balanceOf(address(zap)), 0);
        assertEq(tsla.balanceOf(address(zap)), 0);
    }
}
