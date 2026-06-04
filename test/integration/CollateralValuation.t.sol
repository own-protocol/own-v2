// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, BPS, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CollateralValuation Integration Test
/// @notice Tests collateral and asset valuation updates, health factor behavior
///         under exposure changes and oracle price movements.
contract CollateralValuationTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;
    EToken public eGOLD;
    FeeCalculator public feeCalc;

    bytes32 constant ETH_ASSET = bytes32("ETH");

    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT_WETH = 100e18;
    uint256 constant MINT_AMOUNT = 10_000e6;

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

        vault = OwnVault(factory.createVault(address(weth), vm1Signer, "Own ETH Vault", "oETH", MAX_UTIL_BPS, 2000));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        vault.setGracePeriod(1 days);
        vault.setClaimThreshold(6 hours);
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

        eGOLD = new EToken("Own Gold", "eGOLD", GOLD, address(protocolRegistry), address(usdc));
        AssetConfig memory goldConfig = AssetConfig({
            activeToken: address(eGOLD),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetRegistry.addAsset(GOLD, address(eGOLD), goldConfig);

        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(weth),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetRegistry.addAsset(ETH_ASSET, address(weth), ethConfig);
        vault.setCollateralOracleAsset(ETH_ASSET);

        vm.stopPrank();

        _setOraclePrice(ETH_ASSET, ETH_PRICE);
    }

    function _configureVault() private {
        vm.startPrank(vm1Signer);
        vault.setPaymentToken(address(usdc));
        vault.enableAsset(TSLA);
        vault.enableAsset(GOLD);
        vm.stopPrank();

        vault.updateAssetValuation(TSLA);
        vault.updateAssetValuation(GOLD);
        vault.updateCollateralValuation();
    }

    function _depositLPCollateral() private {
        _fundWETH(vm1Signer, LP_DEPOSIT_WETH);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_DEPOSIT_WETH);
        vault.deposit(LP_DEPOSIT_WETH, Actors.LP1);
        vm.stopPrank();
    }

    /// @dev Market mint for MINTER1 via a VM-signed quote — adds exposure to the vault.
    function _marketMint(bytes32 asset, uint256 amount, uint256 price) internal {
        _fundUSDC(Actors.MINTER1, amount);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), amount);
        Quote memory q = _buildQuote(0, Actors.MINTER1, address(vault), asset, OrderType.Mint, amount, price);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    /// @dev Market redeem of MINTER1's eTokens via a VM-signed quote — removes exposure.
    function _marketRedeem(bytes32 asset, uint256 eAmount, uint256 price) internal {
        // VM funds the payout and approves the market to pull it.
        uint256 grossPayout = Math.mulDiv(eAmount, price, PRECISION * 1e12);
        _fundUSDC(vm1Signer, grossPayout);
        vm.prank(vm1Signer);
        usdc.approve(address(market), grossPayout);

        vm.prank(Actors.MINTER1);
        IERC20(assetRegistry.getActiveToken(asset)).approve(address(market), eAmount);

        Quote memory q = _buildQuote(0, Actors.MINTER1, address(vault), asset, OrderType.Redeem, eAmount, price);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Health factor degrades with exposure
    // ══════════════════════════════════════════════════════════

    function test_healthFactor_degradesWithExposure() public {
        assertEq(vault.healthFactor(), type(uint256).max, "initial health = max");
        assertEq(vault.totalExposureUSD(), 0, "initial exposure = 0");

        // Collateral value = 100 ETH * $3000 = $300,000
        uint256 expectedCollateral = Math.mulDiv(LP_DEPOSIT_WETH, ETH_PRICE, PRECISION);
        assertEq(vault.collateralValueUSD(), expectedCollateral, "collateral value correct");

        _marketMint(TSLA, MINT_AMOUNT, TSLA_PRICE);

        uint256 healthAfterConfirm = vault.healthFactor();
        assertLt(healthAfterConfirm, type(uint256).max, "health decreased from max");
        assertGt(healthAfterConfirm, 0, "health still positive");
        assertGt(vault.totalExposureUSD(), 0, "exposure > 0");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Health factor recovers after confirm
    // ══════════════════════════════════════════════════════════

    function test_healthFactor_withMintAndRedeem() public {
        // Mint adds exposure, redeem removes it
        _marketMint(TSLA, MINT_AMOUNT, TSLA_PRICE);

        uint256 healthWithExposure = vault.healthFactor();
        assertLt(healthWithExposure, type(uint256).max, "health decreased with mint exposure");
        assertGt(vault.totalExposureUSD(), 0, "exposure > 0 after mint");

        // Redeem all eTokens to remove exposure
        uint256 eTokenUnits = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        _marketRedeem(TSLA, eTokenUnits, TSLA_PRICE);

        assertEq(vault.healthFactor(), type(uint256).max, "health recovered to max after redeem");
        assertEq(vault.totalExposureUSD(), 0, "exposure back to 0");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Collateral valuation updates with oracle price change
    // ══════════════════════════════════════════════════════════

    function test_collateralValuation_updatesWithOraclePrice() public {
        uint256 initialCollateral = vault.collateralValueUSD();
        assertGt(initialCollateral, 0, "initial collateral > 0");

        // ETH price doubles
        uint256 newEthPrice = ETH_PRICE * 2;
        _setOraclePrice(ETH_ASSET, newEthPrice);
        vault.updateCollateralValuation();

        uint256 expectedCollateral = Math.mulDiv(LP_DEPOSIT_WETH, newEthPrice, PRECISION);
        assertEq(vault.collateralValueUSD(), expectedCollateral, "collateral doubled");
        assertEq(vault.collateralValueUSD(), initialCollateral * 2, "collateral 2x");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Asset valuation updates with oracle price change
    // ══════════════════════════════════════════════════════════

    function test_assetValuation_updatesWithOraclePrice() public {
        // Create exposure via market mint
        _marketMint(TSLA, MINT_AMOUNT, TSLA_PRICE);

        uint256 exposureBefore = vault.totalExposureUSD();
        assertGt(exposureBefore, 0, "exposure > 0");

        // TSLA price doubles
        uint256 newTslaPrice = TSLA_PRICE * 2;
        _setOraclePrice(TSLA, newTslaPrice);
        vault.updateAssetValuation(TSLA);

        uint256 exposureAfter = vault.totalExposureUSD();
        assertEq(exposureAfter, exposureBefore * 2, "exposure doubled with price");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Health factor with multiple assets
    // ══════════════════════════════════════════════════════════

    function test_healthFactor_withMultipleAssets() public {
        // Market mint TSLA ($10,000)
        _marketMint(TSLA, MINT_AMOUNT, TSLA_PRICE);

        uint256 healthAfterTSLA = vault.healthFactor();
        uint256 exposureAfterTSLA = vault.totalExposureUSD();

        // Market mint GOLD ($10,000)
        _marketMint(GOLD, MINT_AMOUNT, GOLD_PRICE);

        uint256 healthAfterBoth = vault.healthFactor();
        uint256 exposureAfterBoth = vault.totalExposureUSD();

        assertGt(exposureAfterBoth, exposureAfterTSLA, "combined exposure > single");
        assertLt(healthAfterBoth, healthAfterTSLA, "health lower with more exposure");

        // Redeem TSLA → only GOLD exposure remains
        uint256 tslaETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, TSLA_PRICE);
        _marketRedeem(TSLA, tslaETokens, TSLA_PRICE);

        uint256 healthAfterTSLARedeem = vault.healthFactor();
        assertGt(healthAfterTSLARedeem, healthAfterBoth, "health improved after TSLA redeem");
        assertLt(healthAfterTSLARedeem, type(uint256).max, "still has GOLD exposure");

        // Redeem GOLD → all clear
        uint256 goldETokens = Math.mulDiv(MINT_AMOUNT * 1e12, PRECISION, GOLD_PRICE);
        _marketRedeem(GOLD, goldETokens, GOLD_PRICE);

        assertEq(vault.healthFactor(), type(uint256).max, "health max after all redeemed");
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Collateral price drop affects health factor
    // ══════════════════════════════════════════════════════════

    function test_healthFactor_degradesWithCollateralPriceDrop() public {
        _marketMint(TSLA, MINT_AMOUNT, TSLA_PRICE);

        uint256 healthBefore = vault.healthFactor();

        // ETH price drops 50%
        _setOraclePrice(ETH_ASSET, ETH_PRICE / 2);
        vault.updateCollateralValuation();

        uint256 healthAfter = vault.healthFactor();
        assertLt(healthAfter, healthBefore, "health decreased with collateral price drop");

        // Collateral halved, exposure same → health ~halved
        assertApproxEqAbs(healthAfter, healthBefore / 2, PRECISION, "health roughly halved");
    }
}
