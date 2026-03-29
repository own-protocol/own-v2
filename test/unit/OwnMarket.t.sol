// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {IVaultManager} from "../../src/interfaces/IVaultManager.sol";
import {AssetConfig} from "../../src/interfaces/types/Types.sol";
import {
    BPS,
    Order,
    OrderStatus,
    OrderType,
    PRECISION,
    VMConfig
} from "../../src/interfaces/types/Types.sol";

import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnMarket Unit Tests
/// @notice Tests order placement (mint/redeem), claiming, confirming,
///         cancelling, expiry, and access control.
/// @dev Uses mock dependencies: MockOracleVerifier, MockERC20 for stablecoins,
///      and a mock eToken. The actual VaultManager, OwnVault, and AssetRegistry
///      are mocked via interfaces.
contract OwnMarketTest is BaseTest {
    OwnMarket public market;
    AssetRegistry public assetReg;
    FeeCalculator public feeCalc;

    MockERC20 public eTSLAToken;

    // Mock contract addresses acting as dependencies
    address public mockVaultManager = makeAddr("vaultManager");
    address public mockVault = makeAddr("vault");
    uint256 constant DEFAULT_EXPIRY_OFFSET = 1 days;

    function setUp() public override {
        super.setUp();

        eTSLAToken = new MockERC20("Own TSLA", "eTSLA", 18);
        vm.label(address(eTSLAToken), "eTSLA");

        // Deploy real AssetRegistry and register TSLA
        vm.startPrank(Actors.ADMIN);
        assetReg = new AssetRegistry(Actors.ADMIN);
        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLAToken),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2
        });
        assetReg.addAsset(TSLA, address(eTSLAToken), config);
        vm.stopPrank();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ORACLE_VERIFIER(), address(oracle));
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetReg));
        protocolRegistry.setAddress(protocolRegistry.VAULT_MANAGER(), mockVaultManager);

        // Deploy FeeCalculator with zero fees so existing math tests remain unchanged
        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        // OwnMarket constructor now takes (registry_, vault_, gracePeriod_, claimThreshold_)
        market = new OwnMarket(address(protocolRegistry), mockVault, 1 days, 6 hours);
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));
        vm.stopPrank();
        vm.label(address(market), "OwnMarket");

        // Mock the vault's payment token
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.paymentToken.selector), abi.encode(address(usdc)));

        // Setup default oracle price
        _setOraclePrice(TSLA, TSLA_PRICE);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _defaultExpiry() internal view returns (uint256) {
        return block.timestamp + DEFAULT_EXPIRY_OFFSET;
    }

    /// @dev New placeMintOrder signature: (asset, amount, price, expiry)
    function _placeMintOrder(address minter, uint256 stablecoinAmount) internal returns (uint256 orderId) {
        usdc.mint(minter, stablecoinAmount);
        vm.startPrank(minter);
        usdc.approve(address(market), stablecoinAmount);
        orderId = market.placeMintOrder(
            TSLA,
            stablecoinAmount,
            TSLA_PRICE,
            _defaultExpiry()
        );
        vm.stopPrank();
    }

    /// @dev New placeRedeemOrder signature: (asset, amount, price, expiry)
    function _placeRedeemOrder(address minter, uint256 eTokenAmount) internal returns (uint256 orderId) {
        eTSLAToken.mint(minter, eTokenAmount);
        vm.startPrank(minter);
        eTSLAToken.approve(address(market), eTokenAmount);
        orderId = market.placeRedeemOrder(
            TSLA,
            eTokenAmount,
            TSLA_PRICE,
            _defaultExpiry()
        );
        vm.stopPrank();
    }

    function _mockVaultManager(
        address vmAddr
    ) internal {
        VMConfig memory config =
            VMConfig({maxExposure: 0, currentExposure: 0, registered: true, active: true});
        vm.mockCall(mockVaultManager, abi.encodeCall(IVaultManager.getVMConfig, (vmAddr)), abi.encode(config));
        vm.mockCall(mockVaultManager, abi.encodeCall(IVaultManager.getVMVault, (vmAddr)), abi.encode(mockVault));
        vm.mockCall(
            mockVaultManager, abi.encodeWithSelector(IVaultManager.updateExposure.selector), abi.encode()
        );
        // Mock depositFees on the vault (mockVault is a makeAddr, not a real contract)
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.depositFees.selector), abi.encode());
    }

    // ──────────────────────────────────────────────────────────
    //  placeMintOrder
    // ──────────────────────────────────────────────────────────

    function test_placeMintOrder_succeeds() public {
        uint256 amount = 1000e6;
        usdc.mint(Actors.MINTER1, amount);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderPlaced(1, Actors.MINTER1, uint8(OrderType.Mint), TSLA, amount);

        uint256 orderId = market.placeMintOrder(
            TSLA, amount, TSLA_PRICE, _defaultExpiry()
        );
        vm.stopPrank();

        assertEq(orderId, 1);

        // Stablecoins should be escrowed
        assertEq(usdc.balanceOf(address(market)), amount);
        assertEq(usdc.balanceOf(Actors.MINTER1), 0);

        // Order data
        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint256(order.orderType), uint256(OrderType.Mint));
        assertEq(order.asset, TSLA);
        assertEq(order.amount, amount);
        assertEq(uint256(order.status), uint256(OrderStatus.Open));
    }

    function test_placeMintOrder_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.placeMintOrder(
            TSLA, 0, TSLA_PRICE, _defaultExpiry()
        );
    }

    function test_placeMintOrder_pastExpiry_reverts() public {
        uint256 amount = 1000e6;
        usdc.mint(Actors.MINTER1, amount);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);
        vm.expectRevert(IOwnMarket.InvalidExpiry.selector);
        market.placeMintOrder(
            TSLA, amount, TSLA_PRICE, block.timestamp - 1
        );
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  placeRedeemOrder
    // ──────────────────────────────────────────────────────────

    function test_placeRedeemOrder_succeeds() public {
        uint256 eTokenAmount = 4e18; // 4 eTSLA
        eTSLAToken.mint(Actors.MINTER1, eTokenAmount);

        vm.startPrank(Actors.MINTER1);
        eTSLAToken.approve(address(market), eTokenAmount);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderPlaced(1, Actors.MINTER1, uint8(OrderType.Redeem), TSLA, eTokenAmount);

        uint256 orderId = market.placeRedeemOrder(
            TSLA, eTokenAmount, TSLA_PRICE, _defaultExpiry()
        );
        vm.stopPrank();

        // eTokens should be escrowed
        assertEq(eTSLAToken.balanceOf(address(market)), eTokenAmount);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.orderType), uint256(OrderType.Redeem));
        assertEq(order.amount, eTokenAmount);
    }

    // ──────────────────────────────────────────────────────────
    //  claimOrder — now takes only (orderId)
    // ──────────────────────────────────────────────────────────

    function test_claimOrder_succeeds() public {
        _mockVaultManager(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.expectEmit(true, true, false, false);
        emit IOwnMarket.OrderClaimed(orderId, Actors.VM1);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Claimed));
        assertEq(order.vm, Actors.VM1);
    }

    // ──────────────────────────────────────────────────────────
    //  confirmOrder — now takes only (orderId)
    // ──────────────────────────────────────────────────────────

    function test_confirmOrder_mint_succeeds() public {
        _mockVaultManager(Actors.VM1);

        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Confirmed));

        // Minter should have received eTokens
        assertGt(eTSLAToken.balanceOf(Actors.MINTER1), 0);
    }

    // ──────────────────────────────────────────────────────────
    //  cancelOrder
    // ──────────────────────────────────────────────────────────

    function test_cancelOrder_returnsEscrowedStablecoins() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.expectEmit(true, true, false, false);
        emit IOwnMarket.OrderCancelled(orderId, Actors.MINTER1);

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        assertEq(usdc.balanceOf(Actors.MINTER1), 1000e6);
        assertEq(usdc.balanceOf(address(market)), 0);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Cancelled));
    }

    function test_cancelOrder_notOwner_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId));
        market.cancelOrder(orderId);
    }

    // ──────────────────────────────────────────────────────────
    //  expireOrder
    // ──────────────────────────────────────────────────────────

    function test_expireOrder_afterExpiry_succeeds() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.expectEmit(true, false, false, false);
        emit IOwnMarket.OrderExpired(orderId);

        market.expireOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Expired));

        // Escrowed stablecoins returned
        assertEq(usdc.balanceOf(Actors.MINTER1), 1000e6);
    }

    function test_expireOrder_beforeExpiry_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ExpiryNotReached.selector, orderId));
        market.expireOrder(orderId);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    function test_getOrder_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OrderNotFound.selector, 999));
        market.getOrder(999);
    }

    function test_getOpenOrders_returnsOpenOnly() public {
        _placeMintOrder(Actors.MINTER1, 1000e6);
        _placeMintOrder(Actors.MINTER2, 2000e6);

        uint256[] memory openOrders = market.getOpenOrders(TSLA);
        assertEq(openOrders.length, 2);
    }

    function test_getUserOrders_returnsUserOrders() public {
        _placeMintOrder(Actors.MINTER1, 1000e6);
        _placeMintOrder(Actors.MINTER1, 500e6);
        _placeMintOrder(Actors.MINTER2, 2000e6);

        uint256[] memory m1Orders = market.getUserOrders(Actors.MINTER1);
        assertEq(m1Orders.length, 2);

        uint256[] memory m2Orders = market.getUserOrders(Actors.MINTER2);
        assertEq(m2Orders.length, 1);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_placeMintOrder_anyAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);

        usdc.mint(Actors.MINTER1, amount);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        uint256 orderId = market.placeMintOrder(
            TSLA, amount, TSLA_PRICE, _defaultExpiry()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.amount, amount);
        assertEq(usdc.balanceOf(address(market)), amount);
    }
}
