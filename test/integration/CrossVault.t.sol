// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {AssetConfig, OrderStatus} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {EToken} from "../../src/tokens/EToken.sol";

/// @title CrossVault Integration Test
/// @notice Tests VMs from different vaults competing for the same order.
///         TODO: Most test bodies commented out — cross-vault partial fill logic
///         no longer applies with the simplified single-claim model.
contract CrossVaultTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public usdcVault;
    OwnVault public wethVault;
    EToken public eTSLA;
    FeeCalculator public feeCalc;

    uint256 constant MINT_AMOUNT = 10_000e6;

    function setUp() public override {
        super.setUp();
        _deployProtocol();
    }

    function _deployProtocol() private {
        vm.startPrank(Actors.ADMIN);

        assetRegistry = new AssetRegistry(Actors.ADMIN);

        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);

        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));

        AssetConfig memory config =
            AssetConfig({activeToken: address(eTSLA), legacyTokens: new address[](0), active: true, volatilityLevel: 2});
        assetRegistry.addAsset(TSLA, address(eTSLA), config);

        // Deploy factory and create vaults through it
        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        usdcVault = OwnVault(factory.createVault(address(usdc), Actors.VM1, "Own USDC Vault", "oUSDC", 8000, 2000, 900));
        wethVault = OwnVault(factory.createVault(address(weth), Actors.VM2, "Own WETH Vault", "oWETH", 8000, 2000, 900));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        protocolRegistry.setProtocolShareBps(2000);

        usdcVault.setGracePeriod(1 days);
        usdcVault.setClaimThreshold(6 hours);

        vm.stopPrank();

        // Set payment tokens and enable assets
        vm.startPrank(Actors.VM1);
        usdcVault.setPaymentToken(address(usdc));
        usdcVault.enableAsset(TSLA);
        vm.stopPrank();

        vm.startPrank(Actors.VM2);
        wethVault.setPaymentToken(address(usdc));
        wethVault.enableAsset(TSLA);
        vm.stopPrank();

        vm.label(address(usdcVault), "USDCVault");
        vm.label(address(wethVault), "WETHVault");

        // LP1 deposits into USDC vault (via VM1)
        _fundUSDC(Actors.VM1, 500_000e6);
        vm.startPrank(Actors.VM1);
        usdc.approve(address(usdcVault), 500_000e6);
        usdcVault.deposit(500_000e6, Actors.LP1);
        vm.stopPrank();

        // LP2 deposits into WETH vault (via VM2)
        _fundWETH(Actors.VM2, 100e18);
        vm.startPrank(Actors.VM2);
        weth.approve(address(wethVault), 100e18);
        wethVault.deposit(100e18, Actors.LP2);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  Test: VMs registered to different vaults verified
    // ══════════════════════════════════════════════════════════

    function test_crossVault_vaultAttribution() public view {
        assertEq(usdcVault.vm(), Actors.VM1);
        assertEq(wethVault.vm(), Actors.VM2);
    }

    // ══════════════════════════════════════════════════════════
    //  Test: Both vaults maintain independent collateral
    // ══════════════════════════════════════════════════════════

    function test_crossVault_independentCollateral() public view {
        uint256 usdcAssets = usdcVault.totalAssets();
        uint256 wethAssets = wethVault.totalAssets();

        assertGt(usdcAssets, 0, "USDC vault has collateral");
        assertGt(wethAssets, 0, "WETH vault has collateral");
    }

    // TODO: Cross-vault partial fill tests removed — the new model uses
    // single-claim per order. Multi-VM competition no longer applies
    // with the simplified claimOrder(orderId) interface.
}
