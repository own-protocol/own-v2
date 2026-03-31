// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {AssetConfig, BPS, OracleConfig, OrderStatus, PRECISION} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
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
    FeeCalculator public feeCalc;

    // Very low max utilization (10%) to easily trigger breach
    uint256 constant MAX_UTIL_BPS = 1000;
    uint256 constant LP_DEPOSIT_WETH = 100e18;
    uint256 constant GRACE_PERIOD = 1 days;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
        _configureAssets();
        _configureVault();
        _depositLPCollateral();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        // Low max utilization: 10%
        vault = OwnVault(factory.createVault(address(weth), Actors.VM1, "Own ETH Vault", "oETH", MAX_UTIL_BPS, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vault.setGracePeriod(GRACE_PERIOD);
        vault.setClaimThreshold(CLAIM_THRESHOLD);

        vm.stopPrank();
    }

    function _configureAssets() private {
        vm.startPrank(Actors.ADMIN);

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaConfig =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), tslaConfig);
        OracleConfig memory tslaOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(TSLA, tslaOracleConfig);

        bytes32 ethAsset = bytes32("ETH");
        AssetConfig memory ethConfig =
            AssetConfig({activeToken: address(weth), legacyTokens: new address[](0), active: true, volatilityLevel: 1});
        assetRegistry.addAsset(ethAsset, address(weth), ethConfig);
        OracleConfig memory ethOracleConfig =
            OracleConfig({primaryOracle: address(oracle), secondaryOracle: address(0)});
        assetRegistry.setOracleConfig(ethAsset, ethOracleConfig);
        vault.setCollateralOracleAsset(ethAsset);

        vm.stopPrank();

        _setOraclePrice(ethAsset, ETH_PRICE);
    }

    function _configureVault() private {
        vm.startPrank(Actors.VM1);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vm.stopPrank();

        vault.updateAssetValuation(TSLA);
        vault.updateCollateralValuation();
    }

    function _depositLPCollateral() private {
        _fundWETH(Actors.VM1, LP_DEPOSIT_WETH);
        vm.startPrank(Actors.VM1);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();
    }

    function _placeMint(address minter, uint256 amount, uint256 expiry) internal returns (uint256) {
        _fundUSDC(minter, amount);
        vm.startPrank(minter);
        usdc.approve(address(market), amount);
        uint256 orderId = market.placeMintOrder(address(vault), TSLA, amount, TSLA_PRICE, expiry);
        vm.stopPrank();
        return orderId;
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Claim succeeds when within utilization limit
    // ══════════════════════════════════════════════════════════

    function test_utilization_claimSucceedsWithinLimit() public {
        // Collateral = 100 ETH * $3000 = $300,000
        // Max utilization = 10% = $30,000
        // Order = $10,000 = 3.33% utilization → should succeed
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        assertEq(uint8(market.getOrder(orderId).status), uint8(OrderStatus.Claimed));
        assertGt(vault.utilization(), 0, "utilization increased");
        assertLe(vault.utilization(), MAX_UTIL_BPS, "utilization within limit");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Claim reverts when utilization would be breached
    // ══════════════════════════════════════════════════════════

    function test_utilization_claimBlockedWhenBreached() public {
        // Collateral = 100 ETH * $3000 = $300,000
        // Max utilization = 10% = $30,000
        // Order = $50,000 → 16.6% utilization → should revert
        uint256 bigMintAmount = 50_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, bigMintAmount, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        vm.expectRevert(); // UtilizationBreached
        market.claimOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Utilization decreases after confirm
    // ══════════════════════════════════════════════════════════

    function test_utilization_updatesAfterConfirm() public {
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, block.timestamp + 1 days);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        uint256 utilAfterClaim = vault.utilization();
        assertGt(utilAfterClaim, 0, "utilization > 0 after claim");

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        assertEq(vault.utilization(), 0, "utilization back to 0 after confirm");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Utilization decreases after close
    // ══════════════════════════════════════════════════════════

    function test_utilization_updatesAfterClose() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 mintAmount = 10_000e6;
        uint256 orderId = _placeMint(Actors.MINTER1, mintAmount, expiry);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        assertGt(vault.utilization(), 0, "utilization > 0 after claim");

        vm.warp(expiry + 1);

        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), mintAmount);
        market.closeOrder(orderId);
        vm.stopPrank();

        assertEq(vault.utilization(), 0, "utilization back to 0 after close");
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

        vm.prank(Actors.VM1);
        market.claimOrder(orderId1);

        uint256 utilAfterFirst = vault.utilization();
        assertGt(utilAfterFirst, 0, "utilization after first claim");

        vm.prank(Actors.VM1);
        market.claimOrder(orderId2);

        uint256 utilAfterSecond = vault.utilization();
        assertGt(utilAfterSecond, utilAfterFirst, "utilization increased with second claim");

        // Confirm first → utilization drops but not to zero
        vm.prank(Actors.VM1);
        market.confirmOrder(orderId1);

        uint256 utilAfterFirstConfirm = vault.utilization();
        assertGt(utilAfterFirstConfirm, 0, "utilization still > 0 (second order pending)");
        assertLt(utilAfterFirstConfirm, utilAfterSecond, "utilization decreased after first confirm");

        // Confirm second → utilization back to zero
        vm.prank(Actors.VM1);
        market.confirmOrder(orderId2);

        assertEq(vault.utilization(), 0, "utilization back to 0 after all confirmed");
    }
}
