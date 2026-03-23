// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {Actors} from "../helpers/Actors.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {IOwnMarket} from "../../src/interfaces/IOwnMarket.sol";
import {OwnMarket} from "../../src/core/OwnMarket.sol";
import {
    Order,
    ClaimInfo,
    OrderStatus,
    OrderType,
    PriceType,
    BPS,
    PRECISION
} from "../../src/interfaces/types/Types.sol";

/// @title OwnMarket Unit Tests
/// @notice Tests order placement (mint/redeem, market/limit, directed/open),
///         claiming, confirming, cancelling, deadline expiry, partial fills,
///         slippage, and access control.
/// @dev Uses mock dependencies: MockOracleVerifier, MockERC20 for stablecoins,
///      and a mock eToken. The actual VaultManager, OwnVault, AssetRegistry,
///      and PaymentTokenRegistry are mocked via interfaces.
contract OwnMarketTest is BaseTest {
    OwnMarket public market;

    MockERC20 public eTSLAToken;

    // Mock contract addresses acting as dependencies
    address public mockVaultManager = makeAddr("vaultManager");
    address public mockVault = makeAddr("vault");
    address public mockAssetRegistry = makeAddr("assetRegistry");
    address public mockPaymentRegistry = makeAddr("paymentRegistry");

    uint256 constant DEFAULT_DEADLINE = 1 days;

    function setUp() public override {
        super.setUp();

        eTSLAToken = new MockERC20("Own TSLA", "eTSLA", 18);
        vm.label(address(eTSLAToken), "eTSLA");

        vm.prank(Actors.ADMIN);
        market = new OwnMarket(
            Actors.ADMIN,
            address(oracle),
            mockVaultManager,
            mockAssetRegistry,
            mockPaymentRegistry
        );
        vm.label(address(market), "OwnMarket");

        // Setup default oracle price
        _setOraclePrice(TSLA, TSLA_PRICE);
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    function _defaultDeadline() internal view returns (uint256) {
        return block.timestamp + DEFAULT_DEADLINE;
    }

    function _placeMintOrder(
        address minter,
        uint256 stablecoinAmount
    ) internal returns (uint256 orderId) {
        usdc.mint(minter, stablecoinAmount);
        vm.startPrank(minter);
        usdc.approve(address(market), stablecoinAmount);
        orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            stablecoinAmount,
            PriceType.Market,
            100, // 1% slippage
            _defaultDeadline(),
            true,
            address(0), // open order
            _emptyPriceData()
        );
        vm.stopPrank();
    }

    function _placeRedeemOrder(
        address minter,
        uint256 eTokenAmount
    ) internal returns (uint256 orderId) {
        eTSLAToken.mint(minter, eTokenAmount);
        vm.startPrank(minter);
        eTSLAToken.approve(address(market), eTokenAmount);
        orderId = market.placeRedeemOrder(
            TSLA,
            address(usdc),
            eTokenAmount,
            PriceType.Market,
            100, // 1% slippage
            _defaultDeadline(),
            true,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────
    //  placeMintOrder
    // ──────────────────────────────────────────────────────────

    function test_placeMintOrder_succeeds() public {
        uint256 amount = 1_000e6;
        usdc.mint(Actors.MINTER1, amount);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        vm.expectEmit(true, true, false, true);
        emit IOwnMarket.OrderPlaced(1, Actors.MINTER1, uint8(OrderType.Mint), TSLA, amount);

        uint256 orderId = market.placeMintOrder(
            TSLA,
            address(usdc),
            amount,
            PriceType.Market,
            100,
            _defaultDeadline(),
            true,
            address(0),
            _emptyPriceData()
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
        assertEq(order.stablecoin, address(usdc));
        assertEq(uint256(order.status), uint256(OrderStatus.Open));
        assertTrue(order.allowPartialFill);
    }

    function test_placeMintOrder_limitOrder() public {
        uint256 amount = 1_000e6;
        usdc.mint(Actors.MINTER1, amount);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        uint256 orderId = market.placeMintOrder(
            TSLA, address(usdc), amount, PriceType.Limit, 240e18, _defaultDeadline(), false, address(0), _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.priceType), uint256(PriceType.Limit));
        assertEq(order.limitPrice, 240e18);
        assertFalse(order.allowPartialFill);
    }

    function test_placeMintOrder_directedOrder() public {
        uint256 amount = 1_000e6;
        usdc.mint(Actors.MINTER1, amount);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        uint256 orderId = market.placeMintOrder(
            TSLA, address(usdc), amount, PriceType.Market, 100, _defaultDeadline(), true, Actors.VM1, _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.preferredVM, Actors.VM1);
    }

    function test_placeMintOrder_zeroAmount_reverts() public {
        vm.prank(Actors.MINTER1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.placeMintOrder(
            TSLA, address(usdc), 0, PriceType.Market, 100, _defaultDeadline(), true, address(0), _emptyPriceData()
        );
    }

    function test_placeMintOrder_pastDeadline_reverts() public {
        uint256 amount = 1_000e6;
        usdc.mint(Actors.MINTER1, amount);

        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);
        vm.expectRevert(IOwnMarket.InvalidDeadline.selector);
        market.placeMintOrder(
            TSLA, address(usdc), amount, PriceType.Market, 100, block.timestamp - 1, true, address(0), _emptyPriceData()
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
            TSLA,
            address(usdc),
            eTokenAmount,
            PriceType.Market,
            100,
            _defaultDeadline(),
            true,
            address(0),
            _emptyPriceData()
        );
        vm.stopPrank();

        // eTokens should be escrowed
        assertEq(eTSLAToken.balanceOf(address(market)), eTokenAmount);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.orderType), uint256(OrderType.Redeem));
        assertEq(order.amount, eTokenAmount);
    }

    // ──────────────────────────────────────────────────────────
    //  claimOrder
    // ──────────────────────────────────────────────────────────

    function test_claimOrder_fullClaim_succeeds() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.expectEmit(true, true, true, true);
        emit IOwnMarket.OrderClaimed(orderId, 1, Actors.VM1, 1_000e6);

        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, 1_000e6);

        assertEq(claimId, 1);

        ClaimInfo memory claim = market.getClaim(claimId);
        assertEq(claim.vm, Actors.VM1);
        assertEq(claim.amount, 1_000e6);
        assertFalse(claim.confirmed);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.FullyClaimed));
    }

    function test_claimOrder_partialClaim_succeeds() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId, 600e6);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.PartiallyClaimed));
        assertEq(order.filledAmount, 600e6);
    }

    function test_claimOrder_exceedsRemaining_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnMarket.AmountExceedsRemaining.selector, orderId, 1_001e6, 1_000e6)
        );
        market.claimOrder(orderId, 1_001e6);
    }

    function test_claimOrder_partialFillNotAllowed_reverts() public {
        // Place order with allowPartialFill = false
        usdc.mint(Actors.MINTER1, 1_000e6);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), 1_000e6);
        uint256 orderId = market.placeMintOrder(
            TSLA, address(usdc), 1_000e6, PriceType.Market, 100, _defaultDeadline(), false, address(0), _emptyPriceData()
        );
        vm.stopPrank();

        // Try to claim partial amount
        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.PartialFillNotAllowed.selector, orderId));
        market.claimOrder(orderId, 500e6);
    }

    function test_claimOrder_directedOrder_wrongVM_reverts() public {
        // Place directed order to VM1
        usdc.mint(Actors.MINTER1, 1_000e6);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), 1_000e6);
        uint256 orderId = market.placeMintOrder(
            TSLA, address(usdc), 1_000e6, PriceType.Market, 100, _defaultDeadline(), true, Actors.VM1, _emptyPriceData()
        );
        vm.stopPrank();

        // VM2 tries to claim
        vm.prank(Actors.VM2);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnMarket.DirectedOrderWrongVM.selector, orderId, Actors.VM1, Actors.VM2)
        );
        market.claimOrder(orderId, 1_000e6);
    }

    function test_claimOrder_expiredOrder_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        // Warp past deadline
        vm.warp(block.timestamp + DEFAULT_DEADLINE + 1);

        vm.prank(Actors.VM1);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnMarket.OrderExpiredError.selector, orderId, block.timestamp - 1)
        );
        market.claimOrder(orderId, 1_000e6);
    }

    function test_claimOrder_zeroAmount_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        vm.expectRevert(IOwnMarket.ZeroAmount.selector);
        market.claimOrder(orderId, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  confirmOrder
    // ──────────────────────────────────────────────────────────

    function test_confirmOrder_mint_succeeds() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, 1_000e6);

        vm.expectEmit(true, true, true, false);
        emit IOwnMarket.OrderConfirmed(orderId, claimId, Actors.VM1, TSLA_PRICE, 0, 0);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        ClaimInfo memory claim = market.getClaim(claimId);
        assertTrue(claim.confirmed);
        assertEq(claim.executionPrice, TSLA_PRICE);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Confirmed));
    }

    function test_confirmOrder_nonClaimVM_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, 1_000e6);

        // VM2 tries to confirm VM1's claim
        vm.prank(Actors.VM2);
        vm.expectRevert();
        market.confirmOrder(claimId, _emptyPriceData());
    }

    function test_confirmOrder_alreadyConfirmed_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        uint256 claimId = market.claimOrder(orderId, 1_000e6);

        vm.prank(Actors.VM1);
        market.confirmOrder(claimId, _emptyPriceData());

        vm.prank(Actors.VM1);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ClaimAlreadyConfirmed.selector, claimId));
        market.confirmOrder(claimId, _emptyPriceData());
    }

    // ──────────────────────────────────────────────────────────
    //  cancelOrder
    // ──────────────────────────────────────────────────────────

    function test_cancelOrder_returnsEscrowedStablecoins() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.expectEmit(true, true, false, false);
        emit IOwnMarket.OrderCancelled(orderId, Actors.MINTER1);

        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        assertEq(usdc.balanceOf(Actors.MINTER1), 1_000e6);
        assertEq(usdc.balanceOf(address(market)), 0);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Cancelled));
    }

    function test_cancelOrder_partiallyClaimedReturnsUnclaimed() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId, 600e6);

        // Cancel returns only unclaimed portion
        vm.prank(Actors.MINTER1);
        market.cancelOrder(orderId);

        assertEq(usdc.balanceOf(Actors.MINTER1), 400e6);
    }

    function test_cancelOrder_notOwner_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OnlyOrderOwner.selector, orderId, Actors.ATTACKER));
        market.cancelOrder(orderId);
    }

    function test_cancelOrder_fullyClaimed_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId, 1_000e6);

        vm.prank(Actors.MINTER1);
        vm.expectRevert(
            abi.encodeWithSelector(IOwnMarket.OrderNotOpen.selector, orderId, OrderStatus.FullyClaimed)
        );
        market.cancelOrder(orderId);
    }

    // ──────────────────────────────────────────────────────────
    //  expireOrder
    // ──────────────────────────────────────────────────────────

    function test_expireOrder_afterDeadline_succeeds() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.warp(block.timestamp + DEFAULT_DEADLINE + 1);

        vm.expectEmit(true, false, false, false);
        emit IOwnMarket.OrderExpired(orderId);

        market.expireOrder(orderId);

        Order memory order = market.getOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Expired));

        // Escrowed stablecoins returned
        assertEq(usdc.balanceOf(Actors.MINTER1), 1_000e6);
    }

    function test_expireOrder_beforeDeadline_reverts() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(IOwnMarket.DeadlineNotReached.selector, orderId, _defaultDeadline())
        );
        market.expireOrder(orderId);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    function test_getOrder_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.OrderNotFound.selector, 999));
        market.getOrder(999);
    }

    function test_getClaim_nonExistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IOwnMarket.ClaimNotFound.selector, 999));
        market.getClaim(999);
    }

    function test_getOrderClaims_returnsClaims() public {
        uint256 orderId = _placeMintOrder(Actors.MINTER1, 1_000e6);

        vm.prank(Actors.VM1);
        market.claimOrder(orderId, 500e6);

        vm.prank(Actors.VM2);
        market.claimOrder(orderId, 500e6);

        uint256[] memory claimIds = market.getOrderClaims(orderId);
        assertEq(claimIds.length, 2);
    }

    function test_getOpenOrders_returnsOpenOnly() public {
        _placeMintOrder(Actors.MINTER1, 1_000e6);
        _placeMintOrder(Actors.MINTER2, 2_000e6);

        uint256[] memory openOrders = market.getOpenOrders(TSLA);
        assertEq(openOrders.length, 2);
    }

    function test_getUserOrders_returnsUserOrders() public {
        _placeMintOrder(Actors.MINTER1, 1_000e6);
        _placeMintOrder(Actors.MINTER1, 500e6);
        _placeMintOrder(Actors.MINTER2, 2_000e6);

        uint256[] memory m1Orders = market.getUserOrders(Actors.MINTER1);
        assertEq(m1Orders.length, 2);

        uint256[] memory m2Orders = market.getUserOrders(Actors.MINTER2);
        assertEq(m2Orders.length, 1);
    }

    // ──────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────

    function testFuzz_placeMintOrder_anyAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        usdc.mint(Actors.MINTER1, amount);
        vm.startPrank(Actors.MINTER1);
        usdc.approve(address(market), amount);

        uint256 orderId = market.placeMintOrder(
            TSLA, address(usdc), amount, PriceType.Market, 100, _defaultDeadline(), true, address(0), _emptyPriceData()
        );
        vm.stopPrank();

        Order memory order = market.getOrder(orderId);
        assertEq(order.amount, amount);
        assertEq(usdc.balanceOf(address(market)), amount);
    }
}
