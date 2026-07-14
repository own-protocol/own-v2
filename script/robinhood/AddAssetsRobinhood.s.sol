// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {ETokenFactory} from "../../src/tokens/ETokenFactory.sol";

/// @title AddAssetsRobinhood — Register the launch asset set (Robinhood Chain)
/// @notice For each asset: creates its EToken (USDG reward token), registers it in the AssetRegistry
///         (in-house oracle), sets the per-asset USD issuance cap on the VaultManager, and arms the
///         per-asset fail-closed grants (v2 default-deny): maker allowlist (RFQ settlement),
///         lending-vault allowlist (borrows), and force-execute vault pool. Without the grants every
///         one of those paths reverts. Run by the deployer (= admin) after DeployRobinhood.s.sol.
///
/// Launch set (7): MU, SPCX, MSFT, GOOG, TSLA, SPY, QQQ. Confirm the set before running —
/// eToken tickers are protocol-native and independent of the Gen-2 Stock Token listings, but PSM
/// backing (DeployPsmRobinhood) is only possible for assets with a Gen-2 token on this chain
/// (note: Gen-2 lists GOOGL, not GOOG). SPCX: confirm the oracle data provider serves a quote
/// before flipping it active, else pullAssetPrice reverts PriceUnavailable.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, PROTOCOL_REGISTRY_ROBINHOOD,
///      VAULT_ADDRESS_ROBINHOOD (collateral vault from DeployRobinhood),
///      QUOTE_SIGNER_ROBINHOOD (registered RFQ signer)
///
/// Usage:
///   forge script script/robinhood/AddAssetsRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract AddAssetsRobinhood is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // eToken reward/payment token
    uint8 constant ORACLE_TYPE_INHOUSE = 1;

    /// @dev Per-asset USD issuance ceiling (18-decimal USD). 0 blocks minting. Tune per asset.
    uint256 constant ASSET_CAP_USD = 1_000_000e18;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(vm.envAddress("PROTOCOL_REGISTRY_ROBINHOOD"));
        ETokenFactory factory = ETokenFactory(registry.etokenFactory());
        AssetRegistry assetRegistry = AssetRegistry(registry.assetRegistry());
        VaultManager vaultManager = VaultManager(registry.vaultManager());

        uint256 n = 7;
        bytes32[] memory tickers = new bytes32[](n);
        string[] memory names = new string[](n);
        string[] memory symbols = new string[](n);
        uint8[] memory vols = new uint8[](n); // 1 = broad/low, 2 = single-stock, 3 = high-vol

        (tickers[0], names[0], symbols[0], vols[0]) = (bytes32("MU"), "Micron", "eMU", 2);
        (tickers[1], names[1], symbols[1], vols[1]) = (bytes32("SPCX"), "SpaceX", "eSPCX", 3);
        (tickers[2], names[2], symbols[2], vols[2]) = (bytes32("MSFT"), "Microsoft", "eMSFT", 2);
        (tickers[3], names[3], symbols[3], vols[3]) = (bytes32("GOOG"), "Alphabet", "eGOOG", 2);
        (tickers[4], names[4], symbols[4], vols[4]) = (bytes32("TSLA"), "Tesla", "eTSLA", 2);
        (tickers[5], names[5], symbols[5], vols[5]) = (bytes32("SPY"), "S&P 500 ETF", "eSPY", 1);
        (tickers[6], names[6], symbols[6], vols[6]) = (bytes32("QQQ"), "Nasdaq-100 ETF", "eQQQ", 1);

        address vault = vm.envAddress("VAULT_ADDRESS_ROBINHOOD");
        address quoteSigner = vm.envAddress("QUOTE_SIGNER_ROBINHOOD");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD"));

        for (uint256 i = 0; i < n; i++) {
            address eToken = factory.createEToken(names[i], symbols[i], tickers[i], USDG);
            assetRegistry.addAsset(
                tickers[i],
                eToken,
                AssetConfig({
                    activeToken: eToken,
                    legacyTokens: new address[](0),
                    active: true,
                    volatilityLevel: vols[i],
                    oracleType: ORACLE_TYPE_INHOUSE
                })
            );
            vaultManager.setAssetCapUSD(tickers[i], ASSET_CAP_USD);

            // Arm the per-asset fail-closed grants (all default-deny in v2).
            assetRegistry.setMakerAllowed(tickers[i], quoteSigner, true);
            assetRegistry.setLendingVaultAllowed(tickers[i], vault, true);
            assetRegistry.setForceExecuteVaultAllowed(tickers[i], vault, true);

            console.log(symbols[i], eToken);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Assets Added ===", n);
        console.log("Per-asset cap (USD 1e18):", ASSET_CAP_USD);
        console.log("Maker / lending / force-execute grants armed for:", vault);
        console.log("Keepers must pullAssetPrice(ticker) before any mint.");
    }
}
