// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExposureManager} from "../../src/core/ExposureManager.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {BPS, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";
import {Actors} from "./Actors.sol";
import {MockAUSDC} from "./MockAUSDC.sol";
import {MockDEX} from "./MockDEX.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracleVerifier} from "./MockOracleVerifier.sol";
import {MockWstETH} from "./MockWstETH.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test} from "forge-std/Test.sol";

/// @title BaseTest — Common setup for all Own Protocol tests
/// @notice Deploys mock tokens, oracle, and DEX. Labels all actor addresses
///         for readable Foundry traces. Provides utility functions for common
///         test operations (funding actors, setting prices, etc.).
contract BaseTest is Test {
    // ──────────────────────────────────────────────────────────
    //  Mock tokens
    // ──────────────────────────────────────────────────────────

    /// @notice Mock USDC (6 decimals).
    MockERC20 public usdc;

    /// @notice Mock USDT (6 decimals).
    MockERC20 public usdt;

    /// @notice Mock USDS (18 decimals).
    MockERC20 public usds;

    /// @notice Mock WETH (18 decimals).
    MockERC20 public weth;

    /// @notice Mock stETH (18 decimals, used as underlying for wstETH).
    MockERC20 public stETH;

    /// @notice Mock aUSDC (6 decimals, rebasing).
    MockAUSDC public aUSDC;

    /// @notice Mock wstETH (18 decimals, wraps stETH).
    MockWstETH public wstETH;

    // ──────────────────────────────────────────────────────────
    //  Mock infrastructure
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol registry (deployed with Actors.ADMIN as owner).
    ProtocolRegistry public protocolRegistry;

    /// @notice Mock oracle verifier.
    MockOracleVerifier public oracle;

    /// @notice Mock DEX router for Tier 3 liquidation.
    MockDEX public dex;

    /// @notice Central pooled-exposure manager. Deployed/registered on demand by `_deployExposureManager`.
    ExposureManager public exposureManager;

    // ──────────────────────────────────────────────────────────
    //  Common asset tickers
    // ──────────────────────────────────────────────────────────

    bytes32 public constant TSLA = bytes32("TSLA");
    bytes32 public constant GOLD = bytes32("GOLD");
    bytes32 public constant TLT = bytes32("TLT");
    bytes32 public constant ETH = bytes32("ETH");

    /// @dev Default global utilisation cap and per-asset USD ceiling used by test bootstraps.
    uint256 public constant DEFAULT_MAX_UTIL_BPS = 8000;
    uint256 public constant DEFAULT_ASSET_CAP_USD = 1_000_000_000e18;

    // ──────────────────────────────────────────────────────────
    //  Common prices (18 decimals)
    // ──────────────────────────────────────────────────────────

    uint256 public constant TSLA_PRICE = 250e18; // $250
    uint256 public constant GOLD_PRICE = 2000e18; // $2,000
    uint256 public constant TLT_PRICE = 90e18; // $90
    uint256 public constant ETH_PRICE = 3000e18; // $3,000

    // ──────────────────────────────────────────────────────────
    //  Setup
    // ──────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────
    //  VM quote signers (keyed, for RFQ quote signing)
    // ──────────────────────────────────────────────────────────

    /// @notice Primary VM signer (use as a vault's VM where quote signing is needed).
    address public vm1Signer;
    uint256 public vm1SignerPk;

    /// @notice Secondary VM signer (for cross-vault tests).
    address public vm2Signer;
    uint256 public vm2SignerPk;

    function setUp() public virtual {
        (vm1Signer, vm1SignerPk) = makeAddrAndKey("vm1Signer");
        (vm2Signer, vm2SignerPk) = makeAddrAndKey("vm2Signer");
        _deployMockTokens();
        _deployMockInfrastructure();
        _labelActors();
        _setDefaultPrices();
    }

    // ──────────────────────────────────────────────────────────
    //  Utility: RFQ quotes
    // ──────────────────────────────────────────────────────────

    /// @notice Sign a quote with a VM private key, matching OwnMarket's digest scheme.
    function _signQuote(IOwnMarket mkt, Quote memory q, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = mkt.quoteDigest(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Monotonic nonce so generated quotes are unique within a test run.
    uint256 private _baseQuoteNonce = 1;

    /// @notice Build a Quote with a fresh nonce and a default 1-day expiry.
    function _buildQuote(
        uint256 orderId,
        address user,
        address vault,
        bytes32 asset,
        OrderType orderType,
        uint256 amount,
        uint256 price
    ) internal returns (Quote memory q) {
        q = Quote({
            orderId: orderId,
            user: user,
            vault: vault,
            asset: asset,
            orderType: orderType,
            amount: amount,
            price: price,
            quoteId: _baseQuoteNonce++,
            expiry: block.timestamp + 1 days
        });
    }

    // ──────────────────────────────────────────────────────────
    //  Utility: fund actors
    // ──────────────────────────────────────────────────────────

    /// @notice Mint USDC to an address.
    function _fundUSDC(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    /// @notice Mint USDT to an address.
    function _fundUSDT(address to, uint256 amount) internal {
        usdt.mint(to, amount);
    }

    /// @notice Mint WETH to an address.
    function _fundWETH(address to, uint256 amount) internal {
        weth.mint(to, amount);
    }

    /// @notice Mint stETH to an address.
    function _fundStETH(address to, uint256 amount) internal {
        stETH.mint(to, amount);
    }

    /// @notice Mint aUSDC to an address.
    function _fundAUSDC(address to, uint256 amount) internal {
        aUSDC.mint(to, amount);
    }

    /// @notice Deal ETH to an address.
    function _fundETH(address to, uint256 amount) internal {
        vm.deal(to, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  Utility: oracle prices
    // ──────────────────────────────────────────────────────────

    /// @notice Set oracle price for an asset at the current block timestamp.
    function _setOraclePrice(bytes32 asset, uint256 price) internal {
        oracle.setPrice(asset, price, block.timestamp);
    }

    /// @notice Build empty price data bytes (mock oracle ignores the payload).
    function _emptyPriceData() internal pure returns (bytes memory) {
        return "";
    }

    /// @notice Build price proof data for confirmOrder (mock oracle format).
    ///         Encodes two identical price proofs (low == high) with session 0.
    function _buildPriceProof(
        uint256 price
    ) internal view returns (bytes memory) {
        bytes memory proof = abi.encode(price, block.timestamp);
        return abi.encode(proof, proof, uint8(0));
    }

    // ──────────────────────────────────────────────────────────
    //  Internal setup helpers
    // ──────────────────────────────────────────────────────────

    function _deployMockTokens() private {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        usds = new MockERC20("USDS", "USDS", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        stETH = new MockERC20("Staked Ether", "stETH", 18);
        aUSDC = new MockAUSDC();
        wstETH = new MockWstETH(address(stETH));
    }

    function _deployMockInfrastructure() private {
        oracle = new MockOracleVerifier();
        dex = new MockDEX();
        vm.startPrank(Actors.ADMIN);
        protocolRegistry = new ProtocolRegistry(Actors.ADMIN, 2 days);
        protocolRegistry.setAddress(keccak256("INHOUSE_ORACLE"), address(oracle));
        vm.stopPrank();
    }

    function _labelActors() private {
        vm.label(Actors.ADMIN, "admin");
        vm.label(Actors.LP1, "lp1");
        vm.label(Actors.LP2, "lp2");
        vm.label(Actors.LP3, "lp3");
        vm.label(Actors.VM1, "vm1");
        vm.label(Actors.VM2, "vm2");
        vm.label(Actors.MINTER1, "minter1");
        vm.label(Actors.MINTER2, "minter2");
        vm.label(Actors.LIQUIDATOR, "liquidator");
        vm.label(Actors.ATTACKER, "attacker");
        vm.label(Actors.ORACLE_SIGNER, "oracleSigner");
        vm.label(Actors.FEE_RECIPIENT, "feeRecipient");

        vm.label(address(usdc), "USDC");
        vm.label(address(usdt), "USDT");
        vm.label(address(usds), "USDS");
        vm.label(address(weth), "WETH");
        vm.label(address(stETH), "stETH");
        vm.label(address(aUSDC), "aUSDC");
        vm.label(address(wstETH), "wstETH");
        vm.label(address(oracle), "oracle");
        vm.label(address(dex), "DEX");
        vm.label(address(protocolRegistry), "ProtocolRegistry");
    }

    function _setDefaultPrices() private {
        oracle.setPrice(TSLA, TSLA_PRICE, block.timestamp);
        oracle.setPrice(GOLD, GOLD_PRICE, block.timestamp);
        oracle.setPrice(TLT, TLT_PRICE, block.timestamp);
        oracle.setPrice(ETH, ETH_PRICE, block.timestamp);
        // Collateral oracle tickers used by vaults (so pokeCollateral resolves a price).
        oracle.setPrice(bytes32("WSTETH"), ETH_PRICE, block.timestamp);
        oracle.setPrice(bytes32("AUSDC"), 1e18, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  Utility: ExposureManager
    // ──────────────────────────────────────────────────────────

    /// @notice Deploy the ExposureManager, register it in the registry (EXPOSURE_MANAGER slot),
    ///         and set the default global max utilisation. Must be called (as part of protocol
    ///         deployment) BEFORE any `VaultFactory.createVault`, which auto-registers the vault.
    function _deployExposureManager() internal {
        vm.startPrank(Actors.ADMIN);
        exposureManager = new ExposureManager(protocolRegistry);
        protocolRegistry.setAddress(protocolRegistry.EXPOSURE_MANAGER(), address(exposureManager));
        exposureManager.setGlobalMaxUtilizationBps(DEFAULT_MAX_UTIL_BPS);
        vm.stopPrank();
        vm.label(address(exposureManager), "ExposureManager");
    }

    /// @notice Set the per-asset USD issuance ceiling (admin-only).
    function _setAssetCap(bytes32 asset, uint256 capUSD) internal {
        vm.prank(Actors.ADMIN);
        exposureManager.setAssetCapUSD(asset, capUSD);
    }

    /// @notice Set the global max utilisation in BPS (admin-only).
    function _setGlobalMaxUtil(
        uint256 bps
    ) internal {
        vm.prank(Actors.ADMIN);
        exposureManager.setGlobalMaxUtilizationBps(bps);
    }

    /// @notice Permissionless poke of a vault's collateral mark.
    function _pokeCollateral(
        address vault
    ) internal {
        exposureManager.pokeCollateral(vault);
    }

    /// @notice Permissionless poke of an asset's price mark.
    function _pokeAsset(
        bytes32 asset
    ) internal {
        exposureManager.pokeAssetPrice(asset);
    }
}
