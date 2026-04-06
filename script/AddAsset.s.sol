// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../src/core/AssetRegistry.sol";
import {ETokenFactory} from "../src/tokens/ETokenFactory.sol";
import {AssetConfig} from "../src/interfaces/types/Types.sol";

/// @title AddAsset — Create a new EToken and register the asset
/// @notice Deploys a new EToken via ETokenFactory and registers it in the AssetRegistry.
///         Configure the constants below before each deployment.
///
/// Usage:
///   forge script script/AddAsset.s.sol --rpc-url base_sepolia --broadcast --verify
contract AddAsset is Script {
    // ──────────────────────────────────────────────────────────
    //  Configure these per deployment
    // ──────────────────────────────────────────────────────────

    bytes32 constant TICKER = bytes32("AAPL");
    string constant NAME = "Apple";
    string constant SYMBOL = "eAAPL";
    uint8 constant VOLATILITY_LEVEL = 2; // 1=low, 2=medium, 3=high
    uint8 constant ORACLE_TYPE = 1; // 0=Pyth, 1=in-house

    // ──────────────────────────────────────────────────────────

    function run() external {
        address eTokenFactoryAddr = vm.envAddress("ETOKEN_FACTORY");
        address assetRegistryAddr = vm.envAddress("ASSET_REGISTRY");
        address paymentToken = vm.envAddress("MOCK_USDC");

        console.log("ETokenFactory:", eTokenFactoryAddr);
        console.log("AssetRegistry:", assetRegistryAddr);
        console.log("PaymentToken:", paymentToken);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // 1. Create EToken
        ETokenFactory factory = ETokenFactory(eTokenFactoryAddr);
        address eToken = factory.createEToken(NAME, SYMBOL, TICKER, paymentToken);
        console.log("EToken deployed:", eToken);

        // 2. Register asset
        AssetRegistry assetRegistry = AssetRegistry(assetRegistryAddr);
        assetRegistry.addAsset(
            TICKER,
            eToken,
            AssetConfig({
                activeToken: eToken,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: VOLATILITY_LEVEL,
                oracleType: ORACLE_TYPE
            })
        );
        console.log("Asset registered:", string(abi.encodePacked(TICKER)));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Asset Added ===");
        console.log("Ticker:", string(abi.encodePacked(TICKER)));
        console.log("EToken:", eToken);
        console.log("OracleType:", ORACLE_TYPE);
        console.log("VolatilityLevel:", VOLATILITY_LEVEL);
    }
}
