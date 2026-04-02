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
import {ETokenFactory} from "../src/tokens/ETokenFactory.sol";
import {MockERC20} from "../test/helpers/MockERC20.sol";
import {MockWETH} from "../test/helpers/MockWETH.sol";

/// @title Deploy — Deploy all core Own Protocol contracts to Base Sepolia
/// @notice Deploys contracts, registers them in ProtocolRegistry, configures oracle feeds,
///         adds assets, and sets fee levels. Run by deployer (= protocol admin).
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
///
/// To deploy with a MockWETH instead of real WETH:
///   DEPLOY_MOCK_WETH=true forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
///   Then set WETH=<MockWETH address> and MOCK_WETH_COLLATERAL=true in ts-scripts/.env.
contract Deploy is Script {
    // ──────────────────────────────────────────────────────────
    //  External addresses (Base Sepolia)
    // ──────────────────────────────────────────────────────────

    address constant PYTH = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;
    address constant REAL_WETH = 0x4200000000000000000000000000000000000006;

    // ──────────────────────────────────────────────────────────
    //  Pyth feed IDs
    // ──────────────────────────────────────────────────────────

    // TSLA — 4 session feeds (regular, pre-market, post-market, overnight)
    bytes32 constant TSLA_FEED = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 constant TSLA_PRE_FEED = 0x42676a595d0099c381687124805c8bb22c75424dffcaa55e3dc6549854ebe20a;
    bytes32 constant TSLA_POST_FEED = 0x2a797e196973b72447e0ab8e841d9f5706c37dc581fe66a0bd21bcd256cdb9b9;
    bytes32 constant TSLA_OVERNIGHT_FEED = 0x713631e41c06db404e6a5d029f3eebfd5b885c59dce4a19f337c024e26584e26;

    // XAU (Gold) and ETH — 24/7 feeds, single feed ID
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

    uint256 constant TIMELOCK_DELAY = 10 minutes; // Short delay for testing; increase for production
    uint256 constant PYTH_MAX_PRICE_AGE = 120; // 2 minutes
    uint256 constant PROTOCOL_SHARE_BPS = 2000; // 20%

    // ──────────────────────────────────────────────────────────
    //  Deployment result struct — keeps run() under stack limit
    // ──────────────────────────────────────────────────────────

    struct Deployed {
        address usdc;
        address weth;
        address registry;
        address assetRegistry;
        address feeCalc;
        address pythOracle;
        address factory;
        address market;
        address etokenFactory;
        address eTSLA;
        address eGOLD;
        address wethRouter;
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Returns the canonical WETH address or deploys a free-mint MockWETH
    ///      when DEPLOY_MOCK_WETH=true. Extracted to keep run() stack-lean.
    function _resolveWeth() internal returns (address) {
        if (vm.envOr("DEPLOY_MOCK_WETH", false)) {
            address mock = address(new MockWETH());
            console.log("MockWETH (free mint):", mock);
            return mock;
        }
        console.log("Real WETH:", REAL_WETH);
        return REAL_WETH;
    }

    /// @dev Deploys all contracts and returns addresses in a struct.
    ///      Separated from run() to keep the top-level function stack-lean.
    function _deploy(address deployer, address treasury) internal returns (Deployed memory d) {
        // ── 1. Mock USDC ──────────────────────────────────────
        d.usdc = address(new MockERC20("USD Coin", "USDC", 6));
        console.log("MockUSDC:", d.usdc);

        // ── 2. WETH (real or mock) ────────────────────────────
        d.weth = _resolveWeth();

        // ── 3. ProtocolRegistry ───────────────────────────────
        d.registry = address(new ProtocolRegistry(deployer, TIMELOCK_DELAY));
        console.log("ProtocolRegistry:", d.registry);

        // ── 4. AssetRegistry ──────────────────────────────────
        d.assetRegistry = address(new AssetRegistry(deployer));
        console.log("AssetRegistry:", d.assetRegistry);

        // ── 5. FeeCalculator ──────────────────────────────────
        d.feeCalc = address(new FeeCalculator(d.registry, deployer));
        console.log("FeeCalculator:", d.feeCalc);

        FeeCalculator feeCalc = FeeCalculator(d.feeCalc);
        feeCalc.setMintFee(1, 5); // 0.05%
        feeCalc.setMintFee(2, 10); // 0.10%
        feeCalc.setMintFee(3, 50); // 0.50%
        feeCalc.setRedeemFee(1, 5); // 0.05%
        feeCalc.setRedeemFee(2, 10); // 0.10%
        feeCalc.setRedeemFee(3, 50); // 0.50%

        // ── 6. PythOracleVerifier ─────────────────────────────
        d.pythOracle = address(new PythOracleVerifier(deployer, PYTH, PYTH_MAX_PRICE_AGE));
        console.log("PythOracleVerifier:", d.pythOracle);

        PythOracleVerifier pythOracle = PythOracleVerifier(d.pythOracle);
        pythOracle.setFeedId(TSLA, 0, TSLA_FEED);
        pythOracle.setFeedId(TSLA, 1, TSLA_PRE_FEED);
        pythOracle.setFeedId(TSLA, 2, TSLA_POST_FEED);
        pythOracle.setFeedId(TSLA, 3, TSLA_OVERNIGHT_FEED);
        pythOracle.setFeedId(GOLD, 0, XAU_FEED);
        pythOracle.setFeedId(ETH, 0, ETH_FEED);

        // ── 7. VaultFactory ───────────────────────────────────
        d.factory = address(new VaultFactory(deployer, d.registry));
        console.log("VaultFactory:", d.factory);

        // ── 8. OwnMarket ──────────────────────────────────────
        d.market = address(new OwnMarket(d.registry));
        console.log("OwnMarket:", d.market);

        // ── 9. ETokenFactory + ETokens ────────────────────────
        d.etokenFactory = address(new ETokenFactory(deployer, d.registry));
        console.log("ETokenFactory:", d.etokenFactory);

        ETokenFactory etokenFactory = ETokenFactory(d.etokenFactory);
        d.eTSLA = etokenFactory.createEToken("Tesla", "eTSLA", TSLA, d.usdc);
        console.log("EToken TSLA:", d.eTSLA);

        d.eGOLD = etokenFactory.createEToken("Gold", "eGOLD", GOLD, d.usdc);
        console.log("EToken GOLD:", d.eGOLD);

        // ── 10. WETHRouter ────────────────────────────────────
        d.wethRouter = address(new WETHRouter(d.weth));
        console.log("WETHRouter:", d.wethRouter);

        // ── 11. Register in ProtocolRegistry ──────────────────
        ProtocolRegistry registry = ProtocolRegistry(d.registry);
        registry.setAddress(registry.ASSET_REGISTRY(), d.assetRegistry);
        registry.setAddress(registry.TREASURY(), treasury);
        registry.setAddress(keccak256("FEE_CALCULATOR"), d.feeCalc);
        registry.setAddress(registry.VAULT_FACTORY(), d.factory);
        registry.setAddress(registry.MARKET(), d.market);
        registry.setAddress(registry.PYTH_ORACLE(), d.pythOracle);
        registry.setAddress(registry.ETOKEN_FACTORY(), d.etokenFactory);
        registry.setProtocolShareBps(PROTOCOL_SHARE_BPS);

        // ── 12. Add assets ────────────────────────────────────
        AssetRegistry assetRegistry = AssetRegistry(d.assetRegistry);

        assetRegistry.addAsset(
            TSLA,
            d.eTSLA,
            AssetConfig({
                activeToken: d.eTSLA,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 0
            })
        );

        assetRegistry.addAsset(
            GOLD,
            d.eGOLD,
            AssetConfig({
                activeToken: d.eGOLD,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 1,
                oracleType: 0
            })
        );

        assetRegistry.addAsset(
            ETH,
            d.weth,
            AssetConfig({
                activeToken: d.weth,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 0
            })
        );
    }

    function run() external {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        Deployed memory d = _deploy(deployer, treasury);
        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Update .env with these addresses:");
        console.log("MOCK_USDC=", d.usdc);
        console.log("WETH=", d.weth);
        console.log("PROTOCOL_REGISTRY=", d.registry);
        console.log("ASSET_REGISTRY=", d.assetRegistry);
        console.log("FEE_CALCULATOR=", d.feeCalc);
        console.log("PYTH_ORACLE=", d.pythOracle);
        console.log("VAULT_FACTORY=", d.factory);
        console.log("OWN_MARKET=", d.market);
        console.log("ETOKEN_TSLA=", d.eTSLA);
        console.log("ETOKEN_GOLD=", d.eGOLD);
        console.log("WETH_ROUTER=", d.wethRouter);
    }
}
