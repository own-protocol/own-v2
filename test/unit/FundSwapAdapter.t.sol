// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundSwapAdapter} from "../../src/funds/FundSwapAdapter.sol";
import {IFund} from "../../src/interfaces/IFund.sol";
import {IFundSwapAdapter} from "../../src/interfaces/IFundSwapAdapter.sol";
import {FundTestBase} from "../helpers/FundTestBase.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Universal Router stand-in: like the real one, it never pulls from approvals and pays from its own balance.
///      inputs[0] = (tokenIn, spend, tokenOut, amountOut, sweep): keeps `spend` of tokenIn, pays `amountOut` of
///      tokenOut and sweeps `sweep` tokenIn back to the caller.
contract MockUniversalRouter {
    uint256 public lastDeadline;
    bytes public lastCommands;

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        lastDeadline = deadline;
        lastCommands = commands;
        (address tokenIn, uint256 spend, address tokenOut, uint256 amountOut, uint256 sweep) =
            abi.decode(inputs[0], (address, uint256, address, uint256, uint256));
        require(IERC20(tokenIn).balanceOf(address(this)) >= spend + sweep, "router underfunded");
        if (amountOut != 0) IERC20(tokenOut).transfer(msg.sender, amountOut);
        if (sweep != 0) IERC20(tokenIn).transfer(msg.sender, sweep);
    }
}

