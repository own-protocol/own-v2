// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";

import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";

import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {IEToken} from "../../src/interfaces/IEToken.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, BPS, PRECISION} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveDebtToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BorrowManager Unit Tests
/// @notice Covers borrow / repay / liquidate flows, eligibility gating,
///         interest accrual, and admin guards.
contract BorrowManagerTest is BaseTest {
    AssetRegistry public assetRegistry;
    EToken public eTSLA;
    MockAaveV3Pool public aavePool;
    MockAToken public awstETH;
    MockAaveDebtToken public usdcDebt;
    OwnVault public vault;
    BorrowManager public borrowManager;

    uint256 constant TARGET_LTV_BPS = 3500;

    bytes32 constant ASSET = bytes32("TSLA");
    uint256 constant TSLA_PX = 250e18; // $250 / TSLA, 18 decimals.

    address public mockMarket;

    // Default rate params: base 1%, kink 80%, slope1 4%, slope2 75%.
    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        mockMarket = address(this); // this contract acts as MARKET (mints/burns eTokens).

        // 1) Asset registry + USDC + Aave wiring.
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aavePool = new MockAaveV3Pool();
        awstETH = MockAToken(aavePool.registerReserve(address(wstETH), "Aave wstETH", "awstETH", 18));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));

        // 2) ProtocolRegistry slots. This contract doubles as MARKET.
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);

        // AssetRegistry — register TSLA so eligibility passes.
        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        // 3) eTSLA. mockMarket already set above so onlyOrderSystem works.
        eTSLA = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));
        vm.label(address(eTSLA), "eTSLA");

        // Register TSLA in AssetRegistry.
        AssetConfig memory cfg = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(ASSET, address(eTSLA), cfg);

        // 4) OwnVault on awstETH. Bound VM = this contract.
        vm.prank(Actors.ADMIN);
        vault = new OwnVault(address(awstETH), "Own awstETH", "owawstETH", address(protocolRegistry), address(this));

        // VaultManager owns collateral marks now; register the vault (admin-gated)
        // so maxDebtUSD can read its collateral mark.
        _deployVaultManager();
        // Set the global payment token (required by some flows; not used here).
        _setPaymentToken(address(usdc));
        vm.prank(Actors.ADMIN);
        vaultManager.registerVault(address(vault), bytes32("WSTETH"));

        // 5) BorrowManager. Wire credit delegation + Aave reserve liquidity.
        // Seed the vault with collateral value so the manager's `maxDebtUSD` is
        // non-zero — otherwise every borrow trips the cap. Real flows would have
        // LPs deposit awstETH; here we mint awstETH to the vault and refresh.
        _seedVaultCollateral(1_000_000e18); // $1M USD-denominated collateral.

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

        // Wire lending: authorise the manager + grant Aave credit delegation.
        _enableAaveLending(address(vault), address(borrowManager), address(usdcDebt));

        // Borrowing is enabled for every asset by default — no per-asset opt-in needed.

        // Seed Aave with USDC liquidity so borrows can pay out.
        usdc.mint(address(aavePool), 1_000_000e6);

        // Default oracle price.
        _setOraclePrice(ASSET, TSLA_PX);

        // Bad-debt collateral is released to the protocol treasury.
        _setTreasury(Actors.FEE_RECIPIENT);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Seed the vault's collateralValueUSD so the manager's hard cap
    ///      is non-zero. Mints awstETH directly to the vault via the mock pool,
    ///      then runs the keeper-callable valuation refresh.
    function _seedVaultCollateral(
        uint256 usdValue
    ) internal {
        bytes32 collat = bytes32("WSTETH");
        _setOraclePrice(collat, 4000e18); // $4k per wstETH.

        // awstETH amount such that totalAssets * 4_000 / 1e18 == usdValue.
        uint256 amount = (usdValue * PRECISION) / 4000e18;

        vm.prank(address(aavePool));
        awstETH.mint(address(vault), amount);

        // Register WSTETH in AssetRegistry so the vault's oracle resolution succeeds.
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
    }

    function _giveTSLA(address to, uint256 amount) internal {
        eTSLA.mint(to, amount);
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    /// @dev Open a typical borrow: 100 eTSLA at $250 → $25k coll → borrow $10k USDC (40% LTV).
    function _openTypical(
        address borrower
    ) internal returns (uint256 eAmt, uint256 stable) {
        eAmt = 100e18;
        stable = 10_000e6;
        _giveTSLA(borrower, eAmt);
        vm.startPrank(borrower);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(borrowManager.vault(), address(vault));
        assertEq(borrowManager.stablecoin(), address(usdc));
        assertEq(borrowManager.debtToken(), address(usdcDebt));
        assertEq(borrowManager.aavePool(), address(aavePool));
        assertEq(address(borrowManager.registry()), address(protocolRegistry));
        // Pre-approval to Aave for repays.
        assertEq(usdc.allowance(address(borrowManager), address(aavePool)), type(uint256).max);
    }

    function test_constructor_zeroAddresses_revert() public {
        InterestRateModel.Params memory p = _params();
        vm.expectRevert(IBorrowManager.ZeroAddress.selector);
        new BorrowManager(
            address(0),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            TARGET_LTV_BPS,
            p
        );
        vm.expectRevert(IBorrowManager.ZeroAddress.selector);
        new BorrowManager(
            address(vault),
            address(0),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            TARGET_LTV_BPS,
            p
        );
    }

    function test_constructor_invalidLtv_revert() public {
        InterestRateModel.Params memory p = _params();
        vm.expectRevert(IBorrowManager.InvalidLtv.selector);
        new BorrowManager(
            address(vault), address(usdc), address(usdcDebt), address(aavePool), address(protocolRegistry), 0, p
        );
        vm.expectRevert(IBorrowManager.InvalidLtv.selector);
        new BorrowManager(
            address(vault), address(usdc), address(usdcDebt), address(aavePool), address(protocolRegistry), BPS, p
        );
    }

    function test_constructor_invalidRateParams_revert() public {
        InterestRateModel.Params memory p = _params();
        p.optimalUtilBps = 0;
        vm.expectRevert(IBorrowManager.InvalidRateParams.selector);
        new BorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            TARGET_LTV_BPS,
            p
        );
        p.optimalUtilBps = uint64(BPS);
        vm.expectRevert(IBorrowManager.InvalidRateParams.selector);
        new BorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            TARGET_LTV_BPS,
            p
        );
    }

    // ──────────────────────────────────────────────────────────
    //  borrow — happy path
    // ──────────────────────────────────────────────────────────

    function test_borrow_succeeds_recordsPositionAndPaysOut() public {
        (uint256 eAmt, uint256 stable) = _openTypical(Actors.MINTER1);

        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.eTokenCollateral, eAmt);
        // principal stored as scaled debt; at index = PRECISION it equals stable amount.
        assertEq(pos.principal, stable);
        assertEq(pos.interestIndex, PRECISION);

        // Manager holds collateral.
        assertEq(eTSLA.balanceOf(address(borrowManager)), eAmt);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0);

        // Borrower received the USDC.
        assertEq(usdc.balanceOf(Actors.MINTER1), stable);

        // Aave records vault as the on-behalf-of debtor.
        assertEq(aavePool.debtOf(address(vault), address(usdc)), stable);
    }

    function test_borrow_emitsEvent() public {
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6;
        _giveTSLA(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        vm.expectEmit(true, true, false, true);
        emit IBorrowManager.Borrowed(Actors.MINTER1, ASSET, eAmt, stable, TSLA_PX);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  borrow — reverts
    // ──────────────────────────────────────────────────────────

    function test_borrow_zeroAmounts_revert() public {
        vm.expectRevert(IBorrowManager.ZeroAmount.selector);
        borrowManager.borrow(ASSET, 0, 100, _priceData(TSLA_PX));
        vm.expectRevert(IBorrowManager.ZeroAmount.selector);
        borrowManager.borrow(ASSET, 100, 0, _priceData(TSLA_PX));
    }

    /// @dev C-01 regression: borrow values collateral at a current price; a stale price proof reverts,
    ///      blocking the "supply an old high eToken price to over-borrow" vector.
    function test_borrow_stalePrice_reverts() public {
        vm.warp(block.timestamp + 1 hours); // ensure now > freshness window
        uint256 maxAge = protocolRegistry.priceMaxAge();
        uint256 eAmt = 100e18;
        _giveTSLA(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        uint256 staleTs = block.timestamp - maxAge - 1; // older than the freshness window
        bytes memory stale = abi.encode(uint256(TSLA_PX), staleTs);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.StalePrice.selector, staleTs, maxAge));
        borrowManager.borrow(ASSET, eAmt, 10_000e6, stale);
        vm.stopPrank();
    }

    function test_borrow_alreadyOpenPosition_reverts() public {
        _openTypical(Actors.MINTER1);

        // Same borrower, same asset → revert.
        _giveTSLA(Actors.MINTER1, 50e18);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), 50e18);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.PositionAlreadyOpen.selector, Actors.MINTER1, ASSET));
        borrowManager.borrow(ASSET, 50e18, 1000e6, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    function test_borrow_assetNotActive_reverts() public {
        bytes32 newAsset = bytes32("GOLD");

        // Register GOLD in the AssetRegistry as INACTIVE. Per-vault asset enablement is gone;
        // the global AssetRegistry's active flag is what gates borrowing now.
        EToken eGold = new EToken("Own GOLD", "eGOLD", newAsset, address(protocolRegistry), address(usdc));
        AssetConfig memory cfg = AssetConfig({
            activeToken: address(eGold),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        // addAsset always marks the asset active; deactivate it to exercise the active-gate.
        vm.startPrank(Actors.ADMIN);
        assetRegistry.addAsset(newAsset, address(eGold), cfg);
        assetRegistry.deactivateAsset(newAsset);
        vm.stopPrank();

        eGold.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        eGold.approve(address(borrowManager), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.AssetNotActive.selector, newAsset));
        borrowManager.borrow(newAsset, 1e18, 100e6, _priceData(2000e18));
        vm.stopPrank();
    }

    function test_borrow_assetNotBorrowable_reverts() public {
        // Disable borrowing against TSLA.
        vm.prank(Actors.ADMIN);
        borrowManager.setAssetBorrowable(ASSET, false);

        _giveTSLA(Actors.MINTER1, 100e18);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.AssetNotBorrowable.selector, ASSET));
        borrowManager.borrow(ASSET, 100e18, 1000e6, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    function test_borrow_overLtv_reverts() public {
        // 100 eTSLA at $250 = $25k. borrowLtv = 70% → max $17.5k. Try $20k.
        uint256 eAmt = 100e18;
        uint256 stable = 20_000e6;
        _giveTSLA(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        vm.expectRevert(); // InsufficientCollateral with specific args; just check revert.
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    function test_borrow_vaultHalted_reverts() public {
        // Lending eligibility now reads the global VaultManager pause/halt state, not the
        // per-vault status: a permanently halted asset blocks new borrows.
        _haltAsset(ASSET, TSLA_PX);

        _giveTSLA(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), 1e18);
        vm.expectRevert(IBorrowManager.VaultEffectivelyHalted.selector);
        borrowManager.borrow(ASSET, 1e18, 100e6, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  repay — happy paths
    // ──────────────────────────────────────────────────────────

    function test_repay_full_closesPositionAndReturnsCollateral() public {
        (uint256 eAmt, uint256 stable) = _openTypical(Actors.MINTER1);

        // No interest accrued (no time passed); current debt == principal.
        usdc.mint(Actors.MINTER1, stable);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), stable);
        uint256 released = borrowManager.repay(ASSET, type(uint256).max);
        vm.stopPrank();

        assertEq(released, eAmt, "all collateral released");
        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.principal, 0);
        assertEq(pos.eTokenCollateral, 0);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), eAmt, "borrower has eToken back");
        assertEq(eTSLA.balanceOf(address(borrowManager)), 0);
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "Aave debt cleared");
    }

    function test_repay_partial_releasesProRata() public {
        (uint256 eAmt, uint256 stable) = _openTypical(Actors.MINTER1);

        uint256 half = stable / 2;
        usdc.mint(Actors.MINTER1, half);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), half);
        uint256 released = borrowManager.repay(ASSET, half);
        vm.stopPrank();

        assertEq(released, eAmt / 2, "half collateral released");
        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.eTokenCollateral, eAmt - released);
        assertEq(pos.principal, stable - half);
    }

    function test_repay_noPosition_reverts() public {
        vm.startPrank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.NoPosition.selector, Actors.MINTER1, ASSET));
        borrowManager.repay(ASSET, 1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  liquidate
    // ──────────────────────────────────────────────────────────

    function test_liquidate_underwater_fullCloseWithBonus() public {
        (uint256 eAmt, uint256 stable) = _openTypical(Actors.MINTER1);

        // Crash price so the position is deeply underwater (hf < 0.95 → full
        // close allowed) yet the bonus-based seize still fits the collateral.
        // At $105: hf = 100 * 105 * 0.8 / 10000 = 0.84. Seize = $10k * 1.05 / $105
        // = 100 eTSLA exactly = available collateral, zero residual.
        uint256 crashPx = 105e18;
        _setOraclePrice(ASSET, crashPx);

        // Liquidator pays full debt.
        usdc.mint(Actors.LIQUIDATOR, stable);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), stable);
        borrowManager.liquidate(Actors.MINTER1, ASSET, stable, _priceData(crashPx));
        vm.stopPrank();

        // Position closed.
        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.principal, 0);

        // Liquidator received all 100 eTSLA; borrower gets 0 residual.
        assertEq(eTSLA.balanceOf(Actors.LIQUIDATOR), eAmt, "liquidator gets seized collateral");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "no residual to borrower");
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "Aave debt cleared");
    }

    function test_liquidate_notUnderwater_reverts() public {
        _openTypical(Actors.MINTER1);

        // Price unchanged → health > 1, not liquidatable.
        usdc.mint(Actors.LIQUIDATOR, 10_000e6);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), 10_000e6);
        vm.expectRevert();
        borrowManager.liquidate(Actors.MINTER1, ASSET, 10_000e6, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    function test_liquidate_returnsResidualToBorrower() public {
        // Open with surplus collateral so even after bonus there's residual.
        // 200 eTSLA at $250 = $50k coll. Borrow $10k. LTV = 20% (well below 70%).
        uint256 eAmt = 200e18;
        uint256 stable = 10_000e6;
        _giveTSLA(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        // Crash to $59 so hf < 0.95 (full close allowed): adjusted =
        // 200 * 59 * 0.8 = $9440 vs $10k debt → hf = 0.944. Seize = $10k * 1.05
        // / $59 ≈ 178 eTSLA < 200 available → residual ~22 returned to borrower.
        uint256 crashPx = 59e18;
        _setOraclePrice(ASSET, crashPx);

        usdc.mint(Actors.LIQUIDATOR, stable);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), stable);
        borrowManager.liquidate(Actors.MINTER1, ASSET, stable, _priceData(crashPx));
        vm.stopPrank();

        uint256 expectedSeize = uint256(10_000e18) * (BPS + 500) / BPS * PRECISION / crashPx;
        assertApproxEqAbs(eTSLA.balanceOf(Actors.LIQUIDATOR), expectedSeize, 2);
        assertApproxEqAbs(eTSLA.balanceOf(Actors.MINTER1), eAmt - expectedSeize, 2);
    }

    /// @dev A position that is only marginally unhealthy (hf > 0.95) can be
    ///      repaid at most 50% in a single liquidation; the rest stays open.
    function test_liquidate_closeFactorCapsRepayAtHalf() public {
        uint256 eAmt = 200e18;
        uint256 stable = 10_000e6;
        _giveTSLA(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        // Crash to $60: hf = 200 * 60 * 0.8 / 10000 = 0.96 > 0.95 → close factor
        // caps a single liquidation at 50% of the $10k debt = $5k.
        uint256 crashPx = 60e18;
        _setOraclePrice(ASSET, crashPx);

        // Liquidator tries to repay the full debt but only $5k is pulled.
        usdc.mint(Actors.LIQUIDATOR, stable);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), stable);
        borrowManager.liquidate(Actors.MINTER1, ASSET, stable, _priceData(crashPx));
        vm.stopPrank();

        // Only $5k pulled from the liquidator; position remains open at ~$5k.
        assertEq(usdc.balanceOf(Actors.LIQUIDATOR), stable - 5000e6, "only half repaid");
        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.principal, 5000e6, "half debt remains");

        // Seize = $5k * 1.05 / $60 = 87.5 eTSLA; collateral shrinks to 112.5.
        uint256 expectedSeize = uint256(5000e18) * (BPS + 500) / BPS * PRECISION / crashPx;
        assertApproxEqAbs(eTSLA.balanceOf(Actors.LIQUIDATOR), expectedSeize, 2);
        assertApproxEqAbs(pos.eTokenCollateral, eAmt - expectedSeize, 2);
    }

    /// @dev When the position is deeply underwater (hf <= 0.95) the close factor
    ///      lifts, but the liquidator may still choose to repay only part.
    function test_liquidate_partialByLiquidatorChoice() public {
        uint256 eAmt = 200e18;
        uint256 stable = 10_000e6;
        _giveTSLA(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        // Crash to $59: hf = 0.944 < 0.95 → full close allowed, but the
        // liquidator opts to repay only $2k.
        uint256 crashPx = 59e18;
        _setOraclePrice(ASSET, crashPx);

        uint256 repay = 2000e6;
        usdc.mint(Actors.LIQUIDATOR, repay);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), repay);
        borrowManager.liquidate(Actors.MINTER1, ASSET, repay, _priceData(crashPx));
        vm.stopPrank();

        IBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.principal, stable - repay, "debt reduced by repay");

        uint256 expectedSeize = uint256(2000e18) * (BPS + 500) / BPS * PRECISION / crashPx;
        assertApproxEqAbs(eTSLA.balanceOf(Actors.LIQUIDATOR), expectedSeize, 2);
        assertApproxEqAbs(pos.eTokenCollateral, eAmt - expectedSeize, 2);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "borrower gets nothing on partial");
    }

    /// @dev A repay whose bonus-based seize exceeds the remaining collateral
    ///      reverts rather than letting the liquidator overpay for less.
    function test_liquidate_overSeizeReverts() public {
        (, uint256 stable) = _openTypical(Actors.MINTER1);

        // Crash to $100: hf = 0.8 < 0.95 → full close allowed. Seize for the
        // full $10k = $10k * 1.05 / $100 = 105 eTSLA > 100 available → revert.
        uint256 crashPx = 100e18;
        _setOraclePrice(ASSET, crashPx);

        usdc.mint(Actors.LIQUIDATOR, stable);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), stable);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.SeizeExceedsCollateral.selector, 105e18, 100e18));
        borrowManager.liquidate(Actors.MINTER1, ASSET, stable, _priceData(crashPx));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Interest accrual
    // ──────────────────────────────────────────────────────────

    function test_accrual_grewDebtOverTime() public {
        (, uint256 stable) = _openTypical(Actors.MINTER1);

        // Simulate Aave's live rate: 10% APR (RAY-scaled).
        aavePool.setCurrentVariableBorrowRate(address(usdc), uint128(10 * 1e25));

        skip(365 days);

        uint256 debtAfter = borrowManager.debtOf(Actors.MINTER1, ASSET);
        // 10% Aave + 1% base premium = ~11% APR linear. Allow 1% relative slack.
        assertGt(debtAfter, stable, "debt grew");
        assertApproxEqRel(debtAfter, stable * 111 / 100, 1e16);
    }

    function test_liveRate_readFromAave_inBps() public {
        // 5% APR in RAY = 5e25. The manager reads Aave's live rate directly.
        aavePool.setCurrentVariableBorrowRate(address(usdc), uint128(5 * 1e25));
        assertEq(borrowManager.baseRateBps(), 500);
    }

    function test_floor_liftsRateWhenLiveBelow() public {
        // Aave live = 1% APR. Admin floor = 4% APR. Borrower-facing rate uses floor.
        aavePool.setCurrentVariableBorrowRate(address(usdc), uint128(1 * 1e25));
        vm.prank(Actors.ADMIN);
        borrowManager.setMinAaveBorrowRateBps(400);

        (, uint256 stable) = _openTypical(Actors.MINTER1);
        skip(365 days);

        uint256 debtAfter = borrowManager.debtOf(Actors.MINTER1, ASSET);
        // 4% floor + 1% base premium = 5% APR linear.
        assertApproxEqRel(debtAfter, stable * 105 / 100, 1e16);
    }

    function test_floor_ignoredWhenLiveAbove() public {
        // Aave live = 8% APR; floor = 2% APR. Borrower charged 8% (live).
        aavePool.setCurrentVariableBorrowRate(address(usdc), uint128(8 * 1e25));
        vm.prank(Actors.ADMIN);
        borrowManager.setMinAaveBorrowRateBps(200);

        (, uint256 stable) = _openTypical(Actors.MINTER1);
        skip(365 days);

        uint256 debtAfter = borrowManager.debtOf(Actors.MINTER1, ASSET);
        // 8% live + 1% base premium = 9% APR linear.
        assertApproxEqRel(debtAfter, stable * 109 / 100, 1e16);
    }

    // ──────────────────────────────────────────────────────────
    //  Lending fee (premium surplus) routing
    // ──────────────────────────────────────────────────────────

    /// @notice On repay, the premium charged above Aave's own debt is the lending fee;
    ///         it is forwarded to the VM (not the vault, since it is denominated in the
    ///         stablecoin, not the vault collateral) and tracked via LendingFeeAccrued.
    function test_repay_premiumSurplus_goesToVM() public {
        _openTypical(Actors.MINTER1);

        skip(365 days); // accrue the premium above Aave's (static mock) debt

        address vmAddr = vault.manager();
        uint256 managerDebt = borrowManager.debtOf(Actors.MINTER1, ASSET);
        uint256 aaveDebt = aavePool.debtOf(address(vault), address(usdc));
        assertGt(managerDebt, aaveDebt, "premium accrued above aave debt");
        uint256 expectedSurplus = managerDebt - aaveDebt;

        usdc.mint(Actors.MINTER1, managerDebt);
        uint256 vmBefore = usdc.balanceOf(vmAddr);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), managerDebt);
        vm.expectEmit(true, false, false, true, address(borrowManager));
        emit IBorrowManager.LendingFeeAccrued(vmAddr, expectedSurplus);
        borrowManager.repay(ASSET, type(uint256).max);
        vm.stopPrank();

        assertEq(usdc.balanceOf(vmAddr) - vmBefore, expectedSurplus, "VM received lending fee surplus");
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "Aave debt cleared");
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function test_setRateParams_onlyAdmin() public {
        InterestRateModel.Params memory np = _params();
        np.basePremiumBps = 200;
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IBorrowManager.OnlyAdmin.selector);
        borrowManager.setRateParams(np);

        vm.prank(Actors.ADMIN);
        borrowManager.setRateParams(np);
        (uint64 b,,,) = borrowManager.rateParams();
        assertEq(b, 200);
    }

    /// @dev Params that would revert `InterestRateModel.premium` (and thus brick `_accrue`,
    ///      including repay/liquidate) must be rejected at the setter.
    function test_setRateParams_invalidOptimalUtil_reverts() public {
        InterestRateModel.Params memory np = _params();
        np.optimalUtilBps = 0;
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IBorrowManager.InvalidRateParams.selector);
        borrowManager.setRateParams(np);

        np.optimalUtilBps = uint64(BPS);
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IBorrowManager.InvalidRateParams.selector);
        borrowManager.setRateParams(np);
    }

    function test_setLiquidationConfig_validates() public {
        // threshold ≤ ltv → revert.
        uint256 ltv = borrowManager.borrowLtvBps();
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IBorrowManager.InvalidLiquidationConfig.selector);
        borrowManager.setLiquidationConfig(ltv, 500);

        vm.prank(Actors.ADMIN);
        borrowManager.setLiquidationConfig(9000, 700);
        assertEq(borrowManager.liquidationThresholdBps(), 9000);
        assertEq(borrowManager.liquidationBonusBps(), 700);
    }

    function test_setBorrowLtv_validates() public {
        // ltv >= threshold → revert.
        uint256 threshold = borrowManager.liquidationThresholdBps();
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IBorrowManager.InvalidLiquidationConfig.selector);
        borrowManager.setBorrowLtvBps(threshold);

        vm.prank(Actors.ADMIN);
        borrowManager.setBorrowLtvBps(6500);
        assertEq(borrowManager.borrowLtvBps(), 6500);
    }

    // ──────────────────────────────────────────────────────────
    //  absorbBadDebt
    // ──────────────────────────────────────────────────────────

    /// @dev Drive MINTER1 into a zero-collateral residual: open $10k against 100
    ///      eTSLA, crash to $84, then let the liquidator repay $8k — which seizes
    ///      exactly the 100 eTSLA (all collateral) while leaving $2k of
    ///      uncollateralized book debt and a matching $2k Aave loan on the vault.
    function _stripToBadDebt() internal returns (uint256 residual) {
        _openTypical(Actors.MINTER1);

        uint256 crashPx = 84e18; // seize for $8k repay = $8k*1.05/$84 = 100 eTSLA exactly.
        _setOraclePrice(ASSET, crashPx);

        uint256 repay = 8000e6;
        usdc.mint(Actors.LIQUIDATOR, repay);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), repay);
        borrowManager.liquidate(Actors.MINTER1, ASSET, repay, _priceData(crashPx));
        vm.stopPrank();

        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).eTokenCollateral, 0, "collateral stripped");
        residual = borrowManager.debtOf(Actors.MINTER1, ASSET);
        assertEq(residual, 2000e6, "residual book debt");
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 2000e6, "residual aave debt");
    }

    function test_absorbBadDebt_fullAbsorb_treasuryEatsAll() public {
        uint256 residual = _stripToBadDebt();
        uint256 vaultAwstBefore = awstETH.balanceOf(address(vault));

        usdc.mint(Actors.ADMIN, residual);
        vm.startPrank(Actors.ADMIN);
        usdc.approve(address(borrowManager), residual);
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, residual, _priceData(4000e18));
        vm.stopPrank();

        // Position + Aave debt cleared.
        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).principal, 0);
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "aave debt cleared");
        // Caller absorbed everything: no collateral released, LPs + treasury untouched.
        assertEq(awstETH.balanceOf(Actors.FEE_RECIPIENT), 0, "no collateral to treasury");
        assertEq(awstETH.balanceOf(Actors.ADMIN), 0, "no collateral to caller");
        assertEq(awstETH.balanceOf(address(vault)), vaultAwstBefore, "LP collateral untouched");
        assertEq(usdc.balanceOf(Actors.ADMIN), 0, "admin fronted the full residual");
    }

    function test_absorbBadDebt_zeroAbsorb_lpsEatAll() public {
        uint256 residual = _stripToBadDebt();
        uint256 vaultAwstBefore = awstETH.balanceOf(address(vault));

        usdc.mint(Actors.ADMIN, residual);
        vm.startPrank(Actors.ADMIN);
        usdc.approve(address(borrowManager), residual);
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, 0, _priceData(4000e18));
        vm.stopPrank();

        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "aave debt cleared");
        // LPs eat the whole $2k loss: treasury receives $2k of awstETH at $4k = 0.5e18.
        uint256 expectedAwst = uint256(2000e18) * PRECISION / 4000e18;
        assertEq(awstETH.balanceOf(Actors.FEE_RECIPIENT), expectedAwst, "treasury received the released collateral");
        assertEq(awstETH.balanceOf(Actors.ADMIN), 0, "caller received no collateral");
        assertEq(awstETH.balanceOf(address(vault)), vaultAwstBefore - expectedAwst, "vault collateral shrank");
    }

    function test_absorbBadDebt_partial_splitsLoss() public {
        uint256 residual = _stripToBadDebt(); // $2000
        uint256 absorb = 1000e6; // treasury eats $1k, LPs eat $1k.

        usdc.mint(Actors.ADMIN, residual);
        vm.startPrank(Actors.ADMIN);
        usdc.approve(address(borrowManager), residual);
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, absorb, _priceData(4000e18));
        vm.stopPrank();

        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "aave debt cleared");
        // LP slice $1k → 0.25e18 awstETH to the treasury; admin still fronted the full residual.
        uint256 expectedAwst = uint256(1000e18) * PRECISION / 4000e18;
        assertEq(awstETH.balanceOf(Actors.FEE_RECIPIENT), expectedAwst, "treasury received the LP slice");
        assertEq(usdc.balanceOf(Actors.ADMIN), 0, "admin fronted the full residual");
    }

    function test_absorbBadDebt_stillCollateralized_reverts() public {
        _openTypical(Actors.MINTER1); // healthy, full collateral.
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.PositionStillCollateralized.selector, 100e18));
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, 0, _priceData(4000e18));
    }

    function test_absorbBadDebt_onlyAdmin() public {
        _stripToBadDebt();
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IBorrowManager.OnlyAdmin.selector);
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, 0, _priceData(4000e18));
    }

    // ──────────────────────────────────────────────────────────
    //  Dividend sweep (collateral dividends are lending revenue, VM collects)
    // ──────────────────────────────────────────────────────────

    /// @dev Deposit a dividend while the manager holds collateral, then sweep it to the VM
    ///      (this contract is the vault's manager).
    function test_sweepDividends_forwardsToVM() public {
        _openTypical(Actors.MINTER1); // manager now holds 100 eTSLA.

        uint256 reward = 300e6;
        usdc.mint(address(this), reward);
        usdc.approve(address(eTSLA), reward);
        eTSLA.depositRewards(reward);

        assertEq(eTSLA.claimableRewards(address(borrowManager)), reward, "manager accrued the dividend");

        address vmgr = vault.manager(); // == address(this)
        uint256 vmBefore = usdc.balanceOf(vmgr);

        vm.expectEmit(true, true, false, true);
        emit IBorrowManager.DividendsSwept(address(eTSLA), vmgr, reward);
        uint256 swept = borrowManager.sweepDividends(address(eTSLA));

        assertEq(swept, reward);
        assertEq(usdc.balanceOf(vmgr) - vmBefore, reward, "VM received the dividend");
        assertEq(eTSLA.claimableRewards(address(borrowManager)), 0, "manager bucket drained");
    }

    function test_sweepDividends_noDividends_reverts() public {
        _openTypical(Actors.MINTER1);
        vm.expectRevert(IBorrowManager.NoDividendsToSweep.selector);
        borrowManager.sweepDividends(address(eTSLA));
    }

    // ──────────────────────────────────────────────────────────
    //  Borrowable gate (admin)
    // ──────────────────────────────────────────────────────────

    function test_setAssetBorrowable_defaultEnabled_togglesAndEmits() public {
        bytes32 asset = bytes32("GOLD");
        // Enabled by default with no admin action.
        assertTrue(borrowManager.isAssetBorrowable(asset));

        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, false, false, true);
        emit IBorrowManager.AssetBorrowableUpdated(asset, false);
        borrowManager.setAssetBorrowable(asset, false);
        assertFalse(borrowManager.isAssetBorrowable(asset));

        vm.prank(Actors.ADMIN);
        borrowManager.setAssetBorrowable(asset, true);
        assertTrue(borrowManager.isAssetBorrowable(asset));
    }

    function test_setAssetBorrowable_onlyAdmin() public {
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IBorrowManager.OnlyAdmin.selector);
        borrowManager.setAssetBorrowable(ASSET, true);
    }

    // ──────────────────────────────────────────────────────────
    //  Interest-model divergence: index floored to real Aave debt
    // ──────────────────────────────────────────────────────────

    /// @dev If Aave's debt outruns our sampled simple-interest model, the book debt is floored to the
    ///      real Aave debt so a full repay still clears the Aave loan — no shortfall lands on LPs.
    function test_accrue_floorsBookDebtToRealAaveDebt() public {
        (, uint256 stable) = _openTypical(Actors.MINTER1); // borrow $10k, book ~= $10k same block
        assertEq(borrowManager.debtOf(Actors.MINTER1, ASSET), stable, "book == principal at open");

        // Aave rate spike our model missed: the vault's real Aave debt jumps to $10.5k.
        uint256 spiked = 10_500e6;
        aavePool.accrueDebt(address(vault), address(usdc), spiked - stable);

        // The floor lifts book debt to at least the real Aave debt.
        assertGe(borrowManager.debtOf(Actors.MINTER1, ASSET), spiked, "book debt floored to real aave debt");

        // Full repay clears the Aave loan entirely — nothing left for LPs to absorb.
        uint256 owed = borrowManager.debtOf(Actors.MINTER1, ASSET);
        usdc.mint(Actors.MINTER1, owed);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), owed);
        borrowManager.repay(ASSET, type(uint256).max);
        vm.stopPrank();
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "aave debt fully cleared, no LP shortfall");
    }

    /// @dev A keeper can advance/floor the stored index with no borrower interaction, so the
    ///      stored-index reads (totalDebtUSD / utilization) catch up to the real Aave debt.
    function test_accrue_keeperCanSyncIndependently() public {
        (, uint256 stable) = _openTypical(Actors.MINTER1); // borrow $10k
        // Aave debt jumps; no borrow/repay/liquidate touches the manager.
        aavePool.accrueDebt(address(vault), address(usdc), 500e6);
        uint256 storedBefore = borrowManager.totalDebtUSD(); // reads the (stale) stored index

        vm.prank(Actors.ATTACKER); // permissionless — any address
        borrowManager.accrue();

        // Stored book debt is now floored to the real Aave debt ($10.5k → 18-dec USD).
        assertGt(borrowManager.totalDebtUSD(), storedBefore, "keeper sync advanced stored debt");
        assertGe(borrowManager.totalDebtUSD(), uint256(10_500e6) * 1e12, "stored book debt >= real aave debt");
        assertEq(borrowManager.totalDebtUSD(), uint256(stable + 500e6) * 1e12, "exactly floored to aave debt");
    }

    // ──────────────────────────────────────────────────────────
    //  borrow guards: cap sees accrued debt, vault must be Active
    // ──────────────────────────────────────────────────────────

    /// @dev The hard cap must be checked against the accrued + floored debt, not the
    ///      stale stored index — otherwise a borrow can pass while real debt breaches the cap.
    function test_borrow_capChecksAccruedDebt() public {
        (, uint256 stable) = _openTypical(Actors.MINTER1); // $10k book debt, stored index = 1.0

        // Aave rate spike the stored index hasn't seen: real vault debt jumps to $349k,
        // just under the $350k cap (35% of the $1M collateral mark).
        aavePool.accrueDebt(address(vault), address(usdc), 349_000e6 - stable);

        // A $5k borrow passes the stale-index cap ($15k vs $350k) but must revert
        // once the cap sees the floored debt ($349k + $5k > $350k).
        _giveTSLA(Actors.MINTER2, 100e18);
        vm.startPrank(Actors.MINTER2);
        eTSLA.approve(address(borrowManager), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManager.BorrowExceedsCap.selector, 354_000e18, 350_000e18));
        borrowManager.borrow(ASSET, 100e18, 5_000e6, _priceData(TSLA_PX));
        vm.stopPrank();
    }

    /// @dev A paused vault must not be borrowed against via its credit delegation,
    ///      while exits (repay) stay open.
    function test_borrow_pausedVault_reverts() public {
        _openTypical(Actors.MINTER1);

        vault.pause(bytes32("incident")); // this contract is the bound manager

        _giveTSLA(Actors.MINTER2, 100e18);
        vm.startPrank(Actors.MINTER2);
        eTSLA.approve(address(borrowManager), 100e18);
        vm.expectRevert(IBorrowManager.VaultNotActive.selector);
        borrowManager.borrow(ASSET, 100e18, 5_000e6, _priceData(TSLA_PX));
        vm.stopPrank();

        // Exits stay open: the existing position repays in full while paused.
        uint256 owed = borrowManager.debtOf(Actors.MINTER1, ASSET);
        usdc.mint(Actors.MINTER1, owed);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), owed);
        borrowManager.repay(ASSET, type(uint256).max);
        vm.stopPrank();
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "repay clears aave debt while paused");
    }

    function test_borrow_haltedVault_reverts() public {
        vm.prank(Actors.ADMIN);
        vault.haltVault();

        _giveTSLA(Actors.MINTER1, 100e18);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), 100e18);
        vm.expectRevert(IBorrowManager.VaultNotActive.selector);
        borrowManager.borrow(ASSET, 100e18, 5_000e6, _priceData(TSLA_PX));
        vm.stopPrank();
    }
}

