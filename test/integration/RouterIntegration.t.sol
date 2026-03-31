// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockWETH} from "../helpers/MockWETH.sol";
import {MockWstETH} from "../helpers/MockWstETH.sol";

import {OwnVault} from "../../src/core/OwnVault.sol";
import {WETHRouter} from "../../src/periphery/WETHRouter.sol";
import {WstETHRouter} from "../../src/periphery/WstETHRouter.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RouterIntegration Integration Test
/// @notice Tests WETHRouter and WstETHRouter with actual OwnVault deposits/withdrawals.
///         The routers act as the bound VM since vault.deposit() is onlyVM.
contract RouterIntegrationTest is BaseTest {
    MockWETH public mockWeth;
    MockWstETH public mockWstETH;
    WETHRouter public wethRouter;
    WstETHRouter public wstethRouter;
    OwnVault public wethVault;
    OwnVault public wstethVault;

    uint256 constant DEPOSIT_AMOUNT_ETH = 10 ether;
    uint256 constant DEPOSIT_AMOUNT_STETH = 10 ether;

    function setUp() public override {
        super.setUp();
        _deployRoutersAndVaults();
    }

    function _deployRoutersAndVaults() private {
        // Deploy fresh mock tokens for routing (with deposit/withdraw support)
        mockWeth = new MockWETH();
        vm.label(address(mockWeth), "MockWETH");

        // mockWstETH wraps stETH (from BaseTest)
        mockWstETH = new MockWstETH(address(stETH));
        vm.label(address(mockWstETH), "MockWstETH");

        // Deploy routers
        wethRouter = new WETHRouter(address(mockWeth));
        wstethRouter = new WstETHRouter(address(mockWstETH), address(stETH));
        vm.label(address(wethRouter), "WETHRouter");
        vm.label(address(wstethRouter), "WstETHRouter");

        vm.startPrank(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), makeAddr("mockMarket"));

        // WETH vault with router as VM (router calls deposit directly)
        wethVault = new OwnVault(
            address(mockWeth),
            "Own WETH Vault",
            "oWETH",
            address(protocolRegistry),
            address(wethRouter), // bound VM is router
            8000,
            2000
        );

        // wstETH vault with router as VM
        wstethVault = new OwnVault(
            address(mockWstETH),
            "Own wstETH Vault",
            "owstETH",
            address(protocolRegistry),
            address(wstethRouter), // bound VM is router
            8000,
            2000
        );

        vm.stopPrank();

        vm.label(address(wethVault), "WETHVault");
        vm.label(address(wstethVault), "wstETHVault");
    }

    // ══════════════════════════════════════════════════════════
    //  WETH Router: ETH → WETH → vault deposit → shares
    // ══════════════════════════════════════════════════════════

    function test_wethRouter_depositETH_receivesShares() public {
        _fundETH(Actors.LP1, DEPOSIT_AMOUNT_ETH);

        vm.prank(Actors.LP1);
        uint256 shares = wethRouter.depositETH{value: DEPOSIT_AMOUNT_ETH}(
            IERC4626(address(wethVault)),
            Actors.LP1,
            0 // no slippage protection for test
        );

        assertGt(shares, 0, "LP received shares");
        assertEq(wethVault.balanceOf(Actors.LP1), shares, "shares attributed to LP");
        assertEq(wethVault.totalAssets(), DEPOSIT_AMOUNT_ETH, "vault has WETH");
        assertEq(Actors.LP1.balance, 0, "LP ETH drained");
    }

    // ══════════════════════════════════════════════════════════
    //  WETH Router: redeem shares → WETH → ETH
    // ══════════════════════════════════════════════════════════

    function test_wethRouter_redeemETH_receivesETH() public {
        // First deposit
        _fundETH(Actors.LP1, DEPOSIT_AMOUNT_ETH);
        vm.prank(Actors.LP1);
        uint256 shares = wethRouter.depositETH{value: DEPOSIT_AMOUNT_ETH}(IERC4626(address(wethVault)), Actors.LP1, 0);

        // Approve router to pull shares
        vm.prank(Actors.LP1);
        IERC20(address(wethVault)).approve(address(wethRouter), shares);

        uint256 ethBefore = Actors.LP1.balance;

        // Redeem
        vm.prank(Actors.LP1);
        uint256 assets = wethRouter.redeemETH(IERC4626(address(wethVault)), shares, Actors.LP1, 0);

        assertEq(assets, DEPOSIT_AMOUNT_ETH, "received full ETH back");
        assertEq(Actors.LP1.balance, ethBefore + DEPOSIT_AMOUNT_ETH, "LP got ETH");
        assertEq(wethVault.balanceOf(Actors.LP1), 0, "shares burned");
        assertEq(wethVault.totalAssets(), 0, "vault drained");
    }

    // ══════════════════════════════════════════════════════════
    //  WETH Router: Full round trip (deposit + redeem)
    // ══════════════════════════════════════════════════════════

    function test_wethRouter_fullRoundTrip() public {
        _fundETH(Actors.LP1, DEPOSIT_AMOUNT_ETH);

        // Deposit
        vm.prank(Actors.LP1);
        uint256 shares = wethRouter.depositETH{value: DEPOSIT_AMOUNT_ETH}(IERC4626(address(wethVault)), Actors.LP1, 0);

        assertGt(shares, 0);
        assertEq(Actors.LP1.balance, 0);

        // Approve + Redeem
        vm.startPrank(Actors.LP1);
        IERC20(address(wethVault)).approve(address(wethRouter), shares);
        wethRouter.redeemETH(IERC4626(address(wethVault)), shares, Actors.LP1, 0);
        vm.stopPrank();

        assertEq(Actors.LP1.balance, DEPOSIT_AMOUNT_ETH, "full ETH returned");
        assertEq(wethVault.totalAssets(), 0, "vault empty");
    }

    // ══════════════════════════════════════════════════════════
    //  wstETH Router: stETH → wstETH → vault deposit → shares
    // ══════════════════════════════════════════════════════════

    function test_wstethRouter_depositStETH_receivesShares() public {
        _fundStETH(Actors.LP1, DEPOSIT_AMOUNT_STETH);

        vm.startPrank(Actors.LP1);
        stETH.approve(address(wstethRouter), DEPOSIT_AMOUNT_STETH);
        uint256 shares = wstethRouter.depositStETH(IERC4626(address(wstethVault)), DEPOSIT_AMOUNT_STETH, Actors.LP1, 0);
        vm.stopPrank();

        assertGt(shares, 0, "LP received shares");
        assertEq(wstethVault.balanceOf(Actors.LP1), shares, "shares attributed to LP");

        // wstETH amount = stETH amount at 1:1 rate (default mock rate)
        uint256 expectedWstETH = mockWstETH.getWstETHByStETH(DEPOSIT_AMOUNT_STETH);
        assertEq(wstethVault.totalAssets(), expectedWstETH, "vault has wstETH");
        assertEq(stETH.balanceOf(Actors.LP1), 0, "LP stETH drained");
    }

    // ══════════════════════════════════════════════════════════
    //  wstETH Router: redeem shares → wstETH → stETH
    // ══════════════════════════════════════════════════════════

    function test_wstethRouter_redeemStETH_receivesStETH() public {
        // First deposit
        _fundStETH(Actors.LP1, DEPOSIT_AMOUNT_STETH);
        vm.startPrank(Actors.LP1);
        stETH.approve(address(wstethRouter), DEPOSIT_AMOUNT_STETH);
        uint256 shares = wstethRouter.depositStETH(IERC4626(address(wstethVault)), DEPOSIT_AMOUNT_STETH, Actors.LP1, 0);

        // Approve router to pull shares
        IERC20(address(wstethVault)).approve(address(wstethRouter), shares);

        uint256 stethBefore = stETH.balanceOf(Actors.LP1);

        // Redeem
        uint256 stETHOut = wstethRouter.redeemStETH(IERC4626(address(wstethVault)), shares, Actors.LP1, 0);
        vm.stopPrank();

        assertEq(stETHOut, DEPOSIT_AMOUNT_STETH, "received full stETH back");
        assertEq(stETH.balanceOf(Actors.LP1), stethBefore + DEPOSIT_AMOUNT_STETH, "LP got stETH");
        assertEq(wstethVault.balanceOf(Actors.LP1), 0, "shares burned");
    }

    // ══════════════════════════════════════════════════════════
    //  wstETH Router: Exchange rate affects wstETH amounts
    // ══════════════════════════════════════════════════════════

    function test_wstethRouter_withExchangeRate() public {
        // Set exchange rate: 1 stETH = 0.9 wstETH (1e18 stETH → 0.9e18 wstETH)
        mockWstETH.setTokensPerStEth(0.9e18);

        _fundStETH(Actors.LP1, DEPOSIT_AMOUNT_STETH);

        vm.startPrank(Actors.LP1);
        stETH.approve(address(wstethRouter), DEPOSIT_AMOUNT_STETH);
        uint256 shares = wstethRouter.depositStETH(IERC4626(address(wstethVault)), DEPOSIT_AMOUNT_STETH, Actors.LP1, 0);
        vm.stopPrank();

        // Expected wstETH = 10e18 * 0.9e18 / 1e18 = 9e18
        uint256 expectedWstETH = DEPOSIT_AMOUNT_STETH * 0.9e18 / 1e18;
        assertEq(wstethVault.totalAssets(), expectedWstETH, "vault has correct wstETH with rate");
        assertGt(shares, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  WETH Router: Different receiver
    // ══════════════════════════════════════════════════════════

    function test_wethRouter_depositETH_differentReceiver() public {
        _fundETH(Actors.LP1, DEPOSIT_AMOUNT_ETH);

        vm.prank(Actors.LP1);
        uint256 shares = wethRouter.depositETH{value: DEPOSIT_AMOUNT_ETH}(
            IERC4626(address(wethVault)),
            Actors.LP2, // different receiver
            0
        );

        assertEq(wethVault.balanceOf(Actors.LP1), 0, "sender has no shares");
        assertEq(wethVault.balanceOf(Actors.LP2), shares, "receiver has shares");
    }
}
