// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {NettingHandler, NettingStubVault} from "./handlers/NettingHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Minimal asset registry stub: every ticker resolves to the in-house oracle.
contract NettingStubAssetRegistry {
    function getOracleType(
        bytes32
    ) external pure returns (uint8) {
        return 1;
    }
}

/// @title NettingInvariant — per-asset delta-netting accounting invariants
/// @notice After ANY sequence of exposure changes, keeper re-marks, collateral releases, and
///         vault halts/unhalts, the running totals must satisfy:
///           INV-N1: globalNetExposureUSD  == Σ_a max(0, assetExposureUSD[a] − assetRwaCollateralUSD[a])
///           INV-N2: globalCollateralUSD == Σ collateralMark over GENERIC vaults
///           INV-N3: assetRwaCollateralUSD[a] == Σ collateralMark over RWA vaults backing `a`
contract NettingInvariantTest is Test {
    VaultManager internal manager;
    ProtocolRegistry internal registry;
    MockOracleVerifier internal oracle;
    NettingHandler internal handler;

    NettingStubVault internal genericVault;
    NettingStubVault internal rwaTsla1;
    NettingStubVault internal rwaTsla2;
    NettingStubVault internal rwaGold;

    address internal admin = Actors.ADMIN;
    address internal market = makeAddr("market");

    bytes32 internal constant TSLA = bytes32("TSLA");
    bytes32 internal constant GOLD = bytes32("GOLD");
    bytes32 internal constant USDC_TICKER = bytes32("USDC");
    bytes32 internal constant ONDO_TSLA = bytes32("ONDO.TSLA");
    bytes32 internal constant XS_TSLA = bytes32("XS.TSLA");
    bytes32 internal constant ONDO_GOLD = bytes32("ONDO.GOLD");

    function setUp() public {
        registry = new ProtocolRegistry(admin, 0, 2 minutes);
        NettingStubAssetRegistry assetRegistry = new NettingStubAssetRegistry();
        oracle = new MockOracleVerifier();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 wrapper = new MockERC20("Wrapper", "WRAP", 18);

        genericVault = new NettingStubVault(address(usdc));
        rwaTsla1 = new NettingStubVault(address(wrapper));
        rwaTsla2 = new NettingStubVault(address(wrapper));
        rwaGold = new NettingStubVault(address(wrapper));

        vm.startPrank(admin);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);
        registry.setAddress(registry.MARKET(), market);
        registry.setAddress(registry.ASSET_REGISTRY(), address(assetRegistry));
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracle));
        registry.setAddress(registry.PYTH_ORACLE(), address(oracle));
        vm.stopPrank();

        manager = new VaultManager(IProtocolRegistry(address(registry)));

        oracle.setPrice(TSLA, 100e18);
        oracle.setPrice(GOLD, 2000e18);
        oracle.setPrice(USDC_TICKER, 1e18);
        oracle.setPrice(ONDO_TSLA, 100e18);
        oracle.setPrice(XS_TSLA, 100e18);
        oracle.setPrice(ONDO_GOLD, 2000e18);

        vm.startPrank(admin);
        manager.setGlobalMaxUtilizationBps(8000);
        manager.setMaxMarkAge(365 days);
        manager.setAssetCapUSD(TSLA, type(uint128).max);
        manager.setAssetCapUSD(GOLD, type(uint128).max);
        manager.registerVault(address(genericVault), USDC_TICKER);
        manager.registerVault(address(rwaTsla1), ONDO_TSLA, TSLA);
        manager.registerVault(address(rwaTsla2), XS_TSLA, TSLA);
        manager.registerVault(address(rwaGold), ONDO_GOLD, GOLD);
        vm.stopPrank();

        // Seed marks so exposure can open from the first handler call.
        genericVault.setTotalAssets(10_000_000e6); // $10M generic pool
        manager.pullCollateralPrice(address(genericVault));
        manager.pullAssetPrice(TSLA);
        manager.pullAssetPrice(GOLD);

        handler = new NettingHandler(
            manager,
            oracle,
            market,
            [TSLA, GOLD],
            [USDC_TICKER, ONDO_TSLA, XS_TSLA, ONDO_GOLD],
            [genericVault, rwaTsla1, rwaTsla2, rwaGold]
        );
        targetContract(address(handler));
    }

    /// @notice INV-N1: the global net exposure running total equals the recomputed netted sum.
    function invariant_globalExposureIsNettedSum() external view {
        uint256 expected = _net(TSLA) + _net(GOLD);
        assertEq(manager.globalNetExposureUSD(), expected, "net exposure running total diverged");
    }

    /// @notice INV-N2: the generic collateral running total counts generic vaults only.
    function invariant_globalCollateralIsGenericOnly() external view {
        assertEq(
            manager.globalCollateralUSD(),
            manager.collateralMark(address(genericVault)),
            "generic collateral running total diverged"
        );
    }

    /// @notice INV-N3: each asset's RWA reserve total equals the sum of its backing vaults' marks.
    function invariant_rwaReserveSumsMatchMarks() external view {
        assertEq(
            manager.assetRwaCollateralUSD(TSLA),
            manager.collateralMark(address(rwaTsla1)) + manager.collateralMark(address(rwaTsla2)),
            "TSLA reserve total diverged"
        );
        assertEq(
            manager.assetRwaCollateralUSD(GOLD), manager.collateralMark(address(rwaGold)), "GOLD reserve total diverged"
        );
    }

    /// @dev Recompute an asset's netted contribution from public views.
    function _net(
        bytes32 asset
    ) private view returns (uint256) {
        uint256 e = manager.assetExposureUSD(asset);
        uint256 r = manager.assetRwaCollateralUSD(asset);
        return e > r ? e - r : 0;
    }
}