/// @title absorbBadDebt with 6-decimal collateral (aUSDC) — regression for the native-decimal
///        scaling fix. All existing absorbBadDebt tests use 18-dec awstETH, which masks the bug.
contract BorrowManagerBadDebt6DecTest is BaseTest {
    AssetRegistry internal assetRegistry;
    EToken internal eTSLA;
    MockAaveV3Pool internal aavePool;
    MockAToken internal collToken; // 6-decimal collateral aToken
    MockAaveDebtToken internal usdcDebt;
    OwnVault internal vault;
    BorrowManager internal borrowManager;

    bytes32 constant ASSET = bytes32("TSLA");
    bytes32 constant COLLAT = bytes32("AUSDC");
    uint256 constant TSLA_PX = 250e18;
    uint256 constant TARGET_LTV_BPS = 3500;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        aavePool = new MockAaveV3Pool();
        collToken = MockAToken(aavePool.registerReserve(address(usdc), "Aave USDC", "aUSDC", 6)); // 6-dec collateral
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(this)); // act as MARKET
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

        vm.prank(Actors.ADMIN);
        vault = new OwnVault(address(collToken), "Own aUSDC", "oaUSDC", address(protocolRegistry), address(this));

        _deployVaultManager();
        _setPaymentToken(address(usdc));
        vm.prank(Actors.ADMIN);
        vaultManager.registerVault(address(vault), COLLAT);

        // $1M aUSDC collateral at $1; register the collateral asset + oracle, then pull the mark.
        _setOraclePrice(COLLAT, 1e18);
        vm.prank(address(aavePool));
        collToken.mint(address(vault), 1_000_000e6);
        AssetConfig memory ccfg = AssetConfig({
            activeToken: address(collToken),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(COLLAT, address(collToken), ccfg);
        vaultManager.pullCollateralPrice(address(vault));

        borrowManager = new BorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            TARGET_LTV_BPS,
            _params()
        );
        _enableAaveLending(address(vault), address(borrowManager), address(usdcDebt));

        usdc.mint(address(aavePool), 1_000_000e6); // Aave borrow liquidity
        _setOraclePrice(ASSET, TSLA_PX);
        _setTreasury(Actors.FEE_RECIPIENT);
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    /// @dev Strip MINTER1 to a $2k zero-collateral residual (identical to the 18-dec harness).
    function _stripToBadDebt() internal returns (uint256 residual) {
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6;
        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        _setOraclePrice(ASSET, 84e18); // seize for $8k repay = 8000*1.05/84 = 100 eTSLA (all collateral)
        usdc.mint(Actors.LIQUIDATOR, 8000e6);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), 8000e6);
        borrowManager.liquidate(Actors.MINTER1, ASSET, 8000e6, _priceData(84e18));
        vm.stopPrank();

        residual = borrowManager.debtOf(Actors.MINTER1, ASSET);
        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).eTokenCollateral, 0, "collateral stripped");
        assertEq(residual, 2000e6, "residual book debt");
    }

    /// @dev With 6-dec collateral, the LP-socialized slice is released in NATIVE units (2000e6).
    ///      Before the fix this computed 2000e18 and reverted on the vault's balance.
    function test_absorbBadDebt_sixDecimalCollateral_releasesNativeAmount() public {
        uint256 residual = _stripToBadDebt();
        uint256 vaultBefore = collToken.balanceOf(address(vault));

        usdc.mint(Actors.ADMIN, residual);
        vm.startPrank(Actors.ADMIN);
        usdc.approve(address(borrowManager), residual);
        borrowManager.absorbBadDebt(Actors.MINTER1, ASSET, 0, _priceData(1e18)); // LPs eat $2k, $1/aUSDC
        vm.stopPrank();

        // $2k at $1 = 2000 aUSDC = 2000e6 native (NOT 2000e18).
        assertEq(collToken.balanceOf(Actors.FEE_RECIPIENT), 2000e6, "treasury received native 6-dec amount");
        assertEq(collToken.balanceOf(address(vault)), vaultBefore - 2000e6, "vault released native amount");
        assertEq(borrowManager.positionOf(Actors.MINTER1, ASSET).principal, 0, "position cleared");
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "aave debt cleared");
    }
}
