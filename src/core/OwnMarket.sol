// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";

import {BPS, ClaimInfo, Order, OrderStatus, OrderType, PRECISION, PriceType} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OwnMarket — Order escrow and claim marketplace
/// @notice Core execution mechanism: minters place orders in escrow, VMs claim
///         and confirm them with signed oracle prices. Supports market/limit,
///         directed/open, and partial fills.
contract OwnMarket is IOwnMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    address public immutable admin;
    IOracleVerifier public immutable oracle;
    address public immutable vaultManager;
    IAssetRegistry public immutable assetRegistry;
    address public immutable paymentRegistry;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    uint256 private _nextOrderId = 1;
    uint256 private _nextClaimId = 1;

    mapping(uint256 => Order) private _orders;
    mapping(uint256 => ClaimInfo) private _claims;
    mapping(uint256 => uint256[]) private _orderClaims; // orderId → claimIds
    mapping(bytes32 => uint256[]) private _openOrders; // asset → orderIds
    mapping(address => uint256[]) private _userOrders; // user → orderIds

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    constructor(
        address admin_,
        address oracle_,
        address vaultManager_,
        address assetRegistry_,
        address paymentRegistry_
    ) {
        admin = admin_;
        oracle = IOracleVerifier(oracle_);
        vaultManager = vaultManager_;
        assetRegistry = IAssetRegistry(assetRegistry_);
        paymentRegistry = paymentRegistry_;
    }

    // ──────────────────────────────────────────────────────────
    //  Order placement
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function placeMintOrder(
        bytes32 asset,
        address stablecoin,
        uint256 stablecoinAmount,
        PriceType priceType,
        uint256 slippageOrLimitPrice,
        uint256 deadline,
        bool allowPartialFill,
        address preferredVM,
        bytes calldata priceData
    ) external nonReentrant returns (uint256 orderId) {
        if (stablecoinAmount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        // Get placement price from oracle
        (uint256 placementPrice,,) = oracle.verifyPrice(asset, priceData);

        // Escrow stablecoins
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), stablecoinAmount);

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            orderId: orderId,
            user: msg.sender,
            orderType: OrderType.Mint,
            priceType: priceType,
            asset: asset,
            stablecoin: stablecoin,
            amount: stablecoinAmount,
            slippage: priceType == PriceType.Market ? slippageOrLimitPrice : 0,
            limitPrice: priceType == PriceType.Limit ? slippageOrLimitPrice : 0,
            deadline: deadline,
            allowPartialFill: allowPartialFill,
            preferredVM: preferredVM,
            placementPrice: placementPrice,
            filledAmount: 0,
            status: OrderStatus.Open,
            createdAt: block.timestamp
        });

        _openOrders[asset].push(orderId);
        _userOrders[msg.sender].push(orderId);

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Mint), asset, stablecoinAmount);
    }

    /// @inheritdoc IOwnMarket
    function placeRedeemOrder(
        bytes32 asset,
        address stablecoin,
        uint256 eTokenAmount,
        PriceType priceType,
        uint256 slippageOrLimitPrice,
        uint256 deadline,
        bool allowPartialFill,
        address preferredVM,
        bytes calldata priceData
    ) external nonReentrant returns (uint256 orderId) {
        if (eTokenAmount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        // Get placement price from oracle
        (uint256 placementPrice,,) = oracle.verifyPrice(asset, priceData);

        // Escrow eTokens
        address eToken = assetRegistry.getActiveToken(asset);
        IERC20(eToken).safeTransferFrom(msg.sender, address(this), eTokenAmount);

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            orderId: orderId,
            user: msg.sender,
            orderType: OrderType.Redeem,
            priceType: priceType,
            asset: asset,
            stablecoin: stablecoin,
            amount: eTokenAmount,
            slippage: priceType == PriceType.Market ? slippageOrLimitPrice : 0,
            limitPrice: priceType == PriceType.Limit ? slippageOrLimitPrice : 0,
            deadline: deadline,
            allowPartialFill: allowPartialFill,
            preferredVM: preferredVM,
            placementPrice: placementPrice,
            filledAmount: 0,
            status: OrderStatus.Open,
            createdAt: block.timestamp
        });

        _openOrders[asset].push(orderId);
        _userOrders[msg.sender].push(orderId);

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Redeem), asset, eTokenAmount);
    }

    // ──────────────────────────────────────────────────────────
    //  VM operations
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function claimOrder(uint256 orderId, uint256 amount) external nonReentrant returns (uint256 claimId) {
        if (amount == 0) revert ZeroAmount();

        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Open && order.status != OrderStatus.PartiallyClaimed) {
            revert OrderNotOpen(orderId, order.status);
        }
        if (block.timestamp > order.deadline) {
            revert OrderExpiredError(orderId, order.deadline);
        }

        // Directed order check
        if (order.preferredVM != address(0) && order.preferredVM != msg.sender) {
            revert DirectedOrderWrongVM(orderId, order.preferredVM, msg.sender);
        }

        uint256 remaining = order.amount - order.filledAmount;
        if (amount > remaining) {
            revert AmountExceedsRemaining(orderId, amount, remaining);
        }

        // Partial fill check
        if (!order.allowPartialFill && amount < remaining) {
            revert PartialFillNotAllowed(orderId);
        }

        order.filledAmount += amount;
        order.status = (order.filledAmount == order.amount) ? OrderStatus.FullyClaimed : OrderStatus.PartiallyClaimed;

        claimId = _nextClaimId++;
        _claims[claimId] = ClaimInfo({
            claimId: claimId,
            orderId: orderId,
            vm: msg.sender,
            vault: address(0), // Set during confirm
            amount: amount,
            executionPrice: 0,
            confirmed: false,
            claimedAt: block.timestamp
        });

        _orderClaims[orderId].push(claimId);

        // For mint orders, release stablecoins to VM
        if (order.orderType == OrderType.Mint) {
            IERC20(order.stablecoin).safeTransfer(msg.sender, amount);
        }

        emit OrderClaimed(orderId, claimId, msg.sender, amount);
    }

    /// @inheritdoc IOwnMarket
    function confirmOrder(uint256 claimId, bytes calldata priceData) external nonReentrant {
        ClaimInfo storage claim = _claims[claimId];
        if (claim.vm == address(0)) revert ClaimNotFound(claimId);
        if (claim.confirmed) revert ClaimAlreadyConfirmed(claimId);
        require(claim.vm == msg.sender, "OwnMarket: not claim VM");

        Order storage order = _orders[claim.orderId];

        // Verify oracle price
        (uint256 executionPrice,,) = oracle.verifyPrice(order.asset, priceData);

        claim.executionPrice = executionPrice;
        claim.confirmed = true;

        // Check if all claims for this order are confirmed
        bool allConfirmed = _allClaimsConfirmed(claim.orderId);
        if (allConfirmed) {
            order.status = OrderStatus.Confirmed;
        } else if (order.status == OrderStatus.FullyClaimed) {
            order.status = OrderStatus.PartiallyConfirmed;
        }

        emit OrderConfirmed(claim.orderId, claimId, msg.sender, executionPrice, 0, 0);
    }

    // ──────────────────────────────────────────────────────────
    //  User operations
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function cancelOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId, msg.sender);
        if (order.status != OrderStatus.Open && order.status != OrderStatus.PartiallyClaimed) {
            revert OrderNotOpen(orderId, order.status);
        }

        uint256 refundAmount = order.amount - order.filledAmount;
        order.status = OrderStatus.Cancelled;

        // Return escrowed funds
        if (order.orderType == OrderType.Mint && refundAmount > 0) {
            IERC20(order.stablecoin).safeTransfer(order.user, refundAmount);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // ──────────────────────────────────────────────────────────
    //  Deadline enforcement
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function expireOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (block.timestamp <= order.deadline) {
            revert DeadlineNotReached(orderId, order.deadline);
        }
        require(
            order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyClaimed, "OwnMarket: not expirable"
        );

        uint256 refundAmount = order.amount - order.filledAmount;
        order.status = OrderStatus.Expired;

        // Return escrowed funds for unclaimed portion
        if (order.orderType == OrderType.Mint && refundAmount > 0) {
            IERC20(order.stablecoin).safeTransfer(order.user, refundAmount);
        }

        emit OrderExpired(orderId);
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function getOrder(
        uint256 orderId
    ) external view returns (Order memory order) {
        order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
    }

    /// @inheritdoc IOwnMarket
    function getClaim(
        uint256 claimId
    ) external view returns (ClaimInfo memory claim) {
        claim = _claims[claimId];
        if (claim.vm == address(0)) revert ClaimNotFound(claimId);
    }

    /// @inheritdoc IOwnMarket
    function getOrderClaims(
        uint256 orderId
    ) external view returns (uint256[] memory claimIds) {
        return _orderClaims[orderId];
    }

    /// @inheritdoc IOwnMarket
    function getOpenOrders(
        bytes32 asset
    ) external view returns (uint256[] memory orderIds) {
        return _openOrders[asset];
    }

    /// @inheritdoc IOwnMarket
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory orderIds) {
        return _userOrders[user];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────

    function _allClaimsConfirmed(
        uint256 orderId
    ) private view returns (bool) {
        uint256[] storage claimIds = _orderClaims[orderId];
        for (uint256 i; i < claimIds.length;) {
            if (!_claims[claimIds[i]].confirmed) return false;
            unchecked {
                ++i;
            } // SAFETY: i < claimIds.length
        }
        return true;
    }
}
