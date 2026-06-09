// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";

import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {BorrowManagerFactory} from "../../src/core/BorrowManagerFactory.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {AssetConfig, BPS, OrderStatus, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {EToken} from "../../src/tokens/EToken.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveDebtToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RFQ happy-path verification — aUSDC (6-decimal) collateral, LP deposits, and lending.
/// @notice Drives the real OwnMarket + OwnVault + BorrowManager (mock Aave pool) end to end:
///         (1) market mint, (2) market redeem, (3) limit mint+redeem with partial fills,
///         (4) mint → borrow → repay → redeem, LP deposit/withdraw, and the utilization cap.
contract RFQAusdcFlowsTest is BaseTest {
    AssetRegistry assetRegistry;
    OwnMarket market;
    OwnVault vault;
    EToken eTSLA;
    MockAaveV3Pool aavePool;
    MockAToken ausdcAToken;
    MockAaveDebtToken usdcDebt;
    BorrowManagerFactory bmFactory;
    BorrowManager borrowManager;

    bytes32 constant AUSDC = bytes32("AUSDC");
    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant LP_DEPOSIT = 1_000_000e6; // $1,000,000 aUSDC

    uint256 private _qid = 1;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        // ── Aave mock: aUSDC reserve (6-dec) + USDC debt token + borrow liquidity ──
        aavePool = new MockAaveV3Pool();
        ausdcAToken = MockAToken(aavePool.registerReserve(address(usdc), "Aave USDC", "aUSDC", 6));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));
        usdc.mint(address(aavePool), 1_000_000e6);

        // ── Protocol core ──
        vm.startPrank(Actors.ADMIN);
        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        eTSLA = new EToken("Own TSLA", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        assetRegistry.addAsset(
            TSLA,
            address(eTSLA),
            AssetConfig({
                activeToken: address(eTSLA),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 2,
                oracleType: 1
            })
        );
        assetRegistry.addAsset(
            AUSDC,
            address(ausdcAToken),
            AssetConfig({
                activeToken: address(0),
                legacyTokens: new address[](0),
                active: true,
                volatilityLevel: 1,
                oracleType: 1
            })
        );

        VaultFactory factory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(factory));

        vm.stopPrank();
        // Deploy + register the VaultManager before createVault (which auto-registers the vault).
        _deployVaultManager();
        vm.startPrank(Actors.ADMIN);

        vault = OwnVault(factory.createVault(address(ausdcAToken), vm1Signer, "Own aUSDC", "oaUSDC", AUSDC));

        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        vault.setRequireDepositApproval(true);

        // ── Lending: borrow manager over USDC debt against the vault's aUSDC credit ──
        bmFactory = new BorrowManagerFactory(address(aavePool), address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.BORROW_MANAGER_FACTORY(), address(bmFactory));
        borrowManager = BorrowManager(
            bmFactory.createBorrowManager(address(vault), address(usdc), address(usdcDebt), 3500, _params())
        );
        vault.setBorrowManager(address(borrowManager));
        vault.grantCreditDelegation(address(usdcDebt));
        eTSLA.setPassThroughHolder(address(borrowManager), true);
        vm.stopPrank();

        // ── Global protocol config (now on the VaultManager) ──
        _setClaimThreshold(6 hours);
        _registerSigner(vm1Signer, Actors.VM1);
        _setPaymentToken(address(usdc));

        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);

        _setOraclePrice(TSLA, TSLA_PRICE); // $250
        _setOraclePrice(AUSDC, 1e18); // $1

        // ── LP deposits $1,000,000 aUSDC via the async queue ──
        vm.prank(address(aavePool));
        ausdcAToken.mint(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        ausdcAToken.approve(address(vault), LP_DEPOSIT);
        uint256 reqId = vault.requestDeposit(LP_DEPOSIT, Actors.LP1, 0);
        vm.stopPrank();
        vm.prank(vm1Signer);
        vault.acceptDeposit(reqId);
        _pullCollateralPrice(address(vault));
        _pullAssetPrice(TSLA);

        // Fund the signer's linked settlement address with stablecoins so it can settle redeem
        // payouts (it is also the mint proceeds sink).
        usdc.mint(Actors.VM1, 5_000_000e6);
        vm.prank(Actors.VM1);
        usdc.approve(address(market), type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _quote(
        uint256 orderId,
        address user,
        OrderType ot,
        uint256 amount,
        uint256 price
    ) internal returns (Quote memory q) {
        q = Quote({
            orderId: orderId,
            user: user,
            asset: TSLA,
            orderType: ot,
            amount: amount,
            price: price,
            quoteId: _qid++,
            expiry: block.timestamp + 1 days
        });
    }

    function _marketMint(address user, uint256 usdcAmount) internal returns (uint256 eOut) {
        usdc.mint(user, usdcAmount);
        vm.prank(user);
        usdc.approve(address(market), usdcAmount);
        Quote memory q = _quote(0, user, OrderType.Mint, usdcAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(IOwnMarket(address(market)), q, vm1SignerPk);
        uint256 before = eTSLA.balanceOf(user);
        vm.prank(user);
        market.executeOrder(q, sig);
        eOut = eTSLA.balanceOf(user) - before;
    }

    function _expectedRedeemUSDC(
        uint256 eAmount
    ) internal pure returns (uint256) {
        return Math.mulDiv(eAmount, TSLA_PRICE, PRECISION * 1e12);
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────
    //  Foundation: collateral valuation
    // ──────────────────────────────────────────────────────────

    function test_collateralValue_ausdc_is18DecimalUSD() public view {
        assertEq(vaultManager.collateralMark(address(vault)), 1_000_000e18, "collateral USD value (18-dec)");
    }

    // ──────────────────────────────────────────────────────────
    //  1. Mint via market order
    // ──────────────────────────────────────────────────────────

    function test_1_mint_marketOrder() public {
        uint256 eOut = _marketMint(Actors.MINTER1, 25_000e6); // $25k @ $250 → 100 eTSLA
        assertEq(eOut, 100e18, "eTSLA minted");
        assertEq(usdc.balanceOf(Actors.VM1), 5_000_000e6 + 25_000e6, "stablecoins to linked address");
        assertEq(vaultManager.globalAssetUnits(TSLA), 100e18, "exposure tracked");
    }

    // ──────────────────────────────────────────────────────────
    //  2. Redeem via market order
    // ──────────────────────────────────────────────────────────

    function test_2_redeem_marketOrder() public {
        _marketMint(Actors.MINTER1, 25_000e6); // 100 eTSLA
        uint256 eAmount = 100e18;

        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Redeem, eAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(IOwnMarket(address(market)), q, vm1SignerPk);
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "eTSLA burned");
        assertEq(usdc.balanceOf(Actors.MINTER1), _expectedRedeemUSDC(eAmount), "USDC paid to user");
        assertEq(vaultManager.globalAssetUnits(TSLA), 0, "exposure cleared");
    }

    // ──────────────────────────────────────────────────────────
    //  3. Mint & redeem via limit order (with partial fills)
    // ──────────────────────────────────────────────────────────

    function test_3_limitOrder_mint_then_redeem() public {
        // -- Limit mint: place, fill in two partial chunks --
        uint256 mintUsdc = 25_000e6;
        usdc.mint(Actors.MINTER1, mintUsdc);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), mintUsdc);
        uint256 orderId = market.placeOrder(TSLA, OrderType.Mint, mintUsdc, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        Quote memory f1 = _quote(orderId, Actors.MINTER1, OrderType.Mint, 10_000e6, TSLA_PRICE);
        vm.prank(vm1Signer);
        market.fillOrder(f1, _signQuote(IOwnMarket(address(market)), f1, vm1SignerPk));
        assertEq(uint256(vaultManager.globalAssetUnits(TSLA)), 40e18, "partial mint exposure");

        Quote memory f2 = _quote(orderId, Actors.MINTER1, OrderType.Mint, 15_000e6, TSLA_PRICE);
        vm.prank(vm1Signer);
        market.fillOrder(f2, _signQuote(IOwnMarket(address(market)), f2, vm1SignerPk));

        assertEq(eTSLA.balanceOf(Actors.MINTER1), 100e18, "limit mint filled fully");
        assertEq(uint256(market.getOrder(orderId).status), uint256(OrderStatus.Filled), "order filled");

        // -- Limit redeem: place (escrow eTSLA), VM fills --
        uint256 eAmount = 100e18;
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(market), eAmount);
        uint256 rid = market.placeOrder(TSLA, OrderType.Redeem, eAmount, TSLA_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(eTSLA.balanceOf(address(market)), eAmount, "eTSLA escrowed");

        Quote memory rq = _quote(rid, Actors.MINTER1, OrderType.Redeem, eAmount, TSLA_PRICE);
        vm.prank(vm1Signer);
        market.fillOrder(rq, _signQuote(IOwnMarket(address(market)), rq, vm1SignerPk));

        assertEq(usdc.balanceOf(Actors.MINTER1), _expectedRedeemUSDC(eAmount), "limit redeem payout");
        assertEq(vaultManager.globalAssetUnits(TSLA), 0, "exposure cleared");
    }

    // ──────────────────────────────────────────────────────────
    //  4. Mint → borrow → repay → redeem
    // ──────────────────────────────────────────────────────────

    function test_4_mint_borrow_repay_redeem() public {
        // Mint 100 eTSLA ($25k collateral value).
        _marketMint(Actors.MINTER1, 25_000e6);
        uint256 eAmount = 100e18;

        // Borrow $10k USDC against the eTSLA (40% position LTV).
        uint256 borrowAmt = 10_000e6;
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmount);
        borrowManager.borrow(TSLA, eAmount, borrowAmt, _priceData(TSLA_PRICE));
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.MINTER1), borrowAmt, "borrowed USDC received");
        assertEq(eTSLA.balanceOf(address(borrowManager)), eAmount, "eTSLA held as collateral");
        assertEq(aavePool.debtOf(address(vault), address(usdc)), borrowAmt, "vault Aave debt opened");

        // Time passes → interest accrues; repay in full and recover collateral.
        skip(30 days);
        uint256 debt = borrowManager.debtOf(Actors.MINTER1, TSLA);
        assertGe(debt, borrowAmt, "debt accrued");
        usdc.mint(Actors.MINTER1, debt); // top up for interest
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), type(uint256).max);
        borrowManager.repay(TSLA, type(uint256).max);
        vm.stopPrank();

        assertEq(eTSLA.balanceOf(Actors.MINTER1), eAmount, "collateral returned");
        assertEq(aavePool.debtOf(address(vault), address(usdc)), 0, "Aave debt cleared");

        // Redeem the eTSLA back to USDC via market order.
        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Redeem, eAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(IOwnMarket(address(market)), q, vm1SignerPk);
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        assertEq(eTSLA.balanceOf(Actors.MINTER1), 0, "eTSLA redeemed");
        assertGe(usdc.balanceOf(Actors.MINTER1), _expectedRedeemUSDC(eAmount), "redeem payout received");
    }

    // ──────────────────────────────────────────────────────────
    //  5. LP paths: deposit (in setUp) + withdraw
    // ──────────────────────────────────────────────────────────

    function test_5_lp_deposit_and_withdraw() public {
        uint256 shares = vault.balanceOf(Actors.LP1);
        assertGt(shares, 0, "LP received shares on deposit");
        assertEq(vaultManager.collateralMark(address(vault)), 1_000_000e18, "collateral valued");

        // Withdraw half via the async queue (no exposure → utilization stays at 0).
        uint256 half = shares / 2;
        vm.prank(Actors.LP1);
        uint256 wid = vault.requestWithdrawal(half);
        uint256 assets = vault.fulfillWithdrawal(wid);

        assertGt(assets, 0, "withdrawal fulfilled");
        assertEq(ausdcAToken.balanceOf(Actors.LP1), assets, "aUSDC returned to LP");
        assertEq(vault.balanceOf(Actors.LP1), shares - half, "shares burned");
    }

    // ──────────────────────────────────────────────────────────
    //  6. Utilization cap: mint above the threshold reverts
    // ──────────────────────────────────────────────────────────

    function test_6_mint_aboveUtilization_reverts() public {
        // $900k exposure vs $1M collateral = 90% > 80% cap.
        uint256 amount = 900_000e6;
        usdc.mint(Actors.MINTER1, amount);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        Quote memory q = _quote(0, Actors.MINTER1, OrderType.Mint, amount, TSLA_PRICE);
        bytes memory sig = _signQuote(IOwnMarket(address(market)), q, vm1SignerPk);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IVaultManager.GlobalUtilizationBreached.selector, 9000, MAX_UTIL_BPS));
        market.executeOrder(q, sig);
    }
}
