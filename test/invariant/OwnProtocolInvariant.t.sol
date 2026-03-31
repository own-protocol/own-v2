// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";

import {AssetConfig, OracleConfig, PRECISION} from "../../src/interfaces/types/Types.sol";
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
    FeeCalculator public feeCalc;
    VaultFactory public factory;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;

    // ── Handlers ────────────────────────────────────────────────

    VaultHandler public vaultHandler;
    MarketHandler public marketHandler;
    ETokenHandler public eTokenHandler;

    // ── Constants ───────────────────────────────────────────────

    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant VM_SHARE_BPS = 2000;
    uint256 constant PROTOCOL_SHARE_BPS = 2000;
    uint256 constant MINT_FEE_BPS = 30;
    uint256 constant REDEEM_FEE_BPS = 30;
    uint256 constant GRACE_PERIOD = 1 days;
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
        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        // Treasury
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(PROTOCOL_SHARE_BPS);

        // Fee calculator with non-zero fees
        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(2, MINT_FEE_BPS);
        feeCalc.setRedeemFee(2, REDEEM_FEE_BPS);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        // Vault factory
        factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        // Create vault: WETH collateral, VM1, 80% max util, 20% VM fee share
        vault = OwnVault(
            factory.createVault(address(weth), Actors.VM1, "Own ETH Vault", "oETH", MAX_UTIL_BPS, VM_SHARE_BPS)
        );

        // Market
        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        // Vault parameters
        vault.setGracePeriod(GRACE_PERIOD);
        vault.setClaimThreshold(CLAIM_THRESHOLD);
        vault.setWithdrawalWaitPeriod(WITHDRAWAL_WAIT);

        vm.stopPrank();
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        // eTSLA (volatility level 2)
        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaConfig =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);
        OracleConfig memory tslaOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(TSLA, tslaOracleConfig);

        // ETH collateral oracle
        AssetConfig memory ethConfig =
            AssetConfig({activeToken: address(weth), legacyTokens: new address[](0), active: true, volatilityLevel: 1});
        assetRegistry.addAsset(ETH_ASSET, address(weth), ethConfig);
        OracleConfig memory ethOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(ETH_ASSET, ethOracleConfig);
        vault.setCollateralOracleAsset(ETH_ASSET);

        vm.stopPrank();

        // Set oracle prices
        _setOraclePrice(ETH_ASSET, ETH_PRICE);
        _setOraclePrice(TSLA, TSLA_PRICE);
    }

    function _configureVault() private {
        vm.startPrank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();

        // Initialize valuations
        vault.updateAssetValuation(TSLA);
        vault.updateCollateralValuation();
    }

    function _seedVault() private {
        _fundWETH(Actors.VM1, LP_SEED_AMOUNT);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), LP_SEED_AMOUNT);
        vault.deposit(LP_SEED_AMOUNT, Actors.LP1);
        vm.stopPrank();
    }

    function _deployHandlers() private {
        vaultHandler = new VaultHandler(address(vault), address(weth), address(usdc));
        marketHandler = new MarketHandler(
            address(market), address(vault), address(feeCalc), address(usdc), address(eTSLA), address(oracle)
        );
        eTokenHandler = new ETokenHandler(address(eTSLA), address(usdc));

        // Register handlers as target contracts
        targetContract(address(vaultHandler));
        targetContract(address(marketHandler));
        targetContract(address(eTokenHandler));

        // Restrict to handler functions only (exclude ghost getters)
        bytes4[] memory vaultSelectors = new bytes4[](7);
        vaultSelectors[0] = VaultHandler.deposit.selector;
        vaultSelectors[1] = VaultHandler.requestWithdrawal.selector;
        vaultSelectors[2] = VaultHandler.fulfillWithdrawal.selector;
        vaultSelectors[3] = VaultHandler.cancelWithdrawal.selector;
        vaultSelectors[4] = VaultHandler.claimProtocolFees.selector;
        vaultSelectors[5] = VaultHandler.claimVMFees.selector;
        vaultSelectors[6] = VaultHandler.claimLPRewards.selector;
        targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: vaultSelectors}));

        bytes4[] memory marketSelectors = new bytes4[](13);
        marketSelectors[0] = MarketHandler.placeMintOrder.selector;
        marketSelectors[1] = MarketHandler.placeRedeemOrder.selector;
        marketSelectors[2] = MarketHandler.claimMintOrder.selector;
        marketSelectors[3] = MarketHandler.claimRedeemOrder.selector;
        marketSelectors[4] = MarketHandler.confirmMintOrder.selector;
        marketSelectors[5] = MarketHandler.confirmRedeemOrder.selector;
        marketSelectors[6] = MarketHandler.cancelMintOrder.selector;
        marketSelectors[7] = MarketHandler.cancelRedeemOrder.selector;
        marketSelectors[8] = MarketHandler.expireMintOrder.selector;
        marketSelectors[9] = MarketHandler.expireRedeemOrder.selector;
        marketSelectors[10] = MarketHandler.closeMintOrder.selector;
        marketSelectors[11] = MarketHandler.closeRedeemOrder.selector;
        marketSelectors[12] = MarketHandler.warpForward.selector;
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

    /// @notice INV-03: Vault payment token balance covers all unclaimed fees.
    ///         Since collateral=WETH and paymentToken=USDC, fees are in USDC.
    function invariant_vaultFeeSolvency() external view {
        uint256 usdcBalance = usdc.balanceOf(address(vault));
        uint256 protocolFees = vault.accruedProtocolFees();
        uint256 vmFees = vault.accruedVMFees();

        // Sum claimable LP rewards for known LPs
        uint256 lpRewards = vault.claimableLPRewards(Actors.LP1) + vault.claimableLPRewards(Actors.LP2)
            + vault.claimableLPRewards(Actors.LP3);

        assert(usdcBalance >= protocolFees + vmFees + lpRewards);
    }

    /// @notice INV-04: Market stablecoin balance covers escrowed mint order funds.
    function invariant_marketStablecoinEscrow() external view {
        uint256 marketUsdcBalance = usdc.balanceOf(address(market));
        uint256 escrowedTotal = marketHandler.ghost_escrowedStablecoins() + marketHandler.ghost_escrowedMintFees();

        assert(marketUsdcBalance >= escrowedTotal);
    }

    /// @notice INV-05: Market eToken balance covers escrowed redeem orders.
    function invariant_marketETokenEscrow() external view {
        uint256 marketETokenBalance = eTSLA.balanceOf(address(market));
        uint256 escrowedETokens = marketHandler.ghost_escrowedETokens();

        assert(marketETokenBalance >= escrowedETokens);
    }

    // ═════════════════════════════════════════════════════════════
    //  TIER 2 — Core Constraint Invariants
    // ═════════════════════════════════════════════════════════════

    /// @notice INV-06: Pending withdrawal shares never exceed total supply.
    function invariant_pendingWithdrawalBound() external view {
        assert(vault.pendingWithdrawalShares() <= vault.totalSupply());
    }

    /// @notice INV-07: Total exposure USD equals sum of per-asset exposure USD.
    function invariant_exposureConsistency() external view {
        uint256 totalExp = vault.totalExposureUSD();
        uint256 sumExp = vault.assetExposureUSD(TSLA);

        assert(totalExp == sumExp);
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

    /// @notice INV-11: Asset exposure never wraps around (no underflow).
    function invariant_noExposureUnderflow() external view {
        assert(vault.assetExposure(TSLA) < type(uint256).max / 2);
    }

    // ═════════════════════════════════════════════════════════════
    //  Call summary (for debugging)
    // ═════════════════════════════════════════════════════════════

    function invariant_callSummary() external view {
        // This invariant always passes — used to print call distribution
        // when running with -vvv for debugging.
    }
}
