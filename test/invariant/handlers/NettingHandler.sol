// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../../src/core/VaultManager.sol";
import {MockOracleVerifier} from "../../helpers/MockOracleVerifier.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @dev Minimal ERC-4626 surface for VaultManager marking (asset() + settable totalAssets()).
contract NettingStubVault {
    address public asset;
    uint256 public totalAssets;

    constructor(
        address asset_
    ) {
        asset = asset_;
    }

    function setTotalAssets(
        uint256 ta
    ) external {
        totalAssets = ta;
    }
}

/// @title NettingHandler — fuzz driver for the per-asset delta-netting accounting
/// @notice Exercises every VaultManager code path that mutates exposure, reserve, or generic
///         collateral: open/close exposure (as market), keeper price pulls on both sides,
///         collateral release, and vault halt/unhalt — across two assets, one generic vault,
///         and three RWA reserve vaults (two backing TSLA, one backing GOLD).
contract NettingHandler is CommonBase, StdCheats, StdUtils {
    VaultManager public immutable manager;
    MockOracleVerifier public immutable oracle;
    address public immutable market;

    bytes32[2] public assets; // [TSLA, GOLD]
    bytes32[4] public collateralTickers; // [USDC, ONDO.TSLA, XS.TSLA, ONDO.GOLD]
    NettingStubVault[4] public vaults; // [generic, rwa TSLA #1, rwa TSLA #2, rwa GOLD]

    constructor(
        VaultManager manager_,
        MockOracleVerifier oracle_,
        address market_,
        bytes32[2] memory assets_,
        bytes32[4] memory collateralTickers_,
        NettingStubVault[4] memory vaults_
    ) {
        manager = manager_;
        oracle = oracle_;
        market = market_;
        assets = assets_;
        collateralTickers = collateralTickers_;
        vaults = vaults_;
    }

    // ── Exposure (market paths) ──

    function openExposure(uint256 assetSeed, uint256 units) external {
        bytes32 asset = assets[assetSeed % 2];
        units = bound(units, 1e15, 1_000_000e18);
        vm.prank(market);
        try manager.openExposure(asset, units) {} catch {}
    }

    function closeExposure(uint256 assetSeed, uint256 units) external {
        bytes32 asset = assets[assetSeed % 2];
        uint256 have = manager.globalAssetUnits(asset);
        if (have == 0) return;
        units = bound(units, 1, have);
        vm.prank(market);
        try manager.closeExposure(asset, units) {} catch {}
    }

    // ── Keeper price pulls ──

    function pullAssetPrice(uint256 assetSeed, uint256 price) external {
        bytes32 asset = assets[assetSeed % 2];
        price = bound(price, 1e16, 100_000e18);
        oracle.setPrice(asset, price);
        manager.pullAssetPrice(asset);
    }

    function pullCollateralPrice(uint256 vaultSeed, uint256 price, uint256 ta) external {
        uint256 i = vaultSeed % 4;
        NettingStubVault v = vaults[i];
        if (manager.isVaultExcluded(address(v))) return;
        price = bound(price, 1e16, 100_000e18);
        // Generic vault holds 6-decimal USDC; RWA stubs hold 18-decimal wrappers.
        ta = i == 0 ? bound(ta, 0, 100_000_000e6) : bound(ta, 0, 10_000_000e18);
        oracle.setPrice(collateralTickers[i], price);
        v.setTotalAssets(ta);
        manager.pullCollateralPrice(address(v));
    }

    // ── Collateral release (vault path) ──

    function releaseCollateral(uint256 vaultSeed, uint256 amount) external {
        NettingStubVault v = vaults[vaultSeed % 4];
        uint256 ta = v.totalAssets();
        if (ta == 0) return;
        amount = bound(amount, 1, ta);
        // Mirrors OwnVault.releaseCollateral: mark sync first (assets still in the vault), then
        // the assets actually leave.
        vm.prank(address(v));
        manager.onCollateralReleased(amount);
        v.setTotalAssets(ta - amount);
    }

    // ── Vault halt / unhalt ──

    function haltVault(
        uint256 vaultSeed
    ) external {
        NettingStubVault v = vaults[vaultSeed % 4];
        if (manager.isVaultExcluded(address(v))) return;
        vm.prank(address(v));
        manager.onVaultHalted();
    }

    function unhaltVault(
        uint256 vaultSeed
    ) external {
        NettingStubVault v = vaults[vaultSeed % 4];
        if (!manager.isVaultExcluded(address(v))) return;
        vm.prank(address(v));
        manager.onVaultUnhalted();
    }
}