contract FundSwapAdapterTest is FundTestBase {
    MockUniversalRouter internal ur;
    FundSwapAdapter internal adapter;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal caller = makeAddr("caller");

    function setUp() public override {
        super.setUp();
        ur = new MockUniversalRouter();
        adapter = new FundSwapAdapter(address(ur));
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 6);
        tokenA.mint(caller, 100e18);
        tokenB.mint(address(ur), 1000e6);
        vm.prank(caller);
        tokenA.approve(address(adapter), type(uint256).max);
    }

    function _inputs(
        address tIn,
        uint256 spend,
        address tOut,
        uint256 out,
        uint256 sweep
    ) internal pure returns (bytes[] memory inputs) {
        inputs = new bytes[](1);
        inputs[0] = abi.encode(tIn, spend, tOut, out, sweep);
    }

    function test_constructor_zeroRouter_reverts() public {
        vm.expectRevert(IFundSwapAdapter.ZeroAddress.selector);
        new FundSwapAdapter(address(0));
    }

    function test_swap_pullsIntoRouterAndReturnsOutput() public {
        vm.prank(caller);
        uint256 out = adapter.swap(
            address(tokenA), 10e18, address(tokenB), hex"00", _inputs(address(tokenA), 10e18, address(tokenB), 25e6, 0)
        );
        assertEq(out, 25e6);
        assertEq(tokenB.balanceOf(caller), 25e6);
        assertEq(tokenA.balanceOf(caller), 90e18);
        assertEq(tokenA.balanceOf(address(ur)), 10e18);
        assertEq(tokenA.balanceOf(address(adapter)), 0);
        assertEq(tokenB.balanceOf(address(adapter)), 0);
        assertEq(ur.lastDeadline(), block.timestamp);
        assertEq(ur.lastCommands(), hex"00");
    }

    function test_swap_refundsSweptInput() public {
        vm.expectEmit(address(adapter));
        emit IFundSwapAdapter.Swapped(caller, address(tokenA), 10e18, address(tokenB), 20e6, 2e18);
        vm.prank(caller);
        adapter.swap(
            address(tokenA),
            10e18,
            address(tokenB),
            hex"00",
            _inputs(address(tokenA), 8e18, address(tokenB), 20e6, 2e18)
        );
        assertEq(tokenA.balanceOf(caller), 92e18);
        assertEq(tokenB.balanceOf(caller), 20e6);
    }

    function test_swap_leavesDonatedOutputUntouched() public {
        // A token donated or stranded in the adapter before the call must not be paid to this caller:
        // the caller receives only the output this swap produced, and the donation stays resident.
        tokenB.mint(address(adapter), 1e6);
        vm.prank(caller);
        uint256 out = adapter.swap(
            address(tokenA), 1e18, address(tokenB), hex"00", _inputs(address(tokenA), 1e18, address(tokenB), 2e6, 0)
        );
        assertEq(out, 2e6);
        assertEq(tokenB.balanceOf(caller), 2e6);
        assertEq(tokenB.balanceOf(address(adapter)), 1e6);
    }

    function test_swap_leavesDonatedInputUntouched() public {
        // Same for a resident `tokenIn`: only the input swept back by this call is refunded,
        // not a balance that was already sitting in the adapter.
        tokenA.mint(address(adapter), 3e18);
        vm.prank(caller);
        adapter.swap(
            address(tokenA),
            10e18,
            address(tokenB),
            hex"00",
            _inputs(address(tokenA), 8e18, address(tokenB), 20e6, 2e18)
        );
        // Caller sold 10, got 2 back: net 8 out. The 3e18 donation stays in the adapter.
        assertEq(tokenA.balanceOf(caller), 92e18);
        assertEq(tokenA.balanceOf(address(adapter)), 3e18);
    }

    function test_swap_withoutApproval_reverts() public {
        address other = makeAddr("other");
        tokenA.mint(other, 1e18);
        vm.prank(other);
        vm.expectRevert();
        adapter.swap(
            address(tokenA), 1e18, address(tokenB), hex"00", _inputs(address(tokenA), 1e18, address(tokenB), 1, 0)
        );
    }

    function test_swap_zeroAmount_reverts() public {
        vm.prank(caller);
        vm.expectRevert(IFundSwapAdapter.ZeroAmount.selector);
        adapter.swap(address(tokenA), 0, address(tokenB), hex"00", new bytes[](0));
    }

    function test_swap_sameToken_reverts() public {
        vm.prank(caller);
        vm.expectRevert(IFundSwapAdapter.SameToken.selector);
        adapter.swap(address(tokenA), 1e18, address(tokenA), hex"00", new bytes[](0));
    }

    function test_swap_zeroToken_reverts() public {
        vm.prank(caller);
        vm.expectRevert(IFundSwapAdapter.ZeroAddress.selector);
        adapter.swap(address(0), 1e18, address(tokenB), hex"00", new bytes[](0));
        vm.prank(caller);
        vm.expectRevert(IFundSwapAdapter.ZeroAddress.selector);
        adapter.swap(address(tokenA), 1e18, address(0), hex"00", new bytes[](0));
    }

    function test_swap_routerReverts_bubbles() public {
        vm.prank(caller);
        vm.expectRevert("router underfunded");
        adapter.swap(
            address(tokenA), 1e18, address(tokenB), hex"00", _inputs(address(tokenA), 5e18, address(tokenB), 1, 0)
        );
    }

    // ── through a real fund ───────────────────────────────────

    function _fundSetUp() internal {
        _launchDefault();
        vm.prank(admin);
        factory.setRouter(address(adapter), true);
        tsla.mint(address(ur), 100e18);
    }

    function _rebalance(
        uint256 sellAmount,
        uint256 spend,
        uint256 buyAmount,
        uint256 sweep
    ) internal view returns (IFund.RebalanceParams memory) {
        return IFund.RebalanceParams({
            sellAsset: address(net),
            sellAmount: sellAmount,
            buyAsset: address(tsla),
            minBuyAmount: buyAmount,
            router: address(adapter),
            data: abi.encodeCall(
                FundSwapAdapter.swap,
                (
                    address(net),
                    sellAmount,
                    address(tsla),
                    hex"00",
                    _inputs(address(net), spend, address(tsla), buyAmount, sweep)
                )
            )
        });
    }

    function test_fundRebalance_throughAdapter() public {
        _fundSetUp();
        uint256 netBefore = net.balanceOf(address(fund));
        uint256 tslaBefore = tsla.balanceOf(address(fund));
        // Sell 10 NET ($3,000) for 7.4 TSLA ($2,960): inside the 2% bound.
        vm.prank(admin);
        fund.rebalance(_rebalance(10e9, 10e9, 7.4e18, 0));
        assertEq(net.balanceOf(address(fund)), netBefore - 10e9);
        assertEq(tsla.balanceOf(address(fund)), tslaBefore + 7.4e18);
        assertEq(net.allowance(address(fund), address(adapter)), 0);
        assertEq(net.balanceOf(address(adapter)), 0);
        assertEq(tsla.balanceOf(address(adapter)), 0);
    }

    function test_fundRebalance_partialFillRefunded() public {
        _fundSetUp();
        uint256 netBefore = net.balanceOf(address(fund));
        // Only 5 NET used, 5 swept back: the fund is charged for 5.
        vm.prank(admin);
        fund.rebalance(_rebalance(10e9, 5e9, 3.7e18, 5e9));
        assertEq(net.balanceOf(address(fund)), netBefore - 5e9);
    }

    function test_fundRebalance_badFillStillBounded() public {
        _fundSetUp();
        // 7.0 TSLA ($2,800) for $3,000 of NET is 6.7% under oracle: the fund's bound rejects it.
        vm.prank(admin);
        vm.expectRevert(IFund.RebalanceInvalid.selector);
        fund.rebalance(_rebalance(10e9, 10e9, 7.0e18, 0));
    }
}
