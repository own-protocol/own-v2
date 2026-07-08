// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {IBorrowManager} from "../../src/interfaces/IBorrowManager.sol";
import {AssetConfig, BPS, PRECISION} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveDebtToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {BorrowManagerHandler} from "./handlers/BorrowManagerHandler.sol";

/// @title BorrowManagerInvariant — Stateful fuzz of the Aave-funded borrow manager
/// @notice Closes the invariant-suite gap: BorrowManager previously had no stateful coverage. Asserts
///         the interest-index floor, collateral custody, and open-position integrity after every random
///         borrow / repay / accrue / Aave-accrual sequence (mock Aave — fast and deterministic; the live
///         Aave counterpart lives in test/fork/BorrowManagerAaveFork.t.sol).
contract BorrowManagerInvariant is BaseTest {
    AssetRegistry internal assetRegistry;
    EToken internal eTSLA;
    MockAaveV3Pool internal aavePool;
    MockAToken internal awstETH;
    MockAaveDebtToken internal usdcDebt;
    OwnVault internal vault;
    BorrowManager internal borrowManager;
    BorrowManagerHandler internal handler;

    bytes32 internal constant ASSET = bytes32("TSLA");
    uint256 internal constant TSLA_PX = 250e18;
    uint256 internal constant TARGET_LTV_BPS = 3500;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        aavePool = new MockAaveV3Pool();
        awstETH = MockAToken(aavePool.registerReserve(address(wstETH), "Aave wstETH", "awstETH", 18));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));

        vm.startPrank(Actors.ADMIN);
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        eTSLA = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));
        AssetConfig memory cfg = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(ASSET, address(eTSLA), cfg);

        vm.prank(Actors.ADMIN);
        vault = new OwnVault(address(awstETH), "Own awstETH", "owawstETH", address(protocolRegistry), address(this));

        _deployVaultManager(); // sets a wide settle band + mark age by default
        _setPaymentToken(address(usdc));
        vm.prank(Actors.ADMIN);
        vaultManager.registerVault(address(vault), bytes32("WSTETH"));

        // Seed the vault with ~$1M of awstETH collateral and register/price it.
        _setOraclePrice(bytes32("WSTETH"), 4000e18);
        uint256 collatAmt = (1_000_000e18 * PRECISION) / 4000e18;
        vm.prank(address(aavePool));
        awstETH.mint(address(vault), collatAmt);
        AssetConfig memory wcfg = AssetConfig({
            activeToken: address(awstETH),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(bytes32("WSTETH"), address(awstETH), wcfg);
        vaultManager.pullCollateralPrice(address(vault));

        borrowManager = new BorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(protocolRegistry),
            TARGET_LTV_BPS,
            _params()
        );
        _enableAaveLending(address(vault), address(borrowManager), address(usdcDebt));
        vm.prank(Actors.ADMIN);
        assetRegistry.setLendingVaultAllowed(ASSET, address(vault), true);

        usdc.mint(address(aavePool), 100_000_000e6); // Aave borrow liquidity
        _setOraclePrice(ASSET, TSLA_PX);
        _pullAssetPrice(ASSET);

        // The handler doubles as the MARKET so it can mint borrower eToken collateral.
        handler = new BorrowManagerHandler(
            address(borrowManager),
            address(vaultManager),
            address(eTSLA),
            address(usdc),
            address(aavePool),
            address(vault)
        );
        bytes32 marketKey = protocolRegistry.MARKET();
        vm.prank(Actors.ADMIN);
        protocolRegistry.setAddress(marketKey, address(handler));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = BorrowManagerHandler.borrow.selector;
        selectors[1] = BorrowManagerHandler.repay.selector;
        selectors[2] = BorrowManagerHandler.accrue.selector;
        selectors[3] = BorrowManagerHandler.aaveAccrue.selector;
        selectors[4] = BorrowManagerHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ═════════════════════════════════════════════════════════════
    //  Invariants
    // ═════════════════════════════════════════════════════════════

    /// @notice INV-BM-01 (index floor): while the floor is active, the manager's total book debt never
    ///         sits below the vault's real Aave debt, so a full repay always clears the Aave loan. The
    ///         floor is intentionally disabled below a dust SCALED-debt base (`10 ** stableDecimals`, M-08),
    ///         so the guard mirrors that exact condition — `Position.principal` is the scaled debt, so the
    ///         sum across positions is the contract's `_totalScaledDebt`. Guarding on actual `book` would
    ///         over-assert once accrued interest lifts the index above 1.0 (scaled < dust while actual
    ///         book >= 1 USDC), where the floor makes no guarantee. A 1e3 tolerance absorbs per-position
    ///         index flooring across the open positions.
    function invariant_bookDebtCoversRealAaveDebt() external view {
        uint256 book;
        uint256 scaled;
        uint256 n = handler.borrowerCount();
        for (uint256 i; i < n; ++i) {
            address b = handler.borrowerAt(i);
            scaled += borrowManager.positionOf(b, ASSET).principal; // principal == scaled debt
            book += borrowManager.debtOf(b, ASSET);
        }
        if (scaled < 1e6) return; // floor disabled at dust scale (matches contract)
        uint256 realAave = aavePool.debtOf(address(vault), address(usdc));
        assert(book + 1e3 >= realAave);
    }

    /// @notice INV-BM-02 (collateral custody): the manager holds at least the eToken collateral escrowed
    ///         across all open positions — borrowing/repaying never loses track of posted collateral.
    function invariant_collateralCustody() external view {
        uint256 escrowed;
        uint256 n = handler.borrowerCount();
        for (uint256 i; i < n; ++i) {
            escrowed += borrowManager.positionOf(handler.borrowerAt(i), ASSET).eTokenCollateral;
        }
        assert(eTSLA.balanceOf(address(borrowManager)) >= escrowed);
    }

    /// @notice INV-BM-03: every open position (principal > 0) retains non-zero collateral. With no
    ///         liquidation/halt path in this handler, a borrow never strands an uncollateralized position.
    function invariant_openPositionHasCollateral() external view {
        uint256 n = handler.borrowerCount();
        for (uint256 i; i < n; ++i) {
            IBorrowManager.Position memory p = borrowManager.positionOf(handler.borrowerAt(i), ASSET);
            if (p.principal > 0) assert(p.eTokenCollateral > 0);
        }
    }

    function invariant_callSummary() external view {} // call distribution under -vvv
}
