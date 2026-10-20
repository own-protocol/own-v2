// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CcipWrappedToken} from "../../src/bridge/CcipWrappedToken.sol";
import {ICcipWrappedToken} from "../../src/interfaces/ICcipWrappedToken.sol";
import {MockBlocklistToken, MockFeeToken} from "../helpers/MockCcipRouter.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract CcipWrappedTokenTest is Test {
    MockBlocklistToken internal cbZec;
    CcipWrappedToken internal rZec;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        cbZec = new MockBlocklistToken("Coinbase Wrapped ZEC", "cbZEC", 8);
        rZec = new CcipWrappedToken(IERC20(address(cbZec)), "Own Wrapped cbZEC", "rZEC", admin);
        cbZec.mint(alice, 100e8);
        vm.prank(alice);
        cbZec.approve(address(rZec), type(uint256).max);
    }

    function test_constructor_setsMetadata() public view {
        assertEq(rZec.name(), "Own Wrapped cbZEC");
        assertEq(rZec.symbol(), "rZEC");
        assertEq(rZec.decimals(), 8);
        assertEq(address(rZec.underlying()), address(cbZec));
        assertEq(rZec.getCCIPAdmin(), admin);
    }

    function test_constructor_decimalsFollowUnderlying() public {
        MockBlocklistToken hype = new MockBlocklistToken("Coinbase Wrapped HYPE", "cbHYPE", 18);
        CcipWrappedToken rHype = new CcipWrappedToken(IERC20(address(hype)), "Own Wrapped cbHYPE", "rHYPE", admin);
        assertEq(rHype.decimals(), 18);
    }

    function test_constructor_zeroUnderlying_reverts() public {
        vm.expectRevert();
        new CcipWrappedToken(IERC20(address(0)), "x", "x", admin);
    }

    function test_constructor_zeroAdmin_reverts() public {
        vm.expectRevert(ICcipWrappedToken.ZeroAddress.selector);
        new CcipWrappedToken(IERC20(address(cbZec)), "x", "x", address(0));
    }

    function test_depositFor_mintsOneToOne() public {
        vm.prank(alice);
        rZec.depositFor(bob, 3e8);
        assertEq(rZec.balanceOf(bob), 3e8);
        assertEq(rZec.totalSupply(), 3e8);
        assertEq(cbZec.balanceOf(address(rZec)), 3e8);
        assertEq(cbZec.balanceOf(alice), 97e8);
    }

    function test_depositFor_zero_noop() public {
        vm.prank(alice);
        rZec.depositFor(alice, 0);
        assertEq(rZec.totalSupply(), 0);
    }

    function test_depositFor_feeOnTransfer_reverts() public {
        MockFeeToken fee = new MockFeeToken();
        CcipWrappedToken w = new CcipWrappedToken(IERC20(address(fee)), "w", "w", admin);
        fee.mint(alice, 100e18);
        vm.startPrank(alice);
        fee.approve(address(w), type(uint256).max);
        vm.expectRevert(ICcipWrappedToken.UnexpectedBalanceChange.selector);
        w.depositFor(alice, 10e18);
        vm.stopPrank();
    }

    function test_depositFor_toSelf_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(rZec)));
        rZec.depositFor(address(rZec), 1e8);
    }

    function test_depositFor_withoutAllowance_reverts() public {
        cbZec.mint(bob, 1e8);
        vm.prank(bob);
        vm.expectRevert();
        rZec.depositFor(bob, 1e8);
    }

    function test_withdrawTo_returnsUnderlying() public {
        vm.startPrank(alice);
        rZec.depositFor(alice, 5e8);
        rZec.withdrawTo(bob, 2e8);
        vm.stopPrank();
        assertEq(rZec.balanceOf(alice), 3e8);
        assertEq(cbZec.balanceOf(bob), 2e8);
        assertEq(cbZec.balanceOf(address(rZec)), 3e8);
        assertEq(rZec.totalSupply(), 3e8);
    }

    function test_withdrawTo_moreThanBalance_reverts() public {
        vm.prank(alice);
        rZec.depositFor(alice, 1e8);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1e8));
        rZec.withdrawTo(bob, 1e8);
    }

    function test_withdrawTo_toSelf_reverts() public {
        vm.startPrank(alice);
        rZec.depositFor(alice, 1e8);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(rZec)));
        rZec.withdrawTo(address(rZec), 1e8);
        vm.stopPrank();
    }

    function test_withdrawTo_issuerBlocksWrapper_reverts() public {
        vm.prank(alice);
        rZec.depositFor(alice, 1e8);
        cbZec.setBlocked(address(rZec), true);
        vm.prank(alice);
        vm.expectRevert("PolicyForbids");
        rZec.withdrawTo(alice, 1e8);
    }

    function test_directTransfer_staysAsExcessBacking() public {
        vm.startPrank(alice);
        rZec.depositFor(alice, 1e8);
        cbZec.transfer(address(rZec), 1e8);
        vm.stopPrank();
        assertEq(rZec.totalSupply(), 1e8);
        assertEq(cbZec.balanceOf(address(rZec)), 2e8);
    }

    function testFuzz_backingNeverBelowSupply(uint96 inAmt, uint96 outAmt) public {
        uint256 a = bound(inAmt, 0, 100e8);
        uint256 b = bound(outAmt, 0, a);
        vm.startPrank(alice);
        rZec.depositFor(alice, a);
        rZec.withdrawTo(alice, b);
        vm.stopPrank();
        assertEq(rZec.totalSupply(), a - b);
        assertGe(cbZec.balanceOf(address(rZec)), rZec.totalSupply());
    }
}
