// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, BPS, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title UtilizationLimit Integration Test
/// @notice Tests utilization enforcement during order claims: claims that would breach
///         max utilization are rejected, and utilization updates correctly on confirm/close.
contract UtilizationLimitTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;

    // Very low max utilization (10%) to easily trigger breach
    uint256 constant MAX_UTIL_BPS = 1000;
    uint256 constant LP_DEPOSIT_WETH = 100e18;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configureVault();
        _depositLPCollateral();
        // Update collateral valuation AFTER deposit so USD value reflects actual assets
        vault.updateCollateralValuation();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        // Low max utilization: 10%
        vault = OwnVault(factory.createVault(address(weth), vm1Signer, "Own ETH Vault", "oETH", MAX_UTIL_BPS));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        vault.setClaimThreshold(CLAIM_THRESHOLD);
        vault.addQuoteSigner(vm1Signer);

        vm.stopPrank();
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaConfig = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);

        bytes32 ethAsset = bytes32("ETH");
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ethAsset, address(weth), ethConfig);
        vault.setCollateralOracleAsset(ethAsset);

        vm.stopPrank();

        _setOraclePrice(ethAsset, ETH_PRICE);
    }

    function _configureVault() private {
        vm.startPrank(vm1Signer);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();

        vault.updateAssetValuation(TSLA);
        vault.updateCollateralValuation();
    }

    function _depositLPCollateral() private {
        _fundWETH(vm1Signer, LP_DEPOSIT_WETH);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();
    }

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeOrder(address(vault), TSLA, OrderType.Mint, amount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    /// @dev Fill a resting mint order with a VM-signed quote for the full remaining amount.
    function _fillMint(uint256 orderId, address minter, uint256 amount) internal {
        Quote memory q = _buildQuote(orderId, minter, address(vault), TSLA, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(vm1Signer);
        market.fillOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Claim succeeds when within utilization limit
    // ══════════════════════════════════════════════════════════

    function test_utilization_fillSucceedsWithinLimit() public {
        // Collateral = 100 ETH * $3000 = $300,000
        // Max utilization = 10% = $30,000
        // Order = $10,000 = 3.33% utilization → should succeed
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        // Escrow alone does not add exposure
        assertEq(vault.utilization(), 0, "utilization unchanged after placement");

        _fillMint(orderId, Actors.MINTER1, mintAmount);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Filled));
        assertGt(vault.utilization(), 0, "utilization > 0 after fill");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Fill reverts when utilization would be breached
    // ══════════════════════════════════════════════════════════

    function test_utilization_fillBlockedWhenBreached() public {
        // Collateral = 100 ETH * $3000 = $300,000
        // Max utilization = 10% = $30,000
        // Order = $50,000 → 16.6% utilization → should revert
        uint256 bigMintAmount = 50_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, bigMintAmount, block.timestamp + 1 days);

        Quote memory q =
            _buildQuote(orderId, Actors.MINTER1, address(vault), TSLA, OrderType.Mint, bigMintAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);

        vm.prank(vm1Signer);
        vm.expectRevert(); // UtilizationBreached
        market.fillOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Utilization updates after fill
    // ══════════════════════════════════════════════════════════

    function test_utilization_updatesAfterFill() public {
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        assertEq(vault.utilization(), 0, "utilization unchanged after placement");

        _fillMint(orderId, Actors.MINTER1, mintAmount);

        assertGt(vault.utilization(), 0, "utilization > 0 after fill");
        assertLe(vault.utilization(), MAX_UTIL_BPS, "utilization within limit");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Cancelling an unfilled order leaves utilization at zero
    // ══════════════════════════════════════════════════════════

    function test_utilization_unchangedAfterCancel() public {
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        // Escrow doesn't change exposure
        assertEq(vault.utilization(), 0, "utilization unchanged after placement");

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        // Cancel returns escrow — nothing was settled
        assertEq(vault.utilization(), 0, "utilization still 0 after cancel");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Multiple orders accumulate exposure
    // ══════════════════════════════════════════════════════════

    function test_utilization_multipleOrders_cumulativeExposure() public {
        // Two orders of $10,000 each = $20,000 total
        // 10% of $300,000 = $30,000 max → both should fit
        uint256 mintAmount = 10_000e6;
        uint256 orderId1 = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);
        uint256 orderId2 = _placeMint(Actors.MINTER2, mintAmount, block.timestamp + 1 days);

        // Escrow alone doesn't change exposure
        assertEq(vault.utilization(), 0, "utilization unchanged after placements");

        // Fill first mint → exposure increases
        _fillMint(orderId1, Actors.MINTER1, mintAmount);

        uint256 utilAfterFirst = vault.utilization();
        assertGt(utilAfterFirst, 0, "utilization > 0 after first fill");

        // Fill second mint → exposure increases further
        _fillMint(orderId2, Actors.MINTER2, mintAmount);

        uint256 utilAfterSecond = vault.utilization();
        assertGt(utilAfterSecond, utilAfterFirst, "utilization increased with second fill");
    }

    // ══════════════════════════════════════════════════════════
    //  Projected Utilization
    // ══════════════════════════════════════════════════════════

    function test_projectedUtilization_noWithdrawals_matchesUtilization() public {
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        _fillMint(orderId, Actors.MINTER1, mintAmount);

        assertGt(vault.utilization(), 0, "utilization > 0 after confirm");
        assertEq(vault.projectedUtilization(), vault.utilization(), "projected == current when no withdrawals");
        assertEq(vault.pendingWithdrawalShares(), 0, "no pending withdrawal shares");
    }

    function test_projectedUtilization_withPendingWithdrawal_higherThanCurrent() public {
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        _fillMint(orderId, Actors.MINTER1, mintAmount);

        uint256 utilBefore = vault.utilization();
        assertGt(utilBefore, 0);

        // LP requests withdrawal of half their shares
        uint256 lpShares = vault.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        vault.requestWithdrawal(lpShares / 2);

        assertEq(vault.pendingWithdrawalShares(), lpShares / 2, "pending shares tracked");

        // Current utilization unchanged (collateral still in vault)
        assertEq(vault.utilization(), utilBefore, "current util unchanged");

        // Projected utilization higher (accounts for pending withdrawal)
        uint256 projected = vault.projectedUtilization();
        assertGt(projected, utilBefore, "projected > current with pending withdrawal");
    }

    function test_projectedUtilization_afterFulfill_dropsBack() public {
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        _fillMint(orderId, Actors.MINTER1, mintAmount);

        uint256 lpShares = vault.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(lpShares / 4);

        uint256 projectedBefore = vault.projectedUtilization();
        assertGt(projectedBefore, vault.utilization());

        // Fulfill the withdrawal
        vault.fulfillWithdrawal(requestId);

        // After fulfillment, projected should match current (no pending shares)
        assertEq(vault.pendingWithdrawalShares(), 0, "no pending shares after fulfill");
        assertEq(vault.projectedUtilization(), vault.utilization(), "projected == current after fulfill");
    }

    function test_projectedUtilization_afterCancel_dropsBack() public {
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        _fillMint(orderId, Actors.MINTER1, mintAmount);

        uint256 lpShares = vault.balanceOf(Actors.LP1);
        vm.prank(Actors.LP1);
        uint256 requestId = vault.requestWithdrawal(lpShares / 4);

        assertGt(vault.projectedUtilization(), vault.utilization());

        // Cancel the withdrawal
        vm.prank(Actors.LP1);
        vault.cancelWithdrawal(requestId);

        assertEq(vault.pendingWithdrawalShares(), 0, "no pending shares after cancel");
        assertEq(vault.projectedUtilization(), vault.utilization(), "projected == current after cancel");
    }
}
