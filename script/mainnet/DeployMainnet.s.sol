// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {AaveRouter} from "../../src/periphery/AaveRouter.sol";
import {ETokenFactory} from "../../src/tokens/ETokenFactory.sol";

/// @title DeployMainnet — Own Protocol core deploy for Base mainnet (aUSDC collateral vault)
/// @notice Deploys all core contracts, the in-house OracleVerifier, the AaveRouter (USDC→aUSDC),
///         registers the aUSDC collateral asset, deploys + registers a single aUSDC OwnVault, and sets
///         global risk parameters + the USDC payment token. Borrowing is enabled separately by
///         EnableLendingMainnet.s.sol (after the vault's first deposit). Assets are added by
///         AddAssetsMainnet.s.sol. Run by the deployer (= bootstrap PROTOCOL_ADMIN/ADMIN/OPERATOR).
///
/// Env: DEPLOYER_PRIVATE_KEY_MAINNET, VM_ADDRESS_MAINNET, TREASURY_ADDRESS_MAINNET,
///      ORACLE_SIGNER_MAINNET, QUOTE_SIGNER_MAINNET, QUOTE_SIGNER_LINKED_MAINNET
///
/// Usage:
///   forge script script/mainnet/DeployMainnet.s.sol --rpc-url base --broadcast --verify
contract DeployMainnet is Script {
    // ── Base mainnet external addresses (verified on-chain via Aave Pool.getReserveData) ──
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // native Circle USDC (6 dec)
    address constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB; // Aave V3 aBasUSDC (6 dec)
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    /// @dev Collateral oracle ticker for the aUSDC vault. The off-chain signer must attest a "USDC"
    ///      mark (~1e18). aUSDC balance accrues yield, so pricing its face at $1 captures the yield.
    bytes32 constant COLLATERAL_TICKER = bytes32("USDC");
    uint8 constant ORACLE_TYPE_INHOUSE = 1;

    // ── Risk / config params (production values — review before running) ──
    uint48 constant ADMIN_TRANSFER_DELAY = 3 hours; // PROTOCOL_ADMIN (registry root) transfer delay
    uint256 constant PRICE_MAX_AGE = 2 minutes; // max age for inline "current price" proofs
    uint256 constant GLOBAL_MAX_UTIL_BPS = 6500; // 65% global utilisation cap
    uint256 constant SETTLE_BAND_BPS = 500; // ±5% settle-price band around the asset mark
    // NOTE: claim threshold is intentionally NOT set here — it stays at the contract default (0),
    // which disables redeem force-execution. Set it later via VaultManager.setClaimThreshold if needed.
    uint256 constant MAX_MARK_AGE = 1 hours; // staleness gate for opening new exposure (non-zero)

    struct Deployed {
        address registry;
        address assetRegistry;
        address market;
        address vaultManager;
        address etokenFactory;
        address oracle;
        address aaveRouter;
        address vault;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY_MAINNET");
        address deployer = vm.addr(pk);
        address vm_ = vm.envAddress("VM_ADDRESS_MAINNET");
        address oracleSigner = vm.envAddress("ORACLE_SIGNER_MAINNET");
        address quoteSigner = vm.envAddress("QUOTE_SIGNER_MAINNET");
        address quoteLinked = vm.envAddress("QUOTE_SIGNER_LINKED_MAINNET");
        address treasury = vm.envOr("TREASURY_ADDRESS_MAINNET", deployer);

        console.log("Deployer:", deployer);
        console.log("VaultManager (VM) operator:", vm_);

        vm.startBroadcast(pk);

        Deployed memory d = _deployCore(deployer, treasury);
        _deployOracle(d, oracleSigner);
        _deployRouterAndVault(d, vm_);
        _configGlobals(d, quoteSigner, quoteLinked);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Base Mainnet Core Deployment Complete ===");
        console.log("PROTOCOL_REGISTRY=", d.registry);
        console.log("ASSET_REGISTRY=", d.assetRegistry);
        console.log("OWN_MARKET=", d.market);
        console.log("VAULT_MANAGER=", d.vaultManager);
        console.log("ETOKEN_FACTORY=", d.etokenFactory);
        console.log("INHOUSE_ORACLE=", d.oracle);
        console.log("AAVE_ROUTER=", d.aaveRouter);
        console.log("VAULT_ADDRESS=", d.vault);
        console.log("");
        console.log("NEXT: AddAssetsMainnet.s.sol, then first LP deposit, then EnableLendingMainnet.s.sol.");
        console.log("Keepers must pullCollateralPrice(vault) + pullAssetPrice(ticker) before mint/borrow.");
    }

    /// @dev Deploys core contracts, grants the deployer ADMIN/OPERATOR, and registers core addresses.
    function _deployCore(address deployer, address treasury) internal returns (Deployed memory d) {
        d.registry = address(new ProtocolRegistry(deployer, ADMIN_TRANSFER_DELAY, PRICE_MAX_AGE));
        d.assetRegistry = address(new AssetRegistry(d.registry));
        d.market = address(new OwnMarket(d.registry));
        d.vaultManager = address(new VaultManager(IProtocolRegistry(d.registry)));
        d.etokenFactory = address(new ETokenFactory(d.registry));

        ProtocolRegistry registry = ProtocolRegistry(d.registry);
        registry.grantRole(keccak256("ADMIN"), deployer);
        registry.grantRole(keccak256("OPERATOR"), deployer);
        registry.setAddress(registry.ASSET_REGISTRY(), d.assetRegistry);
        registry.setAddress(registry.MARKET(), d.market);
        registry.setAddress(registry.VAULT_MANAGER(), d.vaultManager);
        registry.setAddress(registry.ETOKEN_FACTORY(), d.etokenFactory);
        registry.setAddress(registry.TREASURY(), treasury);

        console.log("ProtocolRegistry:", d.registry);
        console.log("AssetRegistry:", d.assetRegistry);
        console.log("OwnMarket:", d.market);
        console.log("VaultManager:", d.vaultManager);
        console.log("ETokenFactory:", d.etokenFactory);
    }

    /// @dev Deploys the in-house OracleVerifier, adds the price signer, registers it as INHOUSE_ORACLE.
    function _deployOracle(Deployed memory d, address oracleSigner) internal {
        OracleVerifier oracle = new OracleVerifier(d.registry);
        oracle.addSigner(oracleSigner);
        ProtocolRegistry registry = ProtocolRegistry(d.registry);
        registry.setAddress(registry.INHOUSE_ORACLE(), address(oracle));
        d.oracle = address(oracle);
        console.log("OracleVerifier:", d.oracle);
        console.log("Oracle price signer:", oracleSigner);
    }

    /// @dev Deploys the AaveRouter, registers the USDC↔aUSDC reserve, registers the aUSDC collateral
    ///      asset, deploys the aUSDC OwnVault, and registers it on the VaultManager.
    function _deployRouterAndVault(Deployed memory d, address vm_) internal {
        // AaveRouter (single instance, multi-reserve). Register the USDC→aUSDC reserve.
        AaveRouter router = new AaveRouter(AAVE_V3_POOL, d.registry);
        router.registerReserve(USDC, AUSDC);
        d.aaveRouter = address(router);
        console.log("AaveRouter:", d.aaveRouter);

        // Register the aUSDC collateral asset (oracle-priced via the "USDC" ticker; not mintable —
        // no asset cap is set for it, so its mint cap stays 0).
        AssetRegistry(d.assetRegistry).addAsset(
            COLLATERAL_TICKER,
            AUSDC,
            AssetConfig({
                activeToken: AUSDC,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 1,
                oracleType: ORACLE_TYPE_INHOUSE
            })
        );

        // Deploy the single aUSDC vault and register it with the VaultManager under the "USDC" ticker.
        OwnVault vault = new OwnVault(AUSDC, "Own aUSDC Vault", "oaUSDC", d.registry, vm_);
        VaultManager(d.vaultManager).registerVault(address(vault), COLLATERAL_TICKER);
        d.vault = address(vault);
        console.log("OwnVault (aUSDC):", d.vault);
    }

    /// @dev Sets global risk params, the USDC payment token, and registers the RFQ quote signer.
    function _configGlobals(Deployed memory d, address quoteSigner, address quoteLinked) internal {
        VaultManager vaultManager = VaultManager(d.vaultManager);
        vaultManager.setGlobalMaxUtilizationBps(GLOBAL_MAX_UTIL_BPS);
        vaultManager.setSettleBandBps(SETTLE_BAND_BPS);
        vaultManager.setMaxMarkAge(MAX_MARK_AGE);
        vaultManager.setPaymentToken(USDC);
        // RFQ quote signer + its linked settlement wallet (mint proceeds → linked; redeem payouts ← linked).
        vaultManager.registerSigner(quoteSigner, quoteLinked);
        console.log("Global params set; payment token = USDC; quote signer registered:", quoteSigner);
    }
}
