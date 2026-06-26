// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {ETokenFactory} from "../../src/tokens/ETokenFactory.sol";

/// @title AddAssetsMainnet — Register the launch asset set (Base mainnet)
/// @notice For each asset: creates its EToken, registers it in the AssetRegistry (in-house oracle),
///         and sets the per-asset USD issuance cap on the VaultManager. Run by the deployer (= admin)
///         after DeployMainnet.s.sol. Only PROTOCOL_REGISTRY is read from env.
///
/// Launch set (6): MU (Micron), SPCX (SpaceX), MSFT (Microsoft), GOOG (Alphabet), TSLA (Tesla),
/// SPY (S&P 500 ETF). NOTE: SPCX IPO'd 2026-06-12 — confirm the oracle data provider serves an SPCX
/// quote before flipping it active, else pullAssetPrice reverts PriceUnavailable.
///
/// Usage:
///   forge script script/mainnet/AddAssetsMainnet.s.sol --rpc-url base --broadcast --verify
contract AddAssetsMainnet is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // eToken reward/payment token
    address constant PROTOCOL_REGISTRY = 0xAb3C9c1A5cf70fA63AF59644Dd45F82392206C04; // Base mainnet deploy
    uint8 constant ORACLE_TYPE_INHOUSE = 1;

    /// @dev Per-asset USD issuance ceiling (18-decimal USD). 0 blocks minting. Tune per asset.
    uint256 constant ASSET_CAP_USD = 1_000_000e18;

    function run() external {
        IProtocolRegistry registry = IProtocolRegistry(PROTOCOL_REGISTRY);
        ETokenFactory factory = ETokenFactory(registry.etokenFactory());
        AssetRegistry assetRegistry = AssetRegistry(registry.assetRegistry());
        VaultManager vaultManager = VaultManager(registry.vaultManager());

        uint256 n = 6;
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

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET"));

        for (uint256 i = 0; i < n; i++) {
            address eToken = factory.createEToken(names[i], symbols[i], tickers[i], USDC);
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
            console.log(symbols[i], eToken);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Assets Added ===", n);
        console.log("Per-asset cap (USD 1e18):", ASSET_CAP_USD);
        console.log("Keepers must pullAssetPrice(ticker) before any mint.");
    }
}
