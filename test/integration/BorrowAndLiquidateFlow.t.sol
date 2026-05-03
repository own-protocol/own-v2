// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AaveBorrowManager} from "../../src/core/AaveBorrowManager.sol";
import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {BorrowManagerFactory} from "../../src/core/BorrowManagerFactory.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultBorrowCoordinator} from "../../src/core/VaultBorrowCoordinator.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {IAaveBorrowManager} from "../../src/interfaces/IAaveBorrowManager.sol";
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
    VaultFactory public vaultFactory;
    BorrowManagerFactory public bmFactory;
    OwnVault public vault;
    VaultBorrowCoordinator public coordinator;
    AaveBorrowManager public borrowManager;

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
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

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

        // Vault & borrow manager factories.
        vm.startPrank(Actors.ADMIN);
        vaultFactory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(vaultFactory));
        vault =
            OwnVault(vaultFactory.createVault(address(awstETH), address(this), "Own awstETH", "owawstETH", 8000, 2000));

        bmFactory = new BorrowManagerFactory(address(aavePool), address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.BORROW_MANAGER_FACTORY(), address(bmFactory));

        coordinator = new VaultBorrowCoordinator(
            address(vault), address(aavePool), address(protocolRegistry), address(usdc), 3500
        );

        borrowManager = AaveBorrowManager(
            bmFactory.createBorrowManager(
                address(vault), address(usdc), address(usdcDebt), address(coordinator), _params()
            )
        );
        coordinator.registerManager(address(borrowManager));
        vm.stopPrank();

        // Seed the vault with awstETH so coordinator's debt cap is non-zero.
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
        vm.prank(Actors.ADMIN);
        vault.setCollateralOracleAsset(collat);
        vault.updateCollateralValuation();

        // Vault setup: enable asset (as bound VM = this contract), set payment
        // token, opt into lending (delegate credit + register pass-through).
        vault.enableAsset(ASSET);
        vault.setPaymentToken(address(usdc));

        vm.prank(Actors.ADMIN);
        vault.enableLending(address(borrowManager), address(usdcDebt));
        vm.prank(Actors.ADMIN);
        eTSLA.setPassThroughHolder(address(borrowManager), true);

        _setOraclePrice(ASSET, TSLA_PX);
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    /// @dev End-to-end: borrow → dividend deposit while collateral in custody →
    ///      price crashes → liquidate. Verifies position close, Aave debt
    ///      cleared, liquidator gets eTokens AND the dividends earned during
    ///      the borrow window (per the locked design).
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

        // Price crashes — make the position liquidatable. Threshold 80%.
        // hf = collateral * px * 0.8 / debt; need < 1.0e18.
        // With 100 eTSLA collateral and ~10.05k debt, drop px to $90 → hf ≈ 0.71.
        uint256 crashPx = 90e18;
        _setOraclePrice(ASSET, crashPx);

        // Liquidator pulls funds, repays full debt, seizes capped collateral.
        uint256 liqDebt = borrowManager.debtOf(Actors.MINTER1, ASSET);
        usdc.mint(Actors.LIQUIDATOR, liqDebt);
        vm.startPrank(Actors.LIQUIDATOR);
        usdc.approve(address(borrowManager), liqDebt);
        borrowManager.liquidate(Actors.MINTER1, ASSET, _priceData(crashPx));
        vm.stopPrank();

        // Position closed.
        IAaveBorrowManager.Position memory pos = borrowManager.positionOf(Actors.MINTER1, ASSET);
        assertEq(pos.principal, 0);

        // Aave debt cleared on the vault.
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0);

        // Liquidator received eTokens + dividend bucket via pass-through redirect.
        // (Their eToken share = min(targetSeize, 100 eTSLA) — at $90 with 5% bonus,
        // target = 10.05k * 1.05 / 90 ≈ 117 → capped at 100.)
        assertEq(eTSLA.balanceOf(Actors.LIQUIDATOR), eAmt, "liquidator gets all collateral");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "no residual to borrower");

        // Dividends from the borrow window followed the eTokens to the liquidator.
        assertApproxEqAbs(eTSLA.claimableRewards(Actors.LIQUIDATOR), reward, 1);
        assertEq(eTSLA.claimableRewards(address(borrowManager)), 0);
    }

    /// @dev End-to-end: borrow → repay in full → dividend earned during borrow
    ///      pass-through to borrower on collateral return.
    function test_endToEnd_borrowDividendRepay_dividendsFollowBorrower() public {
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
        // Borrower picks up dividends earned during the borrow window.
        assertApproxEqAbs(eTSLA.claimableRewards(Actors.MINTER1), reward, 1);
        assertEq(eTSLA.claimableRewards(address(borrowManager)), 0);
    }
}
