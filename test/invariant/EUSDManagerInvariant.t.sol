// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSDManager} from "../../src/core/EUSDManager.sol";
import {ProtocolRegistry} from "../../src/core/ProtocolRegistry.sol";
import {IEUSDManager} from "../../src/interfaces/IEUSDManager.sol";
import {EUSD} from "../../src/tokens/EUSD.sol";
import {Actors} from "../helpers/Actors.sol";
import {deployEUSDManager} from "../helpers/DeployEusdModule.sol";
import {MockAssetRegistry} from "../helpers/MockAssetRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {MockOracleVerifier} from "../helpers/MockOracleVerifier.sol";
import {MockVaultManager} from "../helpers/MockVaultManager.sol";
import {EUSDHandler} from "./handlers/EUSDHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @title EUSDManagerInvariantTest — Stateful fuzz invariants for the eUSD CDP module
/// @notice Core invariants after ANY operation sequence:
///         1. eusd.totalSupply() == manager.totalDebt() == Σ stored position debt
///         2. per collateral: manager token balance == totalCollateral == Σ position collateral
///         3. sorted list: ascending nominal ratio, consistent links, exactly the positions with
///            debt > 0 and collateral > 0 (debt-only residuals stay off-list)
///         4. every position is healthy (ratio ≥ threshold) or flagged liquidatable — never both
contract EUSDManagerInvariantTest is Test {
    ProtocolRegistry internal registry;
    MockOracleVerifier internal oracle;
    MockAssetRegistry internal assetRegistry;
    MockVaultManager internal vaultManager;
    MockERC20 internal eSPY;
    MockERC20 internal eQQQ;
    EUSD internal eusd;
    EUSDManager internal manager;
    EUSDHandler internal handler;

    address internal admin = Actors.ADMIN;
    address internal treasury = address(uint160(uint256(keccak256("treasury"))));

    bytes32 internal constant SPY = bytes32("SPY");
    bytes32 internal constant QQQ = bytes32("QQQ");
    uint16 internal constant LIQ_THRESHOLD = 13_000;

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
        vm.stopPrank();

        eSPY = new MockERC20("eSPY", "eSPY", 18);
        eQQQ = new MockERC20("eQQQ", "eQQQ", 18);
        assetRegistry.setOracleType(SPY, 1);
        assetRegistry.setValidToken(SPY, address(eSPY), true);
        assetRegistry.setOracleType(QQQ, 1);
        assetRegistry.setValidToken(QQQ, address(eQQQ), true);

        eusd = new EUSD(admin);
        manager = deployEUSDManager(
            address(registry),
            address(eusd),
            IEUSDManager.RiskParams({
                mcrBps: 15_000,
                liquidationThresholdBps: LIQ_THRESHOLD,
                liquidationBonusBps: 500,
                stabilityFeeBps: 200,
                debtCeiling: 1e33, // effectively unbounded — the ceiling is unit-tested
                minDebt: 100e18,
                mintPriceMaxAge: 300
            })
        );
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(manager));
        manager.addCollateral(address(eSPY), SPY);
        manager.addCollateral(address(eQQQ), QQQ);
        vm.stopPrank();

        oracle.setPrice(SPY, 500e18);
        oracle.setPrice(QQQ, 400e18);

        address[] memory actorList = new address[](4);
        actorList[0] = Actors.MINTER1;
        actorList[1] = Actors.MINTER2;
        actorList[2] = Actors.LP1;
        actorList[3] = Actors.LIQUIDATOR;

        handler = new EUSDHandler(
            manager, eusd, oracle, [eSPY, eQQQ], [SPY, QQQ], [uint256(500e18), uint256(400e18)], actorList
        );
        targetContract(address(handler));
    }

    // ──────────────────────────────────────────────────────────
    //  Invariants
    // ──────────────────────────────────────────────────────────

    /// @dev totalSupply == totalDebt == Σ stored position debt across both collaterals.
    function invariant_supplyEqualsTotalDebtEqualsSumOfPositions() public view {
        assertEq(eusd.totalSupply(), manager.totalDebt(), "supply != totalDebt");

        uint256 sum;
        address[] memory actorList = handler.actors();
        address[2] memory colls = handler.collaterals();
        for (uint256 c; c < 2; c++) {
            for (uint256 i; i < actorList.length; i++) {
                sum += manager.getPosition(colls[c], actorList[i]).debt;
            }
        }
        assertEq(manager.totalDebt(), sum, "totalDebt != sum of position debt");
    }

    /// @dev Manager's token balance == totalCollateral == Σ position collateral, per collateral.
    function invariant_collateralAccounting() public view {
        address[] memory actorList = handler.actors();
        address[2] memory colls = handler.collaterals();
        for (uint256 c; c < 2; c++) {
            uint256 sum;
            for (uint256 i; i < actorList.length; i++) {
                sum += manager.getPosition(colls[c], actorList[i]).collateral;
            }
            assertEq(manager.totalCollateral(colls[c]), sum, "totalCollateral != sum");
            assertEq(MockERC20(colls[c]).balanceOf(address(manager)), sum, "token balance != sum");
        }
    }

    /// @dev The sorted list holds exactly the positions with debt and collateral, in ascending
    ///      nominal-ratio order with consistent prev/next links; no listed node is collateral-free.
    function invariant_listSortedAndComplete() public view {
        address[] memory actorList = handler.actors();
        address[2] memory colls = handler.collaterals();
        for (uint256 c; c < 2; c++) {
            uint256 count;
            uint256 lastRatio;
            address lastNode;
            address node = manager.listHead(colls[c]);
            while (node != address(0)) {
                assertGt(manager.getPosition(colls[c], node).collateral, 0, "collateral-free node listed");
                uint256 ratio = manager.nominalRatio(colls[c], node);
                assertGe(ratio, lastRatio, "list not ascending");
                assertEq(manager.listPrev(colls[c], node), lastNode, "prev link broken");
                lastRatio = ratio;
                lastNode = node;
                node = manager.listNext(colls[c], node);
                count++;
            }
            assertEq(manager.listTail(colls[c]), lastNode, "tail mismatch");
            assertEq(manager.listSize(colls[c]), count, "size mismatch");

            uint256 listable;
            for (uint256 i; i < actorList.length; i++) {
                IEUSDManager.Position memory p = manager.getPosition(colls[c], actorList[i]);
                if (p.debt > 0 && p.collateral > 0) listable++;
            }
            assertEq(listable, count, "listable position count mismatch");
        }
    }

    /// @dev Every debt-bearing position is healthy or liquidatable, and the liquidatable flag is
    ///      exactly consistent with the live ratio.
    function invariant_healthyOrLiquidatable() public view {
        address[] memory actorList = handler.actors();
        address[2] memory colls = handler.collaterals();
        for (uint256 c; c < 2; c++) {
            for (uint256 i; i < actorList.length; i++) {
                uint256 ratio = manager.collateralRatioBps(colls[c], actorList[i]);
                bool liquidatable = manager.isLiquidatable(colls[c], actorList[i]);
                if (ratio >= LIQ_THRESHOLD) {
                    assertFalse(liquidatable, "healthy but liquidatable");
                } else {
                    assertTrue(liquidatable, "unhealthy but not liquidatable");
                }
            }
        }
    }

    /// @dev Ghost mint/burn flows reconcile with outstanding supply plus treasury fee mints.
    function invariant_ghostFlowsReconcile() public view {
        // minted - burned == supply held outside the treasury's fee income is not directly
        // trackable (fees mint without a handler action), but supply must never be less than
        // net user mints minus burns.
        assertGe(eusd.totalSupply() + handler.ghost_totalBurned(), handler.ghost_totalMinted(), "supply lost tokens");
    }
}
