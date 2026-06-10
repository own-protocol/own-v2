// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";

import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {AssetConfig, BPS, PRECISION} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveDebtToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";

/// @title BorrowAndLiquidateFlow — End-to-end integration test
/// @notice Drives the full Phase 2 flow with real factories: deploy vault →
///         deploy borrow manager via factory → admin enableLending → register
///         pass-through → user borrows → time passes → price drops →
///         liquidator closes the position. Asserts dividend pass-through
///         routes correctly in the live setup.
contract BorrowAndLiquidateFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    EToken public eTSLA;
    MockAaveV3Pool public aavePool;
    MockAToken public awstETH;
    MockAaveDebtToken public usdcDebt;
    OwnVault public vault;
    BorrowManager public borrowManager;

    bytes32 constant ASSET = bytes32("TSLA");
    uint256 constant TSLA_PX = 250e18;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        // Aave: pool + reserves + debt token.
        aavePool = new MockAaveV3Pool();
        awstETH = MockAToken(aavePool.registerReserve(address(wstETH), "Aave wstETH", "awstETH", 18));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));
        usdc.mint(address(aavePool), 1_000_000e6); // seed liquidity

        // Protocol registry slots.
        address market = address(this); // act as MARKET so we can mint eTSLA in tests.
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), market);

        // Asset registry + eTSLA.
        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        eTSLA = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));

        AssetConfig memory cfg = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(ASSET, address(eTSLA), cfg);

        // Deploy + register the VaultManager before registering the vault (admin-gated).
        _deployVaultManager();

        vm.startPrank(Actors.ADMIN);
        vault = new OwnVault(address(awstETH), "Own awstETH", "owawstETH", address(protocolRegistry), address(this));
        vaultManager.registerVault(address(vault), bytes32("WSTETH"));

        borrowManager = new BorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            3500,
            _params()
        );
        vm.stopPrank();

        // Seed the vault with awstETH so the manager's debt cap is non-zero.
        // 1000 wstETH @ $4k = $4M. Cap at 35% LTV = $1.4M, plenty of headroom
        // for the test's $10k borrow.
        vm.prank(address(aavePool));
        awstETH.mint(address(vault), 1000e18);
        bytes32 collat = bytes32("WSTETH");
        _setOraclePrice(collat, 4000e18);
        AssetConfig memory wstCfg = AssetConfig({
            activeToken: address(awstETH),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(collat, address(awstETH), wstCfg);
        // Refresh the vault's collateral mark in the VaultManager (keeper price pull).
        vaultManager.pullCollateralPrice(address(vault));

        // Payment token is now a global VaultManager setting.
        _setPaymentToken(address(usdc));

        _enableAaveLending(address(vault), address(borrowManager), address(usdcDebt));
        // Borrowing is enabled for every asset by default.

        _setOraclePrice(ASSET, TSLA_PX);
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    /// @dev End-to-end: borrow → dividend deposit while collateral in custody →
    ///      price crashes → liquidate. Verifies position close, Aave debt
    ///      cleared, liquidator gets the eTokens but NOT the dividends — those are
    ///      forfeited (Option A) and sweep to the vault manager.
    function test_endToEnd_borrowDividendCrashLiquidate() public {
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6; // 40% LTV at $250.

        // Borrower opens.
        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.MINTER1), stable);
        assertEq(eTSLA.balanceOf(address(borrowManager)), eAmt);
        assertEq(aavePool.debtOf(address(vault), address(usdc)), stable);

        // Dividend lands while the manager holds the collateral.
        uint256 reward = 500e6;
        usdc.mint(address(this), reward);
        usdc.approve(address(eTSLA), reward);
        eTSLA.depositRewards(reward);

        // Lender's accrued bucket holds all of `reward` (sole holder of supply).
        assertEq(eTSLA.claimableRewards(address(borrowManager)), reward);

        // Time passes → manager-side interest accrues. Live Aave rate stays
        // at 0 in the mock pool unless we set it; floor stays at 0 too. With
        // base premium 1%, debt grows ~0.5% over half a year.
        skip(180 days);

        uint256 debtAfterTime = borrowManager.debtOf(Actors.MINTER1, ASSET);
        assertGt(debtAfterTime, stable, "debt grew with time");

        // Price crashes — make the position liquidatable (threshold 80%). The
        // new liquidation guard reverts when the bonus-based seize exceeds the
        // collateral, so pick a crash price where seizing for the full debt
        // exactly clears the 100 eTSLA collateral (full close, zero residual).
        // seize = debtUSD * (1 + bonus) / px == eAmt  →  px = debtUSD * 1.05 / eAmt.
        uint256 liqDebt = borrowManager.debtOf(Actors.MINTER1, ASSET);
        uint256 withBonusUSD = (liqDebt * 1e12) * (BPS + 500) / BPS; // 6-dec USDC → 18-dec USD
        uint256 crashPx = withBonusUSD * PRECISION / eAmt + 1; // round px up so seize <= eAmt (no revert)
        _setOraclePrice(ASSET, crashPx);

        // Liquidator pulls funds, repays full debt, seizes the collateral.
        usdc.mint(Actors.LIQUIDATOR, liqDebt);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), liqDebt);
        borrowManager.liquidate(Actors.MINTER1, ASSET, liqDebt, _priceData(crashPx));
        vm.stopPrank();

        // Position closed.
        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.principal, 0);

        // Aave debt cleared on the vault.
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0);

        // Liquidator received essentially all the collateral; borrower ~0 residual.
        assertApproxEqAbs(eTSLA.balanceOf(Actors.LIQUIDATOR), eAmt, 1, "liquidator gets all collateral");
        assertApproxEqAbs(eTSLA.balanceOf(Actors.MINTER1), 0, 1, "no residual to borrower");

        // Option A: dividends are forfeited — the liquidator gets none; the manager retains them.
        assertEq(eTSLA.claimableRewards(Actors.LIQUIDATOR), 0, "liquidator gets no dividends");
        assertApproxEqAbs(eTSLA.claimableRewards(address(borrowManager)), reward, 1, "manager retains dividends");

        // The forfeited dividends sweep to the vault manager (this contract).
        uint256 vmBefore = usdc.balanceOf(address(this));
        borrowManager.sweepDividends(address(eTSLA));
        assertApproxEqAbs(usdc.balanceOf(address(this)) - vmBefore, reward, 1, "dividends swept to VM");
        assertEq(eTSLA.claimableRewards(address(borrowManager)), 0, "manager bucket drained");
    }

    /// @dev End-to-end: borrow → dividend earned during borrow → repay in full. Option A: the
    ///      dividend is forfeited by the borrower and sweeps to the vault manager.
    function test_endToEnd_borrowDividendRepay_dividendsForfeitedToVM() public {
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6;

        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        // Dividend during custody.
        uint256 reward = 200e6;
        usdc.mint(address(this), reward);
        usdc.approve(address(eTSLA), reward);
        eTSLA.depositRewards(reward);

        // Repay in full.
        usdc.mint(Actors.MINTER1, stable);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), stable);
        borrowManager.repay(ASSET, type(uint256).max);
        vm.stopPrank();

        assertEq(eTSLA.balanceOf(Actors.MINTER1), eAmt, "collateral returned");
        // Borrower forfeits dividends earned during the borrow window; the manager retains them.
        assertEq(eTSLA.claimableRewards(Actors.MINTER1), 0, "borrower forfeits dividends");
        assertApproxEqAbs(eTSLA.claimableRewards(address(borrowManager)), reward, 1, "manager retains dividends");

        // The forfeited dividends sweep to the vault manager (this contract).
        uint256 vmBefore = usdc.balanceOf(address(this));
        borrowManager.sweepDividends(address(eTSLA));
        assertApproxEqAbs(usdc.balanceOf(address(this)) - vmBefore, reward, 1, "dividends swept to VM");
        assertEq(eTSLA.claimableRewards(address(borrowManager)), 0, "manager bucket drained");
    }

    /// @dev A 3:1 split mid-borrow: the position stays in the legacy token, stays correctly valued
    ///      (HF preserved), and repay returns the original (legacy) token.
    function test_borrowAcrossSplit_positionContinuesInLegacyToken() public {
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6;
        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        uint256 hfBefore = borrowManager.healthFactor(Actors.MINTER1, ASSET, TSLA_PX);

        // 3:1 split — new active token, ratio 3, active oracle price drops to ~1/3.
        vm.prank(Actors.ADMIN);
        assetRegistry.migrateToken(ASSET, makeAddr("eTSLAv2"), 3e18);
        uint256 newPx = TSLA_PX / 3;

        // Legacy collateral valued at ratio x newPx == its pre-split value: HF preserved.
        uint256 hfAfter = borrowManager.healthFactor(Actors.MINTER1, ASSET, newPx);
        assertApproxEqAbs(hfAfter, hfBefore, 1e9, "HF preserved across split");

        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.collateralToken, address(eTSLA), "collateral token snapshotted");

        // Repay in full → original (legacy) eTSLA returned; borrower converts separately.
        usdc.mint(Actors.MINTER1, stable);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), stable);
        borrowManager.repay(ASSET, type(uint256).max);
        vm.stopPrank();
        assertEq(eTSLA.balanceOf(Actors.MINTER1), eAmt, "original (legacy) collateral returned");
    }

    /// @dev A legacy-collateral position is liquidatable at its effective (ratio-scaled) price, and
    ///      the liquidator seizes the original (legacy) token.
    function test_liquidateLegacyPosition_atEffectivePrice() public {
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6;
        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        // 3:1 split, then the active price crashes to $40 (effective = $120 for the legacy token).
        vm.prank(Actors.ADMIN);
        assetRegistry.migrateToken(ASSET, makeAddr("eTSLAv2"), 3e18);
        uint256 activeCrashPx = 40e18; // effective 120e18 → HF 0.96 → partial close (close factor 50%)
        _setOraclePrice(ASSET, activeCrashPx);

        // Partial repay of 4000 USDC → seize = 4000 * 1.05 / 120 = 35 eTSLA (legacy).
        uint256 repay = 4000e6;
        usdc.mint(Actors.LIQUIDATOR, repay);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), repay);
        borrowManager.liquidate(Actors.MINTER1, ASSET, repay, _priceData(activeCrashPx));
        vm.stopPrank();

        assertEq(eTSLA.balanceOf(Actors.LIQUIDATOR), 35e18, "liquidator seized legacy collateral");
        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.eTokenCollateral, eAmt - 35e18, "collateral reduced");
        assertEq(pos.collateralToken, address(eTSLA), "still legacy token");
    }
}
