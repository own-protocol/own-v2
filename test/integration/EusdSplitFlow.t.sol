// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {EToken} from "../../src/tokens/EToken.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {deployEUSDManager} from "../helpers/DeployEusdModule.sol";

/// @title EusdSplitFlowTest — A4-H-02: eUSD positions across a real AssetRegistry.migrateToken
/// @notice Runs the split runbook order (migrate while the anchor is still pre-split, then the
///         feed moves) against the real registry + VaultManager.applySplit seam and asserts every
///         open position's USD value is split-invariant.
contract EusdSplitFlowTest is BaseTest {
    bytes32 constant ASSET = bytes32("TSLA");
    uint256 constant PX = 600e18;

    AssetRegistry internal assetRegistry;
    EToken internal eTSLA;
    EToken internal eTSLAv2;
    EUSD internal eusd;
    EUSDManager internal manager;

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(this)); // lets tests mint eTSLA
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.ADMIN);
        vm.stopPrank();

        eTSLA = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));
        eTSLAv2 = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));
        AssetConfig memory cfg = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(ASSET, address(eTSLA), cfg);
        _deployVaultManager(); // migrateToken drives VaultManager.applySplit

        eusd = new EUSD(Actors.ADMIN);
        manager = deployEUSDManager(
            address(protocolRegistry),
            address(eusd),
            IEUSDManager.RiskParams({
                mcrBps: 15_000,
                liquidationThresholdBps: 13_000,
                liquidationBonusBps: 500,
                stabilityFeeBps: 0,
                debtCeiling: 1e30,
                minDebt: 100e18,
                mintPriceMaxAge: 300
            })
        );
        vm.startPrank(Actors.ADMIN);
        eusd.grantRole(eusd.MINTER_ROLE(), address(manager));
        manager.addCollateral(address(eTSLA), ASSET);
        vm.stopPrank();

        _setOraclePrice(ASSET, PX);
        eTSLA.mint(Actors.MINTER1, 10e18);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(manager), type(uint256).max);
        manager.deposit(address(eTSLA), 2e18, address(0)); // $1200
        manager.mint(address(eTSLA), 800e18, address(0)); // CR 150%
        vm.stopPrank();
    }

    function _migrate(
        uint256 ratio
    ) internal {
        vm.prank(Actors.ADMIN);
        assetRegistry.migrateToken(ASSET, address(eTSLAv2), ratio);
    }

    function test_forwardSplit_positionValueInvariant_runbookOrder() public {
        uint256 before = manager.collateralRatioBps(address(eTSLA), Actors.MINTER1);
        assertEq(before, 15_000);

        // Step 2: migrate while the anchor is still pre-split → over-valued by ratio (safe side).
        _migrate(2e18);
        assertEq(manager.collateralRatioBps(address(eTSLA), Actors.MINTER1), 30_000);
        assertFalse(manager.isLiquidatable(address(eTSLA), Actors.MINTER1));

        // Step 3: feed moves to the post-split price → exact pre-split value.
        _setOraclePrice(ASSET, PX / 2);
        assertEq(manager.collateralRatioBps(address(eTSLA), Actors.MINTER1), before);
        assertFalse(manager.isLiquidatable(address(eTSLA), Actors.MINTER1));
        vm.expectRevert();
        manager.liquidate(address(eTSLA), Actors.MINTER1, type(uint256).max, address(0));
    }

    function test_forwardSplit_redeemAndWithdraw_inLegacyUnitsAtFairValue() public {
        _migrate(2e18);
        _setOraclePrice(ASSET, PX / 2);

        // 300 eUSD buys $300 = 0.5 legacy eTSLA (1 new unit at $300).
        vm.prank(Actors.MINTER1);
        (uint256 out, uint256 repaid) = manager.redeem(address(eTSLA), 300e18, 0.5e18, 0, address(0));
        assertEq(repaid, 300e18);
        assertEq(out, 0.5e18);

        // Owner: 1.5 legacy ($900) vs 500 debt → can withdraw down to 150% = $750 → 0.25 legacy.
        vm.startPrank(Actors.MINTER1);
        vm.expectRevert();
        manager.withdrawCollateral(address(eTSLA), 0.25e18 + 1, address(0));
        manager.withdrawCollateral(address(eTSLA), 0.25e18, address(0));
        vm.stopPrank();
        assertEq(manager.collateralRatioBps(address(eTSLA), Actors.MINTER1), 15_000);
    }

    function test_reverseSplit_noPhantomBacking() public {
        _migrate(0.5e18); // 1:2 reverse
        _setOraclePrice(ASSET, PX * 2);
        assertEq(manager.collateralRatioBps(address(eTSLA), Actors.MINTER1), 15_000);
        vm.startPrank(Actors.MINTER1);
        vm.expectRevert();
        manager.mint(address(eTSLA), 100e18, address(0));
        vm.expectRevert();
        manager.withdrawCollateral(address(eTSLA), 1, address(0));
        vm.stopPrank();
    }

    function test_addCollateral_afterSplit_rejectsLegacyAcceptsActive() public {
        // Two migrations: eTSLA → v2 → v3. v2 is legacy and never onboarded; v3 is active.
        _migrate(2e18);
        EToken eTSLAv3 = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));
        vm.startPrank(Actors.ADMIN);
        assetRegistry.migrateToken(ASSET, address(eTSLAv3), 1e18);
        manager.setCollateralEnabled(address(eTSLA), false);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.LegacyCollateral.selector, address(eTSLAv2)));
        manager.addCollateral(address(eTSLAv2), ASSET);
        manager.addCollateral(address(eTSLAv3), ASSET);
        vm.stopPrank();
        assertTrue(manager.collateralConfig(address(eTSLAv3)).enabled);
        // The original position is now two hops legacy (ratio re-based to 2e18) and still exact.
        _setOraclePrice(ASSET, PX / 2);
        assertEq(manager.collateralRatioBps(address(eTSLA), Actors.MINTER1), 15_000);
    }
}
