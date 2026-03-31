// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IFeeCalculator} from "../interfaces/IFeeCalculator.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
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
    //  State
    // ──────────────────────────────────────────────────────────

    uint256 private _nextOrderId = 1;

    mapping(uint256 => Order) private _orders;
    mapping(bytes32 => uint256[]) private _openOrders;
    mapping(address => uint256[]) private _userOrders;

    /// @dev Escrowed mint fee per order (held in contract until confirm or refund).
    mapping(uint256 => uint256) private _escrowedMintFees;

    // ──────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────

    /// @param registry_ ProtocolRegistry contract address.
    constructor(
        address registry_
    ) {
        registry = IProtocolRegistry(registry_);
    }

    // ──────────────────────────────────────────────────────────
    //  Order placement
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function placeMintOrder(
        address vault,
        bytes32 asset,
        uint256 amount,
        uint256 price,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        _validateVaultAndAsset(vault, asset);

        // Resolve the vault's payment token
        address paymentToken = IOwnVault(vault).paymentToken();

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
            vault: vault,
            claimedAt: 0
        });

        _openOrders[asset].push(orderId);
        _userOrders[msg.sender].push(orderId);

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Mint), asset, vault, amount);
    }

    /// @inheritdoc IOwnMarket
    function placeRedeemOrder(
        address vault,
        bytes32 asset,
        uint256 amount,
        uint256 price,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        _validateVaultAndAsset(vault, asset);

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
            vault: vault,
            claimedAt: 0
        });

        _openOrders[asset].push(orderId);
        _userOrders[msg.sender].push(orderId);

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Redeem), asset, vault, amount);
    }

    // ──────────────────────────────────────────────────────────
    //  VM operations
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function claimOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp > order.expiry) revert OrderExpiredError(orderId);

        // Verify caller is the VM bound to the order's vault
        IOwnVault vaultContract = IOwnVault(order.vault);
        if (vaultContract.vm() != msg.sender) revert OnlyVM();

        order.status = OrderStatus.Claimed;
        order.vm = msg.sender;
        order.claimedAt = block.timestamp;
        _removeFromOpenOrders(order.asset, orderId);

        // For mint: calculate fee, hold in escrow, release net to VM
        if (order.orderType == OrderType.Mint) {
            uint256 feeBps = IFeeCalculator(registry.feeCalculator()).getMintFee(order.asset, order.amount);
            uint256 feeAmount = Math.mulDiv(order.amount, feeBps, BPS, Math.Rounding.Ceil);
            _escrowedMintFees[orderId] = feeAmount;

            address paymentToken = vaultContract.paymentToken();
            IERC20(paymentToken).safeTransfer(msg.sender, order.amount - feeAmount);
        }
        // For redeem: eTokens stay in escrow, nothing moves

        // Update exposure and check utilization
        uint256 exposureDelta = _calculateExposure(order);
        vaultContract.updateExposure(order.asset, int256(exposureDelta));

        uint256 currentUtil = vaultContract.utilization();
        uint256 maxUtil = vaultContract.maxUtilization();
        if (currentUtil > maxUtil) {
            revert UtilizationBreached(currentUtil, maxUtil);
        }

        emit OrderClaimed(orderId, msg.sender);
    }

    /// @inheritdoc IOwnMarket
    function confirmOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Claimed) revert InvalidOrderStatus(orderId, order.status);
        if (order.vm != msg.sender) revert NotClaimVM(orderId, msg.sender);
        if (block.timestamp > order.expiry) revert OrderExpiredError(orderId);

        order.status = OrderStatus.Confirmed;

        if (order.orderType == OrderType.Mint) {
            _executeMint(order);
        } else {
            _executeRedeem(order);
        }

        // Decrease exposure
        uint256 exposureDelta = _calculateExposure(order);
        IOwnVault(order.vault).updateExposure(order.asset, -int256(exposureDelta));

        emit OrderConfirmed(orderId, msg.sender, order.amount);
    }

    /// @inheritdoc IOwnMarket
    function closeOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Claimed) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp <= order.expiry) revert ExpiryNotReached(orderId);
        if (order.vm != msg.sender) revert NotClaimVM(orderId, msg.sender);

        order.status = OrderStatus.Closed;

        if (order.orderType == OrderType.Mint) {
            address paymentToken = IOwnVault(order.vault).paymentToken();
            uint256 feeAmount = _escrowedMintFees[orderId];
            IERC20(paymentToken).safeTransferFrom(msg.sender, order.user, order.amount - feeAmount);

            if (feeAmount > 0) {
                _escrowedMintFees[orderId] = 0;
                IERC20(paymentToken).safeTransfer(order.user, feeAmount);
            }
        } else {
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
        }

        // Decrease exposure
        uint256 exposureDelta = _calculateExposure(order);
        IOwnVault(order.vault).updateExposure(order.asset, -int256(exposureDelta));

        emit OrderClosed(orderId, msg.sender);
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
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId, order.status);

        order.status = OrderStatus.Cancelled;
        _removeFromOpenOrders(order.asset, orderId);

        if (order.orderType == OrderType.Mint) {
            address paymentToken = IOwnVault(order.vault).paymentToken();
            IERC20(paymentToken).safeTransfer(order.user, order.amount);
        } else {
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    /// @inheritdoc IOwnMarket
    /// @dev Caller must send ETH to cover Pyth oracle fees for verifyPrice calls.
    ///      Use verifyFee() on the relevant oracle to calculate the required amounts.
    ///      Any unused ETH is refunded at the end of the call.
    ///      For in-house oracle, no ETH is needed and msg.value should be 0.
    function forceExecute(
        uint256 orderId,
        bytes calldata priceProofData,
        bytes calldata collateralPriceData
    ) external payable nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId);

        bool isClaimed = order.status == OrderStatus.Claimed;
        bool isOpen = order.status == OrderStatus.Open;

        IOwnVault vaultContract = IOwnVault(order.vault);
        if (isClaimed) {
            if (block.timestamp < order.claimedAt + vaultContract.gracePeriod()) {
                revert GracePeriodNotElapsed(orderId);
            }
        } else if (isOpen && order.orderType == OrderType.Redeem) {
            if (block.timestamp < order.createdAt + vaultContract.claimThreshold()) {
                revert ClaimThresholdNotElapsed(orderId);
            }
        } else {
            revert InvalidOrderStatus(orderId, order.status);
        }

        order.status = OrderStatus.ForceExecuted;
        if (isOpen) {
            _removeFromOpenOrders(order.asset, orderId);
        }

        bool priceReachable = _verifyPriceRange(order, priceProofData);

        if (priceReachable) {
            _forceExecuteAtSetPrice(order, collateralPriceData);
        } else {
            _forceExecuteRefund(order, collateralPriceData);
        }

        // Clear exposure if was claimed
        if (isClaimed) {
            uint256 exposureDelta = _calculateExposure(order);
            vaultContract.updateExposure(order.asset, -int256(exposureDelta));
        }

        emit OrderForceExecuted(orderId, msg.sender, priceReachable);

        // Refund any unused ETH (e.g. in-house oracle fees are 0; or priceData path skipped collateral)
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool ok,) = payable(msg.sender).call{value: remaining}("");
            if (!ok) revert ETHRefundFailed();
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Permissionless
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function expireOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (block.timestamp <= order.expiry) revert ExpiryNotReached(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId, order.status);

        order.status = OrderStatus.Expired;
        _removeFromOpenOrders(order.asset, orderId);

        // Return escrowed funds
        if (order.orderType == OrderType.Mint) {
            address paymentToken = IOwnVault(order.vault).paymentToken();
            IERC20(paymentToken).safeTransfer(order.user, order.amount);
        } else {
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
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
    function getOpenOrders(
        bytes32 asset
    ) external view returns (uint256[] memory) {
        return _openOrders[asset];
    }

    /// @inheritdoc IOwnMarket
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory) {
        return _userOrders[user];
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — order execution
    // ──────────────────────────────────────────────────────────

    /// @dev Execute a mint confirmation at the order's set price.
    function _executeMint(
        Order storage order
    ) private {
        uint256 feeAmount = _escrowedMintFees[order.orderId];
        uint256 netAmount = order.amount - feeAmount;
        address paymentToken = IOwnVault(order.vault).paymentToken();

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
    function _executeRedeem(
        Order storage order
    ) private {
        address paymentToken = IOwnVault(order.vault).paymentToken();
        uint256 decimals = IERC20Metadata(paymentToken).decimals();
        uint256 precisionWithDecimals = PRECISION * 10 ** (18 - decimals);

        // Gross payout at set price
        uint256 grossPayout = Math.mulDiv(order.amount, order.price, precisionWithDecimals);

        // Deduct fee (round up — protocol-favorable)
        uint256 feeBps = IFeeCalculator(registry.feeCalculator()).getRedeemFee(order.asset, order.amount);
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

    /// @dev Force execution when set price was reachable. Fees charged and deposited to vault.
    function _forceExecuteAtSetPrice(Order storage order, bytes calldata collateralPriceData) private {
        if (order.orderType == OrderType.Mint) {
            // Mint force execute is only for claimed orders (VM took stablecoins but didn't confirm).
            // Deposit escrowed fee to vault, mint eTokens for net amount.
            address paymentToken = IOwnVault(order.vault).paymentToken();
            uint256 decimals = IERC20Metadata(paymentToken).decimals();
            uint256 decimalScaler = 10 ** (18 - decimals);

            uint256 feeAmount = _escrowedMintFees[order.orderId];
            if (feeAmount > 0) {
                _escrowedMintFees[order.orderId] = 0;
                IERC20(paymentToken).safeIncreaseAllowance(order.vault, feeAmount);
                IOwnVault(order.vault).depositFees(paymentToken, feeAmount);
                emit FeeCollected(order.orderId, paymentToken, feeAmount);
            }

            uint256 netAmount = order.amount - feeAmount;
            uint256 eTokenAmount = Math.mulDiv(netAmount * decimalScaler, PRECISION, order.price);
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IEToken(eToken).mint(order.user, eTokenAmount);
        } else {
            // Redeem: charge fee from gross collateral payout; vault retains fee collateral implicitly
            uint256 grossUsd = Math.mulDiv(order.amount, order.price, PRECISION);
            uint256 grossCollateral = _convertToCollateral(order, grossUsd, collateralPriceData);

            uint256 feeBps = IFeeCalculator(registry.feeCalculator()).getRedeemFee(order.asset, order.amount);
            uint256 feeCollateral = Math.mulDiv(grossCollateral, feeBps, BPS, Math.Rounding.Ceil);

            IOwnVault(order.vault).releaseCollateral(order.user, grossCollateral - feeCollateral);

            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IEToken(eToken).burn(address(this), order.amount);
        }
    }

    /// @dev Force execution when set price was NOT reachable.
    function _forceExecuteRefund(Order storage order, bytes calldata collateralPriceData) private {
        if (order.orderType == OrderType.Mint) {
            // Mint refund is only for claimed orders (VM took stablecoins but didn't confirm).
            // Vault releases equivalent collateral for the net amount, escrowed fee returned in stablecoins.
            address paymentToken = IOwnVault(order.vault).paymentToken();
            uint256 decimals = IERC20Metadata(paymentToken).decimals();
            uint256 feeAmount = _escrowedMintFees[order.orderId];
            uint256 usdValue = (order.amount - feeAmount) * 10 ** (18 - decimals);
            uint256 collateralAmount = _convertToCollateral(order, usdValue, collateralPriceData);
            IOwnVault(order.vault).releaseCollateral(order.user, collateralAmount);
            _returnEscrowedFee(order);
        } else {
            address eToken = IAssetRegistry(registry.assetRegistry()).getActiveToken(order.asset);
            IERC20(eToken).safeTransfer(order.user, order.amount);
        }
    }

    /// @dev Return escrowed mint fee to user.
    function _returnEscrowedFee(
        Order storage order
    ) private {
        uint256 feeAmount = _escrowedMintFees[order.orderId];
        if (feeAmount > 0) {
            _escrowedMintFees[order.orderId] = 0;
            address paymentToken = IOwnVault(order.vault).paymentToken();
            IERC20(paymentToken).safeTransfer(order.user, feeAmount);
        }
    }

    /// @dev Convert a USD value (18 decimals) to collateral amount using the vault's collateral oracle.
    ///      Forwards the exact ETH fee required by the oracle for verifyPrice.
    function _convertToCollateral(
        Order storage order,
        uint256 usdValue,
        bytes calldata collateralPriceData
    ) private returns (uint256) {
        bytes32 collatAsset = IOwnVault(order.vault).collateralOracleAsset();
        address oracleAddr = IAssetRegistry(registry.assetRegistry()).getPrimaryOracle(collatAsset);
        if (oracleAddr == address(0)) revert CollateralOracleNotSet();
        IOracleVerifier oracle = IOracleVerifier(oracleAddr);
        uint256 fee = oracle.verifyFee(collateralPriceData);
        (uint256 price,) = oracle.verifyPrice{value: fee}(collatAsset, collateralPriceData);
        return Math.mulDiv(usdValue, PRECISION, price);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Validate that the vault is registered, has a payment token, and supports the asset.
    function _validateVaultAndAsset(address vault, bytes32 asset) private view {
        if (!IVaultFactory(registry.vaultFactory()).isRegisteredVault(vault)) {
            revert VaultNotRegistered(vault);
        }
        if (IOwnVault(vault).paymentToken() == address(0)) {
            revert PaymentTokenNotSet(vault);
        }
        if (!IAssetRegistry(registry.assetRegistry()).isActiveAsset(asset)) {
            revert AssetNotActive(asset);
        }
        if (!IOwnVault(vault).isAssetSupported(asset)) {
            revert VaultAssetNotSupported(vault, asset);
        }
    }

    /// @dev Verify whether the set price was reachable during the time window.
    ///      For Pyth oracle, each verifyPrice call consumes ETH from msg.value.
    ///      Fees are computed via verifyFee() before each call.
    function _verifyPriceRange(Order storage order, bytes calldata priceProofData) private returns (bool) {
        if (priceProofData.length == 0) return false;

        (bytes memory lowPriceData, bytes memory highPriceData) = abi.decode(priceProofData, (bytes, bytes));

        address oracleAddr = IAssetRegistry(registry.assetRegistry()).getPrimaryOracle(order.asset);
        if (oracleAddr == address(0)) return false;

        uint256 windowStart = order.claimedAt > 0 ? order.claimedAt : order.createdAt;

        (uint256 lowPrice, uint256 lowTs) = _callVerifyPrice(oracleAddr, order.asset, lowPriceData);
        if (lowTs < windowStart || lowTs > block.timestamp) return false;

        (uint256 highPrice, uint256 highTs) = _callVerifyPrice(oracleAddr, order.asset, highPriceData);
        if (highTs < windowStart || highTs > block.timestamp) return false;

        if (lowPrice > highPrice) (lowPrice, highPrice) = (highPrice, lowPrice);

        return order.orderType == OrderType.Mint ? lowPrice <= order.price : highPrice >= order.price;
    }

    /// @dev Call verifyFee then verifyPrice on the oracle, forwarding the exact fee.
    function _callVerifyPrice(
        address oracleAddr,
        bytes32 asset,
        bytes memory proofData
    ) private returns (uint256 price, uint256 timestamp) {
        IOracleVerifier oracle = IOracleVerifier(oracleAddr);
        uint256 fee = oracle.verifyFee(proofData);
        return oracle.verifyPrice{value: fee}(asset, proofData);
    }

    /// @dev Calculate the eToken-unit exposure for an order (18 decimals).
    ///      For mint: converts stablecoin amount to eToken units using the order price.
    ///      For redeem: order.amount is already in eToken units.
    function _calculateExposure(
        Order storage order
    ) private view returns (uint256) {
        if (order.orderType == OrderType.Mint) {
            address paymentToken = IOwnVault(order.vault).paymentToken();
            uint256 decimals = IERC20Metadata(paymentToken).decimals();
            uint256 decimalScaler = 10 ** (18 - decimals);
            return Math.mulDiv(order.amount * decimalScaler, PRECISION, order.price);
        } else {
            return order.amount;
        }
    }

    /// @dev Remove an order from the open orders array (swap-and-pop).
    function _removeFromOpenOrders(bytes32 asset, uint256 orderId) private {
        uint256[] storage ids = _openOrders[asset];
        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            if (ids[i] == orderId) {
                ids[i] = ids[len - 1];
                ids.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }
}
