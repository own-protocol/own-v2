// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../src/core/FeeCalculator.sol";

import {OwnMarket} from "../src/core/OwnMarket.sol";
import {ProtocolRegistry} from "../src/core/ProtocolRegistry.sol";
import {PythOracleVerifier} from "../src/core/PythOracleVerifier.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";

import {AssetConfig} from "../src/interfaces/types/Types.sol";
import {WETHRouter} from "../src/periphery/WETHRouter.sol";
import {EToken} from "../src/tokens/EToken.sol";
import {MockERC20} from "../test/helpers/MockERC20.sol";

/// @title Deploy — Deploy all core Own Protocol contracts to Base Sepolia
/// @notice Deploys contracts, registers them in ProtocolRegistry, configures oracle feeds,
///         adds assets, and sets fee levels. Run by deployer (= protocol admin).
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
contract Deploy is Script {
    // ──────────────────────────────────────────────────────────
    //  External addresses (Base Sepolia)
    // ──────────────────────────────────────────────────────────

    address constant PYTH = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // ──────────────────────────────────────────────────────────
    //  Pyth feed IDs
    // ──────────────────────────────────────────────────────────

    bytes32 constant TSLA_FEED = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 constant XAU_FEED = 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2;
    bytes32 constant ETH_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    // ──────────────────────────────────────────────────────────
    //  Asset tickers
    // ──────────────────────────────────────────────────────────

    bytes32 constant TSLA = bytes32("TSLA");
    bytes32 constant GOLD = bytes32("GOLD");
    bytes32 constant ETH = bytes32("ETH");

    // ──────────────────────────────────────────────────────────
    //  Configuration
    // ──────────────────────────────────────────────────────────

    uint256 constant TIMELOCK_DELAY = 2 days;
    uint256 constant PYTH_MAX_PRICE_AGE = 120; // 2 minutes
    uint256 constant PROTOCOL_SHARE_BPS = 2000; // 20%

    function run() external {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // ── 1. Mock USDC (testnet payment token) ────────────
        MockERC20 mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        console.log("MockUSDC:", address(mockUSDC));

        // ── 2. ProtocolRegistry ─────────────────────────────
        ProtocolRegistry registry = new ProtocolRegistry(deployer, TIMELOCK_DELAY);
        console.log("ProtocolRegistry:", address(registry));

        // ── 3. AssetRegistry ────────────────────────────────
        AssetRegistry assetRegistry = new AssetRegistry(deployer);
        console.log("AssetRegistry:", address(assetRegistry));

        // ── 4. FeeCalculator ────────────────────────────────
        FeeCalculator feeCalc = new FeeCalculator(address(registry), deployer);
        console.log("FeeCalculator:", address(feeCalc));

        // Set fee levels: volatility 1 (low), 2 (medium), 3 (high)
        // Mint fees
        feeCalc.setMintFee(1, 50); // 0.50%
        feeCalc.setMintFee(2, 100); // 1.00%
        feeCalc.setMintFee(3, 200); // 2.00%
        // Redeem fees
        feeCalc.setRedeemFee(1, 25); // 0.25%
        feeCalc.setRedeemFee(2, 50); // 0.50%
        feeCalc.setRedeemFee(3, 100); // 1.00%

        // ── 5. PythOracleVerifier ───────────────────────────
        PythOracleVerifier pythOracle = new PythOracleVerifier(deployer, PYTH, PYTH_MAX_PRICE_AGE);
        console.log("PythOracleVerifier:", address(pythOracle));

        // Configure feed IDs (session 0 = regular market hours)
        pythOracle.setFeedId(TSLA, 0, TSLA_FEED);
        pythOracle.setFeedId(GOLD, 0, XAU_FEED);
        pythOracle.setFeedId(ETH, 0, ETH_FEED);

        // ── 6. VaultFactory ─────────────────────────────────
        VaultFactory factory = new VaultFactory(deployer, address(registry));
        console.log("VaultFactory:", address(factory));

        // ── 7. OwnMarket ────────────────────────────────────
        OwnMarket market = new OwnMarket(address(registry));
        console.log("OwnMarket:", address(market));

        // ── 8. ETokens ──────────────────────────────────────
        EToken eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(registry), address(mockUSDC));
        console.log("EToken TSLA:", address(eTSLA));

        EToken eGOLD = new EToken("Own Gold", "eGOLD", GOLD, address(registry), address(mockUSDC));
        console.log("EToken GOLD:", address(eGOLD));

        // ── 9. WETHRouter ───────────────────────────────────
        WETHRouter wethRouter = new WETHRouter(WETH);
        console.log("WETHRouter:", address(wethRouter));

        // ── 10. Register contracts in ProtocolRegistry ──────
        registry.setAddress(registry.ASSET_REGISTRY(), address(assetRegistry));
        registry.setAddress(registry.TREASURY(), treasury);
        registry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));
        registry.setAddress(registry.VAULT_FACTORY(), address(factory));
        registry.setAddress(registry.MARKET(), address(market));
        registry.setAddress(registry.PYTH_ORACLE(), address(pythOracle));
        registry.setProtocolShareBps(PROTOCOL_SHARE_BPS);

        // ── 11. Add assets to AssetRegistry ─────────────────
        // TSLA — volatility level 2 (medium), oracleType 0 (Pyth)
        assetRegistry.addAsset(
            TSLA,
            address(eTSLA),
            AssetConfig({
                activeToken: address(eTSLA),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 0
            })
        );

        // GOLD — volatility level 1 (low), oracleType 0 (Pyth)
        assetRegistry.addAsset(
            GOLD,
            address(eGOLD),
            AssetConfig({
                activeToken: address(eGOLD),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 1,
                oracleType: 0
            })
        );

        // ETH — registered for collateral pricing (no eToken), oracleType 0 (Pyth)
        assetRegistry.addAsset(
            ETH,
            WETH,
            AssetConfig({
                activeToken: WETH,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 0
            })
        );

        vm.stopBroadcast();

        // ── Summary ─────────────────────────────────────────
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Update .env with these addresses:");
        console.log("MOCK_USDC=", address(mockUSDC));
        console.log("PROTOCOL_REGISTRY=", address(registry));
        console.log("ASSET_REGISTRY=", address(assetRegistry));
        console.log("FEE_CALCULATOR=", address(feeCalc));
        console.log("PYTH_ORACLE=", address(pythOracle));
        console.log("VAULT_FACTORY=", address(factory));
        console.log("OWN_MARKET=", address(market));
        console.log("ETOKEN_TSLA=", address(eTSLA));
        console.log("ETOKEN_GOLD=", address(eGOLD));
        console.log("WETH_ROUTER=", address(wethRouter));
    }
}
