// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {ReserveVault} from "../../src/core/ReserveVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";

/// @title DeployPsmRobinhood — PSM configuration for the Robinhood Chain launch
/// @notice Run after DeployRobinhood.s.sol + AddAssetsRobinhood.s.sol. Registers the wrapper
///         ticker (so its oracle feed resolves), deploys the ReserveVault, registers it as the
///         backed asset's RWA reserve on the VaultManager, wires the PSM config, and sets the
///         global ratio-jump bound. PSM mint/redeem stays inert until the bound is non-zero
///         (fail-closed), so running this script is what turns the PSM on.
///
/// @dev Wrapper = Gen-2 Robinhood "Stock Token" (issuer: Robinhood Assets (Jersey) Ltd), a plain
///      ERC-20 (18 dec) with an ERC-8056 `uiMultiplier` (dividends reinvest via the multiplier;
///      splits jump it — hence the ratio-jump guard). ⚠️ PRE-DEPLOY GATES:
///        1. Read the wrapper's verified source on Blockscout — token-contract admin powers
///           (pause / freeze / upgrade) are still UNVERIFIED. Do not run until reviewed.
///        2. Pre-verify custody mechanics with the wrapper fork test (ROBINHOOD_RPC +
///           WRAPPER_TOKEN env): metadata, transfer restrictions, custody round-trip.
///        3. The oracle service must publish the wrapper TOKEN price (share price × uiMultiplier)
///           under WRAPPER_TICKER, and a keeper must pullCollateralPrice(reserve) pre-first-mint.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (deployer must hold ADMIN + OPERATOR),
///      PROTOCOL_REGISTRY_ROBINHOOD, RESERVE_MANAGER_ROBINHOOD (operating VM — skim/sweep entity)
///
/// Usage:
///   forge script script/robinhood/DeployPsmRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployPsmRobinhood is Script {
    uint8 constant ORACLE_TYPE_INHOUSE = 1;

    /// @dev The launch asset the PSM backs (must already be registered by AddAssetsRobinhood).
    bytes32 constant BACKED_ASSET = bytes32("TSLA");

    /// @dev Gen-2 TSLA Stock Token on Robinhood Chain (docs.robinhood.com/chain/contracts,
    ///      symbol verified on-chain). Confirm this is the intended backing before running.
    address constant WRAPPER_TOKEN = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    /// @dev Oracle ticker for the wrapper token's price feed (token price incl. uiMultiplier).
    bytes32 constant WRAPPER_TICKER = bytes32("R.TSLA");

    /// @dev PSM ratio-jump guard bound (BPS). 100–200 recommended; must be non-zero — this is
    ///      the switch that activates PSM mint/redeem protocol-wide. NOTE: a stock split jumps
    ///      the uiMultiplier far beyond this bound by design — follow the split runbook (halt,
    ///      re-mark, resume) rather than widening the bound.
    uint256 constant RATIO_JUMP_BOUND_BPS = 150;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        AssetRegistry assetRegistry = AssetRegistry(registry.assetRegistry());
        VaultManager vaultManager = VaultManager(registry.vaultManager());
        // Skim/sweep destination + operating entity for the reserve (the VM address).
        address reserveManager = vm.envAddress("RESERVE_MANAGER_ROBINHOOD");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        // 0. Oracle config for the wrapper ticker — without it every updatePrice(R.TSLA) reverts
        //    OracleConfigNotSet and no wrapper mark can ever go live (found in the launch smoke test).
        OracleVerifier(registry.inhouseOracle()).setAssetOracleConfig(WRAPPER_TICKER, 3600, 2000);

        // 1. Wrapper ticker so getOracleType resolves its feed (same pattern as the collateral
        //    ticker in DeployRobinhood). Not mintable: no asset cap is ever set for it.
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

        console.log("=== PSM Configured (Robinhood Chain) ===");
        console.log("RESERVE_VAULT=", address(reserve));
        console.log("Reserve manager:", reserveManager);
        console.log("Ratio-jump bound (BPS):", RATIO_JUMP_BOUND_BPS);
        console.log("");
        console.log("NEXT:");
        console.log(" 1. Oracle service: publish the Gen-2 TOKEN price (incl. uiMultiplier) under the wrapper ticker.");
        console.log(" 2. Keeper: pullCollateralPrice(reserve) once a feed is live.");
        console.log(" 3. Verify with a small psmMint/psmRedeem round-trip before announcing.");
    }
}
