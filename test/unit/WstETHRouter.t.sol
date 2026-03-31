// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnVault} from "../../src/core/OwnVault.sol";
import {IWstETHRouter} from "../../src/interfaces/IWstETHRouter.sol";
import {WstETHRouter} from "../../src/periphery/WstETHRouter.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockWstETH} from "../helpers/MockWstETH.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @title WstETHRouter Unit Tests
/// @notice Tests stETH deposit/redeem flows through the wstETH router.
contract WstETHRouterTest is BaseTest {
    WstETHRouter public router;
    OwnVault public vault;

    address public mockMarket = makeAddr("market");

    function setUp() public override {
        super.setUp();

        // Deploy a wstETH vault (wstETH from BaseTest)
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        // Deploy the router first so we can set it as the vault's VM
        router = new WstETHRouter(address(wstETH), address(stETH));

        // Deploy a wstETH vault with router as the bound VM (router calls deposit directly)
        protocolRegistry.setProtocolShareBps(2000);
        vault = new OwnVault(
            address(wstETH),
            "Own wstETH Vault",
            "owstETH",
            address(protocolRegistry),
            address(router), // bound VM is the router (it calls deposit directly)
            8000, // 80% max util
            2000
        );
        vm.stopPrank();
        vm.label(address(router), "WstETHRouter");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Fund LP with stETH and approve the router.
    function _fundAndApproveStETH(address lp, uint256 amount) internal {
        _fundStETH(lp, amount);
        vm.prank(lp);
        stETH.approve(address(router), amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(router.wstETH()), address(wstETH));
        assertEq(address(router.stETH()), address(stETH));
    }

    function test_constructor_zeroWstETH_reverts() public {
        vm.expectRevert(IWstETHRouter.ZeroAddress.selector);
        new WstETHRouter(address(0), address(stETH));
    }

    function test_constructor_zeroStETH_reverts() public {
        vm.expectRevert(IWstETHRouter.ZeroAddress.selector);
        new WstETHRouter(address(wstETH), address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  depositStETH
    // ──────────────────────────────────────────────────────────

    function test_depositStETH_succeeds() public {
        uint256 amount = 10 ether;
        _fundAndApproveStETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.depositStETH(IERC4626(address(vault)), amount, Actors.LP1, 0);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(Actors.LP1), shares);
        // Router should hold no tokens
        assertEq(stETH.balanceOf(address(router)), 0, "Router should hold no stETH");
        assertEq(wstETH.balanceOf(address(router)), 0, "Router should hold no wstETH");
    }

    function test_depositStETH_differentReceiver() public {
        uint256 amount = 10 ether;
        _fundAndApproveStETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.depositStETH(IERC4626(address(vault)), amount, Actors.LP2, 0);

        assertEq(vault.balanceOf(Actors.LP2), shares);
        assertEq(vault.balanceOf(Actors.LP1), 0);
    }

    function test_depositStETH_emitsEvent() public {
        uint256 amount = 10 ether;
        _fundAndApproveStETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        vm.expectEmit(true, true, true, false);
        emit IWstETHRouter.DepositStETH(address(vault), Actors.LP1, Actors.LP1, amount, 0);
        router.depositStETH(IERC4626(address(vault)), amount, Actors.LP1, 0);
    }

    function test_depositStETH_zeroAmount_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IWstETHRouter.ZeroAmount.selector);
        router.depositStETH(IERC4626(address(vault)), 0, Actors.LP1, 0);
    }

    function test_depositStETH_zeroReceiver_reverts() public {
        uint256 amount = 10 ether;
        _fundAndApproveStETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        vm.expectRevert(IWstETHRouter.ZeroAddress.selector);
        router.depositStETH(IERC4626(address(vault)), amount, address(0), 0);
    }

    function test_depositStETH_slippageProtection_reverts() public {
        uint256 amount = 10 ether;
        _fundAndApproveStETH(Actors.LP1, amount);

        uint256 expectedShares = vault.previewDeposit(wstETH.getWstETHByStETH(amount));
        vm.startPrank(Actors.LP1);
        vm.expectRevert(
            abi.encodeWithSelector(IWstETHRouter.MinSharesError.selector, expectedShares, type(uint256).max)
        );
        router.depositStETH(IERC4626(address(vault)), amount, Actors.LP1, type(uint256).max);
        vm.stopPrank();
    }

    function test_depositStETH_withExchangeRate() public {
        // Set wstETH exchange rate: 1 stETH = 0.9 wstETH (stETH appreciated)
        wstETH.setTokensPerStEth(0.9e18);

        uint256 amount = 10 ether;
        _fundAndApproveStETH(Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.depositStETH(IERC4626(address(vault)), amount, Actors.LP1, 0);

        assertGt(shares, 0);
        // Vault should hold wstETH, not stETH
        assertGt(wstETH.balanceOf(address(vault)), 0);
        assertEq(stETH.balanceOf(address(vault)), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  unwrapWstETH
    // ──────────────────────────────────────────────────────────

    function test_unwrapWstETH_succeeds() public {
        // Give LP some wstETH directly
        uint256 amount = 10 ether;
        _fundStETH(Actors.LP1, amount);
        vm.startPrank(Actors.LP1);
        stETH.approve(address(wstETH), amount);
        uint256 wstETHAmount = wstETH.wrap(amount);

        // Approve router to pull wstETH
        IERC20(address(wstETH)).approve(address(router), wstETHAmount);

        uint256 balanceBefore = stETH.balanceOf(Actors.LP1);
        uint256 stETHOut = router.unwrapWstETH(wstETHAmount, Actors.LP1);
        vm.stopPrank();

        assertGt(stETHOut, 0);
        assertEq(stETH.balanceOf(Actors.LP1), balanceBefore + stETHOut);
        assertEq(IERC20(address(wstETH)).balanceOf(Actors.LP1), 0);
        assertEq(stETH.balanceOf(address(router)), 0, "Router should hold no stETH");
        assertEq(wstETH.balanceOf(address(router)), 0, "Router should hold no wstETH");
    }

    function test_unwrapWstETH_differentReceiver() public {
        uint256 amount = 10 ether;
        _fundStETH(Actors.LP1, amount);
        vm.startPrank(Actors.LP1);
        stETH.approve(address(wstETH), amount);
        uint256 wstETHAmount = wstETH.wrap(amount);
        IERC20(address(wstETH)).approve(address(router), wstETHAmount);

        uint256 lp2BalanceBefore = stETH.balanceOf(Actors.LP2);
        uint256 stETHOut = router.unwrapWstETH(wstETHAmount, Actors.LP2);
        vm.stopPrank();

        assertEq(stETH.balanceOf(Actors.LP2), lp2BalanceBefore + stETHOut);
    }

    function test_unwrapWstETH_emitsEvent() public {
        uint256 amount = 10 ether;
        _fundStETH(Actors.LP1, amount);
        vm.startPrank(Actors.LP1);
        stETH.approve(address(wstETH), amount);
        uint256 wstETHAmount = wstETH.wrap(amount);
        IERC20(address(wstETH)).approve(address(router), wstETHAmount);

        vm.expectEmit(true, true, false, true);
        emit IWstETHRouter.UnwrappedWstETH(Actors.LP1, Actors.LP1, wstETHAmount, amount);
        router.unwrapWstETH(wstETHAmount, Actors.LP1);
        vm.stopPrank();
    }

    function test_unwrapWstETH_zeroAmount_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IWstETHRouter.ZeroAmount.selector);
        router.unwrapWstETH(0, Actors.LP1);
    }

    function test_unwrapWstETH_zeroReceiver_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IWstETHRouter.ZeroAddress.selector);
        router.unwrapWstETH(1, address(0));
    }

    function test_unwrapWstETH_withExchangeRate() public {
        // Set rate: 1 stETH = 0.9 wstETH (stETH appreciated)
        wstETH.setTokensPerStEth(0.9e18);

        uint256 amount = 10 ether;
        _fundStETH(Actors.LP1, amount);
        vm.startPrank(Actors.LP1);
        stETH.approve(address(wstETH), amount);
        uint256 wstETHAmount = wstETH.wrap(amount);
        IERC20(address(wstETH)).approve(address(router), wstETHAmount);

        uint256 stETHOut = router.unwrapWstETH(wstETHAmount, Actors.LP1);
        vm.stopPrank();

        // Should get back approximately the same stETH (minus rounding)
        assertGt(stETHOut, 0);
        assertApproxEqAbs(stETHOut, amount, 2, "Should recover approximately same stETH");
    }
}
