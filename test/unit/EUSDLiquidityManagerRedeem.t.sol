// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEUSDLiquidityManager} from "../../src/interfaces/IEUSDLiquidityManager.sol";
import {LiquidityManagerSetup, deployEUSDLiquidityManager} from "../helpers/LiquidityManagerSetup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EUSDLiquidityManagerRedeemTest — redemption against LP positions, and unused-mint accounting
contract EUSDLiquidityManagerRedeemTest is LiquidityManagerSetup {
    address internal redeemer = address(uint160(uint256(keccak256("redeemer"))));

    function setUp() public override {
        super.setUp();
        giveEusd(redeemer, 1_000_000e18);
        giveEusd(address(ledger), 100_000e18);
    }

    function _owners(
        address a
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _owners(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _redeem(address[] memory owners, uint256 amount) internal returns (uint256 assetOut, uint256 burned) {
        vm.prank(redeemer);
        return manager.redeem(SPY_POOL, owners, amount, 0);
    }

    /// @dev Move only the SPY pool, as a dump into the pool does; the oracle stays.
    function _movePool(
        uint256 price
    ) internal {
        ledger.setPrice(spyKey, address(spy), price);
    }

    // ──────────────────────────────────────────────────────────
    //  Eligibility
    // ──────────────────────────────────────────────────────────

    function test_redeem_inRange_notEligible() public {
        openSpy(alice, 10e18, 3500e18);
        vm.expectRevert(IEUSDLiquidityManager.NothingToRedeem.selector);
        _redeem(_owners(alice), 1000e18);
    }

    function test_redeem_poolDump_eligible_paysOraclePrice() public {
        openSpy(alice, 10e18, 3500e18);
        _movePool(600e18);
        uint256 debtBefore = manager.currentDebt(SPY_POOL, alice);
        uint256 ratioBefore = manager.collateralRatioBps(SPY_POOL, alice);
        uint256 supplyBefore = eusd.totalSupply();
        uint256 eusdBefore = eusd.balanceOf(redeemer);

        (uint256 assetOut, uint256 burned) = _redeem(_owners(alice), 1000e18);

        IEUSDLiquidityManager.Position memory p = manager.getPosition(SPY_POOL, alice);
        assertEq(p.debt, debtBefore - 1000e18, "debt cleared");
        assertEq(eusdBefore - eusd.balanceOf(redeemer), burned, "burned from redeemer");
        assertEq(supplyBefore - eusd.totalSupply(), 1000e18, "supply falls by the cleared debt");
        assertEq(assetOut, Math.mulDiv(burned, 1e18, SPY_PRICE), "asset at the oracle price, rounded down");
        assertEq(spy.balanceOf(redeemer), assetOut);
        assertGt(manager.collateralRatioBps(SPY_POOL, alice), ratioBefore, "ratio rises");
        assertEq(manager.totalDebt(), p.debt);
    }

    function test_redeem_oracleFall_eligible() public {
        openSpy(alice, 10e18, 3500e18);
        moveSpy(600e18);
        (uint256 assetOut, uint256 burned) = _redeem(_owners(alice), 500e18);
        assertGt(burned, 0);
        assertEq(assetOut, Math.mulDiv(burned, 1e18, 600e18));
    }

    function test_redeem_cutoff_followsParam() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(admin);
        manager.setRedeemParams(0, REDEEM_PRICE_MAX_AGE);
        (, uint256 burned) = _redeem(_owners(alice), 1000e18);
        assertGt(burned, 0, "a zero cutoff makes an in-range position redeemable");

        vm.prank(admin);
        manager.setRedeemParams(10_000, REDEEM_PRICE_MAX_AGE);
        _movePool(600e18);
        vm.expectRevert(IEUSDLiquidityManager.NothingToRedeem.selector);
        _redeem(_owners(alice), 1000e18);
        _movePool(590e18);
        (, burned) = _redeem(_owners(alice), 1000e18);
        assertGt(burned, 0, "a 100% cutoff still takes a range below its lower tick");
    }

    function test_redeem_liquidatable_skipped() public {
        openSpy(alice, 10e18, 3500e18);
        uint256 price = SPY_PRICE;
        while (!manager.isLiquidatable(SPY_POOL, alice)) {
            price -= 10e18;
            moveSpy(price);
        }
        vm.expectRevert(IEUSDLiquidityManager.NothingToRedeem.selector);
        _redeem(_owners(alice), 100e18);
    }

    function test_redeem_noDebt_skipped() public {
        vm.prank(alice);
        manager.deposit(SPY_POOL, 1e18);
        vm.expectRevert(IEUSDLiquidityManager.NothingToRedeem.selector);
        _redeem(_owners(alice), 100e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Amounts
    // ──────────────────────────────────────────────────────────

    function test_redeem_full_clearsDebt() public {
        openSpy(alice, 10e18, 3500e18);
        _movePool(600e18);
        uint256 debt = manager.currentDebt(SPY_POOL, alice);
        (uint256 assetOut, uint256 burned) = _redeem(_owners(alice), type(uint128).max);
        IEUSDLiquidityManager.Position memory p = manager.getPosition(SPY_POOL, alice);
        assertEq(p.debt, 0);
        assertLe(burned, debt, "never more than the debt");
        assertEq(assetOut, Math.mulDiv(burned, 1e18, SPY_PRICE));
        assertEq(manager.totalDebt(), 0);
        (,, uint128 held) = FablesVault(p.vault).range();
        assertGt(held, 0, "only the range the payout needed was removed");
    }

    function test_redeem_usesIdleAssetFirst() public {
        openSpy(alice, 10e18, 3500e18);
        vm.prank(alice);
        manager.deposit(SPY_POOL, 20e18);
        _movePool(600e18);
        address vault = manager.getPosition(SPY_POOL, alice).vault;
        (,, uint128 heldBefore) = FablesVault(vault).range();
        (uint256 assetOut,) = _redeem(_owners(alice), 1000e18);
        (,, uint128 heldAfter) = FablesVault(vault).range();
        assertEq(heldAfter, heldBefore, "range untouched");
        assertEq(spy.balanceOf(redeemer), assetOut);
    }

    function test_redeem_minDebt_clamp() public {
        openSpy(alice, 10e18, 3500e18);
        _movePool(600e18);
        uint256 debt = manager.currentDebt(SPY_POOL, alice);
        _redeem(_owners(alice), debt - 50e18);
        assertEq(manager.getPosition(SPY_POOL, alice).debt, MIN_DEBT, "leaves exactly minDebt");
    }

    function test_redeem_multipleOwners_inOrder_skipsIneligible() public {
        openSpy(alice, 10e18, 3500e18);
        // Bob's range sits well below the price, so it holds only eUSD and is never redeemable.
        (int24 lower, int24 upper) = spyRange(400e18, 500e18);
        vm.prank(bob);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: SPY_POOL,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 3e18,
                assetMax: 0,
                eusdMax: 2000e18,
                staked: true
            })
        );
        _movePool(600e18);
        uint256 bobDebt = manager.currentDebt(SPY_POOL, bob);
        uint256 aliceDebt = manager.currentDebt(SPY_POOL, alice);
        _redeem(_owners(bob, alice), 1000e18);
        assertEq(manager.getPosition(SPY_POOL, bob).debt, bobDebt, "bob untouched");
        assertEq(manager.getPosition(SPY_POOL, alice).debt, aliceDebt - 1000e18);
    }

    function test_redeem_slippage_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        _movePool(600e18);
        vm.expectPartialRevert(IEUSDLiquidityManager.SlippageExceeded.selector);
        vm.prank(redeemer);
        manager.redeem(SPY_POOL, _owners(alice), 1000e18, 10e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Price and switches
    // ──────────────────────────────────────────────────────────

    function test_redeem_stalePrice_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        _movePool(600e18);
        vm.warp(block.timestamp + REDEEM_PRICE_MAX_AGE + 1);
        vm.expectPartialRevert(IEUSDLiquidityManager.StaleMintPrice.selector);
        _redeem(_owners(alice), 1000e18);
        oracle.setPrice(SPY, SPY_PRICE);
        _redeem(_owners(alice), 1000e18);
    }

    function test_redeem_disabled_reverts() public {
        openSpy(alice, 10e18, 3500e18);
        _movePool(600e18);
        vm.prank(admin);
        manager.setRedeemParams(REDEEM_SHARE, 0);
        vm.expectRevert(IEUSDLiquidityManager.RedeemDisabled.selector);
        _redeem(_owners(alice), 1000e18);
    }

    function test_redeem_zeroAmount_reverts() public {
        vm.expectRevert(IEUSDLiquidityManager.ZeroAmount.selector);
        _redeem(_owners(alice), 0);
    }

    function test_setRedeemParams() public {
        vm.expectRevert(IEUSDLiquidityManager.OnlyAdmin.selector);
        manager.setRedeemParams(5000, 60);
        vm.prank(admin);
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        manager.setRedeemParams(10_001, 60);
        vm.expectEmit(address(manager));
        emit IEUSDLiquidityManager.RedeemParamsSet(5000, 60);
        vm.prank(admin);
        manager.setRedeemParams(5000, 60);
        IEUSDLiquidityManager.RiskParams memory params = manager.riskParams();
        assertEq(params.redeemMinAssetShareBps, 5000);
        assertEq(params.redeemPriceMaxAge, 60);
    }

    function test_initialize_rejectsShareAbove100() public {
        IEUSDLiquidityManager.RiskParams memory params = defaultParams();
        params.redeemMinAssetShareBps = 10_001;
        vm.expectRevert(IEUSDLiquidityManager.InvalidRiskParams.selector);
        this.deployWith(params);
    }

    function deployWith(
        IEUSDLiquidityManager.RiskParams memory params
    ) external {
        deployEUSDLiquidityManager(address(registry), address(eusd), params);
    }

    function test_redeem_usdgPool_sixDecimals() public {
        (int24 lower, int24 upper) = usdRange(0.99e18, 1.01e18);
        vm.prank(alice);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: USD_POOL,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 2000e6,
                assetMax: 2000e6,
                eusdMax: 1000e18,
                staked: true
            })
        );
        // USDG cheap against eUSD in the pool: the range fills with USDG.
        ledger.setPrice(usdKey, address(usdg), 0.985e18);
        uint256 debt = manager.currentDebt(USD_POOL, alice);
        vm.prank(redeemer);
        (uint256 assetOut, uint256 burned) = manager.redeem(USD_POOL, _owners(alice), 300e18, 0);
        assertEq(manager.getPosition(USD_POOL, alice).debt, debt - 300e18);
        assertEq(assetOut, burned / 1e12, "6-decimal asset at $1");
        assertEq(usdg.balanceOf(redeemer), assetOut);
    }

    // ──────────────────────────────────────────────────────────
    //  Unused mint is principal, not fees
    // ──────────────────────────────────────────────────────────

    function test_add_unusedMint_keepsFeesAccrued() public {
        openSpy(alice, 10e18, 3500e18);
        vm.warp(block.timestamp + 30 days);
        oracle.setPrice(SPY, SPY_PRICE);
        manager.accrue(SPY_POOL, alice);
        IEUSDLiquidityManager.Position memory before = manager.getPosition(SPY_POOL, alice);
        assertGt(before.feesAccrued, 0);

        (int24 lower, int24 upper) = spyRange(595e18, 805e18);
        vm.prank(alice);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: SPY_POOL,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 1e18,
                assetMax: 1e18,
                eusdMax: 2000e18,
                staked: true
            })
        );
        IEUSDLiquidityManager.Position memory afterAdd = manager.getPosition(SPY_POOL, alice);
        assertEq(afterAdd.feesAccrued, before.feesAccrued, "fees stay fees");
        assertLt(afterAdd.debt - before.debt, 2000e18, "only the eUSD the range used is new debt");
        assertEq(eusd.balanceOf(afterAdd.vault), 0, "unused mint burned");
        assertEq(manager.totalDebt(), afterAdd.debt);
    }

    function test_add_unusedMint_keepsMinDebt() public {
        (int24 lower, int24 upper) = spyRange(595e18, 805e18);
        vm.prank(alice);
        manager.addLiquidity(
            IEUSDLiquidityManager.AddLiquidityParams({
                poolId: SPY_POOL,
                tickLower: lower,
                tickUpper: upper,
                assetDeposit: 1e18,
                assetMax: 0.1e18,
                eusdMax: 500e18,
                staked: true
            })
        );
        IEUSDLiquidityManager.Position memory p = manager.getPosition(SPY_POOL, alice);
        assertEq(p.debt, MIN_DEBT, "debt held at minDebt");
        assertGt(eusd.balanceOf(p.vault), 0, "the rest stays idle as collateral");
    }
}

interface FablesVault {
    function range() external view returns (int24, int24, uint128);
}
