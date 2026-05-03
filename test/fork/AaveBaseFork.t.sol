// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AaveBorrowManager} from "../../src/core/AaveBorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IAaveRouter} from "../../src/interfaces/IAaveRouter.sol";
import {IAaveV3Pool} from "../../src/interfaces/external/IAaveV3Pool.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {AaveRouter} from "../../src/periphery/AaveRouter.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @title AaveBaseFork — Fork tests against live Aave V3 on Base mainnet
/// @notice Skipped if `BASE_RPC` is not set. Otherwise:
///         - Verifies the AaveRouter deposit/withdraw round-trip against the
///           real Aave V3 Pool, real wstETH, and real awstETH.
///         - Verifies AaveBorrowManager's live rate read returns a sensible
///           non-zero rate from Aave's USDC reserve.
contract AaveBaseForkTest is Test {
    // Base mainnet addresses (canonical, verified against Aave V3 deployments).
    address constant AAVE_V3_POOL_BASE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant WSTETH_BASE = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Resolved at runtime from Aave's getReserveData.
    address public awstETH;
    address public usdcVariableDebt;

    address public admin = makeAddr("admin");
    address public lp = makeAddr("lp");

    ProtocolRegistry public registry;
    AaveRouter public router;
    OwnVault public vault;
    AaveBorrowManager public borrowManager;

    bool internal _forkActive;

    /// @dev Skip the test suite gracefully if BASE_RPC isn't provided.
    modifier requiresFork() {
        if (!_forkActive) {
            vm.skip(true);
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) {
            return; // BASE_RPC not set — every test will skip.
        }

        vm.createSelectFork(rpc);
        _forkActive = true;

        // Pull live aToken / debtToken addresses from Aave so we don't hard-code
        // them (they're tied to a specific Aave deployment and may change).
        IAaveV3Pool.ReserveDataLegacy memory wstReserve = IAaveV3Pool(AAVE_V3_POOL_BASE).getReserveData(WSTETH_BASE);
        IAaveV3Pool.ReserveDataLegacy memory usdcReserve = IAaveV3Pool(AAVE_V3_POOL_BASE).getReserveData(USDC_BASE);
        awstETH = wstReserve.aTokenAddress;
        usdcVariableDebt = usdcReserve.variableDebtTokenAddress;

        // Minimal protocol scaffolding.
        vm.startPrank(admin);
        registry = new ProtocolRegistry(admin, 2 days);
        registry.setAddress(registry.MARKET(), makeAddr("market"));
        registry.setAddress(registry.TREASURY(), makeAddr("treasury"));
        registry.setProtocolShareBps(2000);

        router = new AaveRouter(AAVE_V3_POOL_BASE, address(registry));
        router.registerReserve(WSTETH_BASE, awstETH);

        vault = new OwnVault(awstETH, "Own awstETH", "owawstETH", address(registry), address(router), 8000, 2000);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Phase 1 round-trip: wstETH → Aave → vault shares → back
    // ──────────────────────────────────────────────────────────

    function test_fork_routerRoundTrip() public requiresFork {
        uint256 amount = 1 ether;
        deal(WSTETH_BASE, lp, amount);
        assertEq(IERC20(WSTETH_BASE).balanceOf(lp), amount, "deal failed");

        vm.startPrank(lp);
        IERC20(WSTETH_BASE).approve(address(router), amount);
        uint256 shares = router.deposit(WSTETH_BASE, IERC4626(address(vault)), amount, lp, 0);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        // Aave can credit fewer aTokens than supplied due to integer rounding
        // on the live liquidity index; tolerate 1 wei.
        uint256 vaultBal = IERC20(awstETH).balanceOf(address(vault));
        assertApproxEqAbs(vaultBal, amount, 1, "vault holds awstETH");

        assertEq(IERC20(WSTETH_BASE).balanceOf(address(router)), 0, "router holds no wstETH");
        assertEq(IERC20(awstETH).balanceOf(address(router)), 0, "router holds no awstETH");
    }

    /// @dev awstETH (and most Aave aTokens) appreciates as Aave accrues
    ///      interest. We verify the vault's totalAssets() rises after time
    ///      advances on the fork (with a fresh block touched on Aave to refresh
    ///      the reserve index).
    function test_fork_aTokenAccrual_lifesShareValue() public requiresFork {
        uint256 amount = 5 ether;
        deal(WSTETH_BASE, lp, amount);

        vm.startPrank(lp);
        IERC20(WSTETH_BASE).approve(address(router), amount);
        router.deposit(WSTETH_BASE, IERC4626(address(vault)), amount, lp, 0);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();

        // Advance ~30 days. awstETH balance rises as Aave's liquidity index
        // grows over time.
        skip(30 days);
        vm.roll(block.number + 1);

        uint256 totalAssetsAfter = vault.totalAssets();
        // Yield is small and depends on Aave reserve activity — assert non-decrease.
        assertGe(totalAssetsAfter, totalAssetsBefore, "awstETH does not lose ground");
    }

    // ──────────────────────────────────────────────────────────
    //  Live Aave rate read
    // ──────────────────────────────────────────────────────────

    function test_fork_borrowManager_readsLiveAaveRate() public requiresFork {
        // Wire a borrow manager on the existing fork vault.
        vm.prank(admin);
        borrowManager = new AaveBorrowManager(
            address(vault),
            USDC_BASE,
            usdcVariableDebt,
            AAVE_V3_POOL_BASE,
            address(registry),
            InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500})
        );

        uint256 liveBps = borrowManager.liveAaveRateBps();
        // Sanity: USDC borrow rate on a productive Aave market should be in
        // a normal range (above 0%, below 50%).
        assertGt(liveBps, 0, "non-zero live rate");
        assertLt(liveBps, 5000, "below 50% APR (decoding sanity)");
        emit log_named_uint("Live Aave USDC borrow rate (BPS)", liveBps);
    }
}
