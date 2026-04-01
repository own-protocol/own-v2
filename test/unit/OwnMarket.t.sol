// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssetRegistry} from "../../src/core/AssetRegistry.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";

import {IOwnVault} from "../../src/interfaces/IOwnVault.sol";
import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";
import {AssetConfig, BPS, Order, OrderStatus, OrderType, PRECISION} from "../../src/interfaces/types/Types.sol";

import {FeeCalculator} from "../../src/core/FeeCalculator.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OwnMarketTest is BaseTest {
    OwnMarket public market;
    AssetRegistry public assetReg;
    FeeCalculator public feeCalc;

    MockERC20 public eTSLAToken;

    address public mockVault = makeAddr("vault");
    address public mockFactory = makeAddr("factory");

    uint256 constant DEFAULT_EXPIRY_OFFSET = 1 days;
    uint256 constant GRACE_PERIOD = 1 days;
    uint256 constant CLAIM_THRESHOLD = 6 hours;

    function setUp() public override {
        super.setUp();

        eTSLAToken = new MockERC20("Own TSLA", "eTSLA", 18);
        vm.label(address(eTSLAToken), "eTSLA");

        vm.startPrank(Actors.ADMIN);
        assetReg = new AssetRegistry(Actors.ADMIN);
        AssetConfig memory config = AssetConfig({
            activeToken: address(eTSLAToken),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 2,
            oracleType: 1
        });
        assetReg.addAsset(TSLA, address(eTSLAToken), config);
        vm.stopPrank();

        vm.startPrank(Actors.ADMIN);
        protocolRegistry.setAddress(protocolRegistry.ASSET_REGISTRY(), address(assetReg));
        feeCalc = new FeeCalculator(address(protocolRegistry), Actors.ADMIN);
        feeCalc.setMintFee(1, 0);
        feeCalc.setMintFee(2, 0);
        feeCalc.setMintFee(3, 0);
        feeCalc.setRedeemFee(1, 0);
        feeCalc.setRedeemFee(2, 0);
        feeCalc.setRedeemFee(3, 0);
        protocolRegistry.setAddress(keccak256("FEE_CALCULATOR"), address(feeCalc));

        protocolRegistry.setAddress(protocolRegistry.VAULT_FACTORY(), mockFactory);
        market = new OwnMarket(address(protocolRegistry));
        protocolRegistry.setAddress(protocolRegistry.MARKET(), address(market));

        // Configure ETH oracle for force execution collateral conversion
        bytes32 ethAsset = bytes32("ETH");
        AssetConfig memory ethConfig = AssetConfig({
            activeToken: address(0),
            legacyTokens: new address[](0),
            active: true,
            volatilityLevel: 1,
            oracleType: 1
        });
        assetReg.addAsset(ethAsset, address(weth), ethConfig);

        vm.stopPrank();
        vm.label(address(market), "OwnMarket");

        // Mock the factory's isRegisteredVault
        vm.mockCall(
            mockFactory, abi.encodeWithSelector(IVaultFactory.isRegisteredVault.selector, mockVault), abi.encode(true)
        );

        // Mock the vault's payment token, collateral release, grace period, claim threshold, collateral oracle asset, and asset support
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.paymentToken.selector), abi.encode(address(usdc)));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.releaseCollateral.selector), abi.encode());
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.gracePeriod.selector), abi.encode(GRACE_PERIOD));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.claimThreshold.selector), abi.encode(CLAIM_THRESHOLD));
        vm.mockCall(
            mockVault, abi.encodeWithSelector(IOwnVault.collateralOracleAsset.selector), abi.encode(bytes32("ETH"))
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isAssetSupported.selector), abi.encode(true));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyPaused.selector), abi.encode(false));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.isEffectivelyHalted.selector), abi.encode(false));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.getAssetHaltPrice.selector), abi.encode(uint256(0)));

        _setOraclePrice(TSLA, TSLA_PRICE);
        _setOraclePrice(ethAsset, ETH_PRICE);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _defaultExpiry() internal view returns (uint256) {
        return block.timestamp + DEFAULT_EXPIRY_OFFSET;
    }

    function _placeMintOrder(address minter, uint256 stablecoinAmount) internal returns (uint256 orderId) {
        usdc.mint(minter, stablecoinAmount);
        vm.startPrank(minter);
        usdc.approve(address(market), stablecoinAmount);
        orderId = market.placeMintOrder(mockVault, TSLA, stablecoinAmount, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();
    }

    function _placeRedeemOrder(address minter, uint256 eTokenAmount) internal returns (uint256 orderId) {
        eTSLAToken.mint(minter, eTokenAmount);
        vm.startPrank(minter);
        eTSLAToken.approve(address(market), eTokenAmount);
        orderId = market.placeRedeemOrder(mockVault, TSLA, eTokenAmount, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();
    }

    function _mockVault(
        address vmAddr
    ) internal {
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.vm.selector), abi.encode(vmAddr));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.updateExposure.selector), abi.encode());
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.depositFees.selector), abi.encode());
        vm.mockCall(
            mockVault, abi.encodeWithSelector(IOwnVault.projectedExposureUtilization.selector), abi.encode(uint256(0))
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.maxUtilization.selector), abi.encode(uint256(BPS)));
    }

    function _claimOrder(address vmAddr, uint256 orderId) internal {
        vm.prank(vmAddr);
        market.claimOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  placeMintOrder
    // ══════════════════════════════════════════════════════════

    function test_placeMintOrder_succeeds() public {
        uint256 amount = 1000e6;
        usdc.mint(Actors.MINTER1, amount);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderPlaced(1, Actors.MINTER1, uint8(OrderType.Mint), TSLA, mockVault, amount);

        uint256 orderId = market.placeMintOrder(mockVault, TSLA, amount, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();

        assertEq(orderId, 1);
        assertEq(usdc.balanceOf(address(market)), amount);
        assertEq(usdc.balanceOf(Actors.MINTER1), 0);

        Order memory order = market.getOrder(orderId);
        assertEq(order.user, Actors.MINTER1);
        assertEq(uint256(order.orderType), uint256(OrderType.Mint));
        assertEq(order.asset, TSLA);
        assertEq(order.amount, amount);
        assertEq(order.price, TSLA_PRICE);
        assertEq(uint256(order.status), uint256(OrderStatus.Open));
        assertEq(order.vm, address(0));
        assertEq(order.claimedAt, 0);
    }

    function test_placeMintOrder_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.placeMintOrder(mockVault, TSLA, 0, TSLA_PRICE, _defaultExpiry());
    }

    function test_placeMintOrder_zeroPrice_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.InvalidPrice.selector);
        market.placeMintOrder(mockVault, TSLA, 1000e6, 0, _defaultExpiry());
    }

    function test_placeMintOrder_pastExpiry_reverts() public {
        uint256 amount = 1000e6;
        usdc.mint(Actors.MINTER1, amount);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);
        vm.expectRevert(IOwnMarket.InvalidExpiry.selector);
        market.placeMintOrder(mockVault, TSLA, amount, TSLA_PRICE, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_placeMintOrder_inactiveAsset_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.AssetNotActive.selector, bytes32("FAKE")));
        market.placeMintOrder(mockVault, bytes32("FAKE"), 1000e6, TSLA_PRICE, _defaultExpiry());
    }

    // ══════════════════════════════════════════════════════════
    //  placeRedeemOrder
    // ══════════════════════════════════════════════════════════

    function test_placeRedeemOrder_succeeds() public {
        uint256 eTokenAmount = 4e18;
        eTSLAToken.mint(Actors.MINTER1, eTokenAmount);

        vm.startPrank(Actors.MINTER1);
        eTSLAToken.approve(address(market), eTokenAmount);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderPlaced(1, Actors.MINTER1, uint8(OrderType.Redeem), TSLA, mockVault, eTokenAmount);

        uint256 orderId = market.placeRedeemOrder(mockVault, TSLA, eTokenAmount, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();

        assertEq(eTSLAToken.balanceOf(address(market)), eTokenAmount);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.orderType), uint256(OrderType.Redeem));
        assertEq(order.amount, eTokenAmount);
        assertEq(order.price, TSLA_PRICE);
    }

    function test_placeRedeemOrder_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.placeRedeemOrder(mockVault, TSLA, 0, TSLA_PRICE, _defaultExpiry());
    }

    // ══════════════════════════════════════════════════════════
    //  claimOrder
    // ══════════════════════════════════════════════════════════

    function test_claimOrder_mint_succeeds() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.expectEmit(true, true, false, false);
        emit IOwnMarket.OrderClaimed(orderId, Actors.VM1);

        _claimOrder(Actors.VM1, orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Claimed));
        assertEq(order.vm, Actors.VM1);
        assertEq(order.vault, mockVault);
        assertGt(order.claimedAt, 0);

        // Stablecoins (minus fee, fee is 0 here) transferred to VM
        assertEq(usdc.balanceOf(Actors.VM1), 1000e6);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function test_claimOrder_redeem_succeeds() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, 4e18);

        _claimOrder(Actors.VM1, orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Claimed));

        // eTokens stay in escrow
        assertEq(eTSLAToken.balanceOf(address(market)), 4e18);
        assertEq(eTSLAToken.balanceOf(Actors.VM1), 0);
    }

    function test_claimOrder_notOpen_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Claimed));
        market.claimOrder(orderId);
    }

    function test_claimOrder_expired_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OrderExpiredError.selector, orderId));
        market.claimOrder(orderId);
    }

    function test_claimOrder_wrongVM_reverts() public {
        // Mock vault's vm() to return a different address
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.vm.selector), abi.encode(Actors.VM2));
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.updateExposure.selector), abi.encode());
        vm.mockCall(
            mockVault, abi.encodeWithSelector(IOwnVault.projectedExposureUtilization.selector), abi.encode(uint256(0))
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.maxUtilization.selector), abi.encode(uint256(BPS)));

        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.prank(Actors.VM1);
        vm.expectRevert(IOwnMarket.OnlyVM.selector);
        market.claimOrder(orderId);
    }

    function test_claimOrder_utilizationBreached_reverts() public {
        _mockVault(Actors.VM1);
        // Override projected utilization to be above max
        vm.mockCall(
            mockVault,
            abi.encodeWithSelector(IOwnVault.projectedExposureUtilization.selector),
            abi.encode(uint256(9500))
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.maxUtilization.selector), abi.encode(uint256(9000)));

        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.UtilizationBreached.selector, 9500, 9000));
        market.claimOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  confirmOrder — mint
    // ══════════════════════════════════════════════════════════

    function test_confirmOrder_mint_succeeds() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Confirmed));

        // eTokens minted at set price: 1000e6 (USDC) * 1e18 / 250e18 = 4e18 * 1e12 scaling
        // Actually: (1000e6 * 1e12 * 1e18) / 250e18 = 1000e18 * 1e18 / 250e18 = 4e18
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 4e18);
    }

    function test_confirmOrder_mint_notClaimed_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Open));
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));
    }

    function test_confirmOrder_mint_wrongVM_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.VM2);
        vm.expectRevert();
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));
    }

    // ══════════════════════════════════════════════════════════
    //  confirmOrder — redeem
    // ══════════════════════════════════════════════════════════

    function test_confirmOrder_redeem_succeeds() public {
        _mockVault(Actors.VM1);
        uint256 eTokenAmount = 4e18;
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, eTokenAmount);

        _claimOrder(Actors.VM1, orderId);

        // VM needs stablecoins to pay user: 4e18 * 250e18 / (1e18 * 1e12) = 1000e6
        uint256 grossPayout = Math.mulDiv(eTokenAmount, TSLA_PRICE, PRECISION * 1e12);
        usdc.mint(Actors.VM1, grossPayout);
        vm.prank(Actors.VM1);
        usdc.approve(address(market), grossPayout);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Confirmed));

        // User receives stablecoins (no fee since fee is 0)
        assertEq(usdc.balanceOf(Actors.MINTER1), grossPayout);

        // eTokens burned
        assertEq(eTSLAToken.balanceOf(address(market)), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  cancelOrder
    // ══════════════════════════════════════════════════════════

    function test_cancelOrder_mint_returnsStablecoins() public {
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

    function test_cancelOrder_redeem_returnsETokens() public {
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, 4e18);

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 4e18);
        assertEq(eTSLAToken.balanceOf(address(market)), 0);
    }

    function test_cancelOrder_notOwner_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId));
        market.cancelOrder(orderId);
    }

    function test_cancelOrder_afterClaim_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Claimed));
        market.cancelOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  expireOrder
    // ══════════════════════════════════════════════════════════

    function test_expireOrder_mint_afterExpiry_succeeds() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.expectEmit(true, false, false, false);
        emit IOwnMarket.OrderExpired(orderId);

        market.expireOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Expired));
        assertEq(usdc.balanceOf(Actors.MINTER1), 1000e6);
    }

    function test_expireOrder_redeem_afterExpiry_succeeds() public {
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, 4e18);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);
        market.expireOrder(orderId);

        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 4e18);
    }

    function test_expireOrder_beforeExpiry_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ExpiryNotReached.selector, orderId));
        market.expireOrder(orderId);
    }

    function test_expireOrder_claimedOrder_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Claimed));
        market.expireOrder(orderId);
    }

    function test_expireOrder_callable_by_anyone() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.prank(Actors.ATTACKER);
        market.expireOrder(orderId);

        assertEq(usdc.balanceOf(Actors.MINTER1), 1000e6);
    }

    // ══════════════════════════════════════════════════════════
    //  closeOrder — VM returns funds for expired claimed order
    // ══════════════════════════════════════════════════════════

    function test_closeOrder_mint_succeeds() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        // Warp past expiry
        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        // VM must have stablecoins to return (it received them on claim)
        // VM already has 1000e6 from claim, now needs to send them back
        vm.startPrank(Actors.VM1);
        usdc.approve(address(market), 1000e6);

        vm.expectEmit(true, true, false, false);
        emit IOwnMarket.OrderClosed(orderId, Actors.VM1);

        market.closeOrder(orderId);
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Closed));

        // User gets full amount back
        assertEq(usdc.balanceOf(Actors.MINTER1), 1000e6);
    }

    function test_closeOrder_redeem_succeeds() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, 4e18);

        _claimOrder(Actors.VM1, orderId);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.expectEmit(true, true, false, false);
        emit IOwnMarket.OrderClosed(orderId, Actors.VM1);

        vm.prank(Actors.VM1);
        market.closeOrder(orderId);

        // eTokens returned to user
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 4e18);
        assertEq(eTSLAToken.balanceOf(address(market)), 0);
    }

    function test_closeOrder_beforeExpiry_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ExpiryNotReached.selector, orderId));
        market.closeOrder(orderId);
    }

    function test_closeOrder_notClaimed_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Open));
        market.closeOrder(orderId);
    }

    function test_closeOrder_wrongVM_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.warp(block.timestamp + DEFAULT_EXPIRY_OFFSET + 1);

        vm.prank(Actors.VM2);
        vm.expectRevert();
        market.closeOrder(orderId);
    }

    // ══════════════════════════════════════════════════════════
    //  forceExecute — claimed mint, grace period
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_claimedMint_afterGracePeriod() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        // Warp past grace period
        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        // Mock collateral oracle and release for force execution
        vm.mockCall(
            mockVault, abi.encodeWithSelector(IOwnVault.collateralOracleAsset.selector), abi.encode(bytes32("ETH"))
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(IOwnVault.releaseCollateral.selector), abi.encode());

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderForceExecuted(orderId, Actors.MINTER1, false);

        // Pass valid ETH price data for collateral conversion
        bytes memory collateralPriceData = abi.encode(uint256(2000e18), uint256(block.timestamp));

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", collateralPriceData);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.ForceExecuted));
    }

    function test_forceExecute_claimedMint_beforeGracePeriod_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.GracePeriodNotElapsed.selector, orderId));
        market.forceExecute(orderId, "", "");
    }

    function test_forceExecute_notOrderOwner_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId));
        market.forceExecute(orderId, "", "");
    }

    // ══════════════════════════════════════════════════════════
    //  forceExecute — claimed redeem
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_claimedRedeem_afterGracePeriod() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, 4e18);

        _claimOrder(Actors.VM1, orderId);

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", "");

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.ForceExecuted));

        // With stub _verifyOHLCProof returning false, eTokens returned to user
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 4e18);
    }

    // ══════════════════════════════════════════════════════════
    //  forceExecute — unclaimed redeem (claim threshold)
    // ══════════════════════════════════════════════════════════

    function test_forceExecute_unclaimedRedeem_afterClaimThreshold() public {
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, 4e18);

        vm.warp(block.timestamp + CLAIM_THRESHOLD + 1);

        vm.prank(Actors.MINTER1);
        market.forceExecute(orderId, "", "");

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.ForceExecuted));

        // eTokens returned (stub returns price not reachable)
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), 4e18);
    }

    function test_forceExecute_unclaimedRedeem_beforeThreshold_reverts() public {
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, 4e18);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ClaimThresholdNotElapsed.selector, orderId));
        market.forceExecute(orderId, "", "");
    }

    function test_forceExecute_unclaimedMint_reverts() public {
        // Open mint orders cannot be force-executed — only claimed mints and open/claimed redeems
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Open));
        market.forceExecute(orderId, "", "");
    }

    function test_forceExecute_confirmedOrder_reverts() public {
        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1000e6);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));

        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.InvalidOrderStatus.selector, orderId, OrderStatus.Confirmed));
        market.forceExecute(orderId, "", "");
    }

    // ══════════════════════════════════════════════════════════
    //  Mint with fees
    // ══════════════════════════════════════════════════════════

    function test_confirmOrder_mint_withFees() public {
        // Set 1% mint fee for volatility level 2
        vm.prank(Actors.ADMIN);
        feeCalc.setMintFee(2, 100); // 100 BPS = 1%

        _mockVault(Actors.VM1);
        uint256 amount = 10_000e6;
        uint256 orderId = _placeMintOrder(Actors.MINTER1, amount);

        _claimOrder(Actors.VM1, orderId);

        // Fee = 10000e6 * 100 / 10000 = 100e6 (ceil)
        uint256 expectedFee = Math.mulDiv(amount, 100, BPS, Math.Rounding.Ceil);
        uint256 netToVM = amount - expectedFee;

        // VM got net amount
        assertEq(usdc.balanceOf(Actors.VM1), netToVM);
        // Fee escrowed in market
        assertEq(usdc.balanceOf(address(market)), expectedFee);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));

        // eTokens minted based on net amount
        uint256 expectedETokens = Math.mulDiv(netToVM * 1e12, PRECISION, TSLA_PRICE);
        assertEq(eTSLAToken.balanceOf(Actors.MINTER1), expectedETokens);
    }

    // ══════════════════════════════════════════════════════════
    //  Redeem with fees
    // ══════════════════════════════════════════════════════════

    function test_confirmOrder_redeem_withFees() public {
        // Set 0.5% redeem fee for volatility level 2
        vm.prank(Actors.ADMIN);
        feeCalc.setRedeemFee(2, 50); // 50 BPS = 0.5%

        _mockVault(Actors.VM1);
        uint256 eTokenAmount = 4e18;
        uint256 orderId = _placeRedeemOrder(Actors.MINTER1, eTokenAmount);

        _claimOrder(Actors.VM1, orderId);

        // Gross payout: 4e18 * 250e18 / (1e18 * 1e12) = 1000e6
        uint256 grossPayout = Math.mulDiv(eTokenAmount, TSLA_PRICE, PRECISION * 1e12);
        uint256 fee = Math.mulDiv(grossPayout, 50, BPS, Math.Rounding.Ceil);
        uint256 netToUser = grossPayout - fee;

        // VM needs to have stablecoins
        usdc.mint(Actors.VM1, grossPayout);
        vm.prank(Actors.VM1);
        usdc.approve(address(market), grossPayout);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));

        // User gets net
        assertEq(usdc.balanceOf(Actors.MINTER1), netToUser);
        // eTokens burned
        assertEq(eTSLAToken.balanceOf(address(market)), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Admin functions
    // ══════════════════════════════════════════════════════════

    // ══════════════════════════════════════════════════════════
    //  View functions
    // ══════════════════════════════════════════════════════════

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

    // ══════════════════════════════════════════════════════════
    //  Fuzz
    // ══════════════════════════════════════════════════════════

    function testFuzz_placeMintOrder_anyAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);

        usdc.mint(Actors.MINTER1, amount);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        uint256 orderId = market.placeMintOrder(mockVault, TSLA, amount, TSLA_PRICE, _defaultExpiry());
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.amount, amount);
        assertEq(usdc.balanceOf(address(market)), amount);
    }

    function testFuzz_fullMintFlow(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 1_000_000e6); // 1 USDC to 1M USDC

        _mockVault(Actors.VM1);
        uint256 orderId = _placeMintOrder(Actors.MINTER1, amount);

        _claimOrder(Actors.VM1, orderId);

        vm.prank(Actors.VM1);
        market.confirmOrder(orderId, _buildPriceProof(TSLA_PRICE));

        // eTokens should be minted
        assertGt(eTSLAToken.balanceOf(Actors.MINTER1), 0);

        // Order should be confirmed
        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Confirmed));
    }
}
