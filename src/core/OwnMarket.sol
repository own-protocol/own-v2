// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";

import {
    BPS,
    ClaimInfo,
    Order,
    OrderStatus,
    OrderType,
    PRECISION,
    PriceType,
    VMConfig
} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnMarket — Order escrow and claim marketplace
/// @notice Core execution mechanism: minters place orders in escrow, VMs claim
///         and confirm them with signed oracle prices. Supports market/limit,
///         directed/open, and partial fills.
contract OwnMarket is IOwnMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    /// @notice Protocol registry for resolving all contract addresses.
    IProtocolRegistry public immutable registry;

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

    /// @param registry_ ProtocolRegistry contract address.
    constructor(address registry_) {
        registry = IProtocolRegistry(registry_);
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
        (uint256 placementPrice,,) = IOracleVerifier(registry.oracleVerifier()).verifyPrice(asset, priceData);

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
        (uint256 placementPrice,,) = IOracleVerifier(registry.oracleVerifier()).verifyPrice(asset, priceData);

        // Escrow eTokens
        address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(asset);
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
        (uint256 executionPrice,,) = IOracleVerifier(registry.oracleVerifier()).verifyPrice(order.asset, priceData);

        // Get VM configuration for spread
        address _vaultManager = registry.vaultManager();
        VMConfig memory vmConfig = IVaultManager(_vaultManager).getVMConfig(msg.sender);
        uint256 vmSpread = vmConfig.spread;

        // Resolve VM's vault
        claim.vault = IVaultManager(_vaultManager).getVMVault(msg.sender);
        claim.executionPrice = executionPrice;
        claim.confirmed = true;

        // Execute mint or redeem with spread-adjusted pricing
        uint256 eTokenAmount;
        uint256 spreadAmount;

        if (order.orderType == OrderType.Mint) {
            (eTokenAmount, spreadAmount) = _executeMint(order, claim, executionPrice, vmSpread);
        } else {
            (eTokenAmount, spreadAmount) = _executeRedeem(order, claim, executionPrice, vmSpread);
        }

        // Update order status
        bool allConfirmed = _allClaimsConfirmed(claim.orderId);
        if (allConfirmed) {
            order.status = OrderStatus.Confirmed;
        } else if (order.status == OrderStatus.FullyClaimed) {
            order.status = OrderStatus.PartiallyConfirmed;
        }

        emit OrderConfirmed(claim.orderId, claimId, msg.sender, executionPrice, eTokenAmount, spreadAmount);
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
    //  Internal — order execution
    // ──────────────────────────────────────────────────────────

    /// @dev Execute a mint confirmation: compute spread-adjusted eToken amount and mint to user.
    /// @return eTokenAmount eTokens minted to the user.
    /// @return spreadAmount Spread revenue in stablecoin terms.
    function _executeMint(
        Order storage order,
        ClaimInfo storage claim,
        uint256 executionPrice,
        uint256 vmSpread
    ) private returns (uint256 eTokenAmount, uint256 spreadAmount) {
        // Effective price includes spread: user pays more per eToken
        uint256 effectivePrice = Math.mulDiv(executionPrice, BPS + vmSpread, BPS);

        // Scale stablecoin amount to 18 decimals, then divide by effective price
        uint256 decimals = IERC20Metadata(order.stablecoin).decimals();
        uint256 decimalScaler = 10 ** (18 - decimals);
        eTokenAmount = Math.mulDiv(claim.amount * decimalScaler, PRECISION, effectivePrice);

        // Mint eTokens to the minter
        address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
        IEToken(eToken).mint(order.user, eTokenAmount);

        // Spread revenue in stablecoin terms (VM keeps all for MVP)
        spreadAmount = Math.mulDiv(claim.amount, vmSpread, BPS + vmSpread);
    }

    /// @dev Execute a redeem confirmation: compute stablecoin payout, transfer from VM, burn eTokens.
    /// @return eTokenAmount eTokens burned from escrow.
    /// @return spreadAmount Spread revenue in stablecoin terms.
    function _executeRedeem(
        Order storage order,
        ClaimInfo storage claim,
        uint256 executionPrice,
        uint256 vmSpread
    ) private returns (uint256 eTokenAmount, uint256 spreadAmount) {
        // Effective price includes spread: user receives less per eToken
        uint256 effectivePrice = Math.mulDiv(executionPrice, BPS - vmSpread, BPS);

        // Calculate stablecoin payout from eToken amount at effective price
        uint256 decimals = IERC20Metadata(order.stablecoin).decimals();
        uint256 decimalScaler = 10 ** (18 - decimals);
        uint256 stablecoinPayout = Math.mulDiv(claim.amount, effectivePrice, PRECISION * decimalScaler);

        // VM sends stablecoins directly to the minter
        IERC20(order.stablecoin).safeTransferFrom(claim.vm, order.user, stablecoinPayout);

        // Burn escrowed eTokens
        address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
        IEToken(eToken).burn(address(this), claim.amount);

        eTokenAmount = claim.amount;

        // Spread = value at oracle price minus what user received
        uint256 valueAtOraclePrice = Math.mulDiv(claim.amount, executionPrice, PRECISION * decimalScaler);
        spreadAmount = valueAtOraclePrice - stablecoinPayout;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
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
