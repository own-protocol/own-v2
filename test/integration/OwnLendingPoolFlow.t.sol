// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {BorrowManager} from "../../src/core/BorrowManager.sol";
import {OwnLendingPool} from "../../src/core/OwnLendingPool.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {AssetConfig, BPS} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {AaveRouter} from "../../src/periphery/AaveRouter.sol";
import {VaultYieldManager} from "../../src/periphery/VaultYieldManager.sol";
import {EToken} from "../../src/tokens/EToken.sol";
import {OwnAToken} from "../../src/tokens/OwnAToken.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title OwnLendingPoolFlow — drop-in integration test
/// @notice Proves OwnLendingPool is a drop-in `aavePool` for the real protocol
///         stack: AaveRouter supplies LP funds into it, OwnVault holds its aToken
///         as ERC-4626 collateral and wires credit delegation, and BorrowManager
///         runs its full lifecycle against it — delegated borrow, premium-only
///         accrual (pool rate is 0 by design), mid-term VM interest claim via a
///         delegated draw, and full repay with the premium surplus swept to the VM.
///         Mirrors the shape of BorrowAndLiquidateFlow, which runs the same stack
///         against MockAaveV3Pool / real Aave.
contract OwnLendingPoolFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    EToken public eTSLA;
    OwnLendingPool public pool;
    OwnAToken public poolAToken;
    AaveRouter public router;
    OwnVault public vault;
    BorrowManager public borrowManager;

    bytes32 constant ASSET = bytes32("TSLA");
    bytes32 constant COLLAT = bytes32("USDC");
    uint256 constant TSLA_PX = 250e18;
    uint256 constant LP_DEPOSIT = 1_000_000e6;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        // Protocol registry slots.
        address market = address(this); // act as MARKET so we can mint eTSLA in tests.
        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), market);

        // In-house lending pool (zero rate — full lending rate lives in the premium curve).
        pool = new OwnLendingPool(
            address(protocolRegistry), address(usdc), "Own aUSDC", "oaUSDC", "Own Debt USDC", "odUSDC", 8000, 9500
        );

        // Router is the only allowed supplier.
        router = new AaveRouter(address(pool), address(protocolRegistry));
        router.registerReserve(address(usdc), pool.aToken());
        pool.setSupplierAllowed(address(router), true);

        // Asset registry + eTSLA.
        assetRegistry = new AssetRegistry(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));
        vm.stopPrank();

        poolAToken = OwnAToken(pool.aToken());
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

        _deployVaultManager();

        // Vault holds the pool's aToken as its ERC-4626 asset; this contract is the VM.
        vm.startPrank(Actors.ADMIN);
        vault = new OwnVault(pool.aToken(), "Own aUSDC Vault", "owaUSDC", address(protocolRegistry), address(this));
        vaultManager.registerVault(address(vault), COLLAT);

        borrowManager = new BorrowManager(
            address(vault),
            address(usdc),
            pool.variableDebtToken(),
            address(pool),
            address(protocolRegistry),
            3500,
            _params()
        );
        vm.stopPrank();

        // Register the collateral asset (the aToken; $1 stablecoin receipt).
        AssetConfig memory collatCfg = AssetConfig({
            activeToken: address(poolAToken),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(COLLAT, address(poolAToken), collatCfg);
        _setOraclePrice(COLLAT, 1e18);

        _setPaymentToken(address(usdc));
        _enableAaveLending(address(vault), address(borrowManager), pool.variableDebtToken());

        // Verifies the pool's getReserveData wiring; collateral counting itself
        // is always-on in OwnLendingPool (the call is a compatibility no-op).
        vm.prank(Actors.ADMIN);
        vault.enableAaveCollateral(address(pool), address(usdc));

        vm.prank(Actors.ADMIN);
        assetRegistry.setLendingVaultAllowed(ASSET, address(vault), true);

        _setOraclePrice(ASSET, TSLA_PX);
        _pullAssetPrice(ASSET);

        // LP deposits through the router: usdc → pool.supply → aUSDC → vault shares.
        usdc.mint(Actors.LP1, LP_DEPOSIT);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(router), LP_DEPOSIT);
        router.deposit(address(usdc), IERC4626(address(vault)), LP_DEPOSIT, Actors.LP1, 0);
        vm.stopPrank();

        vaultManager.pullCollateralPrice(address(vault));
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    function test_setUp_vaultFundedThroughRouter() public view {
        assertEq(poolAToken.balanceOf(address(vault)), LP_DEPOSIT);
        assertEq(pool.availableLiquidity(), LP_DEPOSIT);
        assertGt(vault.balanceOf(Actors.LP1), 0);
        // Zero-rate wiring: the manager reads a 0 base rate from the pool.
        assertEq(borrowManager.baseRateBps(), 0);
    }

    /// @dev Full lifecycle: delegated borrow → premium-only accrual → mid-term VM
    ///      interest claim (delegated draw) → full repay → premium surplus to VM,
    ///      pool made whole, vault collateral untouched throughout.
    function test_endToEnd_borrowAccrueClaimRepay() public {
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6; // 40% LTV at $250.

        // Borrower opens a position; funds come out of pool liquidity via the
        // vault's credit delegation.
        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();

        assertEq(usdc.balanceOf(Actors.MINTER1), stable);
        assertEq(eTSLA.balanceOf(address(borrowManager)), eAmt);
        assertEq(pool.debtOf(address(vault)), stable);
        assertEq(pool.availableLiquidity(), LP_DEPOSIT - stable);
        // The vault's aToken collateral never moves — loans draw pool liquidity.
        assertEq(poolAToken.balanceOf(address(vault)), LP_DEPOSIT);

        // Interest accrues at the premium curve only (pool rate is 0).
        skip(180 days);
        uint256 debtAfterTime = borrowManager.debtOf(Actors.MINTER1, ASSET);
        assertGt(debtAfterTime, stable, "premium accrued");

        // VM claims part of the earned premium mid-term: drawn from the pool on
        // the vault's credit line (delegated borrow), gated by the pool's live HF.
        uint256 claimable = borrowManager.claimableInterest();
        assertGt(claimable, 0);
        uint256 claim = claimable / 2;
        uint256 vmBefore = usdc.balanceOf(address(this));
        borrowManager.claimEarnedInterest(claim);
        assertEq(usdc.balanceOf(address(this)) - vmBefore, claim, "claim paid to VM");
        assertEq(pool.debtOf(address(vault)), stable + claim, "claim drawn on the vault's credit line");

        // Borrower repays in full; premium above the vault's pool debt sweeps to the VM.
        uint256 debt = borrowManager.debtOf(Actors.MINTER1, ASSET);
        usdc.mint(Actors.MINTER1, debt - usdc.balanceOf(Actors.MINTER1));
        vmBefore = usdc.balanceOf(address(this));
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), debt);
        borrowManager.repay(ASSET, debt);
        vm.stopPrank();

        // Position closed, collateral returned.
        assertEq(borrowManager.debtOf(Actors.MINTER1, ASSET), 0);
        assertEq(eTSLA.balanceOf(Actors.MINTER1), eAmt);

        // The vault's pool debt (principal + the VM's draw) is fully retired and
        // the remaining premium swept to the VM.
        assertEq(pool.debtOf(address(vault)), 0, "vault pool debt cleared");
        uint256 surplus = debt - (stable + claim);
        assertEq(usdc.balanceOf(address(this)) - vmBefore, surplus, "premium surplus swept to VM");

        // Pool made exactly whole: every aToken is backed by cash again.
        assertEq(pool.availableLiquidity(), LP_DEPOSIT, "pool liquidity restored");
        assertEq(poolAToken.balanceOf(address(vault)), LP_DEPOSIT, "vault collateral untouched");
        assertEq(poolAToken.totalSupply(), pool.availableLiquidity() + pool.totalDebt(), "solvency invariant");
    }

    /// @dev Yield-shell retrofit: install VaultYieldManager on the live vault with a
    ///      single `setManager` call, then run borrow → claim (operator passthrough) →
    ///      repay → permissionless distribute. All revenue (sweep + claim) splits
    ///      20% to the protocol treasury, 80% to LPs via the 1:1 pool conversion.
    function test_endToEnd_yieldManagerRetrofitAndDistribute() public {
        address treasury = makeAddr("treasury");
        _setTreasury(treasury);

        // Retrofit: one admin call re-routes all future revenue to the shell.
        vm.startPrank(Actors.ADMIN);
        // Shell manager = this contract (the VM entity in this test).
        VaultYieldManager yieldManager =
            new VaultYieldManager(address(protocolRegistry), address(vault), address(pool), address(this), 2000);
        vault.setManager(address(yieldManager));
        pool.setSupplierAllowed(address(yieldManager), true);
        vm.stopPrank();

        // Borrower opens and accrues premium.
        uint256 eAmt = 100e18;
        uint256 stable = 10_000e6;
        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, stable, _priceData(TSLA_PX));
        vm.stopPrank();
        skip(180 days);

        // Anyone realizes earned interest mid-term through the shell (permissionless
        // crank); the cash lands on the shell.
        uint256 claim = borrowManager.claimableInterest() / 2;
        vm.prank(makeAddr("cranker"));
        yieldManager.claimEarnedInterest(claim);
        assertEq(yieldManager.pendingYield(), claim, "claim held by shell");

        // Borrower repays in full; the premium surplus sweeps to the shell (live
        // _boundManager() read — no BorrowManager change needed).
        uint256 debt = borrowManager.debtOf(Actors.MINTER1, ASSET);
        usdc.mint(Actors.MINTER1, debt);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(borrowManager), debt);
        borrowManager.repay(ASSET, debt);
        vm.stopPrank();

        uint256 revenue = yieldManager.pendingYield();
        assertEq(revenue, debt - stable, "all interest (claim + sweep) held by shell");

        // Permissionless crank: 20% treasury, 80% to LPs via 1:1 supply + shareYield.
        uint256 lpAssetsBefore = vault.previewRedeem(vault.balanceOf(Actors.LP1));
        yieldManager.distribute();

        uint256 expectedCut = revenue * 2000 / BPS;
        assertEq(usdc.balanceOf(treasury), expectedCut, "treasury got 20%");
        assertEq(poolAToken.balanceOf(address(vault)), LP_DEPOSIT + (revenue - expectedCut), "vault got 80%");
        uint256 lpAssetsAfter = vault.previewRedeem(vault.balanceOf(Actors.LP1));
        assertApproxEqAbs(lpAssetsAfter - lpAssetsBefore, revenue - expectedCut, 1, "LP share price rose by the yield");

        // Pool stays solvent through the extra supply.
        assertEq(poolAToken.totalSupply(), pool.availableLiquidity() + pool.totalDebt(), "solvency invariant");
    }

    /// @dev The pool's health-factor gate protects the VM claim path: a claim that
    ///      would push the vault's HF below `minClaimHealthFactor` reverts.
    function test_claimEarnedInterest_hfGateUsesPoolAccountData() public {
        uint256 eAmt = 100e18;
        eTSLA.mint(Actors.MINTER1, eAmt);
        vm.startPrank(Actors.MINTER1);
        eTSLA.approve(address(borrowManager), eAmt);
        borrowManager.borrow(ASSET, eAmt, 10_000e6, _priceData(TSLA_PX));
        vm.stopPrank();

        skip(365 days);

        // Sanity: pool reports a live HF for the vault well above the 1.1 gate at
        // this utilization; the claim path reads it through getUserAccountData.
        (,,,,, uint256 hf) = pool.getUserAccountData(address(vault));
        assertGt(hf, borrowManager.minClaimHealthFactor());

        uint256 claimable = borrowManager.claimableInterest();
        borrowManager.claimEarnedInterest(claimable);
        assertEq(pool.debtOf(address(vault)), 10_000e6 + claimable);
    }
}
