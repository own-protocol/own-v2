// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";

import {AssetConfig, PRECISION} from "../../src/interfaces/types/Types.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ETokenHandler} from "./handlers/ETokenHandler.sol";
import {MarketHandler} from "./handlers/MarketHandler.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @title OwnProtocolInvariant — Stateful fuzz tests for the Own Protocol
/// @notice Deploys the full protocol, wires up handlers, and asserts critical invariants
///         after every random operation sequence.
contract OwnProtocolInvariant is BaseTest {
    // ── Protocol contracts ──────────────────────────────────────

    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;

    // ── Handlers ────────────────────────────────────────────────

    VaultHandler public vaultHandler;
    MarketHandler public marketHandler;
    ETokenHandler public eTokenHandler;

    // ── Constants ───────────────────────────────────────────────

    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant CLAIM_THRESHOLD = 6 hours;
    uint256 constant WITHDRAWAL_WAIT = 1 hours;
    uint256 constant LP_SEED_AMOUNT = 50_000e18; // 50k WETH

    bytes32 constant ETH_ASSET = bytes32("ETH");

    // ── Setup ───────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configureVault();
        _seedVault();
        _deployHandlers();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        // Asset registry
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        vm.stopPrank();
        // VaultManager must be registered before registering the vault (admin-gated).
        _deployVaultManager();
        vm.startPrank(Actors.ADMIN);

        // Create vault: WETH collateral, vm1Signer (keyed VM for quote signing). ETH = collateral ticker.
        vault = new OwnVault(address(weth), "Own ETH Vault", "oETH", address(protocolRegistry), vm1Signer);
        vaultManager.registerVault(address(vault), ETH);

        // Market
        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        // Vault parameters
        vault.setWithdrawalWaitPeriod(WITHDRAWAL_WAIT);

        vm.stopPrank();

        // Global controls now live on the VaultManager.
        // Register the keyed VM signer with Actors.VM1 as its linked settlement address
        // (mint proceeds flow to it; redeem payouts come from it).
        _setClaimThreshold(CLAIM_THRESHOLD);
        _registerSigner(vm1Signer, Actors.VM1);
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        // eTSLA (volatility level 2)
        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaConfig = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        // ETH collateral oracle
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ETH_ASSET, address(weth), ethConfig);

        // Scope the maker to its quoted asset (default-deny since Phase 4b).
        assetRegistry.setMakerAllowed(TSLA, vm1Signer, true);

        vm.stopPrank();

        // Set oracle prices
        _setOraclePrice(ETH_ASSET, ETH_PRICE);
        _setOraclePrice(TSLA, TSLA_PRICE);

        // Per-asset issuance ceiling (global max util set by _deployVaultManager).
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);
    }

    function _configureVault() private {
        // Payment token is now a global VaultManager setting.
        _setPaymentToken(address(usdc));
    }

    function _seedVault() private {
        _fundWETH(vm1Signer, LP_SEED_AMOUNT);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_SEED_AMOUNT);
        vault.deposit(LP_SEED_AMOUNT, Actors.LP1);
        vm.stopPrank();

        // Seed the manager's marks so mints have non-zero collateral and an asset price.
        _pullCollateralPrice(address(vault));
        _pullAssetPrice(TSLA);
    }

    function _deployHandlers() private {
        vaultHandler = new VaultHandler(address(vault), address(weth), address(usdc));
        marketHandler = new MarketHandler(
            address(market), address(vault), address(usdc), address(eTSLA), address(oracle), vm1SignerPk
        );
        eTokenHandler = new ETokenHandler(address(eTSLA), address(usdc));

        // Register handlers as target contracts
        targetContract(address(vaultHandler));
        targetContract(address(marketHandler));
        targetContract(address(eTokenHandler));

        // Restrict to handler functions only (exclude ghost getters)
        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = VaultHandler.deposit.selector;
        vaultSelectors[1] = VaultHandler.requestWithdrawal.selector;
        vaultSelectors[2] = VaultHandler.fulfillWithdrawal.selector;
        vaultSelectors[3] = VaultHandler.cancelWithdrawal.selector;
        vaultSelectors[4] = VaultHandler.shareYield.selector;
        targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: vaultSelectors}));

        bytes4[] memory marketSelectors = new bytes4[](9);
        marketSelectors[0] = MarketHandler.placeMintOrder.selector;
        marketSelectors[1] = MarketHandler.placeRedeemOrder.selector;
        marketSelectors[2] = MarketHandler.fillMintOrder.selector;
        marketSelectors[3] = MarketHandler.fillRedeemOrder.selector;
        marketSelectors[4] = MarketHandler.cancelMintOrder.selector;
        marketSelectors[5] = MarketHandler.cancelRedeemOrder.selector;
        marketSelectors[6] = MarketHandler.expireMintOrder.selector;
        marketSelectors[7] = MarketHandler.expireRedeemOrder.selector;
        marketSelectors[8] = MarketHandler.warpForward.selector;
        targetSelector(FuzzSelector({addr: address(marketHandler), selectors: marketSelectors}));

        bytes4[] memory eTokenSelectors = new bytes4[](3);
        eTokenSelectors[0] = ETokenHandler.transfer.selector;
        eTokenSelectors[1] = ETokenHandler.depositRewards.selector;
        eTokenSelectors[2] = ETokenHandler.claimRewards.selector;
        targetSelector(FuzzSelector({addr: address(eTokenHandler), selectors: eTokenSelectors}));
    }

    // ═════════════════════════════════════════════════════════════
    //  TIER 1 — Solvency Invariants
    // ═════════════════════════════════════════════════════════════

    /// @notice INV-01: ERC4626 share value never inflated beyond actual assets.
    ///         vault.totalAssets() >= vault.convertToAssets(vault.totalSupply())
    function invariant_erc4626Accounting() external view {
        uint256 totalShares = vault.totalSupply();
        if (totalShares == 0) return;

        uint256 totalAssetsVal = vault.totalAssets();
        uint256 sharesAsAssets = vault.convertToAssets(totalShares);

        // convertToAssets uses floor division, so totalAssets >= sharesAsAssets
        assert(totalAssetsVal >= sharesAsAssets);
    }

    /// @notice INV-02: Vault's underlying token balance covers totalAssets.
    ///         Since totalAssets() = ERC20.balanceOf(vault) - pendingDepositAssets,
    ///         balanceOf(vault) >= totalAssets() always holds.
    function invariant_vaultCollateralSolvency() external view {
        uint256 vaultBalance = weth.balanceOf(address(vault));
        uint256 totalAssetsVal = vault.totalAssets();

        assert(vaultBalance >= totalAssetsVal);
    }

    /// @notice INV-04: Market stablecoin balance covers escrowed open mint orders.
    ///         Escrow = sum over open MINT orders of (amount - filledAmount).
    function invariant_marketStablecoinEscrow() external view {
        uint256 marketUsdcBalance = usdc.balanceOf(address(market));
        assert(marketUsdcBalance >= marketHandler.ghost_escrowedStablecoins());
    }

    /// @notice INV-05: Market eToken balance covers escrowed open redeem orders.
    ///         Escrow = sum over open REDEEM orders of (amount - filledAmount).
    function invariant_marketETokenEscrow() external view {
        uint256 marketETokenBalance = eTSLA.balanceOf(address(market));
        assert(marketETokenBalance >= marketHandler.ghost_escrowedETokens());
    }

    // ═════════════════════════════════════════════════════════════
    //  TIER 2 — Core Constraint Invariants
    // ═════════════════════════════════════════════════════════════

    /// @notice INV-06: Pending withdrawal shares never exceed total supply.
    function invariant_pendingWithdrawalBound() external view {
        assert(vault.pendingWithdrawalShares() <= vault.totalSupply());
    }

    /// @notice INV-07: Global exposure USD equals Σ globalAssetUnits[a] × assetMark[a] / 1e18.
    ///         Single asset here, so it reduces to the TSLA term.
    function invariant_exposureConsistency() external view {
        uint256 globalExp = vaultManager.globalNetExposureUSD();
        uint256 units = vaultManager.globalAssetUnits(TSLA);
        uint256 mark = vaultManager.assetMark(TSLA);
        assert(globalExp == (units * mark) / PRECISION);
    }

    /// @notice INV-07b: Global outstanding units for an asset equal the eToken's total supply.
    ///         openExposure mirrors mint, closeExposure mirrors burn, so they stay in lockstep.
    function invariant_globalUnitsMatchSupply() external view {
        assert(vaultManager.globalAssetUnits(TSLA) == eTSLA.totalSupply());
    }

    /// @notice INV-07c: Global utilisation never exceeds the cap (collateral mark is fixed across the
    ///         campaign — no keeper price pulls — so every gated open keeps utilisation bounded).
    function invariant_globalUtilizationWithinCap() external view {
        assert(vaultManager.globalUtilizationBps() <= vaultManager.globalMaxUtilizationBps());
    }

    /// @notice INV-08: EToken rewards-per-share accumulator never decreases.
    function invariant_rewardsMonotonicity() external view {
        assert(eTSLA.rewardsPerShare() >= eTokenHandler.ghost_lastRewardsPerShare());
    }

    /// @notice INV-09: EToken reward token balance covers all claimable rewards.
    function invariant_eTokenRewardSolvency() external view {
        uint256 rewardBalance = usdc.balanceOf(address(eTSLA));
        uint256 totalClaimable = eTSLA.claimableRewards(Actors.MINTER1) + eTSLA.claimableRewards(Actors.MINTER2)
            + eTSLA.claimableRewards(address(market));

        assert(rewardBalance >= totalClaimable);
    }

    // ═════════════════════════════════════════════════════════════
    //  TIER 3 — Consistency Invariants
    // ═════════════════════════════════════════════════════════════

    /// @notice INV-10: Ghost pending withdrawal shares matches contract state.
    function invariant_pendingWithdrawalGhostSync() external view {
        assert(vault.pendingWithdrawalShares() == vaultHandler.ghost_pendingWithdrawalShares());
    }

    /// @notice INV-11: Global asset units never wrap around (no underflow).
    function invariant_noExposureUnderflow() external view {
        assert(vaultManager.globalAssetUnits(TSLA) < type(uint256).max / 2);
    }

    // ═════════════════════════════════════════════════════════════
    //  Call summary (for debugging)
    // ═════════════════════════════════════════════════════════════

    function invariant_callSummary() external view {
        // This invariant always passes — used to print call distribution
        // when running with -vvv for debugging.
    }
}
