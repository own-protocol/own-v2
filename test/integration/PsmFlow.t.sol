// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {IReserveVault} from "../../src/interfaces/IReserveVault.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {AssetConfig, BPS, OrderType, PRECISION, Quote} from "../../src/interfaces/types/Types.sol";

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {ReserveVault} from "../../src/core/ReserveVault.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PsmFlowBase — shared PSM integration stack (real contracts)
/// @notice Deploys market, manager, eTSLA, a generic WETH buffer vault, two wrappers (18-dec
///         ondo, 6-dec xs) with their ReserveVaults, and PSM config. The ratio-jump guard is
///         armed via the virtual {_armRatioGuard} hook so the fail-closed suite can leave it
///         unconfigured.
abstract contract PsmFlowBase is BaseTest {
    AssetRegistry public assetRegistry;
    OwnMarket public market;
    OwnVault public vault; // generic WETH vault (the crypto buffer)
    EToken public eTSLA;

    MockERC20 public ondo; // 18-dec wrapper
    MockERC20 public xs; // 6-dec wrapper (decimal-scaling coverage)
    ReserveVault public ondoReserve;
    ReserveVault public xsReserve;

    bytes32 public constant ONDO_TSLA = bytes32("ONDO.TSLA");
    bytes32 public constant XS_TSLA = bytes32("XS.TSLA");
    bytes32 public constant ETH_ASSET = bytes32("ETH");

    uint256 constant LP_SEED_WETH = 50_000e18;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

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

        // eTSLA + asset configs
        eTSLA = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        assetRegistry.addAsset(TSLA, address(eTSLA), _assetConfig(address(eTSLA)));
        assetRegistry.addAsset(ETH_ASSET, address(weth), _assetConfig(address(weth)));

        // Wrappers + reserve vaults (RWA class, backing TSLA). Wrapper tickers are registered
        // like any collateral ticker so getOracleType resolves their feeds (ETH precedent).
        ondo = new MockERC20("Ondo Tesla", "ondoTSLA", 18);
        xs = new MockERC20("xStocks Tesla", "xsTSLA", 6);
        assetRegistry.addAsset(ONDO_TSLA, address(ondo), _assetConfig(address(ondo)));
        assetRegistry.addAsset(XS_TSLA, address(xs), _assetConfig(address(xs)));
        ondoReserve = new ReserveVault(address(ondo), address(protocolRegistry), Actors.VM1);
        xsReserve = new ReserveVault(address(xs), address(protocolRegistry), Actors.VM1);
        vaultManager.registerVault(address(ondoReserve), ONDO_TSLA, TSLA);
        vaultManager.registerVault(address(xsReserve), XS_TSLA, TSLA);
        assetRegistry.setPsmConfig(TSLA, address(ondo), address(ondoReserve));
        assetRegistry.setPsmConfig(TSLA, address(xs), address(xsReserve));
        vm.stopPrank();

        _setClaimThreshold(CLAIM_THRESHOLD);
        _registerSigner(vm1Signer, Actors.VM1);
        // Scope the maker to its quoted assets (default-deny since Phase 4b).
        vm.prank(Actors.ADMIN);
        assetRegistry.setMakerAllowed(TSLA, vm1Signer, true);
        _setPaymentToken(address(usdc));
        _setAssetCap(TSLA, DEFAULT_ASSET_CAP_USD);

        // Wrapper token feeds: token price = share price × sValue (= 1 at launch).
        _setOraclePrice(ONDO_TSLA, TSLA_PRICE);
        _setOraclePrice(XS_TSLA, TSLA_PRICE);
        _setOraclePrice(ETH_ASSET, ETH_PRICE);
        _setOraclePrice(TSLA, TSLA_PRICE);

        // Seed the generic buffer + marks.
        _fundWETH(vm1Signer, LP_SEED_WETH);
        vm.startPrank(vm1Signer);
        weth.approve(address(vault), LP_SEED_WETH);
        vault.deposit(LP_SEED_WETH, Actors.LP1);
        vm.stopPrank();
        _pullCollateralPrice(address(vault));
        _pullAssetPrice(TSLA);

        _armRatioGuard();
    }

    /// @dev The ratio-jump guard is fail-closed; arm it wide (100%) so non-guard tests run
    ///      unimpeded. Guard-specific tests tighten it; PsmFlowUnarmedTest overrides to no-op.
    function _armRatioGuard() internal virtual {
        vm.prank(Actors.ADMIN);
        assetRegistry.setRatioJumpBoundBps(BPS);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _assetConfig(
        address token
    ) internal pure returns (AssetConfig memory) {
        return AssetConfig({
            activeToken: token,
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
    }

    function _psmMintOndo(address user, uint256 amount) internal returns (uint256 out) {
        ondo.mint(user, amount);
        vm.startPrank(user);
        ondo.approve(address(market), amount);
        out = market.psmMint(TSLA, address(ondo), amount);
        vm.stopPrank();
    }

    /// @dev Mint eTSLA via the RFQ channel (buffer-backed) with a signed market quote.
    function _rfqMint(address minter, uint256 usdcAmount) internal {
        _fundUSDC(minter, usdcAmount);
        vm.prank(minter);
        usdc.approve(address(market), usdcAmount);
        Quote memory q = _buildQuote(0, minter, TSLA, OrderType.Mint, usdcAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(minter);
        market.executeOrder(q, sig);
    }

    /// @dev Redeem eTSLA via the RFQ channel; the maker (VM1) funds the USDC payout.
    function _rfqRedeem(address minter, uint256 eAmount) internal {
        uint256 payout = Math.mulDiv(eAmount, TSLA_PRICE, PRECISION * 1e12);
        _fundUSDC(Actors.VM1, payout);
        vm.prank(Actors.VM1);
        usdc.approve(address(market), payout);
        Quote memory q = _buildQuote(0, minter, TSLA, OrderType.Redeem, eAmount, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(minter);
        market.executeOrder(q, sig);
    }
}

/// @title PsmFlow Integration Tests
/// @notice End-to-end PSM behavior with real contracts: mint/redeem/backfill happy paths, the
///         derived conversion ratio (sValue drift, eToken splits, halt pricing), the ratio-jump
///         guard, netting effects (util-neutral matched mints, backfill freeing the buffer),
///         cross-channel consistency with the RFQ paths, and the surplus exits.
contract PsmFlowTest is PsmFlowBase {
    // ──────────────────────────────────────────────────────────
    //  psmMint
    // ──────────────────────────────────────────────────────────

    function test_psmMint_happyPath_oneToOne() public {
        uint256 utilBefore = vaultManager.globalUtilizationBps();

        ondo.mint(Actors.MINTER1, 10e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 10e18);
        vm.expectEmit(true, true, true, true);
        emit IOwnMarket.PsmMinted(Actors.MINTER1, TSLA, address(ondo), 10e18, 10e18, 1e18);
        uint256 out = market.psmMint(TSLA, address(ondo), 10e18);
        vm.stopPrank();

        assertEq(out, 10e18, "1:1 at sValue 1");
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 10e18);
        assertEq(ondo.balanceOf(address(ondoReserve)), 10e18, "reserve holds the wrapper");

        // One set of books: supply == units; matched mint fully netted and util-neutral.
        assertEq(eTSLA.totalSupply(), vaultManager.globalAssetUnits(TSLA));
        assertEq(vaultManager.assetRwaCollateralUSD(TSLA), Math.mulDiv(10e18, TSLA_PRICE, PRECISION));
        assertEq(vaultManager.globalNetExposureUSD(), 0, "fully reserve-covered");
        assertEq(vaultManager.globalUtilizationBps(), utilBefore, "util-neutral");
    }

    function test_psmMint_sValueDrift_mintsMoreETokens() public {
        // Dividend reinvestment: wrapper token price drifts to 1.05× the share price.
        _setOraclePrice(ONDO_TSLA, (TSLA_PRICE * 105) / 100);

        uint256 out = _psmMintOndo(Actors.MINTER1, 10e18);
        assertEq(out, 10.5e18, "1 wrapper = 1.05 shares");
        assertEq(eTSLA.totalSupply(), vaultManager.globalAssetUnits(TSLA));
        assertEq(vaultManager.globalNetExposureUSD(), 0, "still fully covered at drifted price");
    }

    function test_psmMint_sixDecimalWrapper_scales() public {
        xs.mint(Actors.MINTER1, 10e6);
        vm.startPrank(Actors.MINTER1);
        xs.approve(address(market), 10e6);
        uint256 out = market.psmMint(TSLA, address(xs), 10e6);
        vm.stopPrank();

        assertEq(out, 10e18, "6-dec wrapper scales to 18-dec eTokens");
        assertEq(vaultManager.assetRwaCollateralUSD(TSLA), Math.mulDiv(10e18, TSLA_PRICE, PRECISION));
    }

    function test_psmMint_unconfiguredWrapper_reverts() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        rogue.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        rogue.approve(address(market), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.PsmNotConfigured.selector, TSLA, address(rogue)));
        market.psmMint(TSLA, address(rogue), 1e18);
        vm.stopPrank();
    }

    function test_psmMint_psmPaused_reverts() public {
        vm.prank(Actors.ADMIN);
        assetRegistry.setPsmPaused(TSLA, address(ondo), true);

        ondo.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.PsmIsPaused.selector, TSLA, address(ondo)));
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();
    }

    function test_psmMint_tradingPaused_reverts() public {
        vm.prank(Actors.ADMIN);
        vaultManager.setAssetTradingPaused(TSLA, true);

        ondo.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();
    }

    function test_psmMint_halted_reverts() public {
        _haltAsset(TSLA, TSLA_PRICE);

        ondo.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.MintBlockedDuringHalt.selector, TSLA));
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();
    }

    function test_psmMint_inactiveAsset_reverts() public {
        vm.prank(Actors.ADMIN);
        assetRegistry.setAssetActive(TSLA, false);

        ondo.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetNotActive.selector, TSLA));
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();
    }

    function test_psmMint_staleWrapperPrice_reverts() public {
        // Wrapper price goes stale while the asset mark stays keeper-fresh.
        vm.warp(block.timestamp + DEFAULT_MAX_MARK_AGE + 1);
        _setOraclePrice(TSLA, TSLA_PRICE);
        _pullAssetPrice(TSLA);

        ondo.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.StaleWrapperPrice.selector, ONDO_TSLA));
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();
    }

    function test_psmMint_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.psmMint(TSLA, address(ondo), 0);
    }

    function test_psmRedeem_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.psmRedeem(TSLA, address(ondo), 0);
    }

    function test_psmMint_wrapperPriceUnavailable_reverts() public {
        // Feed normalises to exactly zero (Pyth exponent truncation) — fail closed.
        oracle.setForceZeroPrice(true);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.WrapperPriceUnavailable.selector, ONDO_TSLA));
        market.psmMint(TSLA, address(ondo), 1e18);
    }

    function test_psmMint_assetMarkUnavailable_reverts() public {
        // A configured PSM whose asset mark was never keeper-pulled fails closed.
        bytes32 aapl = bytes32("AAPL");
        bytes32 wAaplTicker = bytes32("W.AAPL");
        vm.startPrank(Actors.ADMIN);
        EToken eAAPL = new EToken("Own Apple", "eAAPL", aapl, address(protocolRegistry), address(usdc));
        MockERC20 wAapl = new MockERC20("Wrapped Apple", "wAAPL", 18);
        assetRegistry.addAsset(aapl, address(eAAPL), _assetConfig(address(eAAPL)));
        assetRegistry.addAsset(wAaplTicker, address(wAapl), _assetConfig(address(wAapl)));
        ReserveVault aaplReserve = new ReserveVault(address(wAapl), address(protocolRegistry), Actors.VM1);
        vaultManager.registerVault(address(aaplReserve), wAaplTicker, aapl);
        assetRegistry.setPsmConfig(aapl, address(wAapl), address(aaplReserve));
        vm.stopPrank();
        _setOraclePrice(wAaplTicker, TSLA_PRICE); // wrapper leg fresh; asset mark never pulled

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetMarkUnavailable.selector, aapl));
        market.psmMint(aapl, address(wAapl), 1e18);
    }

    function test_psmMint_ratioFloorsToZero_reverts() public {
        // wrapperPrice « mark floors the derived ratio to 0 — fail closed, never a free mint.
        _setOraclePrice(ONDO_TSLA, 1); // 1e-18 USD vs the $250 mark → ratio 0
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.InvalidPrice.selector);
        market.psmMint(TSLA, address(ondo), 1e18);
    }

    function test_psmMint_dustFloorsToZero_reverts() public {
        // 1 unit of the 6-dec wrapper at a collapsed ratio yields 0 eTokens — the floor rejects it.
        _setOraclePrice(XS_TSLA, 1e7); // ratio = 4e4 (4e-14); 1 xs unit → 0.04 wei eToken → 0
        xs.mint(Actors.MINTER1, 1);
        vm.startPrank(Actors.MINTER1);
        xs.approve(address(market), 1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.psmMint(TSLA, address(xs), 1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Ratio-jump guard
    // ──────────────────────────────────────────────────────────

    function test_ratioJumpGuard_tripsAndResets() public {
        vm.prank(Actors.ADMIN);
        assetRegistry.setRatioJumpBoundBps(200); // 2%

        _psmMintOndo(Actors.MINTER1, 1e18); // arms the guard at ratio 1e18

        // Wrapper feed jumps 5% (e.g. missed corporate-action pause window).
        _setOraclePrice(ONDO_TSLA, (TSLA_PRICE * 105) / 100);
        ondo.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnMarket.RatioJumpExceeded.selector, TSLA, address(ondo), 1.05e18, 1e18)
        );
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();

        // Operator acknowledges; the next operation re-arms at the new ratio.
        vm.prank(Actors.ADMIN);
        assetRegistry.resetRatioGuard(TSLA, address(ondo));
        uint256 out = _psmMintOndo(Actors.MINTER1, 1e18);
        assertEq(out, 1.05e18);
    }

    function test_ratioJumpGuard_smallDriftPasses() public {
        vm.prank(Actors.ADMIN);
        assetRegistry.setRatioJumpBoundBps(200); // 2%

        _psmMintOndo(Actors.MINTER1, 1e18);
        _setOraclePrice(ONDO_TSLA, (TSLA_PRICE * 101) / 100); // 1% drift — within bound
        uint256 out = _psmMintOndo(Actors.MINTER1, 1e18);
        assertEq(out, 1.01e18);
    }

    // ──────────────────────────────────────────────────────────
    //  psmRedeem
    // ──────────────────────────────────────────────────────────

    function test_psmRedeem_happyPath() public {
        _psmMintOndo(Actors.MINTER1, 10e18);

        vm.expectEmit(true, true, true, true);
        emit IOwnMarket.PsmRedeemed(Actors.MINTER1, TSLA, address(ondo), 4e18, 4e18, 1e18);
        vm.prank(Actors.MINTER1);
        uint256 out = market.psmRedeem(TSLA, address(ondo), 4e18);

        assertEq(out, 4e18);
        assertEq(ondo.balanceOf(Actors.MINTER1), 4e18);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), 6e18);
        assertEq(ondo.balanceOf(address(ondoReserve)), 6e18);
        assertEq(eTSLA.totalSupply(), vaultManager.globalAssetUnits(TSLA), "books stay matched");
        assertEq(vaultManager.globalNetExposureUSD(), 0);
    }

    function test_psmRedeem_exceedsReserve_reverts() public {
        // eTSLA minted via RFQ (buffer-backed) — the ondo reserve holds only 2.
        _rfqMint(Actors.MINTER1, 10_000e6);
        _psmMintOndo(Actors.MINTER1, 2e18);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IReserveVault.AmountExceedsReserve.selector);
        market.psmRedeem(TSLA, address(ondo), 10e18);
    }

    function test_psmRedeem_offHours_worksWithFrozenPrices() public {
        _psmMintOndo(Actors.MINTER1, 10e18);

        // Both feeds freeze well past the freshness bound (weekend/holiday): the PAIR still
        // yields the correct ratio, so in-kind redemption keeps working while minting is blocked.
        vm.warp(block.timestamp + DEFAULT_MAX_MARK_AGE + 1 days);

        vm.prank(Actors.MINTER1);
        uint256 out = market.psmRedeem(TSLA, address(ondo), 5e18);
        assertEq(out, 5e18, "off-hours redeem at frozen-pair ratio");
    }

    function test_psmRedeem_halted_settlesAtHaltPrice() public {
        _psmMintOndo(Actors.MINTER1, 10e18);

        // Halt at 2× the market price. ratio = wrapperPrice/haltMark = 0.5 → 1 eTSLA = 2 ondo,
        // i.e. exactly haltPrice-worth of wrapper at its live price.
        _haltAsset(TSLA, 2 * TSLA_PRICE);
        _setOraclePrice(ONDO_TSLA, TSLA_PRICE); // live + fresh wrapper leg

        vm.prank(Actors.MINTER1);
        uint256 out = market.psmRedeem(TSLA, address(ondo), 2e18);
        assertEq(out, 4e18, "2 eTSLA x $500 halt = $2000 = 4 ondo @ $250");
        assertEq(eTSLA.totalSupply(), vaultManager.globalAssetUnits(TSLA));
    }

    function test_psmRedeem_halted_staleWrapper_reverts() public {
        _psmMintOndo(Actors.MINTER1, 10e18);
        _haltAsset(TSLA, TSLA_PRICE);

        // Halted redeems price the payout off the LIVE wrapper leg — stale is not acceptable.
        vm.warp(block.timestamp + DEFAULT_MAX_MARK_AGE + 1);
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.StaleWrapperPrice.selector, ONDO_TSLA));
        market.psmRedeem(TSLA, address(ondo), 1e18);
    }

    function test_psmRedeem_tradingPaused_reverts() public {
        _psmMintOndo(Actors.MINTER1, 10e18);
        vm.prank(Actors.ADMIN);
        vaultManager.setAssetTradingPaused(TSLA, true);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetPaused.selector, TSLA));
        market.psmRedeem(TSLA, address(ondo), 1e18);
    }

    function test_psmRedeem_dustRoundsToZero_reverts() public {
        // 1 wei of eTSLA converts to < 1 unit of the 6-dec wrapper → floor → zero out.
        xs.mint(Actors.MINTER1, 10e6);
        vm.startPrank(Actors.MINTER1);
        xs.approve(address(market), 10e6);
        market.psmMint(TSLA, address(xs), 10e6);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.psmRedeem(TSLA, address(xs), 1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Reserve deposit (backfill) + cross-channel flows
    // ──────────────────────────────────────────────────────────

    function test_reserveDeposit_freesTheBuffer() public {
        // Buyer mints via RFQ: exposure opens against the generic buffer.
        _rfqMint(Actors.MINTER1, 10_000e6); // $10k → 40 eTSLA @ $250
        uint256 netBefore = vaultManager.globalNetExposureUSD();
        assertEq(netBefore, 10_000e18, "buffer carries the un-backfilled exposure");

        // The maker delivers the hedge: 40 ondo into the reserve, no mint.
        ondo.mint(Actors.VM1, 40e18);
        vm.startPrank(Actors.VM1);
        ondo.approve(address(ondoReserve), 40e18);
        vm.expectEmit(true, false, false, true);
        emit IReserveVault.ReserveDeposited(Actors.VM1, 40e18);
        ondoReserve.deposit(40e18);
        vm.stopPrank();

        assertEq(vaultManager.globalNetExposureUSD(), 0, "reserve nets the exposure; buffer freed");
        assertEq(eTSLA.totalSupply(), vaultManager.globalAssetUnits(TSLA));

        // The buyer can now exit in-kind straight from the reserve.
        vm.prank(Actors.MINTER1);
        uint256 out = market.psmRedeem(TSLA, address(ondo), 40e18);
        assertEq(out, 40e18);
        assertEq(vaultManager.globalAssetUnits(TSLA), 0);
    }

    function test_crossChannel_psmMint_rfqRedeem_leavesSkimmableSurplus() public {
        _psmMintOndo(Actors.MINTER1, 10e18); // E = R = $2500

        // Holder exits via RFQ instead: supply and E shrink, the reserve stays — pure surplus.
        _rfqRedeem(Actors.MINTER1, 10e18);
        assertEq(eTSLA.totalSupply(), 0);
        assertEq(vaultManager.globalAssetUnits(TSLA), 0);
        assertEq(vaultManager.assetRwaCollateralUSD(TSLA), Math.mulDiv(10e18, TSLA_PRICE, PRECISION));
        assertEq(vaultManager.globalNetExposureUSD(), 0, "excess reserve clamps at zero");

        // The operator can skim the surplus (paid to the caller)...
        vm.prank(Actors.ADMIN);
        ondoReserve.skimExcess(10e18);
        assertEq(ondo.balanceOf(Actors.ADMIN), 10e18);
        assertEq(vaultManager.assetRwaCollateralUSD(TSLA), 0);
    }

    function test_makerRecovery_rfqRedeem_thenWithdraw() public {
        // Fully matched book: buyer holds 10 eTSLA backed by 10 ondo in reserve.
        _psmMintOndo(Actors.MINTER1, 10e18);

        // Buyer exits via RFQ: the maker (VM1) pays USDC, supply burns, reserve stays → surplus.
        _rfqRedeem(Actors.MINTER1, 4e18);
        assertEq(vaultManager.assetExposureUSD(TSLA), Math.mulDiv(6e18, TSLA_PRICE, PRECISION));

        // One-step maker recovery: the SIGNER calls, the LINKED address (VM1) receives.
        vm.expectEmit(true, true, false, true);
        emit IReserveVault.SurplusWithdrawn(vm1Signer, Actors.VM1, 4e18);
        vm.prank(vm1Signer);
        ondoReserve.withdraw(4e18);
        assertEq(ondo.balanceOf(Actors.VM1), 4e18, "maker recovers its hedge in one tx");

        // Book is exactly matched again; matched backing was untouchable throughout.
        assertEq(ondo.balanceOf(address(ondoReserve)), 6e18);
        assertEq(vaultManager.globalNetExposureUSD(), 0);
        vm.prank(vm1Signer);
        vm.expectRevert(IReserveVault.SkimExceedsSurplus.selector);
        ondoReserve.withdraw(1);
    }

    function test_makerRecovery_worksOffHours() public {
        _psmMintOndo(Actors.MINTER1, 10e18);
        _rfqRedeem(Actors.MINTER1, 4e18);

        // Nothing is minted on withdrawal, so no freshness gate: recovery works while both
        // feeds are frozen past maxMarkAge (weekend), when the old mint+redeem loop could not.
        vm.warp(block.timestamp + DEFAULT_MAX_MARK_AGE + 1 days);
        vm.prank(vm1Signer);
        ondoReserve.withdraw(4e18);
        assertEq(ondo.balanceOf(Actors.VM1), 4e18);
    }

    function test_skimExcess_cannotCutIntoMatchedBacking() public {
        _psmMintOndo(Actors.MINTER1, 10e18); // E = R: zero surplus

        vm.prank(Actors.ADMIN);
        vm.expectRevert(IReserveVault.SkimExceedsSurplus.selector);
        ondoReserve.skimExcess(1e18);

        // Partial RFQ exit creates exactly 4 ondo of surplus; skimming 5 must still fail.
        _rfqRedeem(Actors.MINTER1, 4e18);
        vm.prank(Actors.ADMIN);
        vm.expectRevert(IReserveVault.SkimExceedsSurplus.selector);
        ondoReserve.skimExcess(5e18);

        // Skimming within the surplus succeeds (paid to the caller).
        vm.prank(Actors.ADMIN);
        ondoReserve.skimExcess(4e18);
        assertEq(ondo.balanceOf(Actors.ADMIN), 4e18);
    }

    // ──────────────────────────────────────────────────────────
    //  eToken split — derived ratio auto-rescales
    // ──────────────────────────────────────────────────────────

    function test_split_ratioAutoRescales_afterGuardAck() public {
        vm.prank(Actors.ADMIN);
        assetRegistry.setRatioJumpBoundBps(200);
        _psmMintOndo(Actors.MINTER1, 10e18); // arms guard at 1e18

        // 2:1 TSLA split: eToken migrates (units ×2, mark ÷2); the wrapper is split-invariant.
        vm.startPrank(Actors.ADMIN);
        EToken eTSLA2 = new EToken("Own Tesla", "eTSLA", TSLA, address(protocolRegistry), address(usdc));
        assetRegistry.migrateToken(TSLA, address(eTSLA2), 2e18);
        vm.stopPrank();

        // Post-split share price halves; wrapper token price is continuous.
        _setOraclePrice(TSLA, TSLA_PRICE / 2);
        _pullAssetPrice(TSLA);

        // The derived ratio doubled (2 eTSLA per ondo) — the guard trips until acknowledged.
        ondo.mint(Actors.MINTER2, 1e18);
        vm.startPrank(Actors.MINTER2);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.RatioJumpExceeded.selector, TSLA, address(ondo), 2e18, 1e18));
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();

        vm.prank(Actors.ADMIN);
        assetRegistry.resetRatioGuard(TSLA, address(ondo));

        // No AssetRegistry ratio state was touched by the split — the rescale is automatic.
        ondo.mint(Actors.MINTER2, 1e18);
        vm.startPrank(Actors.MINTER2);
        ondo.approve(address(market), 2e18);
        uint256 out = market.psmMint(TSLA, address(ondo), 2e18);
        vm.stopPrank();
        assertEq(out, 4e18, "1 ondo = 2 post-split eTSLA");
        assertEq(EToken(eTSLA2).balanceOf(Actors.MINTER2), 4e18, "mints the ACTIVE token");
    }

    // ──────────────────────────────────────────────────────────
    //  Multi-wrapper netting
    // ──────────────────────────────────────────────────────────

    function test_multiWrapper_bothReservesNetAgainstTsla() public {
        _psmMintOndo(Actors.MINTER1, 10e18);
        xs.mint(Actors.MINTER1, 5e6);
        vm.startPrank(Actors.MINTER1);
        xs.approve(address(market), 5e6);
        market.psmMint(TSLA, address(xs), 5e6);
        vm.stopPrank();

        assertEq(eTSLA.totalSupply(), 15e18);
        assertEq(vaultManager.assetRwaCollateralUSD(TSLA), Math.mulDiv(15e18, TSLA_PRICE, PRECISION));
        assertEq(vaultManager.globalNetExposureUSD(), 0);

        // Redeeming from either reserve keeps the books matched.
        vm.startPrank(Actors.MINTER1);
        market.psmRedeem(TSLA, address(xs), 3e18);
        market.psmRedeem(TSLA, address(ondo), 3e18);
        vm.stopPrank();
        assertEq(eTSLA.totalSupply(), 9e18);
        assertEq(eTSLA.totalSupply(), vaultManager.globalAssetUnits(TSLA));
        assertEq(vaultManager.globalNetExposureUSD(), 0);
    }
}

