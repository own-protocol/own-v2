// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnVault} from "../../src/core/OwnVault.sol";
import {IAaveRouter} from "../../src/interfaces/IAaveRouter.sol";
import {AaveRouter} from "../../src/periphery/AaveRouter.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AaveRouter Unit Tests
/// @notice Single multi-reserve router. Tests cover reserve registration / enable
///         toggling and deposit/withdraw flows for multiple underlyings (wstETH,
///         WETH, wBTC) routed through the same router.
contract AaveRouterTest is BaseTest {
    AaveRouter public router;
    MockAaveV3Pool public aavePool;
    address public mockMarket = makeAddr("market");

    // Reserves (each underlying decimals matches the real asset).
    MockERC20 public wstETHU;
    MockERC20 public wethU;
    MockERC20 public wbtcU;
    MockAToken public awstETH;
    MockAToken public aweth;
    MockAToken public awbtc;

    OwnVault public wstETHVault;
    OwnVault public wethVault;
    OwnVault public wbtcVault;

    function setUp() public override {
        super.setUp();

        aavePool = new MockAaveV3Pool();

        wstETHU = new MockERC20("Wrapped stETH", "wstETH", 18);
        wethU = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtcU = new MockERC20("Wrapped BTC", "wBTC", 8);

        awstETH = MockAToken(aavePool.registerReserve(address(wstETHU), "Aave wstETH", "awstETH", 18));
        aweth = MockAToken(aavePool.registerReserve(address(wethU), "Aave WETH", "aWETH", 18));
        awbtc = MockAToken(aavePool.registerReserve(address(wbtcU), "Aave wBTC", "awBTC", 8));

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        router = new AaveRouter(address(aavePool), address(protocolRegistry));

        router.registerReserve(address(wstETHU), address(awstETH));
        router.registerReserve(address(wethU), address(aweth));
        router.registerReserve(address(wbtcU), address(awbtc));

        wstETHVault = new OwnVault(
            address(awstETH), "Own awstETH", "owawstETH", address(protocolRegistry), address(router), 8000, 2000
        );
        wethVault =
            new OwnVault(address(aweth), "Own aWETH", "owaWETH", address(protocolRegistry), address(router), 8000, 2000);
        wbtcVault =
            new OwnVault(address(awbtc), "Own awBTC", "owawBTC", address(protocolRegistry), address(router), 8000, 2000);
        vm.stopPrank();

        vm.label(address(router), "AaveRouter");
        vm.label(address(aavePool), "MockAaveV3Pool");
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _fundAndApprove(MockERC20 token, address lp, uint256 amount) internal {
        token.mint(lp, amount);
        vm.prank(lp);
        token.approve(address(router), type(uint256).max);
    }

    function _fundAndApproveAToken(MockERC20 underlying_, MockAToken aToken_, address lp, uint256 amount) internal {
        underlying_.mint(lp, amount);
        vm.startPrank(lp);
        underlying_.approve(address(aavePool), amount);
        aavePool.supply(address(underlying_), amount, lp, 0);
        IERC20(address(aToken_)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(router.pool(), address(aavePool));
        assertEq(address(router.registry()), address(protocolRegistry));
    }

    function test_constructor_zeroPool_reverts() public {
        vm.expectRevert(IAaveRouter.ZeroAddress.selector);
        new AaveRouter(address(0), address(protocolRegistry));
    }

    function test_constructor_zeroRegistry_reverts() public {
        vm.expectRevert(IAaveRouter.ZeroAddress.selector);
        new AaveRouter(address(aavePool), address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  registerReserve
    // ──────────────────────────────────────────────────────────

    function test_registerReserve_setsMappingAndApproval() public {
        (address aToken, bool enabled) = router.reserves(address(wstETHU));
        assertEq(aToken, address(awstETH));
        assertTrue(enabled);
        assertEq(IERC20(address(wstETHU)).allowance(address(router), address(aavePool)), type(uint256).max);
    }

    function test_registerReserve_emitsEvents() public {
        MockERC20 newU = new MockERC20("Token", "TK", 18);
        MockAToken newA = MockAToken(aavePool.registerReserve(address(newU), "Aave TK", "aTK", 18));

        vm.startPrank(Actors.ADMIN);
        vm.expectEmit(true, true, false, false);
        emit IAaveRouter.ReserveRegistered(address(newU), address(newA));
        vm.expectEmit(true, false, false, true);
        emit IAaveRouter.ReserveEnabledChanged(address(newU), true);
        router.registerReserve(address(newU), address(newA));
        vm.stopPrank();
    }

    function test_registerReserve_alreadyRegistered_reverts() public {
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAaveRouter.ReserveAlreadyRegistered.selector, address(wstETHU)));
        router.registerReserve(address(wstETHU), address(awstETH));
    }

    function test_registerReserve_zeroAddresses_revert() public {
        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(IAaveRouter.ZeroAddress.selector);
        router.registerReserve(address(0), address(awstETH));
        vm.expectRevert(IAaveRouter.ZeroAddress.selector);
        router.registerReserve(address(wstETHU), address(0));
        vm.stopPrank();
    }

    function test_registerReserve_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAaveRouter.OnlyAdmin.selector);
        router.registerReserve(makeAddr("u"), makeAddr("a"));
    }

    // ──────────────────────────────────────────────────────────
    //  setReserveEnabled
    // ──────────────────────────────────────────────────────────

    function test_setReserveEnabled_togglesAndEmits() public {
        vm.startPrank(Actors.ADMIN);
        vm.expectEmit(true, false, false, true);
        emit IAaveRouter.ReserveEnabledChanged(address(wstETHU), false);
        router.setReserveEnabled(address(wstETHU), false);
        (, bool enabled) = router.reserves(address(wstETHU));
        assertFalse(enabled);

        router.setReserveEnabled(address(wstETHU), true);
        (, enabled) = router.reserves(address(wstETHU));
        assertTrue(enabled);
        vm.stopPrank();
    }

    function test_setReserveEnabled_unregistered_reverts() public {
        address bogus = makeAddr("bogus");
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAaveRouter.ReserveNotRegistered.selector, bogus));
        router.setReserveEnabled(bogus, false);
    }

    function test_setReserveEnabled_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IAaveRouter.OnlyAdmin.selector);
        router.setReserveEnabled(address(wstETHU), false);
    }

    // ──────────────────────────────────────────────────────────
    //  deposit — happy paths across reserves
    // ──────────────────────────────────────────────────────────

    function test_deposit_wstETH_succeeds() public {
        uint256 amount = 10 ether;
        _fundAndApprove(wstETHU, Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.deposit(address(wstETHU), IERC4626(address(wstETHVault)), amount, Actors.LP1, 0);

        assertGt(shares, 0);
        assertEq(wstETHVault.balanceOf(Actors.LP1), shares);
        assertEq(awstETH.balanceOf(address(wstETHVault)), amount);
        assertEq(awstETH.balanceOf(address(router)), 0);
        assertEq(IERC20(address(wstETHU)).balanceOf(address(router)), 0);
    }

    function test_deposit_weth_succeeds() public {
        uint256 amount = 5 ether;
        _fundAndApprove(wethU, Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.deposit(address(wethU), IERC4626(address(wethVault)), amount, Actors.LP1, 0);

        assertGt(shares, 0);
        assertEq(aweth.balanceOf(address(wethVault)), amount);
    }

    function test_deposit_wbtc_succeeds() public {
        uint256 amount = 1e8; // 1 wBTC, 8 decimals
        _fundAndApprove(wbtcU, Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.deposit(address(wbtcU), IERC4626(address(wbtcVault)), amount, Actors.LP1, 0);

        assertGt(shares, 0);
        assertEq(awbtc.balanceOf(address(wbtcVault)), amount);
    }

    function test_deposit_emitsEvent() public {
        uint256 amount = 10 ether;
        _fundAndApprove(wstETHU, Actors.LP1, amount);

        vm.prank(Actors.LP1);
        vm.expectEmit(true, true, true, false);
        emit IAaveRouter.Deposit(address(wstETHVault), Actors.LP1, Actors.LP1, address(wstETHU), amount, 0);
        router.deposit(address(wstETHU), IERC4626(address(wstETHVault)), amount, Actors.LP1, 0);
    }

    function test_deposit_differentReceiver() public {
        uint256 amount = 10 ether;
        _fundAndApprove(wstETHU, Actors.LP1, amount);

        vm.prank(Actors.LP1);
        uint256 shares = router.deposit(address(wstETHU), IERC4626(address(wstETHVault)), amount, Actors.LP2, 0);

        assertEq(wstETHVault.balanceOf(Actors.LP2), shares);
        assertEq(wstETHVault.balanceOf(Actors.LP1), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  deposit — reverts
    // ──────────────────────────────────────────────────────────

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IAaveRouter.ZeroAmount.selector);
        router.deposit(address(wstETHU), IERC4626(address(wstETHVault)), 0, Actors.LP1, 0);
    }

    function test_deposit_zeroReceiver_reverts() public {
        _fundAndApprove(wstETHU, Actors.LP1, 1 ether);
        vm.prank(Actors.LP1);
        vm.expectRevert(IAaveRouter.ZeroAddress.selector);
        router.deposit(address(wstETHU), IERC4626(address(wstETHVault)), 1 ether, address(0), 0);
    }

    function test_deposit_unregistered_reverts() public {
        MockERC20 bogus = new MockERC20("X", "X", 18);
        _fundAndApprove(bogus, Actors.LP1, 1 ether);
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSelector(IAaveRouter.ReserveNotRegistered.selector, address(bogus)));
        router.deposit(address(bogus), IERC4626(address(wstETHVault)), 1 ether, Actors.LP1, 0);
    }

    function test_deposit_disabled_reverts() public {
        vm.prank(Actors.ADMIN);
        router.setReserveEnabled(address(wstETHU), false);

        _fundAndApprove(wstETHU, Actors.LP1, 1 ether);
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSelector(IAaveRouter.ReserveDisabled.selector, address(wstETHU)));
        router.deposit(address(wstETHU), IERC4626(address(wstETHVault)), 1 ether, Actors.LP1, 0);
    }

    function test_deposit_assetMismatch_reverts() public {
        // Vault expects awstETH; we route via WETH → aWETH. Mismatch.
        _fundAndApprove(wethU, Actors.LP1, 1 ether);

        vm.prank(Actors.LP1);
        vm.expectRevert(
            abi.encodeWithSelector(IAaveRouter.VaultAssetMismatch.selector, address(aweth), address(awstETH))
        );
        router.deposit(address(wethU), IERC4626(address(wstETHVault)), 1 ether, Actors.LP1, 0);
    }

    function test_deposit_slippage_reverts() public {
        uint256 amount = 10 ether;
        _fundAndApprove(wstETHU, Actors.LP1, amount);
        uint256 expectedShares = wstETHVault.previewDeposit(amount);

        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSelector(IAaveRouter.MinSharesError.selector, expectedShares, type(uint256).max));
        router.deposit(address(wstETHU), IERC4626(address(wstETHVault)), amount, Actors.LP1, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  withdraw
    // ──────────────────────────────────────────────────────────

    function test_withdraw_succeeds() public {
        uint256 amount = 10 ether;
        _fundAndApproveAToken(wstETHU, awstETH, Actors.LP1, amount);

        uint256 before_ = IERC20(address(wstETHU)).balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 out = router.withdraw(address(wstETHU), amount, Actors.LP1);

        assertEq(out, amount);
        assertEq(IERC20(address(wstETHU)).balanceOf(Actors.LP1), before_ + amount);
        assertEq(awstETH.balanceOf(Actors.LP1), 0);
    }

    function test_withdraw_emitsEvent() public {
        uint256 amount = 10 ether;
        _fundAndApproveAToken(wstETHU, awstETH, Actors.LP1, amount);

        vm.prank(Actors.LP1);
        vm.expectEmit(true, true, true, true);
        emit IAaveRouter.Withdraw(Actors.LP1, Actors.LP1, address(wstETHU), amount, amount);
        router.withdraw(address(wstETHU), amount, Actors.LP1);
    }

    function test_withdraw_zeroAmount_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IAaveRouter.ZeroAmount.selector);
        router.withdraw(address(wstETHU), 0, Actors.LP1);
    }

    function test_withdraw_zeroReceiver_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(IAaveRouter.ZeroAddress.selector);
        router.withdraw(address(wstETHU), 1, address(0));
    }

    function test_withdraw_unregistered_reverts() public {
        address bogus = makeAddr("bogus");
        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSelector(IAaveRouter.ReserveNotRegistered.selector, bogus));
        router.withdraw(bogus, 1, Actors.LP1);
    }

    function test_withdraw_disabled_reverts() public {
        vm.prank(Actors.ADMIN);
        router.setReserveEnabled(address(wstETHU), false);

        vm.prank(Actors.LP1);
        vm.expectRevert(abi.encodeWithSelector(IAaveRouter.ReserveDisabled.selector, address(wstETHU)));
        router.withdraw(address(wstETHU), 1, Actors.LP1);
    }
}
