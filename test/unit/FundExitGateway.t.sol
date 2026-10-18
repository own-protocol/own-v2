// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundExitGateway} from "../../src/funds/FundExitGateway.sol";
import {IFundExitGateway} from "../../src/interfaces/IFundExitGateway.sol";
import {CcipClient} from "../../src/interfaces/external/ICcip.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockCcipRouter} from "../helpers/MockCcipRouter.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";

contract NoReceive {
    function exit(
        FundExitGateway g,
        address fund,
        uint256 shares,
        IFundExitGateway.Route[] calldata routes
    ) external payable {
        g.exit{value: msg.value}(fund, shares, routes, 0, address(this));
    }
}

contract FundExitGatewayTest is FundTestBase {
    uint64 internal constant BASE = 15_971_525_489_660_198_786;
    uint256 internal constant SHARES = 11_000e18;
    uint256 internal constant FEE = 0.001 ether;

    FundExitGateway internal gateway;
    MockCcipRouter internal ccip;
    MockSwapRouter internal router;
    address internal baseGateway = makeAddr("baseGateway");
    uint256 internal bobShares;

    function setUp() public override {
        super.setUp();
        _launchDefault();
        vm.prank(bob);
        bobShares = launch.claim(false);
        _passDepositorLock();

        ccip = new MockCcipRouter();
        gateway = new FundExitGateway(address(factory), address(ccip), BASE, baseGateway);
        router = new MockSwapRouter();
        vm.prank(admin);
        factory.setRouter(address(router), true);
        usdg.mint(address(router), 1_000_000e6);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        fund.approve(address(gateway), type(uint256).max);
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IFundExitGateway.ZeroAddress.selector);
        new FundExitGateway(address(0), address(ccip), BASE, baseGateway);
        vm.expectRevert(IFundExitGateway.ZeroAddress.selector);
        new FundExitGateway(address(factory), address(0), BASE, baseGateway);
        vm.expectRevert(IFundExitGateway.ZeroAddress.selector);
        new FundExitGateway(address(factory), address(ccip), BASE, address(0));
        vm.expectRevert(IFundExitGateway.ZeroAddress.selector);
        new FundExitGateway(address(factory), address(ccip), 0, baseGateway);
    }

    function test_views() public view {
        assertEq(gateway.factory(), address(factory));
        assertEq(gateway.router(), address(ccip));
        assertEq(gateway.baseSelector(), BASE);
        assertEq(gateway.baseGateway(), baseGateway);
        assertEq(gateway.quoteBridge(address(tsla), 1e18, bob, 1e6), FEE);
    }

    function test_exit_swapsLocalAndBridgesOne() public {
        (uint256[] memory amounts, uint256 usdgPart) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        routes[2] = _bridgeRoute(3300e6); // tsla to Base

        uint256 usdgBefore = usdg.balanceOf(bob);
        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        uint256 out = gateway.exit{value: 0.01 ether}(address(fund), SHARES, routes, 6000e6, bob);

        assertApproxEqRel(out, 6600e6 + usdgPart, 1e14);
        assertEq(usdg.balanceOf(bob) - usdgBefore, out);
        assertEq(ethBefore - bob.balance, FEE, "only the fee is kept");
        assertEq(fund.balanceOf(bob), bobShares - SHARES);

        assertEq(ccip.sends(), 1);
        assertEq(ccip.lastDestChainSelector(), BASE);
        assertEq(ccip.lastToken(), address(tsla));
        assertEq(ccip.lastAmount(), amounts[2]);
        assertEq(tsla.balanceOf(address(ccip)), amounts[2]);
        assertEq(ccip.lastReceiver(), abi.encode(baseGateway));
        assertEq(ccip.lastData(), abi.encode(bob, uint256(3300e6)));
        assertEq(ccip.lastFeeToken(), address(0));
        assertEq(
            ccip.lastExtraArgs(),
            CcipClient.encodeExtraArgs(
                CcipClient.GenericExtraArgsV2({gasLimit: 300_000, allowOutOfOrderExecution: true})
            )
        );
        assertEq(tsla.allowance(address(gateway), address(ccip)), 0);
        _assertEmpty();
    }

    function test_exit_bridgesTwo_paysTwoFees() public {
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        routes[1] = _bridgeRoute(1);
        routes[2] = _bridgeRoute(1);

        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        gateway.exit{value: 2 * FEE}(address(fund), SHARES, routes, 0, bob);
        assertEq(ccip.sends(), 2);
        assertEq(ethBefore - bob.balance, 2 * FEE);
        _assertEmpty();
    }

    function test_exit_unroutedAssetPaidInKind() public {
        (uint256[] memory amounts, uint256 usdgPart) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        routes[1].router = address(0);

        vm.prank(bob);
        uint256 out = gateway.exit(address(fund), SHARES, routes, 0, bob);
        assertApproxEqRel(out, 7000e6 + usdgPart, 1e14);
        assertEq(pons.balanceOf(bob), amounts[1]);
        _assertEmpty();
    }

    function test_exit_noValueNoBridge_refundsNothing() public {
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        gateway.exit{value: 0.5 ether}(address(fund), SHARES, routes, 0, bob);
        assertEq(bob.balance, ethBefore, "full refund when nothing is bridged");
    }

    function test_exit_insufficientFee_reverts() public {
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        routes[1] = _bridgeRoute(1);
        routes[2] = _bridgeRoute(1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IFundExitGateway.InsufficientFee.selector, FEE, 0));
        gateway.exit{value: FEE}(address(fund), SHARES, routes, 0, bob);
    }

    function test_exit_bridgeAndRouter_reverts() public {
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        routes[2].bridge = true;
        vm.prank(bob);
        vm.expectRevert(IFundExitGateway.InvalidRoute.selector);
        gateway.exit{value: FEE}(address(fund), SHARES, routes, 0, bob);
    }

    function test_exit_belowMinimum_reverts() public {
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        vm.prank(bob);
        vm.expectRevert(IFundExitGateway.Slippage.selector);
        gateway.exit(address(fund), SHARES, routes, 1_000_000e6, bob);
    }

    function test_exit_routerNotAllowed_reverts() public {
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        vm.prank(admin);
        factory.setRouter(address(router), false);
        vm.prank(bob);
        vm.expectRevert(IFundExitGateway.RouterNotAllowed.selector);
        gateway.exit(address(fund), SHARES, routes, 0, bob);
    }

    function test_exit_routerFails_reverts() public {
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        routes[0].data = abi.encodeCall(MockSwapRouter.alwaysReverts, ());
        vm.prank(bob);
        vm.expectRevert(IFundExitGateway.SwapFailed.selector);
        gateway.exit(address(fund), SHARES, routes, 0, bob);
    }

    function test_exit_lengthMismatch_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFundExitGateway.LengthMismatch.selector);
        gateway.exit(address(fund), SHARES, new IFundExitGateway.Route[](2), 0, bob);
    }

    function test_exit_notFund_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFundExitGateway.NotFund.selector);
        gateway.exit(address(spare), SHARES, new IFundExitGateway.Route[](3), 0, bob);
    }

    function test_exit_zeroReceiver_reverts() public {
        vm.prank(bob);
        vm.expectRevert(IFundExitGateway.ZeroAddress.selector);
        gateway.exit(address(fund), SHARES, new IFundExitGateway.Route[](3), 0, address(0));
    }

    function test_exit_refundRejected_reverts() public {
        NoReceive c = new NoReceive();
        vm.prank(bob);
        fund.transfer(address(c), SHARES);
        vm.prank(address(c));
        fund.approve(address(gateway), SHARES);
        (uint256[] memory amounts,) = fund.previewRedeem(SHARES);
        IFundExitGateway.Route[] memory routes = _routes(amounts);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IFundExitGateway.RefundFailed.selector);
        c.exit{value: 0.1 ether}(gateway, address(fund), SHARES, routes);
    }

    function _routes(
        uint256[] memory amounts
    ) internal view returns (IFundExitGateway.Route[] memory routes) {
        address[] memory assets = fund.assets();
        uint256[3] memory usdgOut = [uint256(3600e6), 3000e6, 3400e6];
        routes = new IFundExitGateway.Route[](3);
        for (uint256 i; i < 3; ++i) {
            routes[i] = IFundExitGateway.Route({
                router: address(router),
                data: abi.encodeCall(MockSwapRouter.swap, (assets[i], amounts[i], address(usdg), usdgOut[i])),
                bridge: false,
                minOut: 0
            });
        }
    }

    function _bridgeRoute(
        uint256 minOut
    ) internal pure returns (IFundExitGateway.Route memory) {
        return IFundExitGateway.Route({router: address(0), data: "", bridge: true, minOut: minOut});
    }

    function _assertEmpty() internal view {
        assertEq(usdg.balanceOf(address(gateway)), 0);
        assertEq(fund.balanceOf(address(gateway)), 0);
        assertEq(net.balanceOf(address(gateway)), 0);
        assertEq(pons.balanceOf(address(gateway)), 0);
        assertEq(tsla.balanceOf(address(gateway)), 0);
        assertEq(address(gateway).balance, 0);
    }
}
