// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnVault} from "../../src/core/OwnVault.sol";
import {IWETHRouter} from "../../src/interfaces/IWETHRouter.sol";
import {WETHRouter} from "../../src/periphery/WETHRouter.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockWETH} from "../helpers/MockWETH.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @title WETHRouter Unit Tests
/// @notice Tests native ETH deposit/redeem flows through the WETH router.
contract WETHRouterTest is BaseTest {
    WETHRouter public router;
    MockWETH public mockWeth;
    OwnVault public vault;

    address public mockMarket = makeAddr("market");

    function setUp() public override {
        super.setUp();

        // Deploy MockWETH (with deposit/withdraw support)
        mockWeth = new MockWETH();
        vm.label(address(mockWeth), "MockWETH");

        // Deploy the router first so we can use its address as the bound VM
        router = new WETHRouter(address(mockWeth));
        vm.label(address(router), "WETHRouter");

        // Deploy a WETH vault with router as the bound VM (router calls deposit directly)
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);
        vault = new OwnVault(
            address(mockWeth),
            "Own WETH Vault",
            "oWETH",
            address(protocolRegistry),
            address(router), // bound VM is the router (it calls deposit directly)
            8000, // 80% max util
            2000,
            900
        );
        vm.stopPrank();
        vm.label(address(vault), "OwnVault-WETH");
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsWeth() public view {
        assertEq(address(router.weth()), address(mockWeth));
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IWETHRouter.ZeroAddress.selector);
        new WETHRouter(address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  depositETH
    // ──────────────────────────────────────────────────────────

    function test_depositETH_succeeds() public {
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP1, 0);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(Actors.LP1), shares);
        assertEq(mockWeth.balanceOf(address(vault)), amount);
        assertEq(address(router).balance, 0, "Router should hold no ETH");
        assertEq(mockWeth.balanceOf(address(router)), 0, "Router should hold no WETH");
    }

    function test_depositETH_differentReceiver() public {
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP2, 0);

        assertEq(vault.balanceOf(Actors.LP2), shares);
        assertEq(vault.balanceOf(Actors.LP1), 0);
    }

    function test_depositETH_emitsEvent() public {
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        vm.expectEmit(true, true, true, false);
        emit IWETHRouter.DepositETH(address(vault), Actors.LP1, Actors.LP1, amount, 0);
        router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP1, 0);
    }

    function test_depositETH_zeroAmount_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IWETHRouter.ZeroAmount.selector);
        router.depositETH{value: 0}(IERC4626(address(vault)), Actors.LP1, 0);
    }

    function test_depositETH_zeroReceiver_reverts() public {
        _fundETH(Actors.LP1, 1 ether);

        vm.prank(Actors.LP1);
        vm.expectRevert(IWETHRouter.ZeroAddress.selector);
        router.depositETH{value: 1 ether}(IERC4626(address(vault)), address(0), 0);
    }

    function test_depositETH_slippageProtection_reverts() public {
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        vm.expectRevert(
            abi.encodeWithSelector(IWETHRouter.MinSharesError.selector, vault.previewDeposit(amount), type(uint256).max)
        );
        router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP1, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  redeemETH
    // ──────────────────────────────────────────────────────────

    function test_redeemETH_succeeds() public {
        // First deposit
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);
        vm.prank(Actors.LP1);
        uint256 shares = router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP1, 0);

        // Redeem
        uint256 balanceBefore = Actors.LP1.balance;
        vm.startPrank(Actors.LP1);
        vault.approve(address(router), shares);
        uint256 assets = router.redeemETH(IERC4626(address(vault)), shares, Actors.LP1, 0);
        vm.stopPrank();

        assertGt(assets, 0);
        assertEq(Actors.LP1.balance, balanceBefore + assets);
        assertEq(vault.balanceOf(Actors.LP1), 0);
        assertEq(address(router).balance, 0, "Router should hold no ETH");
        assertEq(mockWeth.balanceOf(address(router)), 0, "Router should hold no WETH");
    }

    function test_redeemETH_differentReceiver() public {
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);
        vm.prank(Actors.LP1);
        uint256 shares = router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP1, 0);

        uint256 lp2BalanceBefore = Actors.LP2.balance;
        vm.startPrank(Actors.LP1);
        vault.approve(address(router), shares);
        uint256 assets = router.redeemETH(IERC4626(address(vault)), shares, Actors.LP2, 0);
        vm.stopPrank();

        assertEq(Actors.LP2.balance, lp2BalanceBefore + assets);
    }

    function test_redeemETH_emitsEvent() public {
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);
        vm.prank(Actors.LP1);
        uint256 shares = router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP1, 0);

        vm.startPrank(Actors.LP1);
        vault.approve(address(router), shares);
        vm.expectEmit(true, true, true, false);
        emit IWETHRouter.RedeemETH(address(vault), Actors.LP1, Actors.LP1, 0, shares);
        router.redeemETH(IERC4626(address(vault)), shares, Actors.LP1, 0);
        vm.stopPrank();
    }

    function test_redeemETH_zeroShares_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IWETHRouter.ZeroAmount.selector);
        router.redeemETH(IERC4626(address(vault)), 0, Actors.LP1, 0);
    }

    function test_redeemETH_zeroReceiver_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IWETHRouter.ZeroAddress.selector);
        router.redeemETH(IERC4626(address(vault)), 1, address(0), 0);
    }

    function test_redeemETH_slippageProtection_reverts() public {
        uint256 amount = 1 ether;
        _fundETH(Actors.LP1, amount);
        vm.prank(Actors.LP1);
        uint256 shares = router.depositETH{value: amount}(IERC4626(address(vault)), Actors.LP1, 0);

        vm.startPrank(Actors.LP1);
        vault.approve(address(router), shares);
        vm.expectRevert(
            abi.encodeWithSelector(IWETHRouter.MinAmountError.selector, vault.previewRedeem(shares), type(uint256).max)
        );
        router.redeemETH(IERC4626(address(vault)), shares, Actors.LP1, type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  receive() guard
    // ──────────────────────────────────────────────────────────

    function test_receive_fromNonWETH_reverts() public {
        _fundETH(Actors.ATTACKER, 1 ether);
        vm.prank(Actors.ATTACKER);
        (bool success,) = address(router).call{value: 1 ether}("");
        assertFalse(success);
    }

    function test_receive_fromWETH_succeeds() public {
        // Fund MockWETH with ETH so it can send
        vm.deal(address(mockWeth), 1 ether);
        vm.prank(address(mockWeth));
        (bool success,) = address(router).call{value: 1 ether}("");
        assertTrue(success);
    }
}
