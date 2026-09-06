// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {BPS} from "../../src/interfaces/types/Types.sol";
import {EToken} from "../../src/tokens/EToken.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {Actors} from "../helpers/Actors.sol";
import {deployEUSDManager} from "../helpers/DeployEusdModule.sol";
import {MockAssetRegistry} from "../helpers/MockAssetRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {MockVaultManager} from "../helpers/MockVaultManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract EUSDManagerTest is Test {
    ProtocolRegistry internal registry;
    MockOracleVerifier internal oracle;
    MockAssetRegistry internal assetRegistry;
    MockVaultManager internal vaultManager;
    MockERC20 internal eSPY;
    MockERC20 internal eQQQ;
    EUSD internal eusd;
    EUSDManager internal manager;

    address internal admin = Actors.ADMIN;
    address internal operator = address(uint160(uint256(keccak256("operator"))));
    address internal treasury = address(uint160(uint256(keccak256("treasury"))));
    address internal alice = Actors.MINTER1;
    address internal bob = Actors.MINTER2;
    address internal carol = Actors.LP1;
    address internal keeper = Actors.LIQUIDATOR;
    address internal attacker = Actors.ATTACKER;

    bytes32 internal constant SPY = bytes32("SPY");
    bytes32 internal constant QQQ = bytes32("QQQ");
    uint256 internal constant PRICE = 500e18;

    uint16 internal constant MCR = 15_000;
    uint16 internal constant LIQ_THRESHOLD = 13_000;
    uint16 internal constant LIQ_BONUS = 500;
    uint16 internal constant FEE = 200;
    uint256 internal constant CEILING = 10_000_000e18;
    uint256 internal constant MIN_DEBT = 100e18;
    uint256 internal constant PRICE_MAX_AGE = 300;

    function setUp() public {
        vm.warp(1_000_000);

        registry = new ProtocolRegistry(admin, 2 days, 300);
        oracle = new MockOracleVerifier();
        assetRegistry = new MockAssetRegistry();
        vaultManager = new MockVaultManager();

        vm.startPrank(admin);
        registry.setAddress(keccak256("INHOUSE_ORACLE"), address(oracle));
        registry.setAddress(keccak256("ASSET_REGISTRY"), address(assetRegistry));
        registry.setAddress(keccak256("VAULT_MANAGER"), address(vaultManager));
        registry.setAddress(keccak256("TREASURY"), treasury);
        registry.grantRole(keccak256("ADMIN"), admin);
        registry.grantRole(keccak256("OPERATOR"), operator);
        vm.stopPrank();

        eSPY = new MockERC20("eSPY", "eSPY", 18);
        eQQQ = new MockERC20("eQQQ", "eQQQ", 18);
        assetRegistry.setOracleType(SPY, 1);
        assetRegistry.setValidToken(SPY, address(eSPY), true);
        assetRegistry.setOracleType(QQQ, 1);
        assetRegistry.setValidToken(QQQ, address(eQQQ), true);

        eusd = new EUSD(admin);
        manager = deployEUSDManager(address(registry), address(eusd), _defaultParams());
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(manager));
        manager.addCollateral(address(eSPY), SPY);
        vm.stopPrank();

        oracle.setPrice(SPY, PRICE);
        oracle.setPrice(QQQ, 400e18);

        address[5] memory users = [alice, bob, carol, keeper, attacker];
        for (uint256 i; i < users.length; i++) {
            eSPY.mint(users[i], 1_000_000e18);
            eQQQ.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            eSPY.approve(address(manager), type(uint256).max);
            eQQQ.approve(address(manager), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _defaultParams() internal pure returns (IEUSDManager.RiskParams memory) {
        return IEUSDManager.RiskParams({
            mcrBps: MCR,
            liquidationThresholdBps: LIQ_THRESHOLD,
            liquidationBonusBps: LIQ_BONUS,
            stabilityFeeBps: FEE,
            debtCeiling: CEILING,
            minDebt: MIN_DEBT,
            mintPriceMaxAge: PRICE_MAX_AGE
        });
    }

    function _open(address user, uint256 coll, uint256 debt) internal {
        vm.startPrank(user);
        manager.deposit(address(eSPY), coll, address(0));
        if (debt > 0) manager.mint(address(eSPY), debt, address(0));
        vm.stopPrank();
    }

    /// @dev Walk the sorted list and assert it is ascending by nominal ratio and sized correctly.
    function _assertListSorted(
        address collateral
    ) internal view {
        uint256 count;
        address node = manager.listHead(collateral);
        uint256 lastRatio;
        address lastNode;
        while (node != address(0)) {
            uint256 r = manager.nominalRatio(collateral, node);
            assertGe(r, lastRatio, "list not ascending");
            assertEq(manager.listPrev(collateral, node), lastNode, "prev pointer broken");
            lastRatio = r;
            lastNode = node;
            node = manager.listNext(collateral, node);
            count++;
        }
        assertEq(manager.listTail(collateral), lastNode, "tail mismatch");
        assertEq(manager.listSize(collateral), count, "size mismatch");
    }

    // ──────────────────────────────────────────────────────────
    //  Initialization (UUPS)
    // ──────────────────────────────────────────────────────────

    /// @dev Deploy a proxy over a fresh implementation expecting `err` from initialize.
    function _expectInitRevert(
        address registry_,
        address eusd_,
        IEUSDManager.RiskParams memory p,
        bytes4 err
    ) internal {
        EUSDManager impl = new EUSDManager();
        bytes memory initData = abi.encodeCall(EUSDManager.initialize, (registry_, eusd_, p));
        vm.expectRevert(err);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_zeroRegistry_reverts() public {
        _expectInitRevert(address(0), address(eusd), _defaultParams(), IEUSDManager.ZeroAddress.selector);
    }

    function test_initialize_zeroEusd_reverts() public {
        _expectInitRevert(address(registry), address(0), _defaultParams(), IEUSDManager.ZeroAddress.selector);
    }

    function test_initialize_mcrBelowThreshold_reverts() public {
        IEUSDManager.RiskParams memory p = _defaultParams();
        p.mcrBps = 12_000;
        _expectInitRevert(address(registry), address(eusd), p, IEUSDManager.InvalidRiskParams.selector);
    }

    function test_initialize_thresholdBelowBonus_reverts() public {
        IEUSDManager.RiskParams memory p = _defaultParams();
        p.liquidationThresholdBps = 10_400; // < BPS + 500
        p.mcrBps = 10_500;
        _expectInitRevert(address(registry), address(eusd), p, IEUSDManager.InvalidRiskParams.selector);
    }

    function test_initialize_feeAboveBps_reverts() public {
        IEUSDManager.RiskParams memory p = _defaultParams();
        p.stabilityFeeBps = uint16(BPS) + 1;
        _expectInitRevert(address(registry), address(eusd), p, IEUSDManager.InvalidRiskParams.selector);
    }

    function test_initialize_zeroMintPriceMaxAge_reverts() public {
        IEUSDManager.RiskParams memory p = _defaultParams();
        p.mintPriceMaxAge = 0;
        _expectInitRevert(address(registry), address(eusd), p, IEUSDManager.InvalidRiskParams.selector);
    }

    function test_initialize_bareImplementation_reverts() public {
        EUSDManager impl = new EUSDManager();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(registry), address(eusd), _defaultParams());
    }

    function test_initialize_secondCall_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        manager.initialize(address(registry), address(eusd), _defaultParams());
    }

    function test_upgrade_byAdmin_preservesState() public {
        _open(alice, 10e18, 2000e18);

        EUSDManagerV2 newImpl = new EUSDManagerV2();
        vm.prank(admin);
        UUPSUpgradeable(address(manager)).upgradeToAndCall(address(newImpl), "");

        // State (position, registry binding) survives; new behavior is live.
        assertEq(EUSDManagerV2(address(manager)).version(), 2);
        assertEq(address(manager.registry()), address(registry));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 2000e18);
        assertEq(manager.totalDebt(), 2000e18);
    }

    function test_upgrade_byNonAdmin_reverts() public {
        EUSDManagerV2 newImpl = new EUSDManagerV2();
        vm.expectRevert(IEUSDManager.OnlyAdmin.selector);
        vm.prank(attacker);
        UUPSUpgradeable(address(manager)).upgradeToAndCall(address(newImpl), "");
    }

    function test_initialize_storesParams() public view {
        IEUSDManager.RiskParams memory p = manager.riskParams();
        assertEq(p.mcrBps, MCR);
        assertEq(p.liquidationThresholdBps, LIQ_THRESHOLD);
        assertEq(p.liquidationBonusBps, LIQ_BONUS);
        assertEq(p.stabilityFeeBps, FEE);
        assertEq(p.debtCeiling, CEILING);
        assertEq(p.minDebt, MIN_DEBT);
        assertEq(p.mintPriceMaxAge, PRICE_MAX_AGE);
        assertEq(manager.eusd(), address(eusd));
    }

    // ──────────────────────────────────────────────────────────
    //  addCollateral / setCollateralEnabled
    // ──────────────────────────────────────────────────────────

    function test_addCollateral_succeeds() public {
        vm.expectEmit(true, true, false, true);
        emit IEUSDManager.CollateralAdded(address(eQQQ), QQQ);
        vm.prank(admin);
        manager.addCollateral(address(eQQQ), QQQ);

        IEUSDManager.CollateralConfig memory cfg = manager.collateralConfig(address(eQQQ));
        assertEq(cfg.ticker, QQQ);
        assertTrue(cfg.enabled);
        assertTrue(cfg.exists);
    }

    function test_addCollateral_notAdmin_reverts() public {
        vm.expectRevert(IEUSDManager.OnlyAdmin.selector);
        vm.prank(attacker);
        manager.addCollateral(address(eQQQ), QQQ);
    }

    function test_addCollateral_zeroAddress_reverts() public {
        vm.expectRevert(IEUSDManager.ZeroAddress.selector);
        vm.prank(admin);
        manager.addCollateral(address(0), QQQ);
    }

    function test_addCollateral_duplicate_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralAlreadySupported.selector, address(eSPY)));
        vm.prank(admin);
        manager.addCollateral(address(eSPY), SPY);
    }

    function test_addCollateral_wrongDecimals_reverts() public {
        MockERC20 sixDec = new MockERC20("bad", "bad", 6);
        assetRegistry.setValidToken(QQQ, address(sixDec), true);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.InvalidCollateralDecimals.selector, uint8(6)));
        vm.prank(admin);
        manager.addCollateral(address(sixDec), QQQ);
    }

    function test_addCollateral_tickerMismatch_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.TickerTokenMismatch.selector, SPY, address(eQQQ)));
        vm.prank(admin);
        manager.addCollateral(address(eQQQ), SPY);
    }

    function test_setCollateralEnabled_blocksDepositAndMint() public {
        vm.prank(admin);
        manager.setCollateralEnabled(address(eSPY), false);

        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralDisabled.selector, address(eSPY)));
        vm.prank(alice);
        manager.deposit(address(eSPY), 1e18, address(0));

        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralDisabled.selector, address(eSPY)));
        vm.prank(alice);
        manager.mint(address(eSPY), MIN_DEBT, address(0));

        vm.prank(admin);
        manager.setCollateralEnabled(address(eSPY), true);
        vm.prank(alice);
        manager.deposit(address(eSPY), 1e18, address(0));
    }

    /// @dev A4-L-14: the mint pause also stops collateral withdrawal against debt; pure exits stay open.
    function test_setMintPaused_blocksWithdrawWithDebt_exitsOpen() public {
        _open(alice, 4e18, 1000e18); // $2000 / 1000
        _open(bob, 3e18, 0);
        vm.prank(operator);
        manager.setMintPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(IEUSDManager.MintingPaused.selector);
        manager.withdrawCollateral(address(eSPY), 1e18, address(0)); // would still be 150%
        manager.repay(address(eSPY), alice, 1000e18, address(0));
        manager.withdrawCollateral(address(eSPY), 4e18, address(0)); // debt-free: allowed
        vm.stopPrank();
        vm.prank(bob);
        manager.withdrawCollateral(address(eSPY), 3e18, address(0));

        vm.prank(operator);
        manager.setMintPaused(false);
        _open(carol, 4e18, 1000e18);
        vm.prank(carol);
        manager.withdrawCollateral(address(eSPY), 1e18, address(0)); // resumed
    }

    /// @dev A4-L-10: an existing debtor can top up a disabled collateral; new exposure stays blocked.
    function test_setCollateralEnabled_debtorCanTopUp_noNewExposure() public {
        _open(alice, 3e18, 1000e18);
        _open(bob, 3e18, 0); // collateral only, no debt
        vm.prank(admin);
        manager.setCollateralEnabled(address(eSPY), false);

        oracle.setPrice(SPY, 425e18); // alice 127.5% → liquidatable
        assertTrue(manager.isLiquidatable(address(eSPY), alice));
        vm.prank(alice);
        manager.deposit(address(eSPY), 2e18, address(0)); // defensive top-up allowed
        assertFalse(manager.isLiquidatable(address(eSPY), alice));
        _assertListSorted(address(eSPY));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralDisabled.selector, address(eSPY)));
        manager.mint(address(eSPY), 100e18, address(0)); // no new debt, even for a debtor
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralDisabled.selector, address(eSPY)));
        manager.deposit(address(eSPY), 1e18, address(0)); // debt-free: no new exposure
    }

    function test_setCollateralEnabled_unknown_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralNotSupported.selector, address(eQQQ)));
        vm.prank(admin);
        manager.setCollateralEnabled(address(eQQQ), false);
    }

    function test_setCollateralEnabled_notAdmin_reverts() public {
        vm.expectRevert(IEUSDManager.OnlyAdmin.selector);
        vm.prank(operator);
        manager.setCollateralEnabled(address(eSPY), false);
    }

    // ──────────────────────────────────────────────────────────
    //  deposit
    // ──────────────────────────────────────────────────────────

    function test_deposit_succeeds() public {
        vm.expectEmit(true, true, false, true);
        emit IEUSDManager.CollateralDeposited(address(eSPY), alice, 3e18);
        vm.prank(alice);
        manager.deposit(address(eSPY), 3e18, address(0));

        assertEq(manager.getPosition(address(eSPY), alice).collateral, 3e18);
        assertEq(manager.totalCollateral(address(eSPY)), 3e18);
        assertEq(eSPY.balanceOf(address(manager)), 3e18);
        // Debt-free positions are not listed.
        assertEq(manager.listSize(address(eSPY)), 0);
    }

    function test_deposit_zeroAmount_reverts() public {
        vm.expectRevert(IEUSDManager.ZeroAmount.selector);
        vm.prank(alice);
        manager.deposit(address(eSPY), 0, address(0));
    }

    function test_deposit_unsupported_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralNotSupported.selector, address(eQQQ)));
        vm.prank(alice);
        manager.deposit(address(eQQQ), 1e18, address(0));
    }

    function test_deposit_oracleDown_stillWorks() public {
        oracle.setForceStale(true);
        vm.prank(alice);
        manager.deposit(address(eSPY), 3e18, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 3e18);
    }

    // ──────────────────────────────────────────────────────────
    //  mint
    // ──────────────────────────────────────────────────────────

    function test_mint_succeeds() public {
        _open(alice, 4e18, 0);
        vm.expectEmit(true, true, false, true);
        emit IEUSDManager.EUSDMinted(address(eSPY), alice, 1000e18, 1000e18);
        vm.prank(alice);
        manager.mint(address(eSPY), 1000e18, address(0));

        assertEq(eusd.balanceOf(alice), 1000e18);
        assertEq(eusd.totalSupply(), 1000e18);
        assertEq(manager.totalDebt(), 1000e18);
        assertEq(manager.getPosition(address(eSPY), alice).debt, 1000e18);
        assertEq(manager.listHead(address(eSPY)), alice);
        assertEq(manager.listSize(address(eSPY)), 1);
    }

    function test_mint_atExactMcr_succeeds() public {
        // 3 eSPY * $500 = $1500; 1000 eUSD debt => CR exactly 150_00 bps.
        _open(alice, 3e18, 0);
        vm.prank(alice);
        manager.mint(address(eSPY), 1000e18, address(0));
        assertEq(manager.collateralRatioBps(address(eSPY), alice), MCR);
    }

    function test_mint_belowMcr_reverts() public {
        _open(alice, 3e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralRatioTooLow.selector, 14_999, MCR));
        vm.prank(alice);
        manager.mint(address(eSPY), 1000e18 + 1, address(0));
    }

    function test_mint_noCollateral_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralRatioTooLow.selector, 0, MCR));
        vm.prank(alice);
        manager.mint(address(eSPY), MIN_DEBT, address(0));
    }

    function test_mint_stalePrice_reverts() public {
        _open(alice, 4e18, 0);
        uint256 priceTs = block.timestamp;
        vm.warp(block.timestamp + PRICE_MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.StaleMintPrice.selector, priceTs, PRICE_MAX_AGE));
        vm.prank(alice);
        manager.mint(address(eSPY), 1000e18, address(0));
    }

    function test_mint_priceAtExactMaxAge_succeeds() public {
        _open(alice, 4e18, 0);
        vm.warp(block.timestamp + PRICE_MAX_AGE);
        vm.prank(alice);
        manager.mint(address(eSPY), 1000e18, address(0));
        assertEq(eusd.balanceOf(alice), 1000e18);
    }

    function test_mint_zeroOraclePrice_reverts() public {
        _open(alice, 4e18, 0);
        oracle.setForceZeroPrice(true);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.ZeroOraclePrice.selector, SPY));
        vm.prank(alice);
        manager.mint(address(eSPY), 1000e18, address(0));
    }

    function test_mint_paused_reverts() public {
        _open(alice, 4e18, 0);
        vm.prank(operator);
        manager.setMintPaused(true);
        vm.expectRevert(IEUSDManager.MintingPaused.selector);
        vm.prank(alice);
        manager.mint(address(eSPY), 1000e18, address(0));
    }

    function test_mint_belowMinDebt_reverts() public {
        _open(alice, 4e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.BelowMinimumDebt.selector, MIN_DEBT - 1, MIN_DEBT));
        vm.prank(alice);
        manager.mint(address(eSPY), MIN_DEBT - 1, address(0));
    }

    function test_mint_debtCeilingExceeded_reverts() public {
        vm.prank(admin);
        manager.setDebtCeiling(1500e18);
        _open(alice, 4e18, 1000e18);
        _open(bob, 4e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.DebtCeilingExceeded.selector, 1600e18, 1500e18));
        vm.prank(bob);
        manager.mint(address(eSPY), 600e18, address(0));
    }

    function test_mint_zeroAmount_reverts() public {
        _open(alice, 4e18, 0);
        vm.expectRevert(IEUSDManager.ZeroAmount.selector);
        vm.prank(alice);
        manager.mint(address(eSPY), 0, address(0));
    }

    function test_mint_unsupported_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralNotSupported.selector, address(eQQQ)));
        vm.prank(alice);
        manager.mint(address(eQQQ), MIN_DEBT, address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  withdrawCollateral
    // ──────────────────────────────────────────────────────────

    function test_withdraw_debtFree_oracleDown_stillWorks() public {
        _open(alice, 3e18, 0);
        oracle.setForceStale(true);
        vm.expectEmit(true, true, false, true);
        emit IEUSDManager.CollateralWithdrawn(address(eSPY), alice, 3e18);
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 3e18, address(0));
        assertEq(eSPY.balanceOf(address(manager)), 0);
        assertEq(manager.totalCollateral(address(eSPY)), 0);
    }

    function test_withdraw_withDebt_staysAboveMcr_succeeds() public {
        _open(alice, 4e18, 1000e18);
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 1e18, address(0));
        assertEq(manager.collateralRatioBps(address(eSPY), alice), MCR);
    }

    function test_withdraw_withDebt_breaksMcr_reverts() public {
        _open(alice, 4e18, 1000e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralRatioTooLow.selector, 14_999, MCR));
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 1e18 + 2e14, address(0)); // leaves $1499.9 for 1000 debt
    }

    function test_withdraw_withDebt_stalePrice_reverts() public {
        _open(alice, 4e18, 1000e18);
        uint256 priceTs = block.timestamp;
        vm.warp(block.timestamp + PRICE_MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.StaleMintPrice.selector, priceTs, PRICE_MAX_AGE));
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 1e18, address(0));
    }

    function test_withdraw_exceedsCollateral_reverts() public {
        _open(alice, 3e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.InsufficientCollateral.selector, 4e18, 3e18));
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 4e18, address(0));
    }

    function test_withdraw_zeroAmount_reverts() public {
        vm.expectRevert(IEUSDManager.ZeroAmount.selector);
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 0, address(0));
    }

    function test_withdraw_disabledCollateral_stillWorks() public {
        _open(alice, 3e18, 0);
        vm.prank(admin);
        manager.setCollateralEnabled(address(eSPY), false);
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 3e18, address(0));
        assertEq(eSPY.balanceOf(alice), 1_000_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  repay
    // ──────────────────────────────────────────────────────────

    function test_repay_partial_succeeds() public {
        _open(alice, 4e18, 1000e18);
        vm.expectEmit(true, true, true, true);
        emit IEUSDManager.EUSDRepaid(address(eSPY), alice, alice, 400e18, 600e18);
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 400e18, address(0));

        assertEq(manager.getPosition(address(eSPY), alice).debt, 600e18);
        assertEq(manager.totalDebt(), 600e18);
        assertEq(eusd.totalSupply(), 600e18);
    }

    function test_repay_full_removesFromList() public {
        _open(alice, 4e18, 1000e18);
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 1000e18, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(manager.listSize(address(eSPY)), 0);
        assertEq(manager.listHead(address(eSPY)), address(0));
    }

    function test_repay_capsAtDebt() public {
        _open(alice, 4e18, 1000e18);
        _open(bob, 4e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(alice, 500e18);
        vm.prank(alice);
        manager.repay(address(eSPY), alice, type(uint256).max, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(eusd.balanceOf(alice), 500e18);
    }

    function test_repay_leavesDust_reverts() public {
        _open(alice, 4e18, 1000e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.BelowMinimumDebt.selector, 50e18, MIN_DEBT));
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 950e18, address(0));
    }

    function test_repay_thirdParty_succeeds() public {
        _open(alice, 4e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);
        vm.prank(keeper);
        manager.repay(address(eSPY), alice, 1000e18, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(eusd.balanceOf(keeper), 0);
    }

    function test_repay_zeroAmount_reverts() public {
        _open(alice, 4e18, 1000e18);
        vm.expectRevert(IEUSDManager.ZeroAmount.selector);
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 0, address(0));
    }

    function test_repay_noDebt_reverts() public {
        _open(alice, 4e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.NoDebt.selector, address(eSPY), alice));
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 100e18, address(0));
    }

    function test_repay_oracleDown_stillWorks() public {
        _open(alice, 4e18, 1000e18);
        oracle.setForceStale(true);
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 400e18, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 600e18);
    }

    // ──────────────────────────────────────────────────────────
    //  closePosition
    // ──────────────────────────────────────────────────────────

    function test_close_succeeds() public {
        _open(alice, 4e18, 1000e18);
        vm.expectEmit(true, true, false, true);
        emit IEUSDManager.PositionClosed(address(eSPY), alice, 4e18, 1000e18);
        vm.prank(alice);
        manager.closePosition(address(eSPY));

        assertEq(eSPY.balanceOf(alice), 1_000_000e18);
        assertEq(eusd.balanceOf(alice), 0);
        assertEq(eusd.totalSupply(), 0);
        assertEq(manager.totalDebt(), 0);
        assertEq(manager.totalCollateral(address(eSPY)), 0);
        assertEq(manager.listSize(address(eSPY)), 0);
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 0);
    }

    function test_close_oracleDown_stillWorks() public {
        _open(alice, 4e18, 1000e18);
        oracle.setForceStale(true);
        vm.prank(alice);
        manager.closePosition(address(eSPY));
        assertEq(eSPY.balanceOf(alice), 1_000_000e18);
    }

    function test_close_withAccruedFees_burnsMoreThanMinted() public {
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 365 days);
        // 2% simple over one year on 1000 eUSD = 20 eUSD extra.
        vm.prank(address(manager));
        eusd.mint(alice, 20e18); // top up the fee shortfall for the test
        vm.prank(alice);
        manager.closePosition(address(eSPY));
        assertEq(eusd.balanceOf(alice), 0);
        assertEq(manager.totalDebt(), 0);
        assertEq(eusd.balanceOf(treasury), 20e18);
    }

    function test_close_collateralOnlyPosition_succeeds() public {
        _open(alice, 3e18, 0);
        vm.prank(alice);
        manager.closePosition(address(eSPY));
        assertEq(eSPY.balanceOf(alice), 1_000_000e18);
    }

    function test_close_emptyPosition_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.EmptyPosition.selector, address(eSPY), alice));
        vm.prank(alice);
        manager.closePosition(address(eSPY));
    }

    // ──────────────────────────────────────────────────────────
    //  Stability fee
    // ──────────────────────────────────────────────────────────

    function test_fee_accruesSimpleInterest() public {
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 365 days);

        assertEq(manager.currentDebt(address(eSPY), alice), 1020e18);
        // Stored debt unchanged until touched.
        assertEq(manager.getPosition(address(eSPY), alice).debt, 1000e18);

        vm.prank(alice);
        manager.deposit(address(eSPY), 1, address(0)); // touch to accrue
        assertEq(manager.getPosition(address(eSPY), alice).debt, 1020e18);
        assertEq(manager.totalDebt(), 1020e18);
        assertEq(eusd.totalSupply(), 1020e18);
        assertEq(eusd.balanceOf(treasury), 20e18);
    }

    function test_fee_rateChange_appliesProspectively() public {
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 100 days);
        vm.prank(admin);
        manager.setStabilityFee(400);
        vm.warp(block.timestamp + 100 days);

        uint256 expectedFee = Math.mulDiv(1000e18, uint256(200) * 100 days + uint256(400) * 100 days, BPS * 365 days);
        assertEq(manager.currentDebt(address(eSPY), alice), 1000e18 + expectedFee);

        vm.prank(alice);
        manager.deposit(address(eSPY), 1, address(0));
        assertEq(eusd.balanceOf(treasury), expectedFee);
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    function test_fee_zeroRate_noAccrual() public {
        vm.prank(admin);
        manager.setStabilityFee(0);
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 365 days);
        assertEq(manager.currentDebt(address(eSPY), alice), 1000e18);
    }

    function test_accrue_crystallizesFees_mintsToTreasury() public {
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 365 days);
        assertEq(manager.getPosition(address(eSPY), alice).debt, 1000e18);

        vm.expectEmit(true, true, false, true);
        emit IEUSDManager.StabilityFeeAccrued(address(eSPY), alice, 20e18);
        vm.prank(keeper);
        manager.accrue(address(eSPY), alice, address(0));

        assertEq(manager.getPosition(address(eSPY), alice).debt, 1020e18);
        assertEq(manager.totalDebt(), 1020e18);
        assertEq(eusd.totalSupply(), 1020e18);
        assertEq(eusd.balanceOf(treasury), 20e18);

        // Immediate second call: snapshot is current, nothing more mints.
        vm.prank(keeper);
        manager.accrue(address(eSPY), alice, address(0));
        assertEq(eusd.balanceOf(treasury), 20e18);
        assertEq(manager.totalDebt(), 1020e18);
    }

    function test_accrue_reindexes_listStaysSorted() public {
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 200 days);
        oracle.setPrice(SPY, PRICE); // re-post so bob's mint passes the freshness gate
        _open(bob, 4e18, 1000e18); // fresh snapshot; alice has 200 days pending

        vm.prank(keeper);
        manager.accrue(address(eSPY), alice, address(0));
        // Alice's stored debt grew, bob's didn't — she must sort below him.
        assertEq(manager.listHead(address(eSPY)), alice);
        _assertListSorted(address(eSPY));
    }

    function test_accrue_debtFreePosition_reverts() public {
        _open(alice, 3e18, 0);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.NoDebt.selector, address(eSPY), alice));
        vm.prank(keeper);
        manager.accrue(address(eSPY), alice, address(0));

        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.NoDebt.selector, address(eSPY), bob));
        vm.prank(keeper);
        manager.accrue(address(eSPY), bob, address(0)); // nonexistent position
    }

    function test_accrue_underwaterResidual_accruesAndStaysOffList() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);

        oracle.setPrice(SPY, 400e18);
        vm.prank(keeper);
        manager.redeem(address(eSPY), 1000e18, 0, 1, address(0)); // alice → 200 eUSD debt-only residual

        uint256 treasuryBefore = eusd.balanceOf(treasury);
        vm.warp(block.timestamp + 365 days);
        vm.prank(keeper);
        manager.accrue(address(eSPY), alice, address(0));

        assertEq(manager.getPosition(address(eSPY), alice).debt, 204e18); // 2% on 200
        assertEq(eusd.balanceOf(treasury), treasuryBefore + 4e18);
        assertEq(manager.listHead(address(eSPY)), bob); // residual stays off-list
        assertEq(manager.listSize(address(eSPY)), 1);
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    function test_accrue_worksWhilePausedAndOracleDown() public {
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(operator);
        manager.setMintPaused(true);
        oracle.setForceStale(true);

        vm.prank(keeper);
        manager.accrue(address(eSPY), alice, address(0));
        assertEq(eusd.balanceOf(treasury), 20e18);
    }

    function test_accrue_invalidInputs_revert() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralNotSupported.selector, address(0xdead)));
        manager.accrue(address(0xdead), alice, address(0));

        vm.expectRevert(IEUSDManager.ZeroAddress.selector);
        manager.accrue(address(eSPY), address(0), address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  liquidate
    // ──────────────────────────────────────────────────────────

    function test_liquidate_succeeds() public {
        _open(alice, 3e18, 1000e18); // CR 150% at $500
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);

        oracle.setPrice(SPY, 400e18); // CR 120% < 130%
        // Seize: 1000 * 1.05 / 400 = 2.625 eSPY; 0.375 back to alice.
        vm.expectEmit(true, true, true, true);
        emit IEUSDManager.PositionLiquidated(address(eSPY), alice, keeper, 1000e18, 2.625e18, 0.375e18);
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));

        assertEq(eusd.balanceOf(keeper), 0);
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 2.625e18);
        assertEq(eSPY.balanceOf(alice), 1_000_000e18 - 3e18 + 0.375e18);
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 0);
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(manager.totalDebt(), 1000e18); // bob's remains
        assertEq(manager.listSize(address(eSPY)), 1);
        assertEq(manager.listHead(address(eSPY)), bob);
    }

    function test_liquidate_healthy_reverts() public {
        _open(alice, 3e18, 1000e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.PositionNotLiquidatable.selector, 15_000, LIQ_THRESHOLD));
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
    }

    function test_liquidate_atExactThreshold_reverts() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18); // CR 150% at $750
        oracle.setPrice(SPY, 650e18); // CR exactly 130%
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.PositionNotLiquidatable.selector, 13_000, LIQ_THRESHOLD));
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
    }

    function test_liquidate_justBelowThreshold_succeeds() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        oracle.setPrice(SPY, 650e18 - 1);
        assertTrue(manager.isLiquidatable(address(eSPY), alice));
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
    }

    function test_liquidate_underwater_capsAtCollateral() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);

        oracle.setPrice(SPY, 400e18); // collateral worth $800 < 1000 debt
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 2e18); // all of it, no more
        assertEq(eSPY.balanceOf(alice), 1_000_000e18 - 2e18); // nothing back
        assertEq(manager.totalCollateral(address(eSPY)), 40e18);
    }

    /// @dev A4-M-03: partial liquidation — pro-rata bonus, remainder re-sorted, no refund.
    function test_liquidate_partial_improvesRatioAndRelists() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18); // $1500 / 1000
        _open(bob, 40e18, 1000e18);
        _open(carol, 30e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 400e18); // keeper holds far less than alice's debt

        oracle.setPrice(SPY, 600e18); // $1200 / 1000 = 120% < 130%
        uint256 ownerBefore = eSPY.balanceOf(alice);
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, 400e18, address(0));

        // seized = 400 × 1.05 / 600 = 0.7 eSPY; no refund on a partial.
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 0.7e18);
        assertEq(eSPY.balanceOf(alice), ownerBefore);
        IEUSDManager.Position memory p = manager.getPosition(address(eSPY), alice);
        assertEq(p.debt, 600e18);
        assertEq(p.collateral, 1.3e18);
        // $780 / 600 = 130% → no longer liquidatable, still the riskiest (head).
        assertEq(manager.collateralRatioBps(address(eSPY), alice), 13_000);
        assertFalse(manager.isLiquidatable(address(eSPY), alice));
        assertEq(manager.listHead(address(eSPY)), alice);
        assertEq(manager.listSize(address(eSPY)), 3);
        _assertListSorted(address(eSPY));
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    function test_liquidate_partial_belowMinDebt_reverts() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        oracle.setPrice(SPY, 600e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.BelowMinimumDebt.selector, 50e18, MIN_DEBT));
        manager.liquidate(address(eSPY), alice, 950e18, address(0));
        // Exactly minDebt remaining is fine.
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, 900e18, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, MIN_DEBT);
    }

    function test_liquidate_zeroAmount_reverts() public {
        _open(alice, 3e18, 1000e18);
        vm.expectRevert(IEUSDManager.ZeroAmount.selector);
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, 0, address(0));
    }

    /// @dev The A4-M-03 whale: debt larger than any single keeper's eUSD, cleared in chunks.
    function test_liquidate_whale_clearedInChunks() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 20e18, 10_000e18); // whale, hoards its eUSD
        _open(bob, 40e18, 10_000e18); // the rest of the circulating supply
        oracle.setPrice(SPY, 500e18); // whale: $10,000 / 10,000 = 100% — deeply unsafe

        // Keeper can only ever assemble 1000 eUSD at a time (sourced from bob each round).
        for (uint256 i; i < 10; i++) {
            vm.prank(bob);
            eusd.transfer(keeper, 1000e18);
            vm.prank(keeper);
            manager.liquidate(address(eSPY), alice, 1000e18, address(0));
        }
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 0);
        assertEq(manager.listSize(address(eSPY)), 1);
    }

    /// @dev A4-M-06: below 1 + bonus a partial is capped pro-rata, so the remainder's ratio never
    ///      worsens and no debt is stranded unbacked. Fails without the pro-rata cap (seized 1.871 eSPY,
    ///      remainder at 65%).
    function test_liquidate_partial_inBand_proRataCap_keepsRatio() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);

        oracle.setPrice(SPY, 505e18); // $1010 / 1000 = 101%: solvent, below 1 + bonus
        uint256 ratioBefore = manager.collateralRatioBps(address(eSPY), alice);
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, 900e18, address(0));

        // Pro-rata cap: 2 × 900 / 1000 = 1.8 eSPY (bonus formula would give 1.871).
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 1.8e18);
        IEUSDManager.Position memory p = manager.getPosition(address(eSPY), alice);
        assertEq(p.debt, 100e18);
        assertEq(p.collateral, 0.2e18);
        assertGe(manager.collateralRatioBps(address(eSPY), alice), ratioBefore, "remainder ratio worsened");
        // The remainder is still fully backed: redeeming it leaves no debt-only residual.
        vm.prank(keeper);
        manager.redeem(address(eSPY), 100e18, 0, 0, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    /// @dev A4-M-06: an underwater partial leaves no more bad debt (pro-rata) than a full close
    ///      would; the bonus is never paid out of the shortfall. Fails without the cap (bad debt 95).
    function test_liquidate_partial_underwater_noExtraBadDebt() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);

        oracle.setPrice(SPY, 475e18); // $950 / 1000 = 95%: underwater, shortfall 50
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, 900e18, address(0));

        IEUSDManager.Position memory p = manager.getPosition(address(eSPY), alice);
        assertEq(p.debt, 100e18);
        assertEq(p.collateral, 0.2e18); // pro-rata; worth $95 → residual shortfall 5 = 10% of 50
        assertEq(manager.collateralRatioBps(address(eSPY), alice), 9500);
        // Keeper received $855 for 900 eUSD: the shortfall is absorbed by the liquidator, not created.
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 1.8e18);
    }

    function test_liquidate_noDebt_reverts() public {
        _open(alice, 3e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.NoDebt.selector, address(eSPY), alice));
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
    }

    function test_liquidate_stalePrice_stillWorks() public {
        _open(alice, 3e18, 1000e18);
        _open(bob, 40e18, 1010e18); // extra covers alice's weekend fee accrual
        vm.prank(bob);
        eusd.transfer(keeper, 1010e18);
        oracle.setPrice(SPY, 400e18, block.timestamp);
        vm.warp(block.timestamp + 2 days); // markets closed all weekend
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  redeem
    // ──────────────────────────────────────────────────────────

    function test_redeem_partial_singlePosition() public {
        _open(alice, 3e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 500e18);

        vm.prank(keeper);
        (uint256 out, uint256 repaid) = manager.redeem(address(eSPY), 500e18, 0, 0, address(0));

        assertEq(repaid, 500e18);
        assertEq(out, 1e18); // $500 / $500 per eSPY
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 1e18);
        assertEq(eusd.balanceOf(keeper), 0);
        assertEq(manager.getPosition(address(eSPY), alice).debt, 500e18);
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 2e18);
        assertEq(eusd.totalSupply(), 500e18);
        assertEq(manager.totalDebt(), 500e18);
    }

    function test_redeem_fullPosition_leavesCollateralClaimable() public {
        _open(alice, 3e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);

        vm.prank(keeper);
        manager.redeem(address(eSPY), 1000e18, 0, 0, address(0));

        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 1e18);
        assertEq(manager.listSize(address(eSPY)), 0);

        // Owner can pull the leftover collateral even with the oracle down.
        oracle.setForceStale(true);
        vm.prank(alice);
        manager.withdrawCollateral(address(eSPY), 1e18, address(0));
        assertEq(eSPY.balanceOf(alice), 1_000_000e18 - 2e18);
    }

    function test_redeem_walksRiskiestFirst() public {
        _open(alice, 3e18, 1000e18); // ratio 3e15 — riskiest
        _open(bob, 4e18, 1000e18); // ratio 4e15
        _open(carol, 6e18, 1000e18); // ratio 6e15 — safest
        assertEq(manager.listHead(address(eSPY)), alice);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 500e18);

        vm.prank(keeper);
        (uint256 out, uint256 repaid) = manager.redeem(address(eSPY), 1500e18, 0, 0, address(0));

        assertEq(repaid, 1500e18);
        assertEq(out, 3e18);
        // Alice fully redeemed, bob partially, carol untouched.
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(manager.getPosition(address(eSPY), bob).debt, 500e18);
        assertEq(manager.getPosition(address(eSPY), carol).debt, 1000e18);
        assertEq(manager.listSize(address(eSPY)), 2);
        assertEq(manager.listHead(address(eSPY)), carol); // bob's ratio improved to 6e15, ties go after
        _assertListSorted(address(eSPY));
    }

    function test_redeem_capsAtTotalDebt() public {
        _open(alice, 3e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);

        vm.prank(keeper);
        (, uint256 repaid) = manager.redeem(address(eSPY), 5000e18, 0, 0, address(0));
        assertEq(repaid, 2000e18);
        assertEq(manager.totalDebt(), 0);
        assertEq(eusd.balanceOf(keeper), 0);
    }

    function test_redeem_minCollateralOut_reverts() public {
        _open(alice, 3e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 500e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.SlippageExceeded.selector, 1e18, 1e18 + 1));
        vm.prank(keeper);
        manager.redeem(address(eSPY), 500e18, 1e18 + 1, 0, address(0));
    }

    function test_redeem_maxPositions_limitsWalk() public {
        _open(alice, 3e18, 1000e18);
        _open(bob, 4e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);

        vm.prank(keeper);
        (, uint256 repaid) = manager.redeem(address(eSPY), 2000e18, 0, 1, address(0));
        assertEq(repaid, 1000e18); // only alice touched
        assertEq(manager.getPosition(address(eSPY), bob).debt, 1000e18);
    }

    function test_redeem_zeroAmount_reverts() public {
        vm.expectRevert(IEUSDManager.ZeroAmount.selector);
        vm.prank(keeper);
        manager.redeem(address(eSPY), 0, 0, 0, address(0));
    }

    function test_redeem_noPositions_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.NothingToRedeem.selector, address(eSPY)));
        vm.prank(keeper);
        manager.redeem(address(eSPY), 100e18, 0, 0, address(0));
    }

    function test_redeem_stalePrice_stillWorks() public {
        _open(alice, 3e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 500e18);
        vm.warp(block.timestamp + 2 days); // anchor is 2 days old
        vm.prank(keeper);
        (uint256 out,) = manager.redeem(address(eSPY), 500e18, 0, 0, address(0));
        assertEq(out, 1e18);
    }

    function test_redeem_underwaterHead_capsSeizure() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);

        oracle.setPrice(SPY, 400e18); // alice worth $800 < 1000 debt
        vm.prank(keeper);
        (uint256 out, uint256 repaid) = manager.redeem(address(eSPY), 1000e18, 0, 1, address(0));
        assertEq(out, 2e18); // capped at alice's collateral
        assertEq(repaid, 800e18); // burn capped at the collateral's value
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 0);
        assertEq(manager.getPosition(address(eSPY), alice).debt, 200e18); // unbacked residual
        assertEq(manager.listHead(address(eSPY)), bob); // residual is off-list
        assertEq(manager.listSize(address(eSPY)), 1);
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    /// @dev A4-H-01: partial redemption of an underwater head must not strand a zero-collateral
    ///      node at the list head that tolls every later redeemer.
    function test_redeem_underwaterHead_partial_residualOffList_noToll() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);

        oracle.setPrice(SPY, 400e18); // alice worth $800 < 1000 debt
        // amount strictly between collateral value and debt.
        vm.prank(keeper);
        (uint256 out, uint256 repaid) = manager.redeem(address(eSPY), 900e18, 0, 1, address(0));
        assertEq(out, 2e18);
        assertEq(repaid, 800e18);
        assertEq(manager.getPosition(address(eSPY), alice).debt, 200e18);
        assertEq(manager.getPosition(address(eSPY), alice).collateral, 0);
        assertEq(manager.listHead(address(eSPY)), bob);
        _assertListSorted(address(eSPY));

        // Next redeemer is not tolled: 500 eUSD buys exactly $500 of bob's collateral.
        vm.prank(keeper);
        (out, repaid) = manager.redeem(address(eSPY), 500e18, 1.25e18, 0, address(0));
        assertEq(repaid, 500e18);
        assertEq(out, 1.25e18);
        assertEq(manager.getPosition(address(eSPY), alice).debt, 200e18);
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    /// @dev An underwater head no longer blocks the walk: an accurate `minCollateralOut`
    ///      (amount / price) holds because the redeemer pays fair value at every position.
    function test_redeem_underwaterHead_walkContinues_fairValue() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        oracle.setPrice(SPY, 400e18);

        uint256 amount = 1200e18;
        vm.prank(keeper);
        (uint256 out, uint256 repaid) = manager.redeem(address(eSPY), amount, amount * 1e18 / 400e18, 0, address(0));
        assertEq(repaid, amount);
        assertEq(out, 3e18); // 2 from alice ($800) + 1 from bob ($400)
        assertEq(manager.getPosition(address(eSPY), alice).debt, 200e18);
        assertEq(manager.getPosition(address(eSPY), bob).debt, 600e18);
        assertEq(manager.listHead(address(eSPY)), bob);
        assertEq(manager.listSize(address(eSPY)), 1);
    }

    /// @dev The off-list residual is still a normal position for every other path.
    function test_redeem_residual_repayClosesLiquidatesAndRelists() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        _open(carol, 30e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        oracle.setPrice(SPY, 400e18);
        vm.prank(keeper);
        manager.redeem(address(eSPY), 800e18, 0, 1, address(0));
        assertEq(manager.listSize(address(eSPY)), 2);

        // A stale hint pointing at the off-list residual is ignored, not linked into the list.
        vm.prank(carol);
        manager.deposit(address(eSPY), 1e18, alice);
        _assertListSorted(address(eSPY));
        assertEq(manager.listSize(address(eSPY)), 2);

        // Partial repay keeps it off-list; the list is untouched.
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 50e18, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 150e18);
        assertEq(manager.listSize(address(eSPY)), 2);
        _assertListSorted(address(eSPY));

        // Top-up re-lists it at the head ($40 backing 150 debt — riskiest).
        vm.prank(alice);
        manager.deposit(address(eSPY), 0.1e18, address(0));
        assertEq(manager.listHead(address(eSPY)), alice);
        assertEq(manager.listSize(address(eSPY)), 3);
        _assertListSorted(address(eSPY));

        // Liquidating a listed-again residual unlinks it cleanly.
        assertTrue(manager.isLiquidatable(address(eSPY), alice));
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
        assertEq(manager.listSize(address(eSPY)), 2);
        _assertListSorted(address(eSPY));
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    function test_redeem_residual_liquidateAndClose_offList() public {
        oracle.setPrice(SPY, 750e18);
        _open(alice, 2e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        _open(carol, 30e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        oracle.setPrice(SPY, 400e18);
        vm.prank(keeper);
        manager.redeem(address(eSPY), 800e18, 0, 1, address(0));

        // Liquidate the off-list residual: burns 200 for nothing, list stays intact.
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(manager.listSize(address(eSPY)), 2);
        assertEq(manager.listHead(address(eSPY)), carol);
        _assertListSorted(address(eSPY));
        vm.revertToState(snap);

        // Owner closes the off-list residual: same outcome.
        vm.prank(alice);
        manager.closePosition(address(eSPY));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        assertEq(manager.listSize(address(eSPY)), 2);
        assertEq(manager.listHead(address(eSPY)), carol);
        _assertListSorted(address(eSPY));
        assertEq(eusd.totalSupply(), manager.totalDebt());
    }

    // ──────────────────────────────────────────────────────────
    //  Collateral dividends (A4-L-08): swept to the treasury, never stranded
    // ──────────────────────────────────────────────────────────

    /// @dev Real EToken (dividend-bearing) as collateral; this contract acts as MARKET to mint it.
    function _dividendCollateral() internal returns (EToken token, MockERC20 reward) {
        reward = new MockERC20("USDG", "USDG", 6);
        token = new EToken("Own TLT", "eTLT", bytes32("TLT"), address(registry), address(reward));
        vm.startPrank(admin);
        registry.setAddress(keccak256("MARKET"), address(this));
        vm.stopPrank();
        assetRegistry.setOracleType(bytes32("TLT"), 1);
        assetRegistry.setValidToken(bytes32("TLT"), address(token), true);
        oracle.setPrice(bytes32("TLT"), 100e18);
        vm.prank(admin);
        manager.addCollateral(address(token), bytes32("TLT"));
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(address(manager), type(uint256).max);
        reward.mint(address(this), 1_000_000e6);
        reward.approve(address(token), type(uint256).max);
    }

    function test_sweepCollateralRewards_forwardsToTreasury() public {
        (EToken token, MockERC20 reward) = _dividendCollateral();
        vm.prank(alice);
        manager.deposit(address(token), 40e18, address(0)); // manager holds 40 of 100 supply
        token.depositRewards(1000e6); // $1000 dividend → 40% accrues to the manager

        assertEq(token.claimableRewards(address(manager)), 400e6);
        vm.prank(attacker); // permissionless
        uint256 swept = manager.sweepCollateralRewards(address(token));
        assertEq(swept, 400e6);
        assertEq(reward.balanceOf(treasury), 400e6);
        assertEq(reward.balanceOf(address(manager)), 0);
        assertEq(token.claimableRewards(address(manager)), 0);

        // Collateral accounting is untouched by the sweep.
        assertEq(manager.getPosition(address(token), alice).collateral, 40e18);
        assertEq(token.balanceOf(address(manager)), 40e18);
    }

    function test_sweepCollateralRewards_nothingToSweep_reverts() public {
        (EToken token,) = _dividendCollateral();
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.NoRewardsToSweep.selector, address(token)));
        manager.sweepCollateralRewards(address(token));
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralNotSupported.selector, address(eQQQ)));
        manager.sweepCollateralRewards(address(eQQQ));
    }

    // ──────────────────────────────────────────────────────────
    //  Halt (A4-M-04): halted collateral is worth its fixed halt price; wind-down only
    // ──────────────────────────────────────────────────────────

    function test_halt_mintAndWithdrawWithDebt_revert() public {
        _open(alice, 3e18, 1000e18);
        vaultManager.halt(SPY, 100e18);
        oracle.setPrice(SPY, 160e18); // live rallies above halt
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralHalted.selector, SPY));
        manager.mint(address(eSPY), 100e18, address(0));
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralHalted.selector, SPY));
        manager.withdrawCollateral(address(eSPY), 1, address(0));
        // Debt-free withdrawal and top-ups still work.
        manager.deposit(address(eSPY), 1e18, address(0));
        vm.stopPrank();
        _open(bob, 1e18, 0);
        vm.prank(bob);
        manager.withdrawCollateral(address(eSPY), 1e18, address(0));
    }

    /// @dev Trading pause: leverage pauses with trading; exits stay open; resume restores.
    function test_pause_mintAndWithdrawWithDebt_revert_exitsOpen() public {
        _open(alice, 3e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        vaultManager.setTradingPaused(SPY, true);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralPaused.selector, SPY));
        manager.mint(address(eSPY), 100e18, address(0));
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralPaused.selector, SPY));
        manager.withdrawCollateral(address(eSPY), 1, address(0));
        manager.repay(address(eSPY), alice, 100e18, address(0));
        vm.stopPrank();

        oracle.setPrice(SPY, 380e18); // 3 × 380 / 900 = 126.7% → liquidatable during the pause
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
        assertEq(manager.getPosition(address(eSPY), alice).debt, 0);
        vm.prank(keeper);
        manager.redeem(address(eSPY), 100e18, 0, 1, address(0)); // redemption open too

        vaultManager.setTradingPaused(SPY, false);
        oracle.setPrice(SPY, PRICE);
        _open(carol, 3e18, 1000e18); // minting works again
    }

    /// @dev The A4-M-04 attack: buy halted eTokens at halt value, mint at the live valuation.
    function test_halt_attackerCannotMintAgainstLiveValuation() public {
        vaultManager.halt(SPY, 100e18);
        oracle.setPrice(SPY, 160e18);
        vm.startPrank(attacker);
        manager.deposit(address(eSPY), 1000e18, address(0)); // ~$100k of halted eTokens
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.CollateralHalted.selector, SPY));
        manager.mint(address(eSPY), 100_000e18, address(0));
        vm.stopPrank();
    }

    function test_halt_exitsValueAtHaltPrice_feedDead() public {
        _open(alice, 3e18, 1000e18); // $1500 / 1000 at $500
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        vaultManager.halt(SPY, 400e18); // $1200 / 1000 = 120% < 130%
        oracle.setPrice(SPY, 0); // feed dead — must not matter
        assertEq(manager.collateralRatioBps(address(eSPY), alice), 12_000);
        assertTrue(manager.isLiquidatable(address(eSPY), alice));

        // Partial liquidation at the halt price: seized = 400 × 1.05 / 400 = 1.05 eSPY.
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, 400e18, address(0));
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 1.05e18);
        // 1.95 / 600 at $400 = 130% → no longer liquidatable; redeem the rest at $400.
        assertFalse(manager.isLiquidatable(address(eSPY), alice));
        vm.prank(keeper);
        (uint256 out, uint256 repaid) = manager.redeem(address(eSPY), 600e18, 1.5e18, 1, address(0));
        assertEq(repaid, 600e18);
        assertEq(out, 1.5e18);
        IEUSDManager.Position memory p = manager.getPosition(address(eSPY), alice);
        assertEq(p.debt, 0);
        assertEq(p.collateral, 0.45e18);
    }

    function test_halt_liveAboveHalt_doesNotOvervalue() public {
        _open(alice, 3e18, 1000e18);
        vaultManager.halt(SPY, 400e18);
        oracle.setPrice(SPY, 700e18); // live would read 210%
        assertEq(manager.collateralRatioBps(address(eSPY), alice), 12_000);
        assertTrue(manager.isLiquidatable(address(eSPY), alice));
    }

    function test_halt_repayAndCloseStillWork() public {
        _open(alice, 3e18, 1000e18);
        vaultManager.halt(SPY, 100e18);
        oracle.setPrice(SPY, 0);
        vm.startPrank(alice);
        manager.repay(address(eSPY), alice, 500e18, address(0));
        manager.closePosition(address(eSPY));
        vm.stopPrank();
        assertEq(eSPY.balanceOf(alice), 1_000_000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Splits (A4-H-02): legacy collateral is priced through legacyRatioToActive
    // ──────────────────────────────────────────────────────────

    /// @dev Simulate `AssetRegistry.migrateToken(SPY, new, ratio)` landing together with the
    ///      post-split feed: eSPY becomes legacy at `ratio`, the ticker price scales by 1/ratio.
    function _split(
        uint256 ratio
    ) internal {
        assetRegistry.setLegacyRatio(address(eSPY), ratio);
        oracle.setPrice(SPY, PRICE * 1e18 / ratio);
    }

    function test_split_forward_positionValueAndRatioUnchanged() public {
        _open(alice, 3e18, 1000e18); // $1500 / 1000 → 150%
        uint256 before = manager.collateralRatioBps(address(eSPY), alice);
        _split(2e18); // 2:1 — feed halves, 1 old = 2 new
        assertEq(manager.collateralRatioBps(address(eSPY), alice), before);
        assertFalse(manager.isLiquidatable(address(eSPY), alice));
        vm.expectRevert();
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
    }

    function test_split_forward_redeemPaysLegacyUnitsAtFairValue() public {
        _open(alice, 3e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 500e18);
        _split(2e18);
        // 500 eUSD buys $500 = 1 legacy eSPY (=2 new units at $250).
        vm.prank(keeper);
        (uint256 out, uint256 repaid) = manager.redeem(address(eSPY), 500e18, 1e18, 0, address(0));
        assertEq(repaid, 500e18);
        assertEq(out, 1e18);
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 1e18);
    }

    function test_split_forward_liquidationSeizesLegacyUnitsAtEffectivePrice() public {
        _open(alice, 3e18, 1000e18);
        _open(bob, 40e18, 1000e18);
        vm.prank(bob);
        eusd.transfer(keeper, 1000e18);
        _split(2e18);
        // Active feed drops to $200 → effective $400/legacy unit → $1200/1000 = 120% < 130%.
        oracle.setPrice(SPY, 200e18);
        assertEq(manager.collateralRatioBps(address(eSPY), alice), 12_000);
        vm.prank(keeper);
        manager.liquidate(address(eSPY), alice, type(uint256).max, address(0));
        // seized = 1000 × 1.05 / 400 = 2.625 legacy units; 0.375 refunded.
        assertEq(eSPY.balanceOf(keeper), 1_000_000e18 + 2.625e18);
        assertEq(eSPY.balanceOf(alice), 1_000_000e18 - 3e18 + 0.375e18);
    }

    function test_split_reverse_noPhantomWithdrawOrMint() public {
        _open(alice, 3e18, 1000e18); // exactly at MCR
        _split(0.5e18); // 1:2 reverse — feed doubles, 1 old = 0.5 new
        assertEq(manager.collateralRatioBps(address(eSPY), alice), MCR);
        vm.startPrank(alice);
        vm.expectRevert();
        manager.withdrawCollateral(address(eSPY), 1, address(0));
        vm.expectRevert();
        manager.mint(address(eSPY), 100e18, address(0));
        vm.stopPrank();
    }

    function test_split_mintAgainstLegacy_usesEffectivePrice() public {
        _open(alice, 3e18, 0);
        _split(2e18);
        // $1500 of legacy collateral supports at most 1000 eUSD at 150% MCR.
        vm.startPrank(alice);
        vm.expectRevert();
        manager.mint(address(eSPY), 1000e18 + 1, address(0));
        manager.mint(address(eSPY), 1000e18, address(0));
        vm.stopPrank();
        assertEq(manager.collateralRatioBps(address(eSPY), alice), MCR);
    }

    function test_addCollateral_legacyToken_reverts() public {
        assetRegistry.setLegacyRatio(address(eQQQ), 2e18);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.LegacyCollateral.selector, address(eQQQ)));
        vm.prank(admin);
        manager.addCollateral(address(eQQQ), QQQ);
    }

    // ──────────────────────────────────────────────────────────
    //  Sorted list
    // ──────────────────────────────────────────────────────────

    function test_list_ordering_afterMixedOps() public {
        _open(alice, 5e18, 1000e18);
        _open(bob, 3e18, 1000e18);
        _open(carol, 8e18, 1000e18);
        _assertListSorted(address(eSPY));
        assertEq(manager.listHead(address(eSPY)), bob);
        assertEq(manager.listTail(address(eSPY)), carol);

        // Alice deposits more — becomes safest.
        vm.prank(alice);
        manager.deposit(address(eSPY), 5e18, address(0));
        _assertListSorted(address(eSPY));
        assertEq(manager.listTail(address(eSPY)), alice);

        // Carol repays half — ratio doubles, stays safest side.
        vm.prank(carol);
        manager.repay(address(eSPY), carol, 500e18, address(0));
        _assertListSorted(address(eSPY));

        // Bob closes — removed.
        vm.prank(bob);
        manager.closePosition(address(eSPY));
        _assertListSorted(address(eSPY));
        assertEq(manager.listSize(address(eSPY)), 2);
    }

    function test_list_badHint_stillSortsCorrectly() public {
        _open(alice, 5e18, 1000e18);
        _open(bob, 3e18, 1000e18);
        // Garbage hints: not in list / wrong side.
        vm.startPrank(carol);
        manager.deposit(address(eSPY), 4e18, attacker);
        manager.mint(address(eSPY), 1000e18, alice);
        vm.stopPrank();
        _assertListSorted(address(eSPY));
        assertEq(manager.listSize(address(eSPY)), 3);
        assertEq(manager.listHead(address(eSPY)), bob);
    }

    function test_findInsertHint_matchesInsertion() public {
        _open(alice, 5e18, 1000e18);
        _open(bob, 3e18, 1000e18);
        _open(carol, 8e18, 1000e18);
        // A ratio of 4e15 belongs after bob (3e15), before alice (5e15).
        assertEq(manager.findInsertHint(address(eSPY), 4e15), bob);
        // Riskier than everyone — new head.
        assertEq(manager.findInsertHint(address(eSPY), 1e15), address(0));
        // Safer than everyone — after carol.
        assertEq(manager.findInsertHint(address(eSPY), 100e15), carol);
    }

    function test_multiCollateral_independentPositionsAndLists() public {
        vm.prank(admin);
        manager.addCollateral(address(eQQQ), QQQ);
        _open(alice, 3e18, 1000e18);
        vm.startPrank(alice);
        manager.deposit(address(eQQQ), 10e18, address(0)); // $4000 at $400
        manager.mint(address(eQQQ), 2000e18, address(0));
        vm.stopPrank();

        assertEq(manager.getPosition(address(eSPY), alice).debt, 1000e18);
        assertEq(manager.getPosition(address(eQQQ), alice).debt, 2000e18);
        assertEq(manager.totalDebt(), 3000e18);
        assertEq(manager.listSize(address(eSPY)), 1);
        assertEq(manager.listSize(address(eQQQ)), 1);
        assertEq(eusd.balanceOf(alice), 3000e18);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin setters
    // ──────────────────────────────────────────────────────────

    function test_setRiskParams_succeeds() public {
        vm.expectEmit(false, false, false, true);
        emit IEUSDManager.RiskParamsSet(16_000, 14_000, 800);
        vm.prank(admin);
        manager.setRiskParams(16_000, 14_000, 800);
        IEUSDManager.RiskParams memory p = manager.riskParams();
        assertEq(p.mcrBps, 16_000);
        assertEq(p.liquidationThresholdBps, 14_000);
        assertEq(p.liquidationBonusBps, 800);
    }

    function test_setRiskParams_invalid_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(IEUSDManager.InvalidRiskParams.selector);
        manager.setRiskParams(12_000, 13_000, 500); // mcr < threshold
        vm.expectRevert(IEUSDManager.InvalidRiskParams.selector);
        manager.setRiskParams(15_000, 10_400, 500); // threshold < BPS + bonus
        vm.stopPrank();
    }

    function test_setRiskParams_notAdmin_reverts() public {
        vm.expectRevert(IEUSDManager.OnlyAdmin.selector);
        vm.prank(attacker);
        manager.setRiskParams(16_000, 14_000, 800);
    }

    function test_setStabilityFee_aboveBps_reverts() public {
        vm.expectRevert(IEUSDManager.InvalidRiskParams.selector);
        vm.prank(admin);
        manager.setStabilityFee(uint16(BPS) + 1);
    }

    function test_setDebtCeiling_and_minDebt_succeed() public {
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true);
        emit IEUSDManager.DebtCeilingSet(1e18);
        manager.setDebtCeiling(1e18);
        vm.expectEmit(false, false, false, true);
        emit IEUSDManager.MinDebtSet(5e18);
        manager.setMinDebt(5e18);
        vm.stopPrank();
        assertEq(manager.riskParams().debtCeiling, 1e18);
        assertEq(manager.riskParams().minDebt, 5e18);
    }

    function test_setMintPriceMaxAge_zero_reverts() public {
        vm.expectRevert(IEUSDManager.InvalidRiskParams.selector);
        vm.prank(admin);
        manager.setMintPriceMaxAge(0);
    }

    function test_setMintPaused_operatorOnly() public {
        vm.expectRevert(IEUSDManager.OnlyOperator.selector);
        vm.prank(admin);
        manager.setMintPaused(true);

        vm.expectEmit(false, false, false, true);
        emit IEUSDManager.MintPausedSet(true);
        vm.prank(operator);
        manager.setMintPaused(true);
        assertTrue(manager.mintPaused());
    }

    function test_pause_doesNotBlockExits() public {
        _open(alice, 4e18, 1000e18);
        vm.prank(alice);
        eusd.transfer(keeper, 500e18);
        vm.prank(operator);
        manager.setMintPaused(true);

        vm.prank(keeper);
        manager.redeem(address(eSPY), 500e18, 0, 0, address(0));
        vm.prank(alice);
        manager.repay(address(eSPY), alice, 100e18, address(0));
        vm.prank(alice);
        manager.closePosition(address(eSPY));
        assertEq(manager.totalDebt(), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    function test_collateralRatioBps_debtFree_returnsMax() public {
        _open(alice, 3e18, 0);
        assertEq(manager.collateralRatioBps(address(eSPY), alice), type(uint256).max);
        assertFalse(manager.isLiquidatable(address(eSPY), alice));
    }

    function test_currentDebt_includesPendingFees() public {
        _open(alice, 4e18, 1000e18);
        vm.warp(block.timestamp + 182 days);
        uint256 expected = 1000e18 + Math.mulDiv(1000e18, uint256(FEE) * 182 days, BPS * 365 days);
        assertEq(manager.currentDebt(address(eSPY), alice), expected);
    }

    function test_collateralRatio_usesLiveDebt() public {
        _open(alice, 3e18, 1000e18);
        vm.warp(block.timestamp + 365 days);
        // Live debt 1020: CR = 1500e18 * 1e4 / 1020e18 = 14705.
        assertEq(manager.collateralRatioBps(address(eSPY), alice), 14_705);
    }

    function test_nominalRatio_revertsForDebtFree() public {
        _open(alice, 3e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IEUSDManager.NoDebt.selector, address(eSPY), alice));
        manager.nominalRatio(address(eSPY), alice);
    }
}

/// @dev Minimal upgraded implementation used only to prove UUPS upgrade wiring works and storage
///      is preserved. Appends no storage; adds one pure function.
contract EUSDManagerV2 is EUSDManager {
    function version() external pure returns (uint256) {
        return 2;
    }
}
