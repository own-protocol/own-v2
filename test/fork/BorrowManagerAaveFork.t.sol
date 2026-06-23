// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../../src/interfaces/IProtocolRegistry.sol";
import {IAaveV3Pool} from "../../src/interfaces/external/IAaveV3Pool.sol";
import {AssetConfig, BPS} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {AaveRouter} from "../../src/periphery/AaveRouter.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

/// @title BorrowManagerAaveFork — Borrow / accrue / repay against live Aave V3 on Base.
/// @notice Skipped unless `BASE_RPC` is set; pin a block with `BASE_FORK_BLOCK` for determinism.
///         Validates the BorrowManager's full lending path against the REAL Aave V3 pool, real USDC,
///         and real aTokens — the integration the mock-backed unit tests cannot exercise:
///         - A borrow draws real USDC from Aave on the vault's behalf via credit delegation.
///         - Over time the vault's real Aave debt compounds; the manager's interest-index FLOOR keeps
///           book debt at or above that real debt, so a full repay always clears the Aave loan.
///         Runs the cycle on TWO collateral vaults — aUSDC (the primary collateral) and awstETH — to
///         confirm the mechanism is collateral-agnostic.
///         The in-house oracle is mocked (it is not what's under test); Aave is real.
contract BorrowManagerAaveForkTest is Test {
    // Base mainnet (canonical Aave V3 + tokens).
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    // Resolved from Aave at runtime.
    address public aUSDC;
    address public aWSTETH;
    address public usdcDebt;

    address public admin = makeAddr("admin");
    address public lp = makeAddr("lp");
    address public borrower = makeAddr("borrower");
    address public liquidator = makeAddr("liquidator");
    address public operator = makeAddr("operator"); // bad-debt absorber, distinct from the VM
    address public treasury = makeAddr("treasury");

    ProtocolRegistry public registry;
    VaultManager public vaultManager;
    AssetRegistry public assetReg;
    MockOracleVerifier public oracle;
    AaveRouter public router;
    EToken public eTSLA;

    bytes32 constant TSLA = bytes32("TSLA");
    uint256 constant TSLA_PX = 250e18; // $250 / eTSLA
    uint256 constant TARGET_LTV_BPS = 3500;

    bool internal _forkActive;

    modifier requiresFork() {
        if (!_forkActive) {
            vm.skip(true);
        }
        _;
    }

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) {
            return; // No RPC — every test skips.
        }
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc); // latest (non-deterministic — set BASE_FORK_BLOCK to pin)
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        _forkActive = true;

        aUSDC = IAaveV3Pool(AAVE_V3_POOL).getReserveData(USDC).aTokenAddress;
        aWSTETH = IAaveV3Pool(AAVE_V3_POOL).getReserveData(WSTETH).aTokenAddress;
        usdcDebt = IAaveV3Pool(AAVE_V3_POOL).getReserveData(USDC).variableDebtTokenAddress;

        // This contract doubles as the MARKET, so it can mint the borrower's eToken collateral.
        vm.startPrank(admin);
        registry = new ProtocolRegistry(admin, 2 days, 2 minutes);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), admin);
        registry.grantRole(keccak256("OPERATOR"), operator);
        registry.setAddress(registry.MARKET(), address(this));
        registry.setAddress(registry.TREASURY(), treasury); // bad-debt collateral sink (absorbBadDebt)

        oracle = new MockOracleVerifier();
        registry.setAddress(keccak256("INHOUSE_ORACLE"), address(oracle));

        assetReg = new AssetRegistry(address(registry));
        registry.setAddress(registry.ASSET_REGISTRY(), address(assetReg));

        vaultManager = new VaultManager(IProtocolRegistry(address(registry)));
        registry.setAddress(registry.VAULT_MANAGER(), address(vaultManager));
        vaultManager.setGlobalMaxUtilizationBps(8000);
        vaultManager.setSettleBandBps(BPS); // 100% — the band is not what this fork test exercises
        vaultManager.setMaxMarkAge(365 days);
        vaultManager.setPaymentToken(USDC);

        router = new AaveRouter(AAVE_V3_POOL, address(registry));
        router.registerReserve(USDC, aUSDC);
        router.registerReserve(WSTETH, aWSTETH);
        vm.stopPrank();

        // Borrower-collateral asset (eTSLA) + the two collateral tickers the vaults price against.
        eTSLA = new EToken("Own TSLA", "eTSLA", TSLA, address(registry), USDC);
        _registerAsset(TSLA, address(eTSLA));
        _registerAsset(bytes32("AUSDC"), aUSDC);
        _registerAsset(bytes32("WSTETH"), aWSTETH);

        oracle.setPrice(TSLA, TSLA_PX);
        oracle.setPrice(bytes32("AUSDC"), 1e18); // $1
        oracle.setPrice(bytes32("WSTETH"), 4000e18); // ~$4k; only feeds the manager's debt-cap math
    }

    function _registerAsset(bytes32 ticker, address token) internal {
        AssetConfig memory cfg = AssetConfig({
            activeToken: token,
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1 // in-house (mock) oracle
        });
        vm.prank(admin);
        assetReg.addAsset(ticker, token, cfg);
    }

    /// @dev Stand up an OwnVault backed by `aToken`, fund it with real collateral via the AaveRouter,
    ///      register its mark, and bind a BorrowManager with delegation. When `enableCollateral` is
    ///      true the vault enables its aToken as Aave collateral via the production `enableAaveCollateral`
    ///      path; pass false to leave it disabled (the unfixed deposit-path state — see
    ///      {test_fork_awstETHVault_enableAaveCollateral_unlocksBorrowing}).
    function _setupVaultAndManager(
        address underlying,
        address aToken,
        bytes32 collatTicker,
        uint256 lpUnderlying,
        bool enableCollateral
    ) internal returns (OwnVault vault, BorrowManager bm) {
        vm.prank(admin);
        vault = new OwnVault(aToken, "Own Vault", "oVAULT", address(registry), admin);
        vm.prank(admin);
        vaultManager.registerVault(address(vault), collatTicker);

        // LP supplies the real underlying through the router → vault holds the real aToken.
        deal(underlying, lp, lpUnderlying);
        vm.startPrank(lp);
        IERC20(underlying).approve(address(router), lpUnderlying);
        router.deposit(underlying, IERC4626(address(vault)), lpUnderlying, lp, 0);
        vm.stopPrank();

        // Vault enables its aToken as Aave collateral via the production path → gains USDC borrowing power.
        if (enableCollateral) {
            vm.prank(admin);
            vault.enableAaveCollateral(AAVE_V3_POOL, underlying);
        }

        // Seed the manager's debt cap (reads the VaultManager collateral mark).
        vaultManager.pullCollateralPrice(address(vault));

        vm.startPrank(admin);
        bm = new BorrowManager(
            address(vault), USDC, usdcDebt, AAVE_V3_POOL, address(registry), TARGET_LTV_BPS, _params()
        );
        vault.setBorrowManager(address(bm));
        vault.grantCreditDelegation(usdcDebt);
        vm.stopPrank();
    }

    function _openBorrow(BorrowManager bm, uint256 eAmt, uint256 stable) internal {
        eTSLA.mint(borrower, eAmt); // this contract is the MARKET
        vaultManager.pullAssetPrice(TSLA); // fresh mark for the borrow-time price-band check
        vm.startPrank(borrower);
        eTSLA.approve(address(bm), eAmt);
        bm.borrow(TSLA, eAmt, stable, abi.encode(TSLA_PX, block.timestamp));
        vm.stopPrank();
    }

    /// @dev borrow → 180 days of real Aave accrual → assert the index floor → full repay clears Aave.
    function _runFloorCycle(
        address underlying,
        address aToken,
        bytes32 collatTicker,
        uint256 lpUnderlying,
        uint256 borrowUsdc
    ) internal {
        (OwnVault vault, BorrowManager bm) = _setupVaultAndManager(underlying, aToken, collatTicker, lpUnderlying, true);

        _openBorrow(bm, 100e18, borrowUsdc);

        uint256 realDebt0 = IERC20(usdcDebt).balanceOf(address(vault));
        assertApproxEqAbs(realDebt0, borrowUsdc, 2, "vault carries the borrowed USDC as real Aave debt");
        assertEq(IERC20(USDC).balanceOf(borrower), borrowUsdc, "borrower received the USDC");

        // Let real Aave interest compound.
        skip(180 days);
        bm.accrue();

        uint256 realDebt = IERC20(usdcDebt).balanceOf(address(vault));
        assertGt(realDebt, realDebt0, "real Aave debt compounded over 180 days");
        // Core safety invariant: the manager's book debt never sits below the vault's real Aave debt.
        assertGe(bm.debtOf(borrower, TSLA), realDebt, "book debt >= real Aave debt (index floor holds)");

        // Full repay must clear the vault's real Aave loan to zero.
        uint256 owed = bm.debtOf(borrower, TSLA);
        deal(USDC, borrower, owed);
        vm.startPrank(borrower);
        IERC20(USDC).approve(address(bm), owed);
        bm.repay(TSLA, type(uint256).max);
        vm.stopPrank();

        assertEq(IERC20(usdcDebt).balanceOf(address(vault)), 0, "full repay clears the vault's real Aave debt");
        assertEq(bm.positionOf(borrower, TSLA).principal, 0, "position closed");
    }

    // ──────────────────────────────────────────────────────────
    //  Primary collateral: aUSDC
    // ──────────────────────────────────────────────────────────

    function test_fork_aUSDCVault_borrowAccrueRepay_floorHolds() public requiresFork {
        // Supply 200k USDC as aUSDC collateral; borrow 10k USDC against eTSLA.
        _runFloorCycle(USDC, aUSDC, bytes32("AUSDC"), 200_000e6, 10_000e6);
    }

    // ──────────────────────────────────────────────────────────
    //  Second collateral type: awstETH
    // ──────────────────────────────────────────────────────────

    function test_fork_awstETHVault_borrowAccrueRepay_floorHolds() public requiresFork {
        // Supply 10 wstETH as awstETH collateral; borrow 5k USDC against eTSLA.
        _runFloorCycle(WSTETH, aWSTETH, bytes32("WSTETH"), 10 ether, 5000e6);
    }

    // ──────────────────────────────────────────────────────────
    //  Tier 2 — enableAaveCollateral unlocks borrowing (regression for the deposit-path gap)
    // ──────────────────────────────────────────────────────────

    /// @dev Regression test for the collateral-enablement fix. Aave V3 auto-enables a reserve as
    ///      collateral only on a holder's FIRST `supply(onBehalfOf)` — NOT on the plain aToken transfer
    ///      the deposit path uses (`AaveRouter` supplies on-behalf of the router, then transfers the
    ///      aToken into the vault). So a freshly funded vault has zero Aave borrowing power and the
    ///      delegated borrow reverts. `OwnVault.enableAaveCollateral` is the fix: the vault flips its own
    ///      collateral bit (Aave keys it on msg.sender). This test proves both halves against live Aave —
    ///      the gap (borrow reverts before the enable) and the fix (borrow succeeds after it).
    function test_fork_awstETHVault_enableAaveCollateral_unlocksBorrowing() public requiresFork {
        // Production funding path WITHOUT enabling collateral (enableCollateral = false).
        (OwnVault vault, BorrowManager bm) = _setupVaultAndManager(WSTETH, aWSTETH, bytes32("WSTETH"), 10 ether, false);

        // The vault holds the awstETH, but Aave does NOT count it as collateral → zero borrowing power.
        assertGt(IERC20(aWSTETH).balanceOf(address(vault)), 0, "vault holds the awstETH");
        (,, uint256 borrowsBefore,,,) = IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(vault));
        assertEq(borrowsBefore, 0, "no borrowing power until collateral is enabled");

        // Consequence: the delegated borrow reverts — lending is non-functional without the enable.
        eTSLA.mint(borrower, 100e18);
        vaultManager.pullAssetPrice(TSLA);
        vm.startPrank(borrower);
        eTSLA.approve(address(bm), 100e18);
        vm.expectRevert(); // Aave rejects the borrow: the vault's collateral balance is zero
        bm.borrow(TSLA, 100e18, 5000e6, abi.encode(TSLA_PX, block.timestamp));
        vm.stopPrank();

        // The fix: the vault enables its own collateral via the production admin path.
        vm.prank(admin);
        vault.enableAaveCollateral(AAVE_V3_POOL, WSTETH);
        (uint256 collAfter,, uint256 borrowsAfter,,,) = IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(vault));
        assertGt(collAfter, 0, "awstETH now counts as Aave collateral");
        assertGt(borrowsAfter, 0, "borrowing power appears once collateral is enabled");

        // Same borrow now succeeds and delivers real USDC.
        _openBorrow(bm, 100e18, 5000e6);
        assertEq(IERC20(USDC).balanceOf(borrower), 5000e6, "borrow succeeds once collateral is enabled");
    }

    /// @dev Guard rails on `enableAaveCollateral`: only admin, and the underlying must map to the vault's
    ///      asset (a wrong reserve cannot be enabled).
    function test_fork_enableAaveCollateral_guards() public requiresFork {
        (OwnVault vault,) = _setupVaultAndManager(WSTETH, aWSTETH, bytes32("WSTETH"), 10 ether, false);

        // Non-admin cannot enable.
        vm.prank(borrower);
        vm.expectRevert(IOwnVault.OnlyAdmin.selector);
        vault.enableAaveCollateral(AAVE_V3_POOL, WSTETH);

        // Wrong underlying (USDC, whose aToken is aUSDC, not this vault's awstETH) is rejected.
        vm.prank(admin);
        vm.expectRevert(IOwnVault.InvalidUnderlying.selector);
        vault.enableAaveCollateral(AAVE_V3_POOL, USDC);

        // Zero addresses rejected.
        vm.prank(admin);
        vm.expectRevert(IOwnVault.ZeroAddress.selector);
        vault.enableAaveCollateral(address(0), WSTETH);
    }

    // ──────────────────────────────────────────────────────────
    //  Tier 2 — absorbBadDebt against real Aave
    // ──────────────────────────────────────────────────────────

    /// @dev Full bad-debt path on the live pool. A price crash plus a partial liquidation strips all
    ///      eToken collateral, leaving a zero-collateral residual that still backs a real USDC loan on
    ///      the vault. The operator fronts the residual USDC; `absorbBadDebt` repays the REAL Aave loan
    ///      to zero and clears the book debt, and with `absorbAmount = 0` the loss is socialized — vault
    ///      awstETH collateral is released to the protocol treasury. Exercises the Aave-repay and
    ///      collateral-release legs against real Aave, which the mock-backed unit tests cannot.
    function test_fork_absorbBadDebt_realAaveRepay_collateralToTreasury() public requiresFork {
        (OwnVault vault, BorrowManager bm) = _setupVaultAndManager(WSTETH, aWSTETH, bytes32("WSTETH"), 10 ether, true);

        // Open $10k against 100 eTSLA ($25k @ $250).
        _openBorrow(bm, 100e18, 10_000e6);

        // Crash eTSLA to $40 and refresh the keeper mark so the liquidation price-band check passes.
        uint256 crashPx = 40e18;
        oracle.setPrice(TSLA, crashPx);
        vaultManager.pullAssetPrice(TSLA);

        // Liquidator repays $5k: the bonus-seize (5000 × 1.05 / 40 = 131 eTSLA) caps at the 100 posted,
        // stripping ALL collateral while clearing only half the debt → a zero-collateral residual.
        uint256 liqRepay = 5000e6;
        deal(USDC, liquidator, liqRepay);
        vm.startPrank(liquidator);
        IERC20(USDC).approve(address(bm), liqRepay);
        bm.liquidate(borrower, TSLA, liqRepay, abi.encode(crashPx, block.timestamp));
        vm.stopPrank();

        assertEq(bm.positionOf(borrower, TSLA).eTokenCollateral, 0, "liquidation stripped all collateral");
        assertGt(IERC20(usdcDebt).balanceOf(address(vault)), 0, "residual still backs a real Aave loan");

        // Let the bad debt sit and accrue on the live pool. The premium lifts the book residual above the
        // vault's real Aave debt (the index floor), so fronting the book residual fully clears the Aave loan.
        skip(30 days);
        bm.accrue();
        uint256 residual = bm.debtOf(borrower, TSLA);
        assertGt(residual, 0, "uncollateralized book residual remains");

        uint256 treasuryAwstBefore = IERC20(aWSTETH).balanceOf(treasury);

        // Operator (not the VM) fronts the full residual; absorbAmount = 0 → LPs eat the loss via collateral.
        deal(USDC, operator, residual);
        vm.startPrank(operator);
        IERC20(USDC).approve(address(bm), residual);
        bm.absorbBadDebt(borrower, TSLA, 0, abi.encode(uint256(4000e18), block.timestamp));
        vm.stopPrank();

        // Real Aave loan cleared and the book position closed.
        assertEq(IERC20(usdcDebt).balanceOf(address(vault)), 0, "absorb repaid the real Aave debt to zero");
        assertEq(bm.positionOf(borrower, TSLA).principal, 0, "position closed");
        // Loss socialized: the treasury received the released awstETH collateral; the caller got none.
        assertGt(
            IERC20(aWSTETH).balanceOf(treasury) - treasuryAwstBefore, 0, "treasury received LP-socialized collateral"
        );
        assertEq(IERC20(aWSTETH).balanceOf(operator), 0, "caller received no collateral");
        assertEq(IERC20(USDC).balanceOf(operator), 0, "operator fronted the full residual");
    }

    // ──────────────────────────────────────────────────────────
    //  Tier 2 — settlement against real Base USDC (6-dec, upgradeable, blocklist)
    // ──────────────────────────────────────────────────────────

    /// @dev Borrow/repay settles in the REAL Base USDC (canonical FiatTokenV2_2 proxy at 0x8335…), not
    ///      a MockERC20. Pins the transfer + decimal semantics the protocol depends on: 6-decimal
    ///      stablecoin accounting through the 18-dec eToken / 18-dec USD math, exact transfer amounts on
    ///      both legs (the real token is not fee-on-transfer), and a clean round-trip that returns the
    ///      exact posted collateral and clears the real Aave debt to zero.
    function test_fork_realUSDC_borrowRepaySettlement_exactSemantics() public requiresFork {
        // Sanity on the real token: canonical Base USDC is 6-decimal.
        assertEq(IERC20Metadata(USDC).decimals(), 6, "real Base USDC is 6-decimal");

        (OwnVault vault, BorrowManager bm) = _setupVaultAndManager(WSTETH, aWSTETH, bytes32("WSTETH"), 10 ether, true);

        uint256 eAmt = 100e18; // 18-dec collateral
        uint256 borrowUsdc = 8000e6; // 6-dec stablecoin: $8k against $25k @ $250 (32% LTV)
        assertEq(IERC20(USDC).balanceOf(borrower), 0, "borrower starts with no USDC");

        _openBorrow(bm, eAmt, borrowUsdc);

        // Forward leg arrived intact: real USDC has no fee-on-transfer, the full amount reached the borrower
        // and the manager kept none. Book debt equals the 6-dec borrow (within Aave's compounding dust).
        assertEq(IERC20(USDC).balanceOf(borrower), borrowUsdc, "borrower received exactly the borrowed USDC");
        assertEq(IERC20(USDC).balanceOf(address(bm)), 0, "manager forwarded all USDC, retains none");
        assertApproxEqAbs(bm.debtOf(borrower, TSLA), borrowUsdc, 2, "book debt equals the 6-dec borrow");

        // Full repay in the same block (no accrual): owed equals the borrow within Aave's 2-wei dust.
        uint256 owed = bm.debtOf(borrower, TSLA);
        deal(USDC, borrower, owed); // exact settlement amount in the real token
        vm.startPrank(borrower);
        IERC20(USDC).approve(address(bm), owed);
        uint256 released = bm.repay(TSLA, type(uint256).max);
        vm.stopPrank();

        // Round-trip: exact collateral back, position + real Aave debt cleared, no USDC stranded anywhere.
        assertEq(released, eAmt, "exact posted collateral returned");
        assertEq(bm.positionOf(borrower, TSLA).principal, 0, "position closed");
        assertEq(IERC20(usdcDebt).balanceOf(address(vault)), 0, "real Aave debt cleared to zero");
        assertEq(IERC20(USDC).balanceOf(borrower), 0, "borrower spent exactly the owed USDC");
        assertEq(IERC20(USDC).balanceOf(address(bm)), 0, "manager holds no residual USDC");
    }
}
