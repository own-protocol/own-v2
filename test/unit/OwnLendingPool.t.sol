// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnLendingPool} from "../../src/core/OwnLendingPool.sol";
import {IOwnLendingPool} from "../../src/interfaces/IOwnLendingPool.sol";
import {IAaveV3Pool} from "../../src/interfaces/external/IAaveV3Pool.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";
import {OwnAToken} from "../../src/tokens/OwnAToken.sol";
import {OwnDebtToken} from "../../src/tokens/OwnDebtToken.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Fee-on-transfer token used to assert the pool rejects non-standard transfers.
contract FeeERC20 is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Burn a 1% fee on real transfers (not mint/burn).
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @title OwnLendingPool Unit Tests
/// @notice Single-asset zero-rate pool: 1:1 aToken, principal-only debt,
///         delegation-gated borrows, router-only supply, health checks on
///         withdraw and aToken transfer. Semantics mirror the Aave V3 subset
///         the protocol consumes (see MockAaveV3Pool for the reference shape).
contract OwnLendingPoolTest is BaseTest {
    OwnLendingPool public pool;
    OwnAToken public aUSDG;
    OwnDebtToken public dUSDG;
    MockERC20 public usdg;

    address public router = makeAddr("router");
    address public lp = makeAddr("lp");
    address public borrower = makeAddr("borrower");
    address public delegatee = makeAddr("delegatee");

    uint256 constant LTV = 8000; // 80%
    uint256 constant LT = 9500; // 95%
    uint256 constant SUPPLY = 1_000_000e6;

    function setUp() public override {
        super.setUp();

        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.startPrank(Actors.ADMIN);
        pool = new OwnLendingPool(
            address(protocolRegistry), address(usdg), "Own aUSDG", "oaUSDG", "Own Debt USDG", "odUSDG", LTV, LT
        );
        pool.setSupplierAllowed(router, true);
        vm.stopPrank();

        aUSDG = OwnAToken(pool.aToken());
        dUSDG = OwnDebtToken(pool.variableDebtToken());

        usdg.mint(router, 10 * SUPPLY);
        vm.prank(router);
        usdg.approve(address(pool), type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Supply `amount` from the router, crediting `onBehalfOf` with aUSDG.
    function _supply(address onBehalfOf, uint256 amount) internal {
        vm.prank(router);
        pool.supply(address(usdg), amount, onBehalfOf, 0);
    }

    /// @dev Self-borrow `amount` as `user` (must hold aUSDG collateral).
    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        pool.borrow(address(usdg), amount, 2, 0, user);
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsConfigAndDeploysTokens() public view {
        assertEq(pool.underlying(), address(usdg));
        assertEq(pool.ltvBps(), LTV);
        assertEq(pool.liquidationThresholdBps(), LT);
        assertEq(aUSDG.decimals(), 6);
        assertEq(dUSDG.decimals(), 6);
        assertEq(aUSDG.pool(), address(pool));
        assertEq(dUSDG.pool(), address(pool));
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.availableLiquidity(), 0);
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IOwnLendingPool.ZeroAddress.selector);
        new OwnLendingPool(address(0), address(usdg), "a", "a", "d", "d", LTV, LT);
        vm.expectRevert(IOwnLendingPool.ZeroAddress.selector);
        new OwnLendingPool(address(protocolRegistry), address(0), "a", "a", "d", "d", LTV, LT);
    }

    function test_constructor_invalidLtvConfig_reverts() public {
        // ltv must be non-zero.
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.InvalidLtvConfig.selector, 0, LT));
        new OwnLendingPool(address(protocolRegistry), address(usdg), "a", "a", "d", "d", 0, LT);
        // ltv must not exceed lt.
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.InvalidLtvConfig.selector, LT + 1, LT));
        new OwnLendingPool(address(protocolRegistry), address(usdg), "a", "a", "d", "d", LT + 1, LT);
        // lt must not exceed 100%.
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.InvalidLtvConfig.selector, LTV, BPS + 1));
        new OwnLendingPool(address(protocolRegistry), address(usdg), "a", "a", "d", "d", LTV, BPS + 1);
    }

    // ──────────────────────────────────────────────────────────
    //  getReserveData
    // ──────────────────────────────────────────────────────────

    function test_getReserveData_returnsTokenAddressesAndZeroRate() public view {
        IAaveV3Pool.ReserveDataLegacy memory data = pool.getReserveData(address(usdg));
        assertEq(data.aTokenAddress, address(aUSDG));
        assertEq(data.variableDebtTokenAddress, address(dUSDG));
        assertEq(data.currentVariableBorrowRate, 0);
        assertEq(data.liquidityIndex, 1e27);
        assertEq(data.variableBorrowIndex, 1e27);
        assertEq(data.stableDebtTokenAddress, address(0));
    }

    function test_getReserveData_unknownAsset_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.UnknownReserve.selector, address(usdc)));
        pool.getReserveData(address(usdc));
    }

    // ──────────────────────────────────────────────────────────
    //  Supply
    // ──────────────────────────────────────────────────────────

    function test_supply_mintsATokenOneToOne() public {
        vm.expectEmit(true, true, false, true, address(pool));
        emit IOwnLendingPool.Supplied(router, lp, SUPPLY);
        _supply(lp, SUPPLY);

        assertEq(aUSDG.balanceOf(lp), SUPPLY);
        assertEq(aUSDG.totalSupply(), SUPPLY);
        assertEq(usdg.balanceOf(address(pool)), SUPPLY);
        assertEq(pool.availableLiquidity(), SUPPLY);
    }

    function test_supply_notAllowedSupplier_reverts() public {
        usdg.mint(lp, SUPPLY);
        vm.startPrank(lp);
        usdg.approve(address(pool), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.SupplierNotAllowed.selector, lp));
        pool.supply(address(usdg), SUPPLY, lp, 0);
        vm.stopPrank();
    }

    function test_supply_zeroAmount_reverts() public {
        vm.prank(router);
        vm.expectRevert(IOwnLendingPool.ZeroAmount.selector);
        pool.supply(address(usdg), 0, lp, 0);
    }

    function test_supply_zeroOnBehalfOf_reverts() public {
        vm.prank(router);
        vm.expectRevert(IOwnLendingPool.ZeroAddress.selector);
        pool.supply(address(usdg), SUPPLY, address(0), 0);
    }

    function test_supply_unknownAsset_reverts() public {
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.UnknownReserve.selector, address(usdc)));
        pool.supply(address(usdc), SUPPLY, lp, 0);
    }

    function test_supply_feeOnTransferToken_reverts() public {
        FeeERC20 fee = new FeeERC20();
        vm.startPrank(Actors.ADMIN);
        OwnLendingPool feePool =
            new OwnLendingPool(address(protocolRegistry), address(fee), "a", "a", "d", "d", LTV, LT);
        feePool.setSupplierAllowed(router, true);
        vm.stopPrank();

        fee.mint(router, SUPPLY);
        vm.startPrank(router);
        fee.approve(address(feePool), SUPPLY);
        vm.expectRevert(IOwnLendingPool.FeeOnTransferNotSupported.selector);
        feePool.supply(address(fee), SUPPLY, lp, 0);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Withdraw
    // ──────────────────────────────────────────────────────────

    function test_withdraw_burnsAndReturnsUnderlying() public {
        _supply(lp, SUPPLY);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IOwnLendingPool.Withdrawn(lp, lp, 400_000e6);
        vm.prank(lp);
        uint256 out = pool.withdraw(address(usdg), 400_000e6, lp);

        assertEq(out, 400_000e6);
        assertEq(usdg.balanceOf(lp), 400_000e6);
        assertEq(aUSDG.balanceOf(lp), SUPPLY - 400_000e6);
        assertEq(pool.availableLiquidity(), SUPPLY - 400_000e6);
    }

    function test_withdraw_maxWithdrawsFullBalance() public {
        _supply(lp, SUPPLY);
        vm.prank(lp);
        uint256 out = pool.withdraw(address(usdg), type(uint256).max, lp);
        assertEq(out, SUPPLY);
        assertEq(aUSDG.balanceOf(lp), 0);
    }

    function test_withdraw_toReceiver() public {
        _supply(lp, SUPPLY);
        vm.prank(lp);
        pool.withdraw(address(usdg), SUPPLY, borrower);
        assertEq(usdg.balanceOf(borrower), SUPPLY);
    }

    function test_withdraw_exceedsBalance_reverts() public {
        _supply(lp, SUPPLY);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, lp, SUPPLY, SUPPLY + 1));
        pool.withdraw(address(usdg), SUPPLY + 1, lp);
    }

    function test_withdraw_fullExitAlwaysLiquid_evenAtMaxUtilization() public {
        // Exit-liquidity property: because ltv <= lt <= 100% and debt never accrues,
        // every debtor's collateral covers their own debt, so a non-debtor can always
        // withdraw their full balance even with every borrower at the LTV cap.
        _supply(lp, SUPPLY);
        _supply(borrower, SUPPLY);
        _borrow(borrower, SUPPLY * LTV / BPS);

        vm.prank(lp);
        uint256 out = pool.withdraw(address(usdg), SUPPLY, lp);
        assertEq(out, SUPPLY);
        assertEq(usdg.balanceOf(lp), SUPPLY);
    }

    function test_withdraw_debtorBreachingThreshold_reverts() public {
        _supply(borrower, SUPPLY);
        uint256 debt = SUPPLY * LTV / BPS; // borrow to the LTV cap
        _borrow(borrower, debt);

        // Withdrawing down to where debt > remaining × LT must revert.
        // Max safe remaining collateral: debt × BPS / LT (ceil); withdraw one unit more.
        uint256 minCollateral = (debt * BPS + LT - 1) / LT;
        uint256 excessWithdraw = SUPPLY - minCollateral + 1;
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.HealthCheckFailed.selector, borrower));
        pool.withdraw(address(usdg), excessWithdraw, borrower);

        // Exactly at the threshold is allowed.
        vm.prank(borrower);
        pool.withdraw(address(usdg), excessWithdraw - 1, borrower);
    }

    function test_withdraw_zeroAmount_reverts() public {
        _supply(lp, SUPPLY);
        vm.prank(lp);
        vm.expectRevert(IOwnLendingPool.ZeroAmount.selector);
        pool.withdraw(address(usdg), 0, lp);
    }

    // ──────────────────────────────────────────────────────────
    //  Borrow
    // ──────────────────────────────────────────────────────────

    function test_borrow_selfAgainstCollateral() public {
        _supply(borrower, SUPPLY);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IOwnLendingPool.Borrowed(borrower, borrower, 100_000e6);
        _borrow(borrower, 100_000e6);

        assertEq(usdg.balanceOf(borrower), 100_000e6);
        assertEq(pool.debtOf(borrower), 100_000e6);
        assertEq(dUSDG.balanceOf(borrower), 100_000e6);
        assertEq(pool.totalDebt(), 100_000e6);
    }

    function test_borrow_atExactLtvBoundary() public {
        _supply(borrower, SUPPLY);
        uint256 maxDebt = SUPPLY * LTV / BPS;
        _borrow(borrower, maxDebt);
        assertEq(pool.debtOf(borrower), maxDebt);
    }

    function test_borrow_aboveLtv_reverts() public {
        _supply(borrower, SUPPLY);
        uint256 maxDebt = SUPPLY * LTV / BPS;
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.InsufficientCollateral.selector, borrower));
        pool.borrow(address(usdg), maxDebt + 1, 2, 0, borrower);
    }

    function test_borrow_delegated_consumesAllowance() public {
        _supply(lp, SUPPLY);

        vm.prank(lp);
        dUSDG.approveDelegation(delegatee, 300_000e6);
        assertEq(dUSDG.borrowAllowance(lp, delegatee), 300_000e6);

        vm.prank(delegatee);
        pool.borrow(address(usdg), 200_000e6, 2, 0, lp);

        // Funds to the caller; debt on the delegator.
        assertEq(usdg.balanceOf(delegatee), 200_000e6);
        assertEq(pool.debtOf(lp), 200_000e6);
        assertEq(dUSDG.borrowAllowance(lp, delegatee), 100_000e6);
    }

    function test_borrow_delegated_maxAllowanceNotDecremented() public {
        _supply(lp, SUPPLY);
        vm.prank(lp);
        dUSDG.approveDelegation(delegatee, type(uint256).max);

        vm.prank(delegatee);
        pool.borrow(address(usdg), 200_000e6, 2, 0, lp);
        assertEq(dUSDG.borrowAllowance(lp, delegatee), type(uint256).max);
    }

    function test_borrow_delegated_withoutAllowance_reverts() public {
        _supply(lp, SUPPLY);
        vm.prank(delegatee);
        vm.expectRevert(abi.encodeWithSelector(OwnDebtToken.InsufficientDelegation.selector, lp, delegatee, 1e6));
        pool.borrow(address(usdg), 1e6, 2, 0, lp);
    }

    function test_borrow_zeroAmount_reverts() public {
        _supply(borrower, SUPPLY);
        vm.prank(borrower);
        vm.expectRevert(IOwnLendingPool.ZeroAmount.selector);
        pool.borrow(address(usdg), 0, 2, 0, borrower);
    }

    function test_borrow_unknownAsset_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.UnknownReserve.selector, address(usdc)));
        pool.borrow(address(usdc), 1e6, 2, 0, borrower);
    }

    // ──────────────────────────────────────────────────────────
    //  Repay
    // ──────────────────────────────────────────────────────────

    function test_repay_partial() public {
        _supply(borrower, SUPPLY);
        _borrow(borrower, 100_000e6);

        vm.startPrank(borrower);
        usdg.approve(address(pool), type(uint256).max);
        vm.expectEmit(true, true, false, true, address(pool));
        emit IOwnLendingPool.Repaid(borrower, borrower, 40_000e6);
        uint256 repaid = pool.repay(address(usdg), 40_000e6, 2, borrower);
        vm.stopPrank();

        assertEq(repaid, 40_000e6);
        assertEq(pool.debtOf(borrower), 60_000e6);
        assertEq(pool.totalDebt(), 60_000e6);
    }

    function test_repay_overpaymentCapsAtOutstanding() public {
        _supply(borrower, SUPPLY);
        _borrow(borrower, 100_000e6);
        usdg.mint(borrower, 50_000e6); // extra funds beyond the borrow

        vm.startPrank(borrower);
        usdg.approve(address(pool), type(uint256).max);
        uint256 balBefore = usdg.balanceOf(borrower);
        uint256 repaid = pool.repay(address(usdg), 150_000e6, 2, borrower);
        vm.stopPrank();

        // Caps at outstanding and pulls only the actual amount — the surplus
        // stays with the caller (BorrowManager's sweep depends on this).
        assertEq(repaid, 100_000e6);
        assertEq(usdg.balanceOf(borrower), balBefore - 100_000e6);
        assertEq(pool.debtOf(borrower), 0);
    }

    function test_repay_maxRepaysFullDebt() public {
        _supply(borrower, SUPPLY);
        _borrow(borrower, 100_000e6);
        vm.startPrank(borrower);
        usdg.approve(address(pool), type(uint256).max);
        uint256 repaid = pool.repay(address(usdg), type(uint256).max, 2, borrower);
        vm.stopPrank();
        assertEq(repaid, 100_000e6);
        assertEq(pool.debtOf(borrower), 0);
    }

    function test_repay_zeroOutstandingDebt_reverts() public {
        // Aave V3 parity: repaying with no debt reverts (error '39'), it does not return 0.
        vm.prank(borrower);
        vm.expectRevert(IOwnLendingPool.NoDebtOfSelectedType.selector);
        pool.repay(address(usdg), 1e6, 2, borrower);
    }

    function test_repay_onBehalfOfByThirdParty() public {
        _supply(borrower, SUPPLY);
        _borrow(borrower, 100_000e6);

        usdg.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdg.approve(address(pool), type(uint256).max);
        pool.repay(address(usdg), 100_000e6, 2, borrower);
        vm.stopPrank();

        assertEq(pool.debtOf(borrower), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  getUserAccountData
    // ──────────────────────────────────────────────────────────

    function test_getUserAccountData_noDebt() public {
        _supply(lp, SUPPLY);
        (uint256 collateralBase, uint256 debtBase, uint256 availableBase, uint256 lt, uint256 ltv, uint256 hf) =
            pool.getUserAccountData(lp);

        // Base currency is 1e8 USD; 1 USDG (1e6) == $1 (1e8).
        assertEq(collateralBase, SUPPLY * 100);
        assertEq(debtBase, 0);
        assertEq(availableBase, SUPPLY * LTV / BPS * 100);
        assertEq(lt, LT);
        assertEq(ltv, LTV);
        assertEq(hf, type(uint256).max);
    }

    function test_getUserAccountData_withDebt() public {
        _supply(borrower, SUPPLY);
        uint256 debt = 500_000e6;
        _borrow(borrower, debt);

        (uint256 collateralBase, uint256 debtBase, uint256 availableBase,,, uint256 hf) =
            pool.getUserAccountData(borrower);

        assertEq(collateralBase, SUPPLY * 100);
        assertEq(debtBase, debt * 100);
        // hf = collateral × LT / debt = 1M × 0.95 / 0.5M = 1.9
        assertEq(hf, 1.9e18);
        // headroom = ltv × collateral − debt = 800k − 500k = 300k
        assertEq(availableBase, 300_000e6 * 100);
    }

    function test_getUserAccountData_headroomFloorsAtZero() public {
        _supply(borrower, SUPPLY);
        _borrow(borrower, SUPPLY * LTV / BPS);
        // Admin lowers LTV below the borrower's current debt share; headroom must clamp to 0.
        vm.prank(Actors.ADMIN);
        pool.setLtvConfig(5000, LT);
        (,, uint256 availableBase,,,) = pool.getUserAccountData(borrower);
        assertEq(availableBase, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  aToken transfer health check
    // ──────────────────────────────────────────────────────────

    function test_aTokenTransfer_debtorBreachingThreshold_reverts() public {
        _supply(borrower, SUPPLY);
        uint256 debt = SUPPLY * LTV / BPS;
        _borrow(borrower, debt);

        uint256 minCollateral = (debt * BPS + LT - 1) / LT;
        uint256 excess = SUPPLY - minCollateral;
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.HealthCheckFailed.selector, borrower));
        aUSDG.transfer(lp, excess + 1);

        // Within the LT buffer the transfer succeeds.
        vm.prank(borrower);
        aUSDG.transfer(lp, excess);
    }

    function test_aTokenTransfer_noDebt_unrestricted() public {
        _supply(lp, SUPPLY);
        vm.prank(lp);
        aUSDG.transfer(borrower, SUPPLY);
        assertEq(aUSDG.balanceOf(borrower), SUPPLY);
    }

    // ──────────────────────────────────────────────────────────
    //  setUserUseReserveAsCollateral (compatibility no-op)
    // ──────────────────────────────────────────────────────────

    function test_setUserUseReserveAsCollateral_emitsAndDoesNotGateBorrows() public {
        _supply(borrower, SUPPLY);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IOwnLendingPool.CollateralUseSet(borrower, true);
        vm.prank(borrower);
        pool.setUserUseReserveAsCollateral(address(usdg), true);

        // Collateral counts regardless of the flag — borrow works without ever calling it.
        _borrow(borrower, 1e6);
        assertEq(pool.debtOf(borrower), 1e6);
    }

    function test_setUserUseReserveAsCollateral_unknownAsset_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.UnknownReserve.selector, address(usdc)));
        pool.setUserUseReserveAsCollateral(address(usdc), true);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function test_setSupplierAllowed_onlyAdmin() public {
        vm.prank(lp);
        vm.expectRevert(IOwnLendingPool.OnlyAdmin.selector);
        pool.setSupplierAllowed(lp, true);
    }

    function test_setSupplierAllowed_togglesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit IOwnLendingPool.SupplierAllowedUpdated(lp, true);
        vm.prank(Actors.ADMIN);
        pool.setSupplierAllowed(lp, true);
        assertTrue(pool.supplierAllowed(lp));

        vm.prank(Actors.ADMIN);
        pool.setSupplierAllowed(lp, false);
        assertFalse(pool.supplierAllowed(lp));
    }

    function test_setLtvConfig_onlyAdmin() public {
        vm.prank(lp);
        vm.expectRevert(IOwnLendingPool.OnlyAdmin.selector);
        pool.setLtvConfig(7000, 9000);
    }

    function test_setLtvConfig_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit IOwnLendingPool.LtvConfigUpdated(7000, 9000);
        vm.prank(Actors.ADMIN);
        pool.setLtvConfig(7000, 9000);
        assertEq(pool.ltvBps(), 7000);
        assertEq(pool.liquidationThresholdBps(), 9000);
    }

    function test_setLtvConfig_invalidBounds_reverts() public {
        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.InvalidLtvConfig.selector, 0, 9000));
        pool.setLtvConfig(0, 9000);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.InvalidLtvConfig.selector, 9001, 9000));
        pool.setLtvConfig(9001, 9000);
        vm.expectRevert(abi.encodeWithSelector(IOwnLendingPool.InvalidLtvConfig.selector, 7000, BPS + 1));
        pool.setLtvConfig(7000, BPS + 1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Debt token
    // ──────────────────────────────────────────────────────────

    function test_debtToken_notTransferable() public {
        _supply(borrower, SUPPLY);
        _borrow(borrower, 1e6);
        vm.startPrank(borrower);
        vm.expectRevert(OwnDebtToken.NonTransferable.selector);
        dUSDG.transfer(lp, 1);
        vm.expectRevert(OwnDebtToken.NonTransferable.selector);
        dUSDG.transferFrom(borrower, lp, 1);
        vm.stopPrank();
    }

    function test_debtToken_balanceMirrorsPoolDebt() public {
        _supply(borrower, SUPPLY);
        _borrow(borrower, 123_456e6);
        assertEq(dUSDG.balanceOf(borrower), pool.debtOf(borrower));
        assertEq(dUSDG.totalSupply(), pool.totalDebt());
    }

    // ──────────────────────────────────────────────────────────
    //  Solvency invariant (fuzz)
    // ──────────────────────────────────────────────────────────

    /// @dev After any supply → borrow → repay → withdraw sequence:
    ///      aToken.totalSupply() == availableLiquidity() + totalDebt().
    function test_fuzz_solvencyInvariant(uint256 s, uint256 b, uint256 r, uint256 w) public {
        s = bound(s, 1e6, SUPPLY);
        _supply(borrower, s);
        assertEq(aUSDG.totalSupply(), pool.availableLiquidity() + pool.totalDebt());

        b = bound(b, 1, s * LTV / BPS);
        _borrow(borrower, b);
        assertEq(aUSDG.totalSupply(), pool.availableLiquidity() + pool.totalDebt());

        r = bound(r, 1, b);
        vm.startPrank(borrower);
        usdg.approve(address(pool), type(uint256).max);
        pool.repay(address(usdg), r, 2, borrower);
        vm.stopPrank();
        assertEq(aUSDG.totalSupply(), pool.availableLiquidity() + pool.totalDebt());

        uint256 debt = pool.debtOf(borrower);
        uint256 minCollateral = debt == 0 ? 0 : (debt * BPS + LT - 1) / LT;
        uint256 headroom = s - minCollateral;
        if (headroom > 0 && pool.availableLiquidity() > 0) {
            w = bound(w, 1, headroom < pool.availableLiquidity() ? headroom : pool.availableLiquidity());
            vm.prank(borrower);
            pool.withdraw(address(usdg), w, borrower);
            assertEq(aUSDG.totalSupply(), pool.availableLiquidity() + pool.totalDebt());
        }
    }
}