/// @title PsmFlowUnarmedTest — fail-closed behavior with the ratio-jump guard unconfigured
/// @notice Same stack as PsmFlowTest but the pre-deploy default (`ratioJumpBoundBps == 0`) is
///         left in place: PSM mint/redeem must be inert; backfill (no ratio) must still work.
contract PsmFlowUnarmedTest is PsmFlowBase {
    function _armRatioGuard() internal override {
        // Deliberately left unconfigured.
    }

    function test_unarmedGuard_psmMint_reverts() public {
        ondo.mint(Actors.MINTER1, 1e18);
        vm.startPrank(Actors.MINTER1);
        ondo.approve(address(market), 1e18);
        vm.expectRevert(IOwnMarket.RatioGuardNotConfigured.selector);
        market.psmMint(TSLA, address(ondo), 1e18);
        vm.stopPrank();
    }

    function test_unarmedGuard_psmRedeem_reverts() public {
        // eTSLA via the RFQ channel (unaffected by the guard); the PSM exit is still inert.
        _fundUSDC(Actors.MINTER1, 1000e6);
        vm.prank(Actors.MINTER1);
        usdc.approve(address(market), 1000e6);
        Quote memory q = _buildQuote(0, Actors.MINTER1, TSLA, OrderType.Mint, 1000e6, TSLA_PRICE);
        bytes memory sig = _signQuote(market, q, vm1SignerPk);
        vm.prank(Actors.MINTER1);
        market.executeOrder(q, sig);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.RatioGuardNotConfigured.selector);
        market.psmRedeem(TSLA, address(ondo), 1e18);
    }

    function test_unarmedGuard_reserveDeposit_stillWorks() public {
        // Hedge delivery involves no conversion ratio; adding backing is never blocked.
        ondo.mint(Actors.VM1, 5e18);
        vm.startPrank(Actors.VM1);
        ondo.approve(address(ondoReserve), 5e18);
        ondoReserve.deposit(5e18);
        vm.stopPrank();
        assertEq(ondo.balanceOf(address(ondoReserve)), 5e18);
    }
}
