// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {LPBorrowManager} from "../../src/core/LPBorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultBorrowCoordinator} from "../../src/core/VaultBorrowCoordinator.sol";
import {ILPBorrowManager} from "../../src/interfaces/ILPBorrowManager.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, BPS, PRECISION} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveDebtToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPBorrowManager Unit Tests
/// @notice Covers custody-transfer borrow / repay / liquidate, accrual, admin
///         guards, and pass-through reward routing for vault-fee rewards.
///         The placeMintOrder + claimMintedETokens flow is exercised in the
///         integration test (which wires a full OwnMarket).
contract LPBorrowManagerTest is BaseTest {
    AssetRegistry public assetRegistry;
    MockAaveV3Pool public aavePool;
    MockAToken public awstETH;
    MockAaveDebtToken public usdcDebt;
    OwnVault public vault;
    VaultBorrowCoordinator public coordinator;
    LPBorrowManager public lpManager;

    bytes32 constant COLLAT = bytes32("WSTETH");
    uint256 constant WSTETH_PX = 4000e18; // $4k per wstETH (≈ETH price scaled).

    address public mockMarket;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        mockMarket = makeAddr("market");

        // Aave wiring.
        aavePool = new MockAaveV3Pool();
        awstETH = MockAToken(aavePool.registerReserve(address(wstETH), "Aave wstETH", "awstETH", 18));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));
        usdc.mint(address(aavePool), 10_000_000e6); // seed reserve liquidity.

        // ProtocolRegistry slots.
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), mockMarket);
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        // OwnVault — bound VM = this contract so we can configure freely.
        vm.prank(Actors.ADMIN);
        vault = new OwnVault(
            address(awstETH), "Own awstETH", "owawstETH", address(protocolRegistry), address(this), 8000, 2000
        );

        // Register WSTETH in AssetRegistry as the collateral oracle asset.
        AssetConfig memory cfg = AssetConfig({
            activeToken: address(awstETH),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(COLLAT, address(awstETH), cfg);
        _setOraclePrice(COLLAT, WSTETH_PX);

        // Set vault collateral oracle + payment token.
        vault.setPaymentToken(address(usdc));
        vm.prank(Actors.ADMIN);
        vault.setCollateralOracleAsset(COLLAT);

        // Coordinator.
        vm.prank(Actors.ADMIN);
        coordinator = new VaultBorrowCoordinator(
            address(vault), address(aavePool), address(protocolRegistry), address(usdc), 3500
        );

        // LPBorrowManager.
        vm.prank(Actors.ADMIN);
        lpManager = new LPBorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            mockMarket,
            address(protocolRegistry),
            address(coordinator),
            COLLAT,
            _params()
        );

        // Register manager: vault delegates Aave credit (to the LP manager —
        // user-borrow slot is satisfied with a stub), coordinator counts its
        // debt, vault treats it as a share custodian for fee pass-through.
        vm.prank(Actors.ADMIN);
        vault.enableLending(makeAddr("userBMStub"), address(lpManager), address(usdcDebt));
        vm.prank(Actors.ADMIN);
        vault.setShareCustodian(address(lpManager), true);
        vm.prank(Actors.ADMIN);
        coordinator.registerManager(address(lpManager));

        // Seed coordinator collateral: deposit awstETH on behalf of LP1 so the
        // hard cap has headroom and shares exist for borrowing.
        _seedLPDeposit(Actors.LP1, 100e18); // 100 awstETH ≈ $400k.
        vault.updateCollateralValuation();
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _seedLPDeposit(address lp, uint256 awstETHAmount) internal {
        vm.prank(address(aavePool));
        awstETH.mint(lp, awstETHAmount);
        vm.startPrank(lp);
        IERC20(address(awstETH)).approve(address(vault), awstETHAmount);
        vault.deposit(awstETHAmount, lp);
        vm.stopPrank();
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    /// @dev Open a typical position: 50 shares ≈ $200k coll → borrow $50k USDC (25% LTV).
    function _openTypical(
        address lp
    ) internal returns (uint256 sharesAmount, uint256 stable) {
        sharesAmount = 50e18;
        stable = 50_000e6;
        vm.startPrank(lp);
        IERC20(address(vault)).approve(address(lpManager), sharesAmount);
        lpManager.borrow(sharesAmount, stable, _priceData(WSTETH_PX));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(lpManager.vault(), address(vault));
        assertEq(lpManager.stablecoin(), address(usdc));
        assertEq(lpManager.debtToken(), address(usdcDebt));
        assertEq(lpManager.aavePool(), address(aavePool));
        assertEq(lpManager.market(), mockMarket);
        assertEq(lpManager.collateralAsset(), COLLAT);
        assertEq(address(lpManager.coordinator()), address(coordinator));
    }

    function test_constructor_zeroAddresses_revert() public {
        InterestRateModel.Params memory p = _params();
        vm.expectRevert(ILPBorrowManager.ZeroAddress.selector);
        new LPBorrowManager(
            address(0),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            mockMarket,
            address(protocolRegistry),
            address(coordinator),
            COLLAT,
            p
        );
    }

    function test_constructor_zeroCollateral_reverts() public {
        InterestRateModel.Params memory p = _params();
        vm.expectRevert(ILPBorrowManager.ZeroAmount.selector);
        new LPBorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            mockMarket,
            address(protocolRegistry),
            address(coordinator),
            bytes32(0),
            p
        );
    }

    // ──────────────────────────────────────────────────────────
    //  borrow — happy path
    // ──────────────────────────────────────────────────────────

    function test_borrow_succeeds_takesCustodyAndCreditsStable() public {
        (uint256 sharesAmount, uint256 stable) = _openTypical(Actors.LP1);

        ILPBorrowManager.Position memory pos = lpManager.positionOf(Actors.LP1);
        assertEq(pos.sharesHeld, sharesAmount);
        assertEq(pos.principal, stable, "principal == scaled debt @ index=1.0");
        assertEq(pos.interestIndex, PRECISION);

        // Custody transfer: shares moved from LP to manager.
        assertEq(vault.balanceOf(address(lpManager)), sharesAmount);
        // LP retains the un-pledged remainder (deposited 100, pledged 50).
        assertEq(vault.balanceOf(Actors.LP1), 50e18);

        // Stablecoin held internally for the LP, not yet released.
        assertEq(lpManager.lpStablecoinBalance(Actors.LP1), stable);
        assertEq(usdc.balanceOf(Actors.LP1), 0);

        // Aave shows the vault as the on-behalf-of debtor.
        assertEq(aavePool.debtOf(address(vault), address(usdc)), stable);
    }

    function test_borrow_topUpAddsToPosition() public {
        _openTypical(Actors.LP1);

        // Top up with another 25 shares → borrow $20k more.
        vm.startPrank(Actors.LP1);
        IERC20(address(vault)).approve(address(lpManager), 25e18);
        lpManager.borrow(25e18, 20_000e6, _priceData(WSTETH_PX));
        vm.stopPrank();

        ILPBorrowManager.Position memory pos = lpManager.positionOf(Actors.LP1);
        assertEq(pos.sharesHeld, 75e18);
        assertEq(pos.principal, 70_000e6);
        assertEq(lpManager.lpStablecoinBalance(Actors.LP1), 70_000e6);
    }

    function test_borrow_emitsEvent() public {
        uint256 sharesAmount = 50e18;
        uint256 stable = 50_000e6;
        vm.startPrank(Actors.LP1);
        IERC20(address(vault)).approve(address(lpManager), sharesAmount);
        // Don't pin the exact USD value (depends on convertToAssets), check topic-only.
        vm.expectEmit(true, false, false, false);
        emit ILPBorrowManager.Borrowed(Actors.LP1, sharesAmount, stable, 0);
        lpManager.borrow(sharesAmount, stable, _priceData(WSTETH_PX));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  borrow — reverts
    // ──────────────────────────────────────────────────────────

    function test_borrow_zeroShares_reverts() public {
        vm.prank(Actors.LP1);
        vm.expectRevert(ILPBorrowManager.ZeroAmount.selector);
        lpManager.borrow(0, 100, _priceData(WSTETH_PX));
    }

    function test_borrow_overLtv_reverts() public {
        // 50 shares ≈ $200k coll. LTV 70% → max $140k. Try $200k.
        uint256 sharesAmount = 50e18;
        uint256 stable = 200_000e6;
        vm.startPrank(Actors.LP1);
        IERC20(address(vault)).approve(address(lpManager), sharesAmount);
        vm.expectRevert();
        lpManager.borrow(sharesAmount, stable, _priceData(WSTETH_PX));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  withdrawBorrowed
    // ──────────────────────────────────────────────────────────

    function test_withdrawBorrowed_pullsToLP() public {
        (, uint256 stable) = _openTypical(Actors.LP1);

        vm.prank(Actors.LP1);
        lpManager.withdrawBorrowed(stable);

        assertEq(usdc.balanceOf(Actors.LP1), stable);
        assertEq(lpManager.lpStablecoinBalance(Actors.LP1), 0);
    }

    function test_withdrawBorrowed_overBalance_reverts() public {
        (, uint256 stable) = _openTypical(Actors.LP1);
        vm.prank(Actors.LP1);
        vm.expectRevert(
            abi.encodeWithSelector(ILPBorrowManager.InsufficientStablecoinBalance.selector, stable + 1, stable)
        );
        lpManager.withdrawBorrowed(stable + 1);
    }

    // ──────────────────────────────────────────────────────────
    //  repay
    // ──────────────────────────────────────────────────────────

    function test_repay_full_returnsCustodyAndClearsDebt() public {
        (uint256 sharesAmount, uint256 stable) = _openTypical(Actors.LP1);

        // Drain stable internal balance (so we model the LP having spent it).
        vm.prank(Actors.LP1);
        lpManager.withdrawBorrowed(stable);

        // Mint repay amount (no interest accrued — same block).
        usdc.mint(Actors.LP1, stable);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(lpManager), stable);
        uint256 released = lpManager.repay(type(uint256).max);
        vm.stopPrank();

        assertEq(released, sharesAmount);
        ILPBorrowManager.Position memory pos = lpManager.positionOf(Actors.LP1);
        assertEq(pos.sharesHeld, 0);
        assertEq(pos.principal, 0);

        // Custody returned to LP.
        assertEq(vault.balanceOf(Actors.LP1), 100e18);
        assertEq(vault.balanceOf(address(lpManager)), 0);
        // Aave debt cleared.
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0);
    }

    function test_repay_partial_releasesProRata() public {
        (uint256 sharesAmount, uint256 stable) = _openTypical(Actors.LP1);
        vm.prank(Actors.LP1);
        lpManager.withdrawBorrowed(stable);

        uint256 half = stable / 2;
        usdc.mint(Actors.LP1, half);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(lpManager), half);
        uint256 released = lpManager.repay(half);
        vm.stopPrank();

        assertEq(released, sharesAmount / 2);
        ILPBorrowManager.Position memory pos = lpManager.positionOf(Actors.LP1);
        assertEq(pos.sharesHeld, sharesAmount / 2);
        assertEq(pos.principal, stable - half);
    }

    function test_repay_noPosition_reverts() public {
        vm.prank(Actors.LP2);
        vm.expectRevert(abi.encodeWithSelector(ILPBorrowManager.NoPosition.selector, Actors.LP2));
        lpManager.repay(1);
    }

    // ──────────────────────────────────────────────────────────
    //  liquidate
    // ──────────────────────────────────────────────────────────

    function test_liquidate_underwater_seizesShares() public {
        (uint256 sharesAmount, uint256 stable) = _openTypical(Actors.LP1);
        vm.prank(Actors.LP1);
        lpManager.withdrawBorrowed(stable);

        // Crash wstETH price hard so HF<1.
        // Coll value = 50 shares * convertToAssets(1e18) * pxLow / 1e18.
        // convertToAssets(1e18) ≈ 1e18 (no yield), so coll = 50 * pxLow.
        // Need 50 * pxLow * 0.8 < 50_000e18 → pxLow < $1250.
        uint256 crashPx = 1000e18;
        _setOraclePrice(COLLAT, crashPx);

        // Liquidator pays full debt.
        usdc.mint(Actors.LIQUIDATOR, stable);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(lpManager), stable);
        lpManager.liquidate(Actors.LP1, _priceData(crashPx));
        vm.stopPrank();

        // Position closed.
        ILPBorrowManager.Position memory pos = lpManager.positionOf(Actors.LP1);
        assertEq(pos.principal, 0);

        // Liquidator receives vault shares (claim on vault, not awstETH).
        // Target = $50k * 1.05 / $1k = 52.5 shares; cap at 50; full custody to liquidator.
        assertEq(vault.balanceOf(Actors.LIQUIDATOR), sharesAmount);
        assertEq(vault.balanceOf(address(lpManager)), 0);
        // Aave debt cleared.
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0);
    }

    function test_liquidate_returnsResidualToLP() public {
        (uint256 sharesAmount, uint256 stable) = _openTypical(Actors.LP1);
        vm.prank(Actors.LP1);
        lpManager.withdrawBorrowed(stable);

        // Crash to a level where HF<1 AND target seize < held.
        // HF<1: 50 * px * 0.8 < 50_000 → px < $1250.
        // target seize = $52500 / px shares; for residual we want target<50 → px>$1050.
        uint256 crashPx = 1100e18;
        _setOraclePrice(COLLAT, crashPx);

        usdc.mint(Actors.LIQUIDATOR, stable);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(lpManager), stable);
        lpManager.liquidate(Actors.LP1, _priceData(crashPx));
        vm.stopPrank();

        // Liquidator + LP residual + LP unpledged 50 shares = 100 shares total.
        uint256 liqShares = vault.balanceOf(Actors.LIQUIDATOR);
        uint256 lpResidual = vault.balanceOf(Actors.LP1) - 50e18; // subtract LP's unpledged half.
        assertEq(liqShares + lpResidual, sharesAmount);
        assertGt(lpResidual, 0, "borrower keeps something");
        assertGt(liqShares, 0, "liquidator gets something");
    }

    function test_liquidate_notUnderwater_reverts() public {
        (, uint256 stable) = _openTypical(Actors.LP1);
        vm.prank(Actors.LP1);
        lpManager.withdrawBorrowed(stable);

        usdc.mint(Actors.LIQUIDATOR, stable);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(lpManager), stable);
        vm.expectRevert(); // NotLiquidatable
        lpManager.liquidate(Actors.LP1, _priceData(WSTETH_PX));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Pass-through fee rewards
    // ──────────────────────────────────────────────────────────

    function test_passThrough_feesEarnedDuringBorrowReturnToLP() public {
        (, uint256 stable) = _openTypical(Actors.LP1);
        vm.prank(Actors.LP1);
        lpManager.withdrawBorrowed(stable);

        // Drive a fee deposit while half the LP's shares sit with the manager.
        // protocolBps=20%, vmBps=20% of remainder → LP slice = 80% × 80% = 64%.
        uint256 totalFee = 1000e6;
        uint256 lpSlice = (totalFee * 8000 / BPS) * 8000 / BPS; // 640e6
        usdc.mint(mockMarket, totalFee);
        vm.startPrank(mockMarket);
        usdc.approve(address(vault), totalFee);
        vault.depositFees(address(usdc), totalFee);
        vm.stopPrank();

        // Manager has half the shares → half the LP slice on its books pre-redirect.
        uint256 mgrAccrued = vault.claimableLPRewards(address(lpManager));
        assertGt(mgrAccrued, 0);

        // LP repays — pass-through redirects manager's slice back to LP.
        usdc.mint(Actors.LP1, stable);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(lpManager), stable);
        lpManager.repay(type(uint256).max);
        vm.stopPrank();

        // Manager drained; LP holds the FULL LP slice (their own half + redirected half).
        assertEq(vault.claimableLPRewards(address(lpManager)), 0);
        assertApproxEqAbs(vault.claimableLPRewards(Actors.LP1), lpSlice, 2);
        assertEq(vault.balanceOf(Actors.LP1), 100e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    function test_setRateParams_onlyAdmin() public {
        InterestRateModel.Params memory np = _params();
        np.basePremiumBps = 250;
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(ILPBorrowManager.OnlyAdmin.selector);
        lpManager.setRateParams(np);

        vm.prank(Actors.ADMIN);
        lpManager.setRateParams(np);
        (uint64 b,,,) = lpManager.rateParams();
        assertEq(b, 250);
    }

    function test_setLiquidationConfig_validates() public {
        uint256 ltv = lpManager.borrowLtvBps();
        vm.prank(Actors.ADMIN);
        vm.expectRevert(ILPBorrowManager.InvalidLiquidationConfig.selector);
        lpManager.setLiquidationConfig(ltv, 500);

        vm.prank(Actors.ADMIN);
        lpManager.setLiquidationConfig(9000, 700);
        assertEq(lpManager.liquidationThresholdBps(), 9000);
        assertEq(lpManager.liquidationBonusBps(), 700);
    }

    function test_setBorrowLtvBps_validates() public {
        uint256 thr = lpManager.liquidationThresholdBps();
        vm.prank(Actors.ADMIN);
        vm.expectRevert(ILPBorrowManager.InvalidLiquidationConfig.selector);
        lpManager.setBorrowLtvBps(thr);

        vm.prank(Actors.ADMIN);
        lpManager.setBorrowLtvBps(6500);
        assertEq(lpManager.borrowLtvBps(), 6500);
    }
}
