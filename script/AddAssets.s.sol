// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../src/core/AssetRegistry.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../src/interfaces/types/Types.sol";
import {ETokenFactory} from "../src/tokens/ETokenFactory.sol";

/// @title AddAssets — Batch-register the US stocks + ETFs asset set
/// @notice For each asset: creates its EToken, registers it in the AssetRegistry (in-house oracle),
///         and sets the per-asset USD issuance cap on the VaultManager. All dependencies are
///         resolved from the ProtocolRegistry. Run by deployer (= admin) after Deploy.s.sol.
///
/// Assets use oracleType = 1 (in-house OracleVerifier) — deploy + register that first via
/// DeployOracleSigner.s.sol so prices can be pulled. TSLA/GOLD/ETH are already added by Deploy.s.sol.
///
/// Usage:
///   forge script script/AddAssets.s.sol --rpc-url base_sepolia --broadcast --verify
contract AddAssets is Script {
    /// @dev Testnet USDC — the eToken reward/payment token (must match Deploy.s.sol).
    address constant TESTNET_USDC = 0x6f5BB5824C8D572966a1DED0470AF3E72C527613;

    uint8 constant ORACLE_TYPE_INHOUSE = 1;

    /// @dev Per-asset USD issuance ceiling (18-decimal USD). 0 would block minting.
    uint256 constant ASSET_CAP_USD = 10_000_000e18;

    function run() external {
        address registryAddr = vm.envAddress("PROTOCOL_REGISTRY");
        IProtocolRegistry registry = IProtocolRegistry(registryAddr);

        ETokenFactory factory = ETokenFactory(registry.etokenFactory());
        AssetRegistry assetRegistry = AssetRegistry(registry.assetRegistry());
        VaultManager vaultManager = VaultManager(registry.vaultManager());

        console.log("ProtocolRegistry:", registryAddr);
        console.log("ETokenFactory:", address(factory));
        console.log("AssetRegistry:", address(assetRegistry));
        console.log("VaultManager:", address(vaultManager));

        // ── Asset set: 14 US stocks + 5 US ETFs (TSLA already live from Deploy.s.sol) ──
        bytes32[] memory tickers = new bytes32[](19);
        string[] memory names = new string[](19);
        string[] memory symbols = new string[](19);
        uint8[] memory vols = new uint8[](19);

        // US stocks (medium volatility = 2)
        (tickers[0], names[0], symbols[0], vols[0]) = (bytes32("AAPL"), "Apple", "eAAPL", 2);
        (tickers[1], names[1], symbols[1], vols[1]) = (bytes32("NVDA"), "Nvidia", "eNVDA", 2);
        (tickers[2], names[2], symbols[2], vols[2]) = (bytes32("AMZN"), "Amazon", "eAMZN", 2);
        (tickers[3], names[3], symbols[3], vols[3]) = (bytes32("MSFT"), "Microsoft", "eMSFT", 2);
        (tickers[4], names[4], symbols[4], vols[4]) = (bytes32("META"), "Meta", "eMETA", 2);
        (tickers[5], names[5], symbols[5], vols[5]) = (bytes32("GOOG"), "Alphabet", "eGOOG", 2);
        (tickers[6], names[6], symbols[6], vols[6]) = (bytes32("COIN"), "Coinbase", "eCOIN", 3);
        (tickers[7], names[7], symbols[7], vols[7]) = (bytes32("MSTR"), "MicroStrategy", "eMSTR", 3);
        (tickers[8], names[8], symbols[8], vols[8]) = (bytes32("AMD"), "AMD", "eAMD", 2);
        (tickers[9], names[9], symbols[9], vols[9]) = (bytes32("PLTR"), "Palantir", "ePLTR", 3);
        (tickers[10], names[10], symbols[10], vols[10]) = (bytes32("TSM"), "TSMC", "eTSM", 2);
        (tickers[11], names[11], symbols[11], vols[11]) = (bytes32("NFLX"), "Netflix", "eNFLX", 2);
        (tickers[12], names[12], symbols[12], vols[12]) = (bytes32("HOOD"), "Robinhood", "eHOOD", 3);
        (tickers[13], names[13], symbols[13], vols[13]) = (bytes32("WMT"), "Walmart", "eWMT", 1);

        // US ETFs (broad index = 1, sector/tech = 2)
        (tickers[14], names[14], symbols[14], vols[14]) = (bytes32("SPY"), "S&P 500 ETF", "eSPY", 1);
        (tickers[15], names[15], symbols[15], vols[15]) = (bytes32("QQQ"), "Nasdaq 100 ETF", "eQQQ", 2);
        (tickers[16], names[16], symbols[16], vols[16]) = (bytes32("TLT"), "20+ Year Treasury ETF", "eTLT", 1);
        (tickers[17], names[17], symbols[17], vols[17]) = (bytes32("MAGS"), "Magnificent Seven ETF", "eMAGS", 2);
        (tickers[18], names[18], symbols[18], vols[18]) = (bytes32("ITA"), "US Aerospace & Defense ETF", "eITA", 2);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        for (uint256 i = 0; i < tickers.length; i++) {
            address eToken = factory.createEToken(names[i], symbols[i], tickers[i], TESTNET_USDC);

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
        console.log("=== Assets Added ===");
        console.log("Registered assets:", tickers.length);
        console.log("Oracle type: in-house (1). Cap (USD 1e18):", ASSET_CAP_USD);
    }
}
