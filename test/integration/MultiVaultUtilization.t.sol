// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, OrderStatus, OrderType, Quote} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title MultiVaultUtilization Integration Test
/// @notice Two vaults registered with one VaultManager share a single global risk pool: collateral
///         sums into the global denominator and exposure draws on the shared budget. So one vault's
///         collateral can unblock a mint, a withdrawal from one vault can be gated by protocol-wide
///         exposure that was never "in" that vault, and deregistering a vault is gated the same way.
///         Fills a coverage gap — every other integration test exercises a single vault, yet the
///         utilisation math (`_globalCollateralUSD` / `_globalNetExposureUSD`) is protocol-wide.
contract MultiVaultUtilizationTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vaultA;
    OwnVault public vaultB;
    EToken public eTSLA;

    uint256 constant MAX_UTIL_BPS = 1000; // 10%
    uint256 constant VAULT_WETH = 100e18; // 100 ETH @ $3,000 = $300k of collateral per vault
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        _deployVaultManager();
        _setGlobalMaxUtil(MAX_UTIL_BPS);

        vm.startPrank(Actors.ADMIN);
        vaultA = new OwnVault(address(weth), "Vault A", "vA", address(protocolRegistry), vm1Signer);
        vaultB = new OwnVault(address(weth), "Vault B", "vB", address(protocolRegistry), vm2Signer);
        vaultManager.registerVault(address(vaultA), ETH);
        vaultManager.registerVault(address(vaultB), ETH);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        // Minted asset (exposure side).
        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaConfig = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        // ETH is both vaults' collateral ticker — must be registered so pullCollateralPrice resolves it.
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ETH, address(weth), ethConfig);
        vm.stopPrank();

        _setPaymentToken(address(usdc));
        _setClaimThreshold(CLAIM_THRESHOLD);
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);
        _setOraclePrice(ETH, ETH_PRICE);
        _pullAssetPrice(TSLA);

        // Each vault is signed by its own VM; register both signers so either can fill.
        _registerSigner(vm1Signer, Actors.VM1);
        _registerSigner(vm2Signer, Actors.VM2);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _depositCollateral(OwnVault v, address signer, address lp, uint256 amount) internal {
        _fundWETH(signer, amount);
        vm.startPrank(signer);
        weth.approve(address(v), amount);
        v.deposit(amount, lp);
        vm.stopPrank();
    }

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, amount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    function _fillMint(uint256 orderId, address minter, uint256 amount) internal {
        Quote memory q = _buildQuote(orderId, minter, TSLA, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(vm1Signer);
        market.fillOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Collateral pools across vaults into the global denominator
    // ══════════════════════════════════════════════════════════

    /// @dev A mint that breaches the cap against vault A's collateral alone fits once vault B's
    ///      collateral is added to the global pool — proving the denominator is protocol-wide.
    function test_multiVault_collateralPoolsIntoGlobalDenominator() public {
        // Only vault A marked → global collateral $300k.
        _depositCollateral(vaultA, vm1Signer, Actors.LP1, VAULT_WETH);
        _pullCollateralPrice(address(vaultA));
        assertApproxEqAbs(vaultManager.globalCollateralUSD(), 300_000e18, 1e18, "only A in the pool");

        // $40k mint = 13.3% of $300k > 10% cap → fill blocked.
        uint256 mintAmount = 40_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);
        Quote memory q = _buildQuote(orderId, Actors.MINTER1, TSLA, OrderType.Mint, mintAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(vm1Signer);
        vm.expectRevert(); // GlobalUtilizationBreached
        market.fillOrder(q, sig);

        // Add vault B's collateral → global $600k; the SAME order is now 6.7% < cap → fills.
        _depositCollateral(vaultB, vm2Signer, Actors.LP2, VAULT_WETH);
        _pullCollateralPrice(address(vaultB));
        assertApproxEqAbs(vaultManager.globalCollateralUSD(), 600_000e18, 1e18, "both vaults pooled");

        vm.prank(vm1Signer);
        market.fillOrder(q, sig);
        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Filled), "fill succeeds once pooled");
        assertGt(vaultManager.globalUtilizationBps(), 0, "exposure recorded");
        assertLe(vaultManager.globalUtilizationBps(), MAX_UTIL_BPS, "within cap on pooled collateral");
    }

    // ══════════════════════════════════════════════════════════
    //  A vault's withdrawal is gated by protocol-wide exposure
    // ══════════════════════════════════════════════════════════

    /// @dev Exposure minted against the shared pool gates a large withdrawal from a *different* vault:
    ///      draining vault B shrinks the global denominator until the global exposure breaches the cap.
    function test_multiVault_withdrawalGatedByProtocolWideExposure() public {
        _depositCollateral(vaultA, vm1Signer, Actors.LP1, VAULT_WETH);
        _depositCollateral(vaultB, vm2Signer, Actors.LP2, VAULT_WETH);
        _pullCollateralPrice(address(vaultA));
        _pullCollateralPrice(address(vaultB));

        // Mint $50k against the protocol → util = 50k / 600k = 8.3% (< 10% cap).
        uint256 orderId = _placeMint(Actors.MINTER1, 50_000e6, block.timestamp + 1 days);
        _fillMint(orderId, Actors.MINTER1, 50_000e6);
        assertGt(vaultManager.globalUtilizationBps(), 0, "exposure present");
        assertLe(vaultManager.globalUtilizationBps(), MAX_UTIL_BPS, "within cap after mint");

        uint256 lpBShares = vaultB.balanceOf(Actors.LP2);

        // Small vault-B withdrawal keeps global collateral high → does not breach.
        uint256 small = lpBShares / 10; // ~$30k of $600k
        assertFalse(
            vaultManager.withdrawalBreachesUtil(address(vaultB), vaultB.convertToAssets(small)),
            "small B withdrawal does not breach"
        );

        // Draining most of vault B shrinks global collateral to ~$330k → 50k/330k ≈ 15% > 10% cap.
        // The blocking exposure was minted globally, never "in" vault B — cross-vault risk coupling.
        uint256 large = (lpBShares * 9) / 10;
        assertTrue(
            vaultManager.withdrawalBreachesUtil(address(vaultB), vaultB.convertToAssets(large)),
            "large B withdrawal breaches on global exposure"
        );

        vm.prank(Actors.LP2);
        uint256 requestId = vaultB.requestWithdrawal(large);
        vm.expectRevert(IOwnVault.MaxUtilizationExceeded.selector);
        vaultB.fulfillWithdrawal(requestId);
    }

    // ══════════════════════════════════════════════════════════
    //  Deregistration is gated by the shared pool too
    // ══════════════════════════════════════════════════════════

    /// @dev Deregistering a vault removes its collateral; if that pushes global utilisation over the
    ///      cap (because of exposure backed by the *other* vault), the deregister reverts.
    function test_multiVault_deregisterBlockedWhenItWouldBreachUtil() public {
        _depositCollateral(vaultA, vm1Signer, Actors.LP1, VAULT_WETH);
        _depositCollateral(vaultB, vm2Signer, Actors.LP2, VAULT_WETH);
        _pullCollateralPrice(address(vaultA));
        _pullCollateralPrice(address(vaultB));

        // Mint $50k → util 8.3% on $600k.
        uint256 orderId = _placeMint(Actors.MINTER1, 50_000e6, block.timestamp + 1 days);
        _fillMint(orderId, Actors.MINTER1, 50_000e6);

        // Removing vault B drops collateral to $300k → 50k/300k = 16.7% > cap → revert.
        vm.prank(Actors.ADMIN);
        vm.expectRevert(); // DeregisterWouldBreachUtilization
        vaultManager.deregisterVault(address(vaultB));

        // Vault A (which the exposure rides on) is still registered and the pool is intact.
        assertApproxEqAbs(vaultManager.globalCollateralUSD(), 600_000e18, 1e18, "pool unchanged after revert");
    }
}
