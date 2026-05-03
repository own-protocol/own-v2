// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {LPBorrowManager} from "../../src/core/LPBorrowManager.sol";
import {OwnVault} from "../../src/core/OwnVault.sol";
import {VaultBorrowCoordinator} from "../../src/core/VaultBorrowCoordinator.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {ILPBorrowManager} from "../../src/interfaces/ILPBorrowManager.sol";
import {AssetConfig, BPS, PRECISION} from "../../src/interfaces/types/Types.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {EToken} from "../../src/tokens/EToken.sol";

import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockAToken, MockAaveDebtToken, MockAaveV3Pool} from "../helpers/MockAaveV3Pool.sol";
import {MockOwnMarket} from "../helpers/MockOwnMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPBorrowAndMintFlow — End-to-end LP borrow + place mint order via multicall
/// @notice Verifies the headline LP UX: a single transaction borrows USDC
///         against vault shares AND queues a mint order, then on order
///         confirmation the LP claims the minted eTokens. Exercises the
///         pass-through fee-reward redirect on collateral return.
contract LPBorrowAndMintFlowTest is BaseTest {
    AssetRegistry public assetRegistry;
    EToken public eTSLA;
    MockAaveV3Pool public aavePool;
    MockAToken public awstETH;
    MockAaveDebtToken public usdcDebt;
    VaultFactory public vaultFactory;
    OwnVault public vault;
    VaultBorrowCoordinator public coordinator;
    LPBorrowManager public lpManager;
    MockOwnMarket public mockMarket;

    bytes32 constant COLLAT = bytes32("WSTETH");
    bytes32 constant ASSET = bytes32("TSLA");
    uint256 constant WSTETH_PX = 4000e18;
    uint256 constant TSLA_PX = 250e18;

    function _params() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({basePremiumBps: 100, optimalUtilBps: 8000, slope1Bps: 400, slope2Bps: 7500});
    }

    function setUp() public override {
        super.setUp();

        // Aave wiring.
        aavePool = new MockAaveV3Pool();
        awstETH = MockAToken(aavePool.registerReserve(address(wstETH), "Aave wstETH", "awstETH", 18));
        usdcDebt = MockAaveDebtToken(aavePool.deployVariableDebtToken(address(usdc)));
        usdc.mint(address(aavePool), 10_000_000e6);

        // Mock OwnMarket — registered on protocol registry as MARKET.
        mockMarket = new MockOwnMarket();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(mockMarket));
        protocolRegistry.setAddress(protocolRegistry.TREASURY(), Actors.FEE_RECIPIENT);
        protocolRegistry.setProtocolShareBps(2000);

        assetRegistry = new AssetRegistry(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetRegistry));

        vaultFactory = new VaultFactory(Actors.ADMIN, address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), address(vaultFactory));
        vault =
            OwnVault(vaultFactory.createVault(address(awstETH), address(this), "Own awstETH", "owawstETH", 8000, 2000));
        vm.stopPrank();

        // eTSLA — the asset we'll mint into.
        eTSLA = new EToken("Own TSLA", "eTSLA", ASSET, address(protocolRegistry), address(usdc));
        AssetConfig memory tslaCfg = AssetConfig({
            activeToken: address(eTSLA),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(ASSET, address(eTSLA), tslaCfg);

        // WSTETH — collateral oracle asset for the vault.
        AssetConfig memory wstCfg = AssetConfig({
            activeToken: address(awstETH),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        vm.prank(Actors.ADMIN);
        assetRegistry.addAsset(COLLAT, address(awstETH), wstCfg);
        _setOraclePrice(COLLAT, WSTETH_PX);
        _setOraclePrice(ASSET, TSLA_PX);

        // Vault payment token + collateral oracle.
        vault.setPaymentToken(address(usdc));
        vm.prank(Actors.ADMIN);
        vault.setCollateralOracleAsset(COLLAT);

        // Coordinator + LPBorrowManager.
        vm.prank(Actors.ADMIN);
        coordinator = new VaultBorrowCoordinator(
            address(vault), address(aavePool), address(protocolRegistry), address(usdc), 3500
        );
        vm.prank(Actors.ADMIN);
        lpManager = new LPBorrowManager(
            address(vault),
            address(usdc),
            address(usdcDebt),
            address(aavePool),
            address(mockMarket),
            address(protocolRegistry),
            address(coordinator),
            COLLAT,
            _params()
        );

        // Wire up: delegation, custodian flag, coordinator registration, eToken target.
        vm.prank(Actors.ADMIN);
        vault.enableLending(makeAddr("userBMStub"), address(lpManager), address(usdcDebt));
        vm.prank(Actors.ADMIN);
        vault.setShareCustodian(address(lpManager), true);
        vm.prank(Actors.ADMIN);
        coordinator.registerManager(address(lpManager));
        mockMarket.registerEToken(ASSET, address(eTSLA));

        // Seed LP1 with collateral and mint into the vault for shares.
        vm.prank(address(aavePool));
        awstETH.mint(Actors.LP1, 100e18);
        vm.startPrank(Actors.LP1);
        IERC20(address(awstETH)).approve(address(vault), 100e18);
        vault.deposit(100e18, Actors.LP1);
        vm.stopPrank();

        vault.updateCollateralValuation();
    }

    function _priceData(
        uint256 px
    ) internal view returns (bytes memory) {
        return abi.encode(px, block.timestamp);
    }

    /// @dev Headline flow: LP atomically borrows AND places a mint order in
    ///      one transaction via Multicall. Then the (mocked) VM confirms the
    ///      order; the LP claims the minted eTokens.
    function test_endToEnd_borrowAndPlaceMintOrder_viaMulticall() public {
        uint256 sharesAmount = 50e18;
        uint256 stable = 50_000e6;

        // LP approves shares for the manager.
        vm.prank(Actors.LP1);
        IERC20(address(vault)).approve(address(lpManager), sharesAmount);

        // Build the multicall payload: borrow + placeMintOrder.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(ILPBorrowManager.borrow.selector, sharesAmount, stable, _priceData(WSTETH_PX));
        calls[1] = abi.encodeWithSelector(
            ILPBorrowManager.placeMintOrder.selector, ASSET, stable, TSLA_PX, block.timestamp + 1 days
        );

        vm.prank(Actors.LP1);
        bytes[] memory results = lpManager.multicall(calls);

        // Decode the orderId returned by placeMintOrder.
        uint256 orderId = abi.decode(results[1], (uint256));
        assertGt(orderId, 0, "order placed");

        // Manager held custody, paid out USDC to OwnMarket, recorded the order.
        assertEq(vault.balanceOf(address(lpManager)), sharesAmount);
        assertEq(usdc.balanceOf(address(mockMarket)), stable);
        assertEq(lpManager.lpStablecoinBalance(Actors.LP1), 0, "stable went to OwnMarket");

        // VM confirms (test harness; mints eTokens to manager — the order user).
        mockMarket.forceConfirm(orderId);

        // Manager now holds the minted eTokens.
        // Mock has no fee, so mintedAmount = 50_000e6 * 1e12 * 1e18 / 250e18 = 200e18.
        uint256 expectedMinted = 200e18;
        assertEq(eTSLA.balanceOf(address(lpManager)), expectedMinted);

        // LP claims — eTokens land on LP.
        // The on-chain manager re-derives the mint amount via the FeeCalculator;
        // protocol registry has no FeeCalculator wired, so the staticcall returns
        // empty and the manager defaults fee=0, matching the mock's mint exactly.
        lpManager.claimMintedETokens(orderId);
        assertEq(eTSLA.balanceOf(Actors.LP1), expectedMinted);
        assertEq(eTSLA.balanceOf(address(lpManager)), 0);
        assertTrue(lpManager.orderRef(orderId).claimed);
    }

    /// @dev Pass-through redirect: fees deposited while shares are held by
    ///      the manager land in the LP's claimable bucket on repay.
    function test_endToEnd_passThroughOnRepay() public {
        uint256 sharesAmount = 50e18;
        uint256 stable = 50_000e6;
        vm.startPrank(Actors.LP1);
        IERC20(address(vault)).approve(address(lpManager), sharesAmount);
        lpManager.borrow(sharesAmount, stable, _priceData(WSTETH_PX));
        lpManager.withdrawBorrowed(stable);
        vm.stopPrank();

        // Drive a fee deposit via the mock market (which is registered as MARKET).
        usdc.mint(address(mockMarket), 1000e6);
        vm.startPrank(address(mockMarket));
        usdc.approve(address(vault), 1000e6);
        vault.depositFees(address(usdc), 1000e6);
        vm.stopPrank();

        // LP repays. Manager's accrued bucket should drain into the LP's bucket.
        usdc.mint(Actors.LP1, stable);
        vm.startPrank(Actors.LP1);
        usdc.approve(address(lpManager), stable);
        lpManager.repay(type(uint256).max);
        vm.stopPrank();

        assertEq(vault.claimableLPRewards(address(lpManager)), 0);
        // LP slice = 64% of 1000e6.
        assertApproxEqAbs(vault.claimableLPRewards(Actors.LP1), 640e6, 2);
    }
}
