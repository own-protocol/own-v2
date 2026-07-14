// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OracleVerifier} from "../../src/core/OracleVerifier.sol";
import {OwnLendingPool} from "../../src/core/OwnLendingPool.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {LendingRouter} from "../../src/periphery/LendingRouter.sol";
import {ETokenFactory} from "../../src/tokens/ETokenFactory.sol";

/// @title DeployRobinhood — Own Protocol core deploy for Robinhood Chain (USDG collateral vault)
/// @notice Robinhood Chain (4663) has no Aave, so this deploy replaces the Base wiring with the
///         in-house OwnLendingPool (zero-rate, single-reserve USDG): deploys all core contracts,
///         the in-house OracleVerifier, the OwnLendingPool (+ its oUSDG/debt tokens), the
///         LendingRouter (USDG→oUSDG), registers the oUSDG collateral asset, deploys + registers
///         a single oUSDG OwnVault, and sets global risk parameters + the USDG payment token.
///         Borrowing + yield automation are enabled by EnableLendingRobinhood.s.sol (no
///         first-deposit precondition here — OwnLendingPool's collateral flag is a no-op). Assets
///         are added by AddAssetsRobinhood.s.sol. Run by the deployer (= bootstrap
///         PROTOCOL_ADMIN/ADMIN/OPERATOR).
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD, VM_ADDRESS_ROBINHOOD, TREASURY_ADDRESS_ROBINHOOD,
///      ORACLE_SIGNER_ROBINHOOD, QUOTE_SIGNER_ROBINHOOD, QUOTE_SIGNER_LINKED_ROBINHOOD
///
/// Usage:
///   forge script script/robinhood/DeployRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployRobinhood is Script {
    // ── Robinhood Chain external addresses (docs.robinhood.com/chain/contracts, verified on-chain) ──
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Paxos Global Dollar (6 dec)

    /// @dev Collateral oracle ticker for the oUSDG vault. The off-chain signer must attest a "USDG"
    ///      mark (~1e18). The oUSDG receipt is 1:1 with USDG (zero-rate pool), so $1 face pricing holds.
    bytes32 constant COLLATERAL_TICKER = bytes32("USDG");
    uint8 constant ORACLE_TYPE_INHOUSE = 1;

    // ── Risk / config params (production values — review before running) ──
    uint48 constant ADMIN_TRANSFER_DELAY = 3 hours; // PROTOCOL_ADMIN (registry root) transfer delay
    uint256 constant PRICE_MAX_AGE = 2 minutes; // max age for inline "current price" proofs
    uint256 constant GLOBAL_MAX_UTIL_BPS = 6000; // 60% global utilisation cap
    uint256 constant SETTLE_BAND_BPS = 500; // ±5% settle-price band around the asset mark
    // NOTE: claim threshold is intentionally NOT set here — it stays at the contract default (0),
    // which disables redeem force-execution. Set it later via VaultManager.setClaimThreshold if needed.
    uint256 constant MAX_MARK_AGE = 1 hours; // staleness gate for opening new exposure (non-zero)

    // OwnLendingPool bounds: LTV is the hard ceiling on the vault's pool-side debt (BorrowManager
    // caps new borrows at 70%; premium claims drift pool debt above it, up to this LTV) — 75%
    // guarantees >= 25% of LP funds stay in the pool as cash. LT gates aToken withdrawals/transfers;
    // 100% aligns the gate with the cash floor (debt never accrues pool-side and HF < 1 is
    // unreachable, so an LT margin only strands LP liquidity below the intended buffer).
    uint256 constant POOL_LTV_BPS = 7500; // 75%
    uint256 constant POOL_LT_BPS = 10_000; // 100%

    struct Deployed {
        address registry;
        address assetRegistry;
        address market;
        address vaultManager;
        address etokenFactory;
        address oracle;
        address lendingPool;
        address lendingRouter;
        address vault;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        address deployer = vm.addr(pk);
        address vm_ = vm.envAddress("VM_ADDRESS_ROBINHOOD");
        address oracleSigner = vm.envAddress("ORACLE_SIGNER_ROBINHOOD");
        address quoteSigner = vm.envAddress("QUOTE_SIGNER_ROBINHOOD");
        address quoteLinked = vm.envAddress("QUOTE_SIGNER_LINKED_ROBINHOOD");
        address treasury = vm.envOr("TREASURY_ADDRESS_ROBINHOOD", deployer);

        require(block.chainid == 4663, "RPC is not Robinhood Chain (4663)");
        console.log("Deployer:", deployer);
        console.log("VaultManager (VM) operator:", vm_);

        vm.startBroadcast(pk);

        Deployed memory d = _deployCore(deployer, treasury);
        _deployOracle(d, oracleSigner);
        _deployPoolRouterVault(d, vm_);
        _configGlobals(d, quoteSigner, quoteLinked);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Robinhood Chain Core Deployment Complete ===");
        console.log("PROTOCOL_REGISTRY_ROBINHOOD=", d.registry);
        console.log("ASSET_REGISTRY_ROBINHOOD=", d.assetRegistry);
        console.log("OWN_MARKET_ROBINHOOD=", d.market);
        console.log("VAULT_MANAGER_ROBINHOOD=", d.vaultManager);
        console.log("ETOKEN_FACTORY_ROBINHOOD=", d.etokenFactory);
        console.log("INHOUSE_ORACLE_ROBINHOOD=", d.oracle);
        console.log("LENDING_POOL_ROBINHOOD=", d.lendingPool);
        console.log("LENDING_ROUTER_ROBINHOOD=", d.lendingRouter);
        console.log("VAULT_ADDRESS_ROBINHOOD=", d.vault);
        console.log("OUSDG (pool aToken)=", OwnLendingPool(d.lendingPool).aToken());
        console.log("USDG_DEBT_TOKEN=", OwnLendingPool(d.lendingPool).variableDebtToken());
        console.log("");
        console.log("NEXT: SetOracleConfigsRobinhood + BootstrapUsdgPriceRobinhood, AddAssetsRobinhood,");
        console.log("EnableLendingRobinhood, SeedDepositRobinhood. Keepers must pullCollateralPrice(vault)");
        console.log("+ pullAssetPrice(ticker) before mint/borrow.");
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

    /// @dev Deploys the OwnLendingPool (USDG reserve) + LendingRouter, allowlists the router as the
    ///      pool's supplier, registers the oUSDG collateral asset, deploys the oUSDG OwnVault, and
    ///      registers it on the VaultManager.
    function _deployPoolRouterVault(Deployed memory d, address vm_) internal {
        // In-house zero-rate pool (no Aave on Robinhood Chain). All lending interest lives in the
        // BorrowManager premium curve; the pool reports a 0 borrow rate.
        OwnLendingPool pool = new OwnLendingPool(
            d.registry, USDG, "Own USDG", "oUSDG", "Own Debt USDG", "odUSDG", POOL_LTV_BPS, POOL_LT_BPS
        );
        d.lendingPool = address(pool);
        console.log("OwnLendingPool:", d.lendingPool);

        // Router fronts the pool (supply/withdraw); it is the pool's only allowed supplier.
        LendingRouter router = new LendingRouter(d.lendingPool, d.registry);
        router.registerReserve(USDG, pool.aToken());
        pool.setSupplierAllowed(address(router), true);
        d.lendingRouter = address(router);
        console.log("LendingRouter:", d.lendingRouter);

        // Register the oUSDG collateral asset (oracle-priced via the "USDG" ticker; not mintable —
        // no asset cap is set for it, so its mint cap stays 0).
        AssetRegistry(d.assetRegistry).addAsset(
            COLLATERAL_TICKER,
            pool.aToken(),
            AssetConfig({
                activeToken: pool.aToken(),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 1,
                oracleType: ORACLE_TYPE_INHOUSE
            })
        );

        // Deploy the single oUSDG vault and register it with the VaultManager under the "USDG" ticker.
        OwnVault vault = new OwnVault(pool.aToken(), "Own USDG Vault", "ovUSDG", d.registry, vm_);
        VaultManager(d.vaultManager).registerVault(address(vault), COLLATERAL_TICKER);
        d.vault = address(vault);
        console.log("OwnVault (oUSDG):", d.vault);
    }

    /// @dev Sets global risk params, the USDG payment token, and registers the RFQ quote signer.
    function _configGlobals(Deployed memory d, address quoteSigner, address quoteLinked) internal {
        VaultManager vaultManager = VaultManager(d.vaultManager);
        vaultManager.setGlobalMaxUtilizationBps(GLOBAL_MAX_UTIL_BPS);
        vaultManager.setSettleBandBps(SETTLE_BAND_BPS);
        vaultManager.setMaxMarkAge(MAX_MARK_AGE);
        vaultManager.setPaymentToken(USDG);
        // RFQ quote signer + its linked settlement wallet (mint proceeds → linked; redeem payouts ← linked).
        vaultManager.registerSigner(quoteSigner, quoteLinked);
        console.log("Global params set; payment token = USDG; quote signer registered:", quoteSigner);
    }
}
