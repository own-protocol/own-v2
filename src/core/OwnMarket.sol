// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IFeeCalculator} from "../interfaces/IFeeCalculator.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BPS, Order, OrderStatus, OrderType, PRECISION} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnMarket — Order escrow and execution marketplace
/// @notice Users place mint/redeem orders with a price and expiry. The VM claims,
///         hedges off-chain, and confirms at the user's set price. Force execution
///         provides user recourse when the VM fails to act within the grace period.
contract OwnMarket is IOwnMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;

    // ──────────────────────────────────────────────────────────
    //  Protocol parameters
    // ──────────────────────────────────────────────────────────

    /// @notice The single vault backing all orders.
    address public vault;

    /// @dev Time after claim before user can force-execute.
    uint256 public gracePeriod;

    /// @dev Time after placement before user can force-redeem an unclaimed order.
    uint256 public claimThreshold;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    uint256 private _nextOrderId = 1;

    mapping(uint256 => Order) private _orders;
    mapping(bytes32 => uint256[]) private _openOrders;
    mapping(address => uint256[]) private _userOrders;

    /// @dev Escrowed mint fee per order (held in contract until confirm or refund).
    mapping(uint256 => uint256) private _escrowedMintFees;

    // ──────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(
            msg.sender == address(registry) || msg.sender == _registryOwner(), "OwnMarket: not admin"
        );
        _;
    }

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param registry_      ProtocolRegistry contract address.
    /// @param vault_         The single vault address.
    /// @param gracePeriod_    Seconds after claim before force-execute is allowed.
    /// @param claimThreshold_ Seconds after placement before unclaimed redeem can be force-executed.
    constructor(address registry_, address vault_, uint256 gracePeriod_, uint256 claimThreshold_) {
        registry = IProtocolRegistry(registry_);
        vault = vault_;
        gracePeriod = gracePeriod_;
        claimThreshold = claimThreshold_;
    }

    // ──────────────────────────────────────────────────────────
    //  Order placement
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function placeMintOrder(
        bytes32 asset,
        uint256 amount,
        uint256 price,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (!IAssetRegistry(registry.assetRegistry()).isActiveAsset(asset)) revert AssetNotActive(asset);

        // Resolve the vault's payment token
        address paymentToken = _getPaymentToken();

        // Escrow stablecoins
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), amount);

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            orderId: orderId,
            user: msg.sender,
            orderType: OrderType.Mint,
            asset: asset,
            amount: amount,
            price: price,
            expiry: expiry,
            status: OrderStatus.Open,
            createdAt: block.timestamp,
            vm: address(0),
            vault: address(0),
            claimedAt: 0
        });

        _openOrders[asset].push(orderId);
        _userOrders[msg.sender].push(orderId);

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Mint), asset, amount);
    }

    /// @inheritdoc IOwnMarket
    function placeRedeemOrder(
        bytes32 asset,
        uint256 amount,
        uint256 price,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (!IAssetRegistry(registry.assetRegistry()).isActiveAsset(asset)) revert AssetNotActive(asset);

        // Escrow eTokens
        address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(asset);
        IERC20(eToken).safeTransferFrom(msg.sender, address(this), amount);

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            orderId: orderId,
            user: msg.sender,
            orderType: OrderType.Redeem,
            asset: asset,
            amount: amount,
            price: price,
            expiry: expiry,
            status: OrderStatus.Open,
            createdAt: block.timestamp,
            vm: address(0),
            vault: address(0),
            claimedAt: 0
        });

        _openOrders[asset].push(orderId);
        _userOrders[msg.sender].push(orderId);

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Redeem), asset, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  VM operations
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function claimOrder(uint256 orderId) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp > order.expiry) revert OrderExpiredError(orderId);

        // Verify caller is the VM bound to our vault
        IVaultManager vmManager = IVaultManager(registry.vaultManager());
        require(vmManager.getVMVault(msg.sender) == vault, "OwnMarket: not vault VM");

        order.status = OrderStatus.Claimed;
        order.vm = msg.sender;
        order.vault = vault;
        order.claimedAt = block.timestamp;

        // For mint: calculate fee, hold in escrow, release net to VM
        if (order.orderType == OrderType.Mint) {
            uint256 feeBps =
                IFeeCalculator(registry.feeCalculator()).getMintFee(order.asset, order.amount);
            uint256 feeAmount = Math.mulDiv(order.amount, feeBps, BPS, Math.Rounding.Ceil);
            _escrowedMintFees[orderId] = feeAmount;

            address paymentToken = _getPaymentToken();
            IERC20(paymentToken).safeTransfer(msg.sender, order.amount - feeAmount);
        }
        // For redeem: eTokens stay in escrow, nothing moves

        // Update VM exposure
        uint256 exposureDelta = _calculateExposure(order);
        vmManager.updateExposure(msg.sender, int256(exposureDelta));

        emit OrderClaimed(orderId, msg.sender);
    }

    /// @inheritdoc IOwnMarket
    function confirmOrder(uint256 orderId) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Claimed) revert InvalidOrderStatus(orderId, order.status);
        require(order.vm == msg.sender, "OwnMarket: not claim VM");

        order.status = OrderStatus.Confirmed;

        if (order.orderType == OrderType.Mint) {
            _executeMint(order);
        } else {
            _executeRedeem(order);
        }

        // Decrease VM exposure
        uint256 exposureDelta = _calculateExposure(order);
        IVaultManager(registry.vaultManager()).updateExposure(msg.sender, -int256(exposureDelta));

        emit OrderConfirmed(orderId, msg.sender, order.amount);
    }

    /// @inheritdoc IOwnMarket
    function closeOrder(uint256 orderId) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Claimed) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp <= order.expiry) revert ExpiryNotReached(orderId);
        require(order.vm == msg.sender, "OwnMarket: not claim VM");

        order.status = OrderStatus.Closed;

        if (order.orderType == OrderType.Mint) {
            // VM returns stablecoins to user in this transaction
            address paymentToken = _getPaymentToken();
            uint256 feeAmount = _escrowedMintFees[orderId];
            IERC20(paymentToken).safeTransferFrom(msg.sender, order.user, order.amount - feeAmount);

            // Return escrowed fee to user
            if (feeAmount > 0) {
                _escrowedMintFees[orderId] = 0;
                IERC20(paymentToken).safeTransfer(order.user, feeAmount);
            }
        } else {
            // Return escrowed eTokens to user
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
        }

        // Decrease VM exposure
        uint256 exposureDelta = _calculateExposure(order);
        IVaultManager(registry.vaultManager()).updateExposure(order.vm, -int256(exposureDelta));

        emit OrderClosed(orderId, msg.sender);
    }

    // ──────────────────────────────────────────────────────────
    //  User operations
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId, order.status);

        order.status = OrderStatus.Cancelled;

        if (order.orderType == OrderType.Mint) {
            address paymentToken = _getPaymentToken();
            IERC20(paymentToken).safeTransfer(order.user, order.amount);
        } else {
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    /// @inheritdoc IOwnMarket
    function forceExecute(uint256 orderId, bytes calldata ohlcProofData) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId);

        bool isClaimed = order.status == OrderStatus.Claimed;
        bool isOpen = order.status == OrderStatus.Open;

        if (isClaimed) {
            // Force after grace period on claimed orders (both mint & redeem)
            if (block.timestamp < order.claimedAt + gracePeriod) {
                revert GracePeriodNotElapsed(orderId);
            }
        } else if (isOpen && order.orderType == OrderType.Redeem) {
            // Force on unclaimed redeem after claim threshold
            if (block.timestamp < order.createdAt + claimThreshold) {
                revert ClaimThresholdNotElapsed(orderId);
            }
        } else {
            revert InvalidOrderStatus(orderId, order.status);
        }

        order.status = OrderStatus.ForceExecuted;

        // Verify OHLC proof to determine if set price was reachable
        // TODO: Integrate OHLC oracle verification
        bool priceReachable = _verifyOHLCProof(order, ohlcProofData);

        if (priceReachable) {
            _forceExecuteAtSetPrice(order);
        } else {
            _forceExecuteRefund(order);
        }

        // Clear VM exposure if was claimed
        if (isClaimed) {
            uint256 exposureDelta = _calculateExposure(order);
            IVaultManager(registry.vaultManager()).updateExposure(order.vm, -int256(exposureDelta));
        }

        emit OrderForceExecuted(orderId, msg.sender, priceReachable);
    }

    // ──────────────────────────────────────────────────────────
    //  Permissionless
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function expireOrder(uint256 orderId) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (block.timestamp <= order.expiry) revert ExpiryNotReached(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId, order.status);

        order.status = OrderStatus.Expired;

        // Return escrowed funds
        if (order.orderType == OrderType.Mint) {
            address paymentToken = _getPaymentToken();
            IERC20(paymentToken).safeTransfer(order.user, order.amount);
        } else {
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
        }

        emit OrderExpired(orderId);
    }

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice Update the vault address.
    function setVault(address newVault) external onlyAdmin {
        vault = newVault;
    }

    /// @notice Update the grace period for force execution.
    function setGracePeriod(uint256 newGracePeriod) external onlyAdmin {
        gracePeriod = newGracePeriod;
    }

    /// @notice Update the claim threshold for unclaimed redeem force execution.
    function setClaimThreshold(uint256 newClaimThreshold) external onlyAdmin {
        claimThreshold = newClaimThreshold;
    }

    // ──────────────────────────────────────────────────────────
    //  View functions
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function getOrder(uint256 orderId) external view returns (Order memory order) {
        order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
    }

    /// @inheritdoc IOwnMarket
    function getOpenOrders(bytes32 asset) external view returns (uint256[] memory) {
        return _openOrders[asset];
    }

    /// @inheritdoc IOwnMarket
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return _userOrders[user];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — order execution
    // ──────────────────────────────────────────────────────────

    /// @dev Execute a mint confirmation at the order's set price.
    function _executeMint(Order storage order) private {
        uint256 feeAmount = _escrowedMintFees[order.orderId];
        uint256 netAmount = order.amount - feeAmount;
        address paymentToken = _getPaymentToken();

        // Deposit escrowed fee to vault
        if (feeAmount > 0) {
            _escrowedMintFees[order.orderId] = 0;
            IERC20(paymentToken).safeIncreaseAllowance(order.vault, feeAmount);
            IOwnVault(order.vault).depositFees(paymentToken, feeAmount);
            emit FeeCollected(order.orderId, paymentToken, feeAmount);
        }

        // Mint eTokens at set price: eTokenAmount = netStablecoin * 1e18 / price
        uint256 decimals = IERC20Metadata(paymentToken).decimals();
        uint256 decimalScaler = 10 ** (18 - decimals);
        uint256 eTokenAmount = Math.mulDiv(netAmount * decimalScaler, PRECISION, order.price);

        address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
        IEToken(eToken).mint(order.user, eTokenAmount);
    }

    /// @dev Execute a redeem confirmation at the order's set price.
    function _executeRedeem(Order storage order) private {
        address paymentToken = _getPaymentToken();
        uint256 decimals = IERC20Metadata(paymentToken).decimals();
        uint256 precisionWithDecimals = PRECISION * 10 ** (18 - decimals);

        // Gross payout at set price
        uint256 grossPayout = Math.mulDiv(order.amount, order.price, precisionWithDecimals);

        // Deduct fee (round up — protocol-favorable)
        uint256 feeBps =
            IFeeCalculator(registry.feeCalculator()).getRedeemFee(order.asset, order.amount);
        uint256 feeAmount = Math.mulDiv(grossPayout, feeBps, BPS, Math.Rounding.Ceil);

        // VM sends stablecoins: net to user, fee to vault
        IERC20(paymentToken).safeTransferFrom(order.vm, order.user, grossPayout - feeAmount);
        if (feeAmount > 0) {
            IERC20(paymentToken).safeTransferFrom(order.vm, address(this), feeAmount);
            IERC20(paymentToken).safeIncreaseAllowance(order.vault, feeAmount);
            IOwnVault(order.vault).depositFees(paymentToken, feeAmount);
            emit FeeCollected(order.orderId, paymentToken, feeAmount);
        }

        // Burn escrowed eTokens
        address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
        IEToken(eToken).burn(address(this), order.amount);
    }

    /// @dev Force execution when set price was reachable. No fees charged.
    ///      Mint: eTokens minted at set price. Redeem: user gets collateral (ETH).
    function _forceExecuteAtSetPrice(Order storage order) private {
        if (order.orderType == OrderType.Mint) {
            // Mint eTokens at set price, no fees
            address paymentToken = _getPaymentToken();
            uint256 decimals = IERC20Metadata(paymentToken).decimals();
            uint256 decimalScaler = 10 ** (18 - decimals);

            // Use full amount (no fee deduction for force execution)
            uint256 eTokenAmount = Math.mulDiv(order.amount * decimalScaler, PRECISION, order.price);
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IEToken(eToken).mint(order.user, eTokenAmount);

            // Return escrowed fee to user (fee was held in contract)
            uint256 feeAmount = _escrowedMintFees[order.orderId];
            if (feeAmount > 0) {
                _escrowedMintFees[order.orderId] = 0;
                IERC20(paymentToken).safeTransfer(order.user, feeAmount);
            }
        } else {
            // Redeem: user gets collateral (ETH) equivalent from vault
            // collateralAmount = eTokenAmount * setPrice / ethPrice
            // TODO: Integrate ETH/USD oracle for collateral conversion
            // TODO: Add vault.releaseCollateral() function
            // For now: burn eTokens and emit event — collateral release to be implemented
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IEToken(eToken).burn(address(this), order.amount);
        }
    }

    /// @dev Force execution when set price was NOT reachable.
    ///      Mint: user gets original value as collateral (ETH). Redeem: eTokens returned.
    function _forceExecuteRefund(Order storage order) private {
        if (order.orderType == OrderType.Mint) {
            // User gets original stablecoin value as ETH collateral from vault
            // collateralAmount = stablecoinAmount / ethPrice
            // TODO: Integrate ETH/USD oracle for collateral conversion
            // TODO: Add vault.releaseCollateral() function
            // Return escrowed fee to user
            uint256 feeAmount = _escrowedMintFees[order.orderId];
            if (feeAmount > 0) {
                _escrowedMintFees[order.orderId] = 0;
                address paymentToken = _getPaymentToken();
                IERC20(paymentToken).safeTransfer(order.user, feeAmount);
            }
        } else {
            // Return escrowed eTokens to user
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Verify OHLC proof to check if set price was reachable.
    ///      Placeholder — to be replaced with Pyth/in-house oracle integration.
    function _verifyOHLCProof(Order storage, /*order*/ bytes calldata /*ohlcProofData*/ )
        private
        pure
        returns (bool)
    {
        // TODO: Implement OHLC verification
        // For mint: check if price <= order.price during [claimTime, now]
        // For redeem: check if price >= order.price during [claimTime, now]
        return false;
    }

    /// @dev Calculate the USD exposure for an order (amount * price for redeems, amount for mints).
    function _calculateExposure(Order storage order) private view returns (uint256) {
        if (order.orderType == OrderType.Mint) {
            // Mint: exposure is the stablecoin amount (already in USD terms)
            return order.amount;
        } else {
            // Redeem: exposure is eToken amount * set price
            return Math.mulDiv(order.amount, order.price, PRECISION);
        }
    }

    /// @dev Get the payment token from the vault.
    function _getPaymentToken() private view returns (address) {
        return IOwnVault(vault).paymentToken();
    }

    /// @dev Get the registry owner (admin).
    function _registryOwner() private view returns (address) {
        return Ownable(address(registry)).owner();
    }
}
