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
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title BorrowBrickPoC — regression coverage for the zero-vault-Aave-debt close brick (H-09) and
///        the seize-granularity bad-debt strand (H-10).
/// @notice H-09 (FIXED): every close path (repay / liquidate / absorbBadDebt / settleHaltedPosition)
///         routes through `BorrowManager._repayAaveAndSweep`. It used to call `IAaveV3Pool.repay`
///         unconditionally, so once the vault's pooled Aave debt was driven to 0 — which ANYONE can do
///         by repaying it on the vault's behalf — while a book position was still open, real Aave
///         reverted `NO_DEBT_OF_SELECTED_TYPE` and the position could never be closed (collateral
///         locked; permanent during a halt, where `borrow()` can't recreate the debt). The fix skips
///         the Aave call when the vault owes nothing (the full amount is surplus then). These tests run
///         against the faithful `MockAaveV3Pool` (reverts on zero-debt repay, mirroring production Aave)
///         and assert the close paths now SUCCEED at zero vault debt.
contract BorrowBrickPoCTest is BaseTest {
    AssetRegistry public assetRegistry;
    EToken public eTSLA;
    MockAaveV3Pool public aavePool;
    MockAToken public awstETH;
    MockAaveDebtToken public usdcDebt;
    OwnVault public vault;
    BorrowManager public borrowManager;

    uint256 constant TARGET_LTV_BPS = 3500;
    bytes32 constant ASSET = bytes32("TSLA");
    uint256 constant TSLA_PX = 250e18;

    address public mockMarket;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        mockMarket = address(this); // acts as MARKET (mints/burns eTokens, redeemHalted shim).

        usdc = new MockERC20("USD Coin", "USDC", 6);
        aavePool = new MockAaveV3Pool();
        awstETH = MockAToken(aavePool.registerReserve(address(wstETH), "Aave wstETH", "awstETH", 18));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        eTSLA = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));
        vm.label(address(eTSLA), "eTSLA");

        AssetConfig memory cfg = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(ASSET, address(eTSLA), cfg);

        vm.prank(Actors.ADMIN);
        vault = new OwnVault(address(awstETH), "Own awstETH", "owawstETH", address(protocolRegistry), address(this));

        _deployVaultManager();
        _setPaymentToken(address(usdc));
        vm.prank(Actors.ADMIN);
        vaultManager.registerVault(address(vault), bytes32("WSTETH"));

        _seedVaultCollateral(1_000_000e18);

        borrowManager = new BorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            TARGET_LTV_BPS,
            _params()
        );
        vm.label(address(borrowManager), "BorrowManager");

        _enableAaveLending(address(vault), address(borrowManager), address(usdcDebt));
        vm.prank(Actors.ADMIN);
        assetRegistry.setLendingVaultAllowed(ASSET, address(vault), true);

        usdc.mint(address(aavePool), 1_000_000e6);

        _setOraclePrice(ASSET, TSLA_PX);
        _pullAssetPrice(ASSET);
        _setTreasury(Actors.FEE_RECIPIENT);
    }

    function _seedVaultCollateral(
        uint256 usdValue
    ) internal {
        bytes32 collat = bytes32("WSTETH");
        _setOraclePrice(collat, 4000e18);
        uint256 amount = (usdValue * PRECISION) / 4000e18;
        vm.prank(address(aavePool));
        awstETH.mint(address(vault), amount);

        AssetConfig memory wstCfg = AssetConfig({
            activeToken: address(awstETH),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(collat, address(awstETH), wstCfg);
        vaultManager.pullCollateralPrice(address(vault));
    }

    function _giveTSLA(address to, uint256 amount) internal {
        eTSLA.mint(to, amount);
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    /// @dev Open a borrow for `borrower`: `eAmt` eTSLA collateral, borrow `stable` USDC.
    function _open(address borrower, uint256 eAmt, uint256 stable) internal {
        _giveTSLA(borrower, eAmt);
        vm.startPrank(borrower);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    function _fullClose(
        address borrower
    ) internal {
        uint256 owed = borrowManager.debtOf(borrower, ASSET);
        usdc.mint(borrower, owed);
        vm.startPrank(borrower);
        usdc.approve(address(borrowManager), owed);
        borrowManager.repay(ASSET, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Permissionlessly repay the vault's ENTIRE pooled Aave debt on its behalf (Aave allows
    ///      repay-on-behalf-of-anyone), zeroing it WITHOUT touching the manager's book — the H-09 trigger.
    function _zeroVaultAaveDebt(
        address who
    ) internal {
        uint256 owed = aavePool.debtOf(address(vault), address(usdc));
        usdc.mint(who, owed);
        vm.startPrank(who);
        usdc.approve(address(aavePool), owed);
        aavePool.repay(address(usdc), owed, 2, address(vault));
        vm.stopPrank();
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "vault Aave debt zeroed");
    }

    // ──────────────────────────────────────────────────────────
    //  Market shim — this test contract IS the registered MARKET. settleHaltedPosition
    //  calls market.redeemHalted(); implement it minimally so the settle path reaches
    //  _repayAaveAndSweep instead of reverting early.
    // ──────────────────────────────────────────────────────────

    /// @dev Burn the caller's (manager's) eTokens and pay USDC proceeds at the halt price,
    ///      mirroring OwnMarket.redeemHalted.
    function redeemHalted(bytes32, uint256 eTokenAmount) external returns (uint256 payout) {
        eTSLA.burn(msg.sender, eTokenAmount); // caller is the BorrowManager
        payout = (eTokenAmount * TSLA_PX) / 1e18 / 1e12; // 18-dec eToken * 18-dec px -> 6-dec USDC
        usdc.mint(msg.sender, payout); // fund the manager so it can repay
    }

    /// @dev Unused here (no legacy tokens), but settleHaltedPosition references it.
    function convertLegacy(bytes32, address, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    // ──────────────────────────────────────────────────────────
    //  H-09 — harness fidelity: the mock now mirrors real Aave (reverts on zero-debt repay).
    // ──────────────────────────────────────────────────────────

    /// @dev The faithful MockAaveV3Pool reverts `NoDebtOfSelectedType` on a zero-debt repay, mirroring
    ///      Aave V3 `ValidationLogic.validateRepay` ('39'). The old mock returned 0, which is exactly
    ///      why the suite never observed this brick. This locks the corrected behavior in.
    function test_h09_mockRepay_revertsOnZeroDebt() public {
        MockAaveV3Pool pool = new MockAaveV3Pool();
        pool.deployVariableDebtToken(address(usdc));
        assertEq(pool.debtOf(address(vault), address(usdc)), 0, "no debt");
        vm.expectRevert(MockAaveV3Pool.NoDebtOfSelectedType.selector);
        pool.repay(address(usdc), 1000e6, 2, address(vault));
    }

    // ──────────────────────────────────────────────────────────
    //  H-09 — every close path still works once the pooled Aave debt is externally zeroed.
    // ──────────────────────────────────────────────────────────

    /// @dev Attacker zeroes the vault's Aave debt while MINTER1 is open; the borrower can STILL repay
    ///      and reclaim collateral (the fix skips the Aave call). The repaid amount is pure surplus
    ///      (the vault owed Aave nothing) and sweeps to the VM.
    function test_h09_externalRepay_borrowerStillCloses() public {
        uint256 eAmt = 100e18;
        _open(Actors.MINTER1, eAmt, 10_000e6);
        _zeroVaultAaveDebt(Actors.ATTACKER);
        assertGt(borrowManager.debtOf(Actors.MINTER1, ASSET), 0, "book still open after external repay");

        uint256 owed = borrowManager.debtOf(Actors.MINTER1, ASSET);
        uint256 vmBefore = usdc.balanceOf(vault.manager());
        usdc.mint(Actors.MINTER1, owed);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), owed);
        uint256 released = borrowManager.repay(ASSET, type(uint256).max); // no longer reverts
        vm.stopPrank();

        assertEq(released, eAmt, "collateral released to borrower");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), eAmt, "borrower got collateral back");
        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).principal, 0, "position closed");
        assertEq(usdc.balanceOf(vault.manager()) - vmBefore, owed, "full repay swept to VM as surplus");
    }

    /// @dev With the vault's Aave debt zeroed, a liquidator can still wind down an underwater position
    ///      (seizes collateral, repay sweeps to the VM) — previously this reverted `NO_DEBT`.
    function test_h09_externalRepay_liquidateStillWorks() public {
        _open(Actors.MINTER1, 100e18, 10_000e6);
        _zeroVaultAaveDebt(Actors.ATTACKER);

        uint256 crashPx = 105e18; // hf < 1
        _setOraclePrice(ASSET, crashPx);

        uint256 repay = 5000e6;
        usdc.mint(Actors.LIQUIDATOR, repay);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), repay);
        borrowManager.liquidate(Actors.MINTER1, ASSET, repay, _priceData(crashPx)); // no longer reverts
        vm.stopPrank();

        assertGt(eTSLA.balanceOf(Actors.LIQUIDATOR), 0, "liquidator seized collateral");
        assertLt(borrowManager.debtOf(Actors.MINTER1, ASSET), 10_000e6, "debt reduced by the liquidation");
    }

    /// @dev With the vault's Aave debt zeroed, the operator can still absorb a stripped (zero-collateral)
    ///      bad-debt residual — the cleanup path is no longer bricked.
    function test_h09_externalRepay_absorbBadDebtStillWorks() public {
        _open(Actors.MINTER1, 100e18, 10_000e6);

        // Strip MINTER1 to a $2k zero-collateral residual via an $8k liquidation at $84.
        _setOraclePrice(ASSET, 84e18);
        usdc.mint(Actors.LIQUIDATOR, 8000e6);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), 8000e6);
        borrowManager.liquidate(Actors.MINTER1, ASSET, 8000e6, _priceData(84e18));
        vm.stopPrank();
        _setOraclePrice(ASSET, TSLA_PX);

        uint256 residual = borrowManager.debtOf(Actors.MINTER1, ASSET);
        assertEq(residual, 2000e6, "zero-collateral residual");
        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).eTokenCollateral, 0, "no collateral");

        _zeroVaultAaveDebt(Actors.ATTACKER);

        usdc.mint(Actors.ADMIN, residual);
        vm.startPrank(Actors.ADMIN);
        usdc.approve(address(borrowManager), residual);
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, residual, _priceData(4000e18)); // no longer reverts
        vm.stopPrank();

        assertEq(borrowManager.debtOf(Actors.MINTER1, ASSET), 0, "bad-debt residual cleared");
    }

    /// @dev The case that was PERMANENT before the fix: with the asset halted, `borrow()` cannot recreate
    ///      Aave debt, so a zeroed pool left `settleHaltedPosition` (the only wind-down path) bricked
    ///      forever. Post-fix, the halt settlement succeeds at zero Aave debt.
    function test_h09_haltedSettle_worksAtZeroVaultDebt() public {
        uint256 eAmt = 100e18;
        _open(Actors.MINTER1, eAmt, 10_000e6);
        _zeroVaultAaveDebt(Actors.ATTACKER);
        _haltAsset(ASSET, TSLA_PX);

        // borrow() is blocked while halted — the old recovery lever is unavailable...
        _giveTSLA(Actors.LP2, 100e18);
        vm.startPrank(Actors.LP2);
        eTSLA.approve(address(borrowManager), 100e18);
        vm.expectRevert(IBorrowManager.VaultEffectivelyHalted.selector);
        borrowManager.borrow(ASSET, 100e18, 10_000e6, _priceData(TSLA_PX));
        vm.stopPrank();

        // ...yet settleHaltedPosition now winds the position down cleanly at zero Aave debt.
        borrowManager.settleHaltedPosition(Actors.MINTER1, ASSET); // no longer reverts
        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).principal, 0, "position settled");
        // Debt covered by 40 eTSLA at $250; the remaining 60 eTSLA returned to the borrower.
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 60e18, "residual collateral returned to borrower");
    }

    // ──────────────────────────────────────────────────────────
    //  Sanity — normal multi-borrower full close still settles cleanly (the pool can never fall below an
    //  open position's own principal via repays alone; premium surplus sweeps to the VM).
    // ──────────────────────────────────────────────────────────

    function test_normalMultiBorrowerFullClose_succeeds() public {
        _open(Actors.MINTER1, 100e18, 10_000e6);
        _open(Actors.MINTER2, 100e18, 10_000e6);
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 20_000e6, "pooled = 20k");

        aavePool.setCurrentVariableBorrowRate(address(usdc), uint128(10 * 1e25)); // 10% APR
        skip(365 days);
        borrowManager.accrue();

        uint256 book1 = borrowManager.debtOf(Actors.MINTER1, ASSET);
        uint256 book2 = borrowManager.debtOf(Actors.MINTER2, ASSET);
        uint256 pooled = aavePool.debtOf(address(vault), address(usdc));
        assertGt(book1 + book2, pooled, "sum of books exceeds pool by accrued premium");

        _fullClose(Actors.MINTER1);
        uint256 poolAfter1 = aavePool.debtOf(address(vault), address(usdc));
        assertEq(poolAfter1, pooled - book1, "pool reduced by full book1");
        assertGt(book2, poolAfter1, "last borrower book > remaining pool (premium overflow)");

        uint256 vmBefore = usdc.balanceOf(vault.manager());
        _fullClose(Actors.MINTER2);
        assertEq(borrowManager.positionOf(Actors.MINTER2, ASSET).principal, 0, "last position closed cleanly");
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "pool to zero AFTER the last close");
        assertGt(usdc.balanceOf(vault.manager()), vmBefore, "premium surplus swept to VM on the last close");
    }

    // ──────────────────────────────────────────────────────────
    //  H-10 (FIXED) — liquidation caps the seize at remaining collateral, so a stranded sub-seize-unit
    //  dust crumb can be swept to exactly 0 and the residual bad debt absorbed. Distinct from H-09: the
    //  pooled Aave debt stays positive throughout.
    // ──────────────────────────────────────────────────────────

    /// @dev `seizeAmount` floors and scales linearly, so a profitable liquidation of a deeply underwater
    ///      position strands a sub-step crumb `0 < r < seize(1 unit)`. Pre-fix that crumb was unseizable
    ///      (`liquidate` reverted) and un-absorbable (`absorbBadDebt` requires zero collateral), stranding
    ///      the residual bad debt forever. Post-fix a tiny follow-up liquidation caps the seize at the
    ///      crumb -> collateral exactly 0, after which `absorbBadDebt` clears the residual.
    function test_h10_strandedDust_clearedThenAbsorbed() public {
        uint256 collat = 100e18;
        _open(Actors.MINTER1, collat, 17_000e6);

        uint256 crashPx = 100e18; // collateral worth $10k vs $17k debt -> deeply underwater
        _setOraclePrice(ASSET, crashPx);

        // A profitable liquidation maximizes collateral-per-dollar and strands a dust crumb (unchanged).
        uint256 collateralUSD18 = collat * crashPx / PRECISION; // $10,000 (18-dec)
        uint256 bonus = borrowManager.liquidationBonusBps(); // 500 (5%)
        uint256 maxRepay = collateralUSD18 * BPS / (BPS + bonus) / 1e12; // ~$9,523.80 (6-dec USDC)
        usdc.mint(Actors.LIQUIDATOR, maxRepay);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), maxRepay);
        borrowManager.liquidate(Actors.MINTER1, ASSET, maxRepay, _priceData(crashPx));
        vm.stopPrank();

        uint256 dust = borrowManager.positionOf(Actors.MINTER1, ASSET).eTokenCollateral;
        assertGt(dust, 0, "sub-step dust crumb stranded by the profitable liquidation");
        assertLt(dust, 0.0001e18, "crumb is negligible (< $0.01-worth)");

        // FIX: a tiny follow-up liquidation caps the seize at the crumb -> collateral to exactly 0.
        usdc.mint(Actors.LIQUIDATOR, 1e6);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), 1e6);
        borrowManager.liquidate(Actors.MINTER1, ASSET, 1e6, _priceData(crashPx)); // caps, no revert
        vm.stopPrank();
        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).eTokenCollateral, 0, "crumb seized -> zero collateral");

        // absorbBadDebt now succeeds on the zero-collateral residual.
        uint256 residual = borrowManager.debtOf(Actors.MINTER1, ASSET);
        assertGt(residual, 5000e6, "meaningful residual bad debt remains to absorb");
        usdc.mint(Actors.ADMIN, residual);
        vm.startPrank(Actors.ADMIN);
        usdc.approve(address(borrowManager), residual);
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, residual, _priceData(4000e18)); // no longer reverts
        vm.stopPrank();
        assertEq(borrowManager.debtOf(Actors.MINTER1, ASSET), 0, "bad debt absorbed -- H-10 cleared");
    }
}
