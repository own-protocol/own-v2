// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundMintZap} from "../../src/funds/FundMintZap.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundMintZap} from "../../src/interfaces/IFundMintZap.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";

contract FundMintZapTest is FundTestBase {
    FundMintZap internal zap;
    MockSwapRouter internal router;

    uint256 internal constant NAV_SHARES = 1000e18;
    uint256 internal constant PAY = 5000e6;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        zap = new FundMintZap(address(factory));
        router = new MockSwapRouter();
        vm.prank(admin);
        factory.setRouter(address(router), true);
        net.mint(address(router), 1000e9);
        pons.mint(address(router), 10_000_000e18);
        tsla.mint(address(router), 1000e18);

        usdg.mint(alice, PAY);
        vm.prank(alice);
        usdg.approve(address(zap), type(uint256).max);
    }

    /// @dev USDG -> each basket asset, `extra` on top of what the slice needs, 1000 USDG per swap.
    function _swaps(
        uint256 extra
    ) internal view returns (IFundMintZap.Swap[] memory swaps) {
        (,, uint256[] memory amounts,) = fund.previewMint(NAV_SHARES, 0);
        address[] memory a = fund.assets();
        swaps = new IFundMintZap.Swap[](3);
        for (uint256 i; i < 3; ++i) {
            swaps[i] = IFundMintZap.Swap({
                router: address(router),
                tokenIn: address(usdg),
                amountIn: 1000e6,
                data: abi.encodeCall(MockSwapRouter.swap, (address(usdg), 1000e6, a[i], amounts[i] + extra))
            });
        }
    }

    function test_zapMint_fromUsdg() public {
        (uint256 quoted,,, uint256 usdgAmount) = fund.previewMint(NAV_SHARES, 0);
        IFundMintZap.Swap[] memory sw = _swaps(0);
        vm.expectEmit(address(zap));
        emit IFundMintZap.ZapMinted(address(fund), alice, alice, address(usdg), PAY, quoted);
        vm.prank(alice);
        uint256 shares = zap.zapMint(address(fund), address(usdg), PAY, sw, NAV_SHARES, 0, quoted, alice);

        assertEq(shares, quoted);
        assertEq(fund.balanceOf(alice), shares);
        assertEq(usdg.balanceOf(alice), PAY - 3000e6 - usdgAmount); // the rest comes back
        _assertZapEmpty();
    }

    function test_zapMint_leftoversRefunded() public {
        IFundMintZap.Swap[] memory sw = _swaps(5);
        vm.prank(alice);
        zap.zapMint(address(fund), address(usdg), PAY, sw, NAV_SHARES, 0, 0, alice);
        assertEq(net.balanceOf(alice), 5);
        assertEq(pons.balanceOf(alice), 5);
        assertEq(tsla.balanceOf(alice), 5);
        _assertZapEmpty();
    }

    function test_zapMint_withLock_toReceiver() public {
        IFundMintZap.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        uint256 shares = zap.zapMint(address(fund), address(usdg), PAY, sw, NAV_SHARES, 1, 0, bob);
        IFund.Lock[] memory locks = fund.locksOf(bob);
        assertEq(locks.length, 1);
        assertEq(locks[0].amount, shares);
        _assertZapEmpty();
    }

    function test_zapMint_shortSwap_reverts() public {
        IFundMintZap.Swap[] memory swaps = _swaps(0);
        (,, uint256[] memory amounts,) = fund.previewMint(NAV_SHARES, 0);
        swaps[2].data = abi.encodeCall(MockSwapRouter.swap, (address(usdg), 1000e6, address(tsla), amounts[2] - 1));
        vm.prank(alice);
        vm.expectRevert();
        zap.zapMint(address(fund), address(usdg), PAY, swaps, NAV_SHARES, 0, 0, alice);
    }

    function test_zapMint_slippage_reverts() public {
        (uint256 quoted,,,) = fund.previewMint(NAV_SHARES, 0);
        IFundMintZap.Swap[] memory swaps = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFund.Slippage.selector);
        zap.zapMint(address(fund), address(usdg), PAY, swaps, NAV_SHARES, 0, quoted + 1, alice);
    }

    function test_zapMint_routerNotAllowed_reverts() public {
        IFundMintZap.Swap[] memory swaps = _swaps(0);
        swaps[0].router = address(new MockSwapRouter());
        vm.prank(alice);
        vm.expectRevert(IFundMintZap.RouterNotAllowed.selector);
        zap.zapMint(address(fund), address(usdg), PAY, swaps, NAV_SHARES, 0, 0, alice);
    }

    function test_zapMint_swapFails_reverts() public {
        IFundMintZap.Swap[] memory swaps = _swaps(0);
        swaps[0].data = abi.encodeCall(MockSwapRouter.alwaysReverts, ());
        vm.prank(alice);
        vm.expectRevert(IFundMintZap.SwapFailed.selector);
        zap.zapMint(address(fund), address(usdg), PAY, swaps, NAV_SHARES, 0, 0, alice);
    }

    function test_zapMint_notFund_reverts() public {
        IFundMintZap.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFundMintZap.NotFund.selector);
        zap.zapMint(address(usdg), address(usdg), PAY, sw, NAV_SHARES, 0, 0, alice);
    }

    function test_zapMint_zeroReceiver_reverts() public {
        IFundMintZap.Swap[] memory sw = _swaps(0);
        vm.prank(alice);
        vm.expectRevert(IFundMintZap.ZeroAddress.selector);
        zap.zapMint(address(fund), address(usdg), PAY, sw, NAV_SHARES, 0, 0, address(0));
    }

    function test_constructor_zeroFactory_reverts() public {
        vm.expectRevert(IFundMintZap.ZeroAddress.selector);
        new FundMintZap(address(0));
    }

    function _assertZapEmpty() internal view {
        MockERC20[4] memory tokens = [usdg, net, pons, tsla];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(address(zap)), 0);
            assertEq(tokens[i].allowance(address(zap), address(fund)), 0);
            assertEq(tokens[i].allowance(address(zap), address(router)), 0);
        }
        assertEq(fund.balanceOf(address(zap)), 0);
    }
}
