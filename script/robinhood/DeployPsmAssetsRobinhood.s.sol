// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {ReserveVault} from "../../src/core/ReserveVault.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DeployPsmAssetsRobinhood — PSM reserves for the remaining launch assets
/// @notice Completes PSM coverage after DeployPsmRobinhood (TSLA). For each of the 6 remaining
///         assets: sets the wrapper ticker's oracle config, registers the wrapper ticker (Gen-2
///         token, not mintable — no cap), deploys its ReserveVault, registers it as the asset's
///         RWA reserve, and wires setPsmConfig. The global ratio-jump bound (150 bps) is already
///         armed, so each route goes live as soon as its wrapper feed is published and pulled.
///
///         On-chain safety check: each Gen-2 token's symbol() and decimals() are asserted inside
///         the run before any state change — a wrong address aborts the whole broadcast.
///
///         All 6 Gen-2 tokens were validated pre-deploy (2026-07-14): symbol/decimals/uiMultiplier
///         on-chain + the WrapperRobinhoodFork custody suite per token.
///
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD (ADMIN + OPERATOR), PROTOCOL_REGISTRY_ROBINHOOD,
///      RESERVE_MANAGER_ROBINHOOD (operating VM — skim/sweep entity)
///
/// Usage:
///   forge script script/robinhood/DeployPsmAssetsRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployPsmAssetsRobinhood is Script {
    uint8 constant ORACLE_TYPE_INHOUSE = 1;
    uint256 constant MAX_STALENESS = 3600; // 1 hour — matches the launch tickers
    uint256 constant MAX_DEVIATION_BPS = 2000; // 20%

    struct PsmAsset {
        bytes32 backedAsset; // protocol asset ticker (must be registered by AddAssetsRobinhood)
        bytes32 wrapperTicker; // oracle feed for the Gen-2 TOKEN price (incl. uiMultiplier)
        string expectedSymbol; // on-chain symbol() assertion before any state change
        address wrapper; // Gen-2 Stock Token (docs.robinhood.com/chain/contracts, verified)
        uint8 vol; // informational, mirrors the eToken's volatility level
    }

    function _assets() internal pure returns (PsmAsset[] memory a) {
        a = new PsmAsset[](6);
        a[0] = PsmAsset(bytes32("MU"), bytes32("R.MU"), "MU", 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 2);
        a[1] = PsmAsset(bytes32("SPCX"), bytes32("R.SPCX"), "SPCX", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 3);
        a[2] = PsmAsset(bytes32("MSFT"), bytes32("R.MSFT"), "MSFT", 0xe93237C50D904957Cf27E7B1133b510C669c2e74, 2);
        a[3] = PsmAsset(bytes32("GOOGL"), bytes32("R.GOOGL"), "GOOGL", 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 2);
        a[4] = PsmAsset(bytes32("SPY"), bytes32("R.SPY"), "SPY", 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 1);
        a[5] = PsmAsset(bytes32("QQQ"), bytes32("R.QQQ"), "QQQ", 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, 1);
    }

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        AssetRegistry assetRegistry = AssetRegistry(registry.assetRegistry());
        VaultManager vaultManager = VaultManager(registry.vaultManager());
        OracleVerifier oracle = OracleVerifier(registry.inhouseOracle());
        address reserveManager = vm.envAddress("RESERVE_MANAGER_ROBINHOOD");

        PsmAsset[] memory assets = _assets();

        // Validate every wrapper address on-chain BEFORE any state change.
        for (uint256 i = 0; i < assets.length; i++) {
            IERC20Metadata t = IERC20Metadata(assets[i].wrapper);
            require(
                keccak256(bytes(t.symbol())) == keccak256(bytes(assets[i].expectedSymbol)), "wrapper symbol mismatch"
            );
            require(t.decimals() == 18, "wrapper decimals != 18");
        }

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        for (uint256 i = 0; i < assets.length; i++) {
            PsmAsset memory a = assets[i];

            // 0. Oracle config so the wrapper feed can actually be pushed.
            oracle.setAssetOracleConfig(a.wrapperTicker, MAX_STALENESS, MAX_DEVIATION_BPS);

            // 1. Wrapper ticker registration (price feed slot; never mintable — no cap set).
            assetRegistry.addAsset(
                a.wrapperTicker,
                a.wrapper,
                AssetConfig({
                    activeToken: a.wrapper,
                    legacyTokens: new address[](0),
                    active: true,
                    volatilityLevel: a.vol,
                    oracleType: ORACLE_TYPE_INHOUSE
                })
            );

            // 2. ReserveVault custody + RWA-reserve registration (nets against the asset's exposure).
            ReserveVault reserve = new ReserveVault(a.wrapper, address(registry), reserveManager);
            vaultManager.registerVault(address(reserve), a.wrapperTicker, a.backedAsset);

            // 3. PSM route. Ratio-jump bound is global and already armed (150 bps).
            assetRegistry.setPsmConfig(a.backedAsset, a.wrapper, address(reserve));

            console.log(string.concat("RESERVE ", a.expectedSymbol, ":"), address(reserve));
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== PSM configured for 6 assets (TSLA was done at launch) ===");
        console.log("NEXT: oracle service publishes each R.* TOKEN price (incl. uiMultiplier);");
        console.log("keeper pullCollateralPrice(reserve) per reserve once feeds are live.");
    }
}
