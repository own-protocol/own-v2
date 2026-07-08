// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {ReserveVault} from "../../src/core/ReserveVault.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {PsmHandler} from "./handlers/PsmHandler.sol";

/// @title PsmInvariant — one-set-of-books + netting invariants across PSM and RFQ channels
/// @notice Full real-contract stack (market, manager, eToken, generic vault, reserve vault).
///         The handler interleaves psmMint/psmRedeem/reserve deposits with RFQ mints/redeems and
///         drifting asset + wrapper prices; the invariants pin the accounting identities.
contract PsmInvariantTest is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault;
    EToken public eTSLA;
    MockERC20 public ondo;
    ReserveVault public reserve;
    PsmHandler public handler;

    bytes32 public constant ONDO_TSLA = bytes32("ONDO.TSLA");
    bytes32 public constant ETH_ASSET = bytes32("ETH");
    uint256 constant LP_SEED_WETH = 100_000e18;

    function setUp() public override {
        super.setUp();

        vm.startPrank(Actors.ADMIN);
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        _deployVaultManager();

        vm.startPrank(Actors.ADMIN);
        vault = new OwnVault(address(weth), "Own ETH Vault", "oETH", address(protocolRegistry), vm1Signer);
        vaultManager.registerVault(address(vault), ETH_ASSET);

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        assetRegistry.addAsset(TSLA, address(eTSLA), _cfg(address(eTSLA)));
        assetRegistry.addAsset(ETH_ASSET, address(weth), _cfg(address(weth)));

        ondo = new MockERC20("Ondo Tesla", "ondoTSLA", 18);
        assetRegistry.addAsset(ONDO_TSLA, address(ondo), _cfg(address(ondo)));
        reserve = new ReserveVault(address(ondo), address(protocolRegistry));
        vaultManager.registerVault(address(reserve), ONDO_TSLA, TSLA);
        assetRegistry.setPsmConfig(TSLA, address(ondo), address(reserve));
        // Fail-closed guard: arm wide (100%) so the campaign explores freely; big price-drift
        // jumps beyond the bound revert inside the handler's try/catch.
        assetRegistry.setRatioJumpBoundBps(10_000);
        vm.stopPrank();

        _registerSigner(vm1Signer, Actors.VM1);
        _setPaymentToken(address(usdc));
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);
        _setOraclePrice(TSLA, TSLA_PRICE);
        _setOraclePrice(ONDO_TSLA, TSLA_PRICE);
        _setOraclePrice(ETH_ASSET, ETH_PRICE);

        _fundWETH(vm1Signer, LP_SEED_WETH);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_SEED_WETH);
        vault.deposit(LP_SEED_WETH, Actors.LP1);
        vm.stopPrank();
        _pullCollateralPrice(address(vault));
        _pullAssetPrice(TSLA);

        handler = new PsmHandler(
            address(market),
            address(vaultManager),
            address(eTSLA),
            address(usdc),
            address(ondo),
            address(reserve),
            address(oracle),
            vm1SignerPk
        );
        targetContract(address(handler));
    }

    function _cfg(
        address token
    ) private pure returns (AssetConfig memory) {
        return AssetConfig({
            activeToken: token,
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
    }

    /// @notice INV-P1: one set of books — eTSLA supply equals global units across BOTH channels
    ///         (RFQ settle and PSM mint/redeem all route through open/closeExposure).
    function invariant_supplyMatchesUnits() external view {
        assertEq(eTSLA.totalSupply(), vaultManager.globalAssetUnits(TSLA), "supply != units");
    }

    /// @notice INV-P2: the net-exposure running total equals the recomputed netted sum.
    function invariant_netExposureIdentity() external view {
        uint256 e = vaultManager.assetExposureUSD(TSLA);
        uint256 r = vaultManager.assetRwaCollateralUSD(TSLA);
        assertEq(vaultManager.globalNetExposureUSD(), e > r ? e - r : 0, "netting identity diverged");
    }

    /// @notice INV-P3: the generic pool counts only the generic vault; the reserve mark matches
    ///         the RWA running total.
    function invariant_collateralSegregation() external view {
        assertEq(vaultManager.globalCollateralUSD(), vaultManager.collateralMark(address(vault)));
        assertEq(vaultManager.assetRwaCollateralUSD(TSLA), vaultManager.collateralMark(address(reserve)));
    }

    /// @notice INV-P4: reserve custody solvency — the vault's wrapper balance never goes negative
    ///         relative to what releases demand (releases are balance-bounded by construction),
    ///         and the mark never exceeds the value of what is actually held at the last-pulled
    ///         price (mark is set from balance × price at every sync point).
    function invariant_reserveBalanceBacksMark() external view {
        (uint256 price,) = oracle.getPrice(ONDO_TSLA);
        uint256 valueAtCurrentPrice = (reserve.totalAssets() * price) / 1e18;
        // The mark can lag the CURRENT price (keeper model) but never exceeds the value at the
        // price it was last synced with; with prices bounded in [200, 300] the mark can never
        // exceed 1.5× the current-price value.
        assertLe(vaultManager.collateralMark(address(reserve)), (valueAtCurrentPrice * 3) / 2 + 1);
    }
}
