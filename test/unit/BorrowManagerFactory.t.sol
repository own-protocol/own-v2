// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AaveBorrowManager} from "../../src/core/AaveBorrowManager.sol";
import {BorrowManagerFactory} from "../../src/core/BorrowManagerFactory.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {IBorrowManagerFactory} from "../../src/interfaces/IBorrowManagerFactory.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveDebtToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title BorrowManagerFactory Unit Tests
/// @notice Covers admin gating, 1:1 binding, vault validation, and the
///         deployment of a working AaveBorrowManager.
contract BorrowManagerFactoryTest is BaseTest {
    BorrowManagerFactory public factory;
    MockAaveV3Pool public aavePool;
    MockAToken public awstETH;
    MockAaveDebtToken public usdcDebt;
    OwnVault public vault;
    VaultFactory public vaultFactory;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        aavePool = new MockAaveV3Pool();
        awstETH = MockAToken(aavePool.registerReserve(address(wstETH), "Aave wstETH", "awstETH", 18));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), makeAddr("market"));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        vaultFactory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(vaultFactory));

        // Vault is created via VaultFactory so isRegisteredVault() returns true.
        vault = OwnVault(vaultFactory.createVault(address(awstETH), Actors.VM1, "OwnAwstETH", "owAwstETH", 8000, 2000));

        factory = new BorrowManagerFactory(address(aavePool), address(protocolRegistry));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(factory.aavePool(), address(aavePool));
        assertEq(factory.registry(), address(protocolRegistry));
    }

    function test_constructor_zeroAddresses_revert() public {
        vm.expectRevert(IBorrowManagerFactory.ZeroAddress.selector);
        new BorrowManagerFactory(address(0), address(protocolRegistry));
        vm.expectRevert(IBorrowManagerFactory.ZeroAddress.selector);
        new BorrowManagerFactory(address(aavePool), address(0));
    }

    // ──────────────────────────────────────────────────────────
    //  createBorrowManager
    // ──────────────────────────────────────────────────────────

    function test_create_succeeds_records1to1Binding() public {
        InterestRateModel.Params memory p = _params();
        vm.prank(Actors.ADMIN);
        address bm = factory.createBorrowManager(address(vault), address(usdc), address(usdcDebt), p);

        assertNotEq(bm, address(0));
        assertEq(factory.borrowManagerOf(address(vault)), bm);
        assertEq(factory.vaultOf(bm), address(vault));

        // Manager wired correctly.
        AaveBorrowManager mgr = AaveBorrowManager(bm);
        assertEq(mgr.vault(), address(vault));
        assertEq(mgr.stablecoin(), address(usdc));
        assertEq(mgr.debtToken(), address(usdcDebt));
        assertEq(mgr.aavePool(), address(aavePool));
    }

    function test_create_emitsEvent() public {
        InterestRateModel.Params memory p = _params();
        vm.prank(Actors.ADMIN);
        vm.expectEmit(true, false, false, false);
        emit IBorrowManagerFactory.BorrowManagerCreated(address(vault), address(0));
        factory.createBorrowManager(address(vault), address(usdc), address(usdcDebt), p);
    }

    function test_create_alreadyExists_reverts() public {
        InterestRateModel.Params memory p = _params();
        vm.prank(Actors.ADMIN);
        factory.createBorrowManager(address(vault), address(usdc), address(usdcDebt), p);

        vm.prank(Actors.ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(IBorrowManagerFactory.VaultAlreadyHasBorrowManager.selector, address(vault))
        );
        factory.createBorrowManager(address(vault), address(usdc), address(usdcDebt), p);
    }

    function test_create_unknownVault_reverts() public {
        OwnVault stranger =
            new OwnVault(address(awstETH), "Stranger", "S", address(protocolRegistry), Actors.VM2, 8000, 2000);

        InterestRateModel.Params memory p = _params();
        vm.prank(Actors.ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IBorrowManagerFactory.UnknownVault.selector, address(stranger)));
        factory.createBorrowManager(address(stranger), address(usdc), address(usdcDebt), p);
    }

    function test_create_zeroAddresses_revert() public {
        InterestRateModel.Params memory p = _params();
        vm.startPrank(Actors.ADMIN);
        vm.expectRevert(IBorrowManagerFactory.ZeroAddress.selector);
        factory.createBorrowManager(address(0), address(usdc), address(usdcDebt), p);
        vm.expectRevert(IBorrowManagerFactory.ZeroAddress.selector);
        factory.createBorrowManager(address(vault), address(0), address(usdcDebt), p);
        vm.expectRevert(IBorrowManagerFactory.ZeroAddress.selector);
        factory.createBorrowManager(address(vault), address(usdc), address(0), p);
        vm.stopPrank();
    }

    function test_create_onlyAdmin() public {
        InterestRateModel.Params memory p = _params();
        vm.prank(Actors.ATTACKER);
        vm.expectRevert(IBorrowManagerFactory.OnlyAdmin.selector);
        factory.createBorrowManager(address(vault), address(usdc), address(usdcDebt), p);
    }
}
