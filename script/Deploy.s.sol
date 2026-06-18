// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AssetRegistry} from "../src/core/AssetRegistry.sol";

import {OwnMarket} from "../src/core/OwnMarket.sol";
import {ProtocolRegistry} from "../src/core/ProtocolRegistry.sol";
import {VaultManager} from "../src/core/VaultManager.sol";

import {IProtocolRegistry} from "../src/interfaces/IProtocolRegistry.sol";
import {AssetConfig} from "../src/interfaces/types/Types.sol";
import {WETHRouter} from "../src/periphery/WETHRouter.sol";
import {ETokenFactory} from "../src/tokens/ETokenFactory.sol";

/// @title Deploy — Deploy all core Own Protocol contracts to Base Sepolia
/// @notice Deploys core contracts, registers them in ProtocolRegistry, registers the ETH collateral
///         asset, and configures global VaultManager parameters. Run by deployer (= protocol admin).
///
/// All assets use the in-house OracleVerifier (oracleType 1) — there is no Pyth. Deploy the in-house
/// oracle with DeployOracleSigner.s.sol, then register the eToken asset set with AddAssets.s.sol.
///
/// Reuses the existing testnet collateral/payment tokens (TESTNET_USDC, TESTNET_WETH) rather than
/// deploying fresh mocks, so existing testnet balances and tooling keep working.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
contract Deploy is Script {
    // ──────────────────────────────────────────────────────────
    //  Existing testnet tokens (reused — not redeployed)
    // ──────────────────────────────────────────────────────────

    /// @dev Testnet USDC (MockERC20, 6 decimals, open mint) — collateral payment token.
    address constant TESTNET_USDC = 0x6f5BB5824C8D572966a1DED0470AF3E72C527613;
    /// @dev Testnet ETH (MockWETH, 18 decimals, open mint + deposit/withdraw) — ETH vault collateral.
    address constant TESTNET_WETH = 0xfbd78Da8aDbc322084eE7F80C10F914B92CEb6FE;

    // ──────────────────────────────────────────────────────────
    //  Asset tickers
    // ──────────────────────────────────────────────────────────

    /// @dev ETH collateral asset — priced via the in-house oracle (oracleType 1).
    bytes32 constant ETH = bytes32("ETH");

    // ──────────────────────────────────────────────────────────
    //  Configuration
    // ──────────────────────────────────────────────────────────

    /// @dev Delay (seconds) on transferring PROTOCOL_ADMIN (the registry root role). Short for testnet;
    ///      production should use ~48h, hand PROTOCOL_ADMIN to a TimelockController, and grant
    ///      ADMIN/OPERATOR to the governance/ops multisigs (see SetupGovernance.s.sol).
    uint48 constant ADMIN_TRANSFER_DELAY = 10 minutes;
    uint256 constant PRICE_MAX_AGE = 2 minutes; // Max age for inline "current price" proofs

    /// @dev Initial global utilisation cap (80%). Solvency bound across all pooled vaults.
    uint256 constant GLOBAL_MAX_UTIL_BPS = 8000;

    /// @dev Settle-price band (5%). Quote settle prices must fall within ±band of the asset mark,
    ///      capping the damage a leaked signer key can inflict per unit of size.
    uint256 constant SETTLE_BAND_BPS = 500;

    /// @dev Force-execute claim threshold (6h): delay after a resting redeem order is placed before
    ///      its owner can force-execute against vault collateral. Must be non-zero — zero disables
    ///      force-execution, so setting it here is what enables the user's recourse path.
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    /// @dev Max keeper-mark age (15min): asset marks older than this block new exposure opens
    ///      (openExposure). Must be non-zero — zero blocks all minting, so setting it here arms the
    ///      staleness guard.
    uint256 constant MAX_MARK_AGE = 15 minutes;

    /// @dev Initial per-asset USD issuance ceiling (18-decimal USD). 0 would block minting.
    uint256 constant ASSET_CAP_USD = 10_000_000e18;

    // ──────────────────────────────────────────────────────────
    //  Deployment result struct — keeps run() under stack limit
    // ──────────────────────────────────────────────────────────

    struct Deployed {
        address usdc;
        address weth;
        address registry;
        address assetRegistry;
        address market;
        address vaultManager;
        address etokenFactory;
        address wethRouter;
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Deploys all contracts and returns addresses in a struct.
    ///      Separated from run() to keep the top-level function stack-lean.
    function _deploy(
        address deployer
    ) internal returns (Deployed memory d) {
        // ── 1. Reuse existing testnet USDC (payment token) ────
        d.usdc = TESTNET_USDC;
        console.log("USDC (reused):", d.usdc);

        // ── 2. Reuse existing testnet WETH (ETH vault collateral) ─
        d.weth = TESTNET_WETH;
        console.log("WETH (reused):", d.weth);

        // ── 3. ProtocolRegistry ───────────────────────────────
        d.registry = address(new ProtocolRegistry(deployer, ADMIN_TRANSFER_DELAY, PRICE_MAX_AGE));
        console.log("ProtocolRegistry:", d.registry);

        // ── 4. AssetRegistry ──────────────────────────────────
        d.assetRegistry = address(new AssetRegistry(d.registry));
        console.log("AssetRegistry:", d.assetRegistry);

        // ── 5. OwnMarket ──────────────────────────────────────
        d.market = address(new OwnMarket(d.registry));
        console.log("OwnMarket:", d.market);

        // ── 6. VaultManager ───────────────────────────────────
        d.vaultManager = address(new VaultManager(IProtocolRegistry(d.registry)));
        console.log("VaultManager:", d.vaultManager);

        // ── 7. ETokenFactory ──────────────────────────────────
        d.etokenFactory = address(new ETokenFactory(d.registry));
        console.log("ETokenFactory:", d.etokenFactory);

        // ── 8. WETHRouter ─────────────────────────────────────
        d.wethRouter = address(new WETHRouter(d.weth));
        console.log("WETHRouter:", d.wethRouter);

        // ── 9. Register in ProtocolRegistry ───────────────────
        // The in-house OracleVerifier (INHOUSE_ORACLE) is deployed + registered separately by
        // DeployOracleSigner.s.sol. There is no Pyth oracle.
        ProtocolRegistry registry = ProtocolRegistry(d.registry);
        // Deployer is the initial PROTOCOL_ADMIN (default admin); grant it the functional ADMIN/OPERATOR
        // roles so this script can drive every admin/operator entry point (addAsset, VaultManager config).
        // Production: grant these to the governance/ops multisigs and hand PROTOCOL_ADMIN to a timelock.
        registry.grantRole(keccak256("ADMIN"), deployer);
        registry.grantRole(keccak256("OPERATOR"), deployer);
        registry.setAddress(registry.ASSET_REGISTRY(), d.assetRegistry);
        registry.setAddress(registry.MARKET(), d.market);
        registry.setAddress(registry.VAULT_MANAGER(), d.vaultManager);
        // Protocol treasury — bad-debt collateral sink. Defaults to the deployer/admin if unset.
        registry.setAddress(registry.TREASURY(), vm.envOr("TREASURY_ADDRESS", deployer));
        registry.setAddress(registry.ETOKEN_FACTORY(), d.etokenFactory);

        // ── 10. Register the ETH collateral asset (in-house oracle) ─
        AssetRegistry assetRegistry = AssetRegistry(d.assetRegistry);
        assetRegistry.addAsset(
            ETH,
            d.weth,
            AssetConfig({
                activeToken: d.weth,
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 1
            })
        );

        // ── 11. Configure global risk parameters + payment token ─────
        // An asset can only be minted once BOTH its price is pulled (assetMark != 0) and its
        // per-asset cap is non-zero. Caps are set here; keepers pull marks post-deploy.
        VaultManager vaultManager = VaultManager(d.vaultManager);
        vaultManager.setGlobalMaxUtilizationBps(GLOBAL_MAX_UTIL_BPS);
        vaultManager.setSettleBandBps(SETTLE_BAND_BPS);
        vaultManager.setClaimThreshold(CLAIM_THRESHOLD);
        vaultManager.setMaxMarkAge(MAX_MARK_AGE);
        vaultManager.setAssetCapUSD(ETH, ASSET_CAP_USD);
        // Single global order-settlement currency for all vaults.
        vaultManager.setPaymentToken(d.usdc);
    }

    function run() external {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        console.log("Deployer:", deployer);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        Deployed memory d = _deploy(deployer);
        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Update .env with these addresses:");
        console.log("MOCK_USDC=", d.usdc);
        console.log("WETH=", d.weth);
        console.log("PROTOCOL_REGISTRY=", d.registry);
        console.log("ASSET_REGISTRY=", d.assetRegistry);
        console.log("OWN_MARKET=", d.market);
        console.log("VAULT_MANAGER=", d.vaultManager);
        console.log("ETOKEN_FACTORY=", d.etokenFactory);
        console.log("WETH_ROUTER=", d.wethRouter);
    }
}
