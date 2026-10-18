// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseGateway} from "../../src/bridge/BaseGateway.sol";
import {CcipWrappedToken} from "../../src/bridge/CcipWrappedToken.sol";
import {IBaseGateway} from "../../src/interfaces/IBaseGateway.sol";
import {CcipClient, IAny2EVMMessageReceiver} from "../../src/interfaces/external/ICcip.sol";
import {MockAcrossSpokePool} from "../helpers/MockAcrossSpokePool.sol";
import {MockBlocklistToken, MockCcipRouter} from "../helpers/MockCcipRouter.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockSwapRouter} from "../helpers/MockSwapRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Test} from "forge-std/Test.sol";

contract BaseGatewayTest is Test {
    uint64 internal constant RH = 6_180_753_054_346_818_345;
    uint256 internal constant RH_CHAIN = 4663;
    bytes32 internal constant MSG = keccak256("msg");

    BaseGateway internal gw;
    MockCcipRouter internal ccip;
    MockAcrossSpokePool internal spoke;
    MockSwapRouter internal router;
    MockERC20 internal usdc;
    MockBlocklistToken internal cbZec;
    CcipWrappedToken internal rZec;

    address internal owner = makeAddr("safe");
    address internal keeper = makeAddr("keeper");
    address internal remote = makeAddr("rhExitGateway");
    address internal rhUsdg = makeAddr("rhUsdg");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        ccip = new MockCcipRouter();
        spoke = new MockAcrossSpokePool();
        router = new MockSwapRouter();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cbZec = new MockBlocklistToken("Coinbase Wrapped ZEC", "cbZEC", 8);
        rZec = new CcipWrappedToken(IERC20(address(cbZec)), "Own Wrapped cbZEC", "rZEC", address(this));
        gw = new BaseGateway(owner, address(ccip), RH, address(usdc), address(spoke), RH_CHAIN, rhUsdg);

        vm.startPrank(owner);
        gw.setRemoteGateway(remote);
        gw.setKeeper(keeper, true);
        gw.setRouter(address(router), true);
        gw.setWrapper(address(rZec), true);
        vm.stopPrank();

        usdc.mint(address(router), 1_000_000e6);
        cbZec.mint(address(router), 1000e8);
        // CCIP pool inventory: rZEC the mock router hands to the gateway on delivery.
        cbZec.mint(address(this), 100e8);
        cbZec.approve(address(rZec), type(uint256).max);
        rZec.depositFor(address(ccip), 100e8);
    }

    // ---------------------------------------------------------------- receive

    function test_ccipReceive_fromRemote_unwrapsAndRecordsOrder() public {
        bytes32 id = _deliver(2e8, alice, 900e6);
        IBaseGateway.Order memory o = gw.getOrder(id);
        assertEq(o.receiver, alice);
        assertEq(uint8(o.status), uint8(IBaseGateway.Status.Pending));
        assertEq(o.token, address(cbZec));
        assertEq(o.amount, 2e8);
        assertEq(o.minOut, 900e6);
        assertEq(cbZec.balanceOf(address(gw)), 2e8);
        assertEq(rZec.balanceOf(address(gw)), 0);
        assertEq(id, gw.orderId(MSG, 0));
    }

    function test_ccipReceive_foreignSender_claimOnlyForSender() public {
        ccip.deliver(address(gw), address(rZec), 1e8, abi.encode(bob), abi.encode(alice, uint256(1)));
        bytes32 id = gw.orderId(MSG, 0);
        IBaseGateway.Order memory o = gw.getOrder(id);
        assertEq(o.receiver, bob);
        assertEq(o.minOut, type(uint256).max);
        IBaseGateway.Swap memory s = _sellSwap(1e8, 400e6);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.ClaimOnly.selector);
        gw.settle(id, s, 400e6, 0);
        vm.prank(bob);
        gw.claim(id, bob);
        assertEq(cbZec.balanceOf(bob), 1e8);
    }

    function test_ccipReceive_wrongSourceChain_claimOnly() public {
        ccip.deliverFrom(MSG, 1, address(gw), address(rZec), 1e8, abi.encode(remote), abi.encode(alice, uint256(1)));
        IBaseGateway.Order memory o = gw.getOrder(gw.orderId(MSG, 0));
        assertEq(o.receiver, remote);
        assertEq(o.minOut, type(uint256).max);
    }

    function test_ccipReceive_malformedData_claimOnly() public {
        ccip.deliver(address(gw), address(rZec), 1e8, abi.encode(remote), abi.encode(alice));
        assertEq(gw.getOrder(gw.orderId(MSG, 0)).minOut, type(uint256).max);
    }

    function test_ccipReceive_nonWrapperToken_heldAsDelivered() public {
        usdc.mint(address(ccip), 50e6);
        ccip.deliver(address(gw), address(usdc), 50e6, abi.encode(remote), abi.encode(alice, uint256(49e6)));
        IBaseGateway.Order memory o = gw.getOrder(gw.orderId(MSG, 0));
        assertEq(o.token, address(usdc));
        assertEq(o.amount, 50e6);
    }

    function test_ccipReceive_frozenUnderlying_keepsWrapper() public {
        cbZec.setBlocked(address(gw), true);
        bytes32 id = _deliver(1e8, alice, 1);
        IBaseGateway.Order memory o = gw.getOrder(id);
        assertEq(o.token, address(rZec));
        assertEq(rZec.balanceOf(address(gw)), 1e8);
    }

    function test_ccipReceive_notRouter_reverts() public {
        vm.expectRevert(IBaseGateway.NotRouter.selector);
        vm.prank(alice);
        CcipClient.Any2EVMMessage memory m;
        gw.ccipReceive(m);
    }

    // ---------------------------------------------------------------- settle

    function test_settle_sellsAndBridges() public {
        bytes32 id = _deliver(2e8, alice, 900e6);
        vm.warp(1000);
        vm.prank(keeper);
        gw.settle(id, _sellSwap(2e8, 1000e6), 998e6, 990);

        assertEq(uint8(gw.getOrder(id).status), uint8(IBaseGateway.Status.Settled));
        MockAcrossSpokePool.Deposit memory d = spoke.lastDeposit();
        assertEq(d.depositor, alice);
        assertEq(d.recipient, alice);
        assertEq(d.inputToken, address(usdc));
        assertEq(d.outputToken, rhUsdg);
        assertEq(d.inputAmount, 1000e6);
        assertEq(d.outputAmount, 998e6);
        assertEq(d.destinationChainId, RH_CHAIN);
        assertEq(d.exclusiveRelayer, address(0));
        assertEq(d.quoteTimestamp, 990);
        assertEq(d.fillDeadline, 1000 + 4 hours);
        assertEq(d.exclusivityDeadline, 0);
        assertEq(usdc.balanceOf(address(spoke)), 1000e6);
        assertEq(cbZec.balanceOf(address(gw)), 0);
        assertEq(usdc.allowance(address(gw), address(spoke)), 0);
    }

    function test_settle_byReceiver() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(alice);
        gw.settle(id, _sellSwap(1e8, 500e6), 499e6, 0);
        assertEq(uint8(gw.getOrder(id).status), uint8(IBaseGateway.Status.Settled));
    }

    function test_settle_usdcOrder_noSwap() public {
        usdc.mint(address(ccip), 50e6);
        ccip.deliver(address(gw), address(usdc), 50e6, abi.encode(remote), abi.encode(alice, uint256(49e6)));
        bytes32 id = gw.orderId(MSG, 0);
        vm.prank(keeper);
        gw.settle(id, IBaseGateway.Swap(address(0), ""), 49.5e6, 0);
        assertEq(usdc.balanceOf(address(spoke)), 50e6);
    }

    function test_settle_stranger_reverts() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(bob);
        vm.expectRevert(IBaseGateway.NotKeeper.selector);
        gw.settle(id, _sellSwap(1e8, 500e6), 499e6, 0);
    }

    function test_settle_belowMinimum_reverts() public {
        bytes32 id = _deliver(1e8, alice, 500e6);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.Slippage.selector);
        gw.settle(id, _sellSwap(1e8, 500e6), 499e6, 0);
    }

    function test_settle_outputAboveInput_reverts() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.OutputTooHigh.selector);
        gw.settle(id, _sellSwap(1e8, 500e6), 501e6, 0);
    }

    function test_settle_bridgeFeeAboveCap_reverts() public {
        // Cap is max(2 USDC, 0.5%): on 1000 USDC that is 5 USDC.
        bytes32 id = _deliver(2e8, alice, 1);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.BridgeFeeTooHigh.selector);
        gw.settle(id, _sellSwap(2e8, 1000e6), 994.99e6, 0);
        vm.prank(keeper);
        gw.settle(id, _sellSwap(2e8, 1000e6), 995e6, 0);
    }

    function test_settle_flatCapAppliesToSmallOrders() public {
        bytes32 id = _deliver(1e6, alice, 1); // sells for 10 USDC: 0.5% is 0.05, flat cap 2 USDC
        vm.prank(keeper);
        gw.settle(id, _sellSwap(1e6, 10e6), 8e6, 0);
    }

    function test_settle_partialFill_reverts() public {
        bytes32 id = _deliver(2e8, alice, 1);
        IBaseGateway.Swap memory s = IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(cbZec), 1e8, address(usdc), 500e6))
        );
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.PartialFill.selector);
        gw.settle(id, s, 499e6, 0);
    }

    function test_settle_routerNotAllowed_reverts() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(owner);
        gw.setRouter(address(router), false);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.RouterNotAllowed.selector);
        gw.settle(id, _sellSwap(1e8, 500e6), 499e6, 0);
    }

    function test_settle_swapFails_reverts() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.SwapFailed.selector);
        gw.settle(id, IBaseGateway.Swap(address(router), abi.encodeCall(MockSwapRouter.alwaysReverts, ())), 1, 0);
    }

    function test_settle_twice_reverts() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(keeper);
        gw.settle(id, _sellSwap(1e8, 500e6), 499e6, 0);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.NotPending.selector);
        gw.settle(id, _sellSwap(1e8, 500e6), 499e6, 0);
    }

    function test_settle_doesNotSpendOtherOrders() public {
        bytes32 a = _deliverId(keccak256("a"), 1e8, alice, 1);
        bytes32 b = _deliverId(keccak256("b"), 1e8, bob, 1);
        // A router that tries to take two orders' worth only gets the approved amount.
        IBaseGateway.Swap memory s = IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(cbZec), 2e8, address(usdc), 1000e6))
        );
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.SwapFailed.selector);
        gw.settle(a, s, 1, 0);
        vm.prank(bob);
        gw.claim(b, bob);
        assertEq(cbZec.balanceOf(bob), 1e8);
    }

    // ---------------------------------------------------------------- claim / minOut

    function test_claim_paysAssetOnBase() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(alice);
        gw.claim(id, bob);
        assertEq(cbZec.balanceOf(bob), 1e8);
        assertEq(uint8(gw.getOrder(id).status), uint8(IBaseGateway.Status.Claimed));
        vm.prank(alice);
        vm.expectRevert(IBaseGateway.NotPending.selector);
        gw.claim(id, bob);
    }

    function test_claim_notReceiver_reverts() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.NotReceiver.selector);
        gw.claim(id, keeper);
    }

    function test_claim_zeroTo_reverts() public {
        bytes32 id = _deliver(1e8, alice, 1);
        vm.prank(alice);
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        gw.claim(id, address(0));
    }

    function test_updateMinOut_lowersMinimum() public {
        bytes32 id = _deliver(1e8, alice, 600e6);
        vm.prank(alice);
        gw.updateMinOut(id, 400e6);
        assertEq(gw.getOrder(id).minOut, 400e6);
        vm.prank(keeper);
        gw.settle(id, _sellSwap(1e8, 500e6), 499e6, 0);
    }

    function test_updateMinOut_guards() public {
        bytes32 id = _deliver(1e8, alice, 600e6);
        vm.prank(bob);
        vm.expectRevert(IBaseGateway.NotReceiver.selector);
        gw.updateMinOut(id, 1);
        vm.prank(alice);
        vm.expectRevert(IBaseGateway.ClaimOnly.selector);
        gw.updateMinOut(id, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(IBaseGateway.NotPending.selector);
        gw.updateMinOut(keccak256("none"), 1);
    }

    // ---------------------------------------------------------------- manual options

    function test_buyAndWrap() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(gw), 1000e6);
        IBaseGateway.Swap memory s = IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(usdc), 900e6, address(cbZec), 2e8))
        );
        uint256 out = gw.buyAndWrap(address(rZec), 1000e6, s, 2e8, bob);
        vm.stopPrank();
        assertEq(out, 2e8);
        assertEq(rZec.balanceOf(bob), 2e8);
        assertEq(usdc.balanceOf(alice), 100e6, "unspent USDC refunded");
        assertEq(usdc.balanceOf(address(gw)), 0);
    }

    function test_buyAndWrap_leavesOrdersAlone() public {
        bytes32 id = _deliver(1e8, alice, 1);
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(gw), 500e6);
        gw.buyAndWrap(
            address(rZec),
            500e6,
            IBaseGateway.Swap(
                address(router), abi.encodeCall(MockSwapRouter.swap, (address(usdc), 500e6, address(cbZec), 1e8))
            ),
            1e8,
            bob
        );
        vm.stopPrank();
        assertEq(rZec.balanceOf(bob), 1e8);
        assertEq(cbZec.balanceOf(address(gw)), 1e8, "the order's cbZEC stays");
        vm.prank(alice);
        gw.claim(id, alice);
    }

    function test_buyAndWrap_guards() public {
        IBaseGateway.Swap memory s = IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(usdc), 100e6, address(cbZec), 1e7))
        );
        vm.expectRevert(IBaseGateway.WrapperNotAllowed.selector);
        gw.buyAndWrap(address(cbZec), 100e6, s, 1, bob);
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        gw.buyAndWrap(address(rZec), 100e6, s, 1, address(0));
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(gw), 100e6);
        vm.expectRevert(IBaseGateway.Slippage.selector);
        gw.buyAndWrap(address(rZec), 100e6, s, 1e7 + 1, bob);
        vm.stopPrank();
    }

    function test_unwrapAndSell() public {
        cbZec.mint(alice, 1e8);
        vm.startPrank(alice);
        cbZec.approve(address(rZec), 1e8);
        rZec.depositFor(alice, 1e8);
        rZec.approve(address(gw), 1e8);
        IBaseGateway.Swap memory s = IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(cbZec), 0.8e8, address(usdc), 400e6))
        );
        uint256 out = gw.unwrapAndSell(address(rZec), 1e8, s, 400e6, bob);
        vm.stopPrank();
        assertEq(out, 400e6);
        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(cbZec.balanceOf(bob), 0.2e8, "unsold underlying to the receiver");
        assertEq(cbZec.balanceOf(address(gw)), 0);
    }

    function test_unwrapAndSell_guards() public {
        IBaseGateway.Swap memory s = IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(cbZec), 1e8, address(usdc), 400e6))
        );
        vm.expectRevert(IBaseGateway.WrapperNotAllowed.selector);
        gw.unwrapAndSell(address(cbZec), 1e8, s, 1, bob);
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        gw.unwrapAndSell(address(rZec), 0, s, 1, bob);
        cbZec.mint(alice, 1e8);
        vm.startPrank(alice);
        cbZec.approve(address(rZec), 1e8);
        rZec.depositFor(alice, 1e8);
        rZec.approve(address(gw), 1e8);
        vm.expectRevert(IBaseGateway.Slippage.selector);
        gw.unwrapAndSell(address(rZec), 1e8, s, 400e6 + 1, bob);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- admin

    function test_admin_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        gw.setRemoteGateway(alice);
        vm.expectRevert(err);
        gw.setKeeper(alice, true);
        vm.expectRevert(err);
        gw.setRouter(alice, true);
        vm.expectRevert(err);
        gw.setWrapper(alice, true);
        vm.expectRevert(err);
        gw.setBridgeFeeCap(1, 1);
        vm.expectRevert(err);
        gw.setFillWindow(1 hours);
        vm.stopPrank();
    }

    function test_admin_setters() public {
        vm.startPrank(owner);
        gw.setBridgeFeeCap(100, 5e6);
        assertEq(gw.maxFeeBps(), 100);
        assertEq(gw.maxFeeFlat(), 5e6);
        gw.setFillWindow(1 hours);
        assertEq(gw.fillWindow(), 1 hours);
        gw.setKeeper(keeper, false);
        assertFalse(gw.isKeeper(keeper));
        assertTrue(gw.isRouter(address(router)));
        assertTrue(gw.isWrapper(address(rZec)));
        assertEq(gw.remoteGateway(), remote);
        vm.stopPrank();
    }

    function test_admin_invalidParams_revert() public {
        vm.startPrank(owner);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setBridgeFeeCap(1001, 0);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setFillWindow(9 minutes);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setFillWindow(6 hours + 1);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setRouter(address(usdc), true);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setRouter(address(spoke), true);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setRouter(address(ccip), true);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setRouter(address(rZec), true);
        vm.expectRevert(IBaseGateway.InvalidParam.selector);
        gw.setWrapper(address(router), true);
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        gw.setRemoteGateway(address(0));
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        gw.setKeeper(address(0), true);
        vm.stopPrank();
    }

    function test_constructor_zero_reverts() public {
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        new BaseGateway(owner, address(0), RH, address(usdc), address(spoke), RH_CHAIN, rhUsdg);
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        new BaseGateway(owner, address(ccip), RH, address(usdc), address(spoke), RH_CHAIN, address(0));
    }

    // ---------------------------------------------------------------- restock

    function test_restock_buysWrapsAndSendsToMintGateway() public {
        address mintGw = makeAddr("rhMintGateway");
        vm.prank(owner);
        gw.setRemoteMintGateway(mintGw);
        usdc.mint(address(gw), 1000e6);
        ccip.setFee(0.01 ether);
        vm.deal(keeper, 1 ether);
        IBaseGateway.Swap memory s = _buySwap(900e6, 2e8);

        vm.prank(keeper);
        gw.restock{value: 0.05 ether}(address(rZec), 1000e6, s, 2e8);

        assertEq(ccip.lastDestChainSelector(), RH);
        assertEq(ccip.lastToken(), address(rZec));
        assertEq(ccip.lastAmount(), 2e8);
        assertEq(abi.decode(ccip.lastReceiver(), (address)), mintGw);
        assertEq(rZec.balanceOf(address(ccip)), 100e8 + 2e8);
        assertEq(usdc.balanceOf(address(gw)), 100e6, "unspent USDC stays free");
        assertEq(keeper.balance, 1 ether - 0.01 ether, "excess fee refunded");
        assertEq(cbZec.balanceOf(address(gw)), 0);
    }

    function test_restock_neverSpendsOrderUsdc() public {
        vm.prank(owner);
        gw.setRemoteMintGateway(makeAddr("rhMintGateway"));
        usdc.mint(address(ccip), 500e6);
        ccip.deliverFrom(MSG, RH, address(gw), address(usdc), 500e6, abi.encode(remote), abi.encode(alice, 1));
        assertEq(gw.freeUsdc(), 0);
        usdc.mint(address(gw), 300e6);
        assertEq(gw.freeUsdc(), 300e6);
        ccip.setFee(0);

        IBaseGateway.Swap memory s = _buySwap(300e6, 1e8);
        vm.prank(keeper);
        vm.expectRevert(IBaseGateway.InsufficientUsdc.selector);
        gw.restock(address(rZec), 301e6, s, 1e8);
        vm.prank(keeper);
        gw.restock(address(rZec), 300e6, s, 1e8);
        assertEq(usdc.balanceOf(address(gw)), 500e6);

        bytes32 id = gw.orderId(MSG, 0);
        vm.prank(alice);
        gw.claim(id, alice);
        assertEq(usdc.balanceOf(alice), 500e6);
    }

    function test_restock_guards() public {
        IBaseGateway.Swap memory s = _buySwap(100e6, 1e7);
        usdc.mint(address(gw), 100e6);
        vm.expectRevert(IBaseGateway.NotKeeper.selector);
        gw.restock(address(rZec), 100e6, s, 1);
        vm.startPrank(keeper);
        vm.expectRevert(IBaseGateway.WrapperNotAllowed.selector);
        gw.restock(address(cbZec), 100e6, s, 1);
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        gw.restock(address(rZec), 100e6, s, 1);
        vm.stopPrank();

        vm.prank(owner);
        gw.setRemoteMintGateway(makeAddr("rhMintGateway"));
        ccip.setFee(0.01 ether);
        vm.startPrank(keeper);
        vm.expectRevert(IBaseGateway.Slippage.selector);
        gw.restock(address(rZec), 100e6, s, 1e7 + 1);
        vm.expectRevert(abi.encodeWithSelector(IBaseGateway.InsufficientFee.selector, 0.01 ether, 0));
        gw.restock(address(rZec), 100e6, s, 1e7);
        vm.stopPrank();
    }

    function test_setRemoteMintGateway_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gw.setRemoteMintGateway(alice);
        vm.prank(owner);
        vm.expectRevert(IBaseGateway.ZeroAddress.selector);
        gw.setRemoteMintGateway(address(0));
    }

    function test_supportsInterface() public view {
        assertTrue(gw.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(gw.supportsInterface(type(IERC165).interfaceId));
        assertFalse(gw.supportsInterface(0xdeadbeef));
    }

    // ---------------------------------------------------------------- helpers

    function _deliver(uint256 amount, address receiver, uint256 minOut) internal returns (bytes32) {
        return _deliverId(MSG, amount, receiver, minOut);
    }

    function _deliverId(bytes32 msgId, uint256 amount, address receiver, uint256 minOut) internal returns (bytes32) {
        ccip.deliverFrom(
            msgId, RH, address(gw), address(rZec), amount, abi.encode(remote), abi.encode(receiver, minOut)
        );
        return gw.orderId(msgId, 0);
    }

    function _sellSwap(uint256 amount, uint256 usdcOut) internal view returns (IBaseGateway.Swap memory) {
        return IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(cbZec), amount, address(usdc), usdcOut))
        );
    }

    function _buySwap(uint256 usdcIn, uint256 out) internal view returns (IBaseGateway.Swap memory) {
        return IBaseGateway.Swap(
            address(router), abi.encodeCall(MockSwapRouter.swap, (address(usdc), usdcIn, address(cbZec), out))
        );
    }
}
