// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CcipWrapRouter} from "../../src/bridge/CcipWrapRouter.sol";
import {CcipWrappedToken} from "../../src/bridge/CcipWrappedToken.sol";
import {ICcipWrapRouter} from "../../src/interfaces/ICcipWrapRouter.sol";
import {CcipClient, IAny2EVMMessageReceiver} from "../../src/interfaces/external/ICcip.sol";
import {MockBlocklistToken, MockCcipRouter} from "../helpers/MockCcipRouter.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Test} from "forge-std/Test.sol";

contract RefundRejecter {
    function send(CcipWrapRouter r, address w, uint256 amt) external payable {
        r.wrapAndSend{value: msg.value}(w, amt, address(this));
    }
}

contract CcipWrapRouterTest is Test {
    uint64 internal constant RH = 6_180_753_054_346_818_345;

    MockCcipRouter internal ccip;
    MockBlocklistToken internal cbZec;
    CcipWrappedToken internal rZec;
    CcipWrapRouter internal router;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        ccip = new MockCcipRouter();
        cbZec = new MockBlocklistToken("Coinbase Wrapped ZEC", "cbZEC", 8);
        rZec = new CcipWrappedToken(IERC20(address(cbZec)), "Own Wrapped cbZEC", "rZEC", address(this));
        router = new CcipWrapRouter(address(ccip), RH);
        cbZec.mint(alice, 100e8);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        cbZec.approve(address(router), type(uint256).max);
    }

    function test_constructor_zeroRouter_reverts() public {
        vm.expectRevert(ICcipWrapRouter.ZeroAddress.selector);
        new CcipWrapRouter(address(0), RH);
    }

    function test_supportsInterface() public view {
        assertTrue(router.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(router.supportsInterface(type(IERC165).interfaceId));
        assertFalse(router.supportsInterface(0xdeadbeef));
    }

    function test_quote_returnsRouterFee() public view {
        assertEq(router.quote(address(rZec), 1e8, bob), 0.001 ether);
    }

    function test_wrapAndSend_wrapsAndSends() public {
        vm.prank(alice);
        bytes32 id = router.wrapAndSend{value: 0.001 ether}(address(rZec), 4e8, bob);
        assertEq(id, keccak256(abi.encode(uint256(1))));
        assertEq(cbZec.balanceOf(address(rZec)), 4e8);
        assertEq(rZec.balanceOf(address(ccip)), 4e8);
        assertEq(cbZec.balanceOf(alice), 96e8);
        assertEq(ccip.lastDestChainSelector(), RH);
        assertEq(ccip.lastReceiver(), abi.encode(bob));
        assertEq(ccip.lastToken(), address(rZec));
        assertEq(ccip.lastAmount(), 4e8);
        assertEq(ccip.lastFeeToken(), address(0));
        assertEq(ccip.lastData().length, 0);
        assertEq(
            ccip.lastExtraArgs(),
            abi.encodeWithSelector(
                CcipClient.GENERIC_EXTRA_ARGS_V2_TAG,
                CcipClient.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true})
            )
        );
        assertEq(address(router).balance, 0);
        assertEq(rZec.allowance(address(router), address(ccip)), 0);
        assertEq(cbZec.allowance(address(router), address(rZec)), 0);
    }

    function test_wrapAndSend_refundsExcessFee() public {
        vm.prank(alice);
        router.wrapAndSend{value: 0.01 ether}(address(rZec), 1e8, bob);
        assertEq(alice.balance, 1 ether - 0.001 ether);
        assertEq(address(router).balance, 0);
    }

    function test_wrapAndSend_emits() public {
        vm.expectEmit(address(router));
        emit ICcipWrapRouter.WrappedAndSent(
            keccak256(abi.encode(uint256(1))), address(rZec), alice, bob, 1e8, 0.001 ether
        );
        vm.prank(alice);
        router.wrapAndSend{value: 0.001 ether}(address(rZec), 1e8, bob);
    }

    function test_wrapAndSend_lowFee_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICcipWrapRouter.InsufficientFee.selector, 0.001 ether, 0.0009 ether));
        router.wrapAndSend{value: 0.0009 ether}(address(rZec), 1e8, bob);
    }

    function test_wrapAndSend_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ICcipWrapRouter.ZeroAmount.selector);
        router.wrapAndSend{value: 0.001 ether}(address(rZec), 0, bob);
    }

    function test_wrapAndSend_zeroReceiver_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ICcipWrapRouter.ZeroAddress.selector);
        router.wrapAndSend{value: 0.001 ether}(address(rZec), 1e8, address(0));
    }

    function test_wrapAndSend_zeroWrapper_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ICcipWrapRouter.ZeroAddress.selector);
        router.wrapAndSend{value: 0.001 ether}(address(0), 1e8, bob);
    }

    function test_wrapAndSend_refundRejected_reverts() public {
        RefundRejecter r = new RefundRejecter();
        cbZec.mint(address(r), 1e8);
        vm.prank(address(r));
        cbZec.approve(address(router), 1e8);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ICcipWrapRouter.RefundFailed.selector);
        r.send{value: 0.002 ether}(router, address(rZec), 1e8);
    }

    function test_ccipReceive_notRouter_reverts() public {
        CcipClient.Any2EVMMessage memory m;
        vm.expectRevert(ICcipWrapRouter.NotRouter.selector);
        router.ccipReceive(m);
    }

    function _fundCcip(
        uint256 amount
    ) internal {
        vm.startPrank(alice);
        cbZec.transfer(address(this), amount);
        vm.stopPrank();
        cbZec.approve(address(rZec), amount);
        rZec.depositFor(address(ccip), amount);
    }

    function test_ccipReceive_unwrapsToRecipient() public {
        _fundCcip(2e8);
        vm.expectEmit(address(router));
        emit ICcipWrapRouter.Unwrapped(keccak256("msg"), address(rZec), bob, 2e8);
        ccip.deliver(address(router), address(rZec), 2e8, abi.encode(alice), abi.encode(bob));
        assertEq(cbZec.balanceOf(bob), 2e8);
        assertEq(rZec.totalSupply(), 0);
        assertEq(rZec.balanceOf(address(router)), 0);
    }

    function test_ccipReceive_noData_unwrapsToSender() public {
        _fundCcip(1e8);
        ccip.deliver(address(router), address(rZec), 1e8, abi.encode(bob), "");
        assertEq(cbZec.balanceOf(bob), 1e8);
    }

    function test_ccipReceive_dirtyData_fallsBackToSender() public {
        _fundCcip(1e8);
        ccip.deliver(address(router), address(rZec), 1e8, abi.encode(bob), abi.encode(type(uint256).max));
        assertEq(cbZec.balanceOf(bob), 1e8);
    }

    function test_ccipReceive_recipientBlocked_forwardsWrapper() public {
        _fundCcip(1e8);
        cbZec.setBlocked(bob, true);
        vm.expectEmit(address(router));
        emit ICcipWrapRouter.Forwarded(keccak256("msg"), address(rZec), bob, 1e8);
        ccip.deliver(address(router), address(rZec), 1e8, abi.encode(alice), abi.encode(bob));
        assertEq(rZec.balanceOf(bob), 1e8);
        assertEq(cbZec.balanceOf(bob), 0);
    }

    function test_ccipReceive_plainToken_forwarded() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        usdc.mint(address(ccip), 5e6);
        ccip.deliver(address(router), address(usdc), 5e6, abi.encode(alice), abi.encode(bob));
        assertEq(usdc.balanceOf(bob), 5e6);
    }

    function test_ccipReceive_nonEvmSender_keepsTokens() public {
        _fundCcip(1e8);
        ccip.deliver(address(router), address(rZec), 1e8, hex"01", "");
        assertEq(rZec.balanceOf(address(router)), 1e8);
    }
}
