// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {ReserveVault} from "../../src/core/ReserveVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";

/// @title DeployPsmMainnet — PSM configuration for the v2 launch (Base mainnet)
/// @notice Run after DeployMainnet.s.sol + AddAssetsMainnet.s.sol. Registers the wrapper
///         ticker (so its oracle feed resolves), deploys the ReserveVault, registers it as the
///         backed asset's RWA reserve on the VaultManager, wires the PSM config, and sets the
///         global ratio-jump bound. PSM mint/redeem stays inert until the bound is non-zero
///         (fail-closed), so running this script is what turns the PSM on.
///
/// @dev ⚠️ PLACEHOLDER CONFIG — WRAPPER_TOKEN / WRAPPER_TICKER / BACKED_ASSET are dummy values.
///      Set the real issuer token (pending issuer decision — e.g. Dinari dTSLA on Base), the
///      real ticker string, and the target asset before running. The oracle service must
///      publish the wrapper TOKEN price under WRAPPER_TICKER (raw token price for a
///      price-tracking issuer like Dinari; share price × sValue for a total-return issuer
///      like Ondo). Pre-verify the token with test/fork/WrapperBaseFork.t.sol
///      (WRAPPER_TOKEN_BASE env).
///
/// Env: DEPLOYER_PRIVATE_KEY_MAINNET (deployer must hold ADMIN + OPERATOR),
///      PROTOCOL_REGISTRY_MAINNET, RESERVE_MANAGER_MAINNET (operating VM — skim/sweep entity)
///
/// Usage:
///   forge script script/mainnet/DeployPsmMainnet.s.sol --rpc-url base --broadcast --verify
contract DeployPsmMainnet is Script {
    uint8 constant ORACLE_TYPE_INHOUSE = 1;

    // ═════════════════════════════════════════════════════════════
    //  PSM config — ⚠️ ALL PLACEHOLDERS, set real values pre-deploy
    // ═════════════════════════════════════════════════════════════

    /// @dev The launch asset the PSM backs (must already be registered by AddAssetsMainnet).
    bytes32 constant BACKED_ASSET = bytes32("TSLA");

    /// @dev Wrapper token custodied by the ReserveVault. ⚠️ DUMMY — replace with the selected
    ///      issuer's Base token address once the issuer decision is final.
    address constant WRAPPER_TOKEN = address(0xBEEF);

    /// @dev Oracle ticker for the wrapper token's price feed. ⚠️ DUMMY name.
    bytes32 constant WRAPPER_TICKER = bytes32("W.TSLA");

    /// @dev PSM ratio-jump guard bound (BPS). 100–200 recommended; must be non-zero — this is
    ///      the switch that activates PSM mint/redeem protocol-wide.
    uint256 constant RATIO_JUMP_BOUND_BPS = 150;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_MAINNET"));
        AssetRegistry assetRegistry = AssetRegistry(registry.assetRegistry());
        VaultManager vaultManager = VaultManager(registry.vaultManager());
        // Skim/sweep destination + operating entity for the reserve (the VM address).
        address reserveManager = vm.envAddress("RESERVE_MANAGER_MAINNET");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET"));

        // 1. Wrapper ticker so getOracleType resolves its feed (same pattern as the collateral
        //    ticker in DeployMainnet). Not mintable: no asset cap is ever set for it.
        assetRegistry.addAsset(
            WRAPPER_TICKER,
            WRAPPER_TOKEN,
            AssetConfig({
                activeToken: WRAPPER_TOKEN,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: ORACLE_TYPE_INHOUSE
            })
        );

        // 2. ReserveVault custodies the wrapper; registered as the backed asset's RWA reserve
        //    so its balance nets against outstanding exposure.
        ReserveVault reserve = new ReserveVault(WRAPPER_TOKEN, address(registry), reserveManager);
        vaultManager.registerVault(address(reserve), WRAPPER_TICKER, BACKED_ASSET);

        // 3. PSM route + the fail-closed ratio guard (non-zero bound activates mint/redeem).
        assetRegistry.setPsmConfig(BACKED_ASSET, WRAPPER_TOKEN, address(reserve));
        assetRegistry.setRatioJumpBoundBps(RATIO_JUMP_BOUND_BPS);

        vm.stopBroadcast();

        console.log("=== PSM Configured ===");
        console.log("RESERVE_VAULT=", address(reserve));
        console.log("Reserve manager:", reserveManager);
        console.log("Ratio-jump bound (BPS):", RATIO_JUMP_BOUND_BPS);
        console.log("");
        console.log("NEXT:");
        console.log(" 1. Oracle service: publish the wrapper TOKEN price under the wrapper ticker.");
        console.log(" 2. Keeper: pullCollateralPrice(reserve) once a feed is live.");
        console.log(" 3. Verify with a small psmMint/psmRedeem round-trip before announcing.");
    }
}
