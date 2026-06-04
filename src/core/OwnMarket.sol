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
import {BPS, Order, OrderStatus, OrderType, PRECISION, Quote} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnMarket — RFQ order execution marketplace
/// @notice Orders settle against firm, VM-signed quotes. Market orders execute atomically in a
///         single transaction; limit / redeem orders rest on-chain (escrowing the input) and are
///         filled — possibly in partial chunks — by the VM or a relayer carrying a VM-signed quote.
///         Redeem orders additionally let the user force execution at the oracle price after the
///         vault's claim threshold, as recourse against an unresponsive VM. Mint orders have no
///         force path. The oracle is only consulted on the force path.
contract OwnMarket is IOwnMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ──────────────────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────────────────

    IProtocolRegistry public immutable registry;

    // ──────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────

    uint256 private _nextOrderId = 1;

    mapping(uint256 => Order) private _orders;
    mapping(address => uint256[]) private _userOrders;

    /// @dev Single-use guard for quotes, keyed by quote digest.
    mapping(bytes32 => bool) private _usedQuotes;

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
    //  Market orders (atomic)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function executeOrder(Quote calldata quote, bytes calldata signature) external nonReentrant {
        if (quote.orderId != 0) revert QuoteOrderMismatch();
        if (msg.sender != quote.user) revert NotQuoteUser();
        if (quote.amount == 0) revert ZeroAmount();
        if (quote.price == 0) revert InvalidPrice();
        _validateVaultAndAsset(quote.vault, quote.asset);

        IOwnVault vaultContract = IOwnVault(quote.vault);
        if (vaultContract.isEffectivelyPaused(quote.asset)) revert AssetPaused(quote.asset);
        if (vaultContract.isEffectivelyHalted(quote.asset)) {
            if (quote.orderType == OrderType.Mint) revert MintBlockedDuringHalt(quote.asset);
            revert TradingHalted(quote.asset);
        }

        // Effects: consume the quote before any value movement.
        _consumeQuote(quote, signature);

        uint256 amountOut = quote.orderType == OrderType.Mint
            ? _settleMint(quote.user, quote.vault, quote.asset, quote.amount, quote.price, false, 0)
            : _settleRedeem(quote.user, quote.vault, quote.asset, quote.amount, quote.price, false, 0);

        emit OrderExecuted(
            quote.quoteId, quote.user, vaultContract.vm(), quote.asset, uint8(quote.orderType), quote.amount, amountOut
        );
    }

    // ──────────────────────────────────────────────────────────
    //  Resting orders (limit / redeem)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function placeOrder(
        address vault,
        bytes32 asset,
        OrderType orderType,
        uint256 amount,
        uint256 limitPrice,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (limitPrice == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        _validateVaultAndAsset(vault, asset);

        IOwnVault vaultContract = IOwnVault(vault);
        if (vaultContract.isEffectivelyPaused(asset)) revert AssetPaused(asset);
        if (orderType == OrderType.Mint && vaultContract.isEffectivelyHalted(asset)) {
            revert MintBlockedDuringHalt(asset);
        }

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            orderId: orderId,
            user: msg.sender,
            vault: vault,
            asset: asset,
            orderType: orderType,
            amount: amount,
            filledAmount: 0,
            limitPrice: limitPrice,
            createdAt: block.timestamp,
            expiry: expiry,
            status: OrderStatus.Open
        });
        _userOrders[msg.sender].push(orderId);

        // Escrow the input.
        if (orderType == OrderType.Mint) {
            IERC20(vaultContract.paymentToken()).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            IERC20(_activeToken(asset)).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit OrderPlaced(orderId, msg.sender, uint8(orderType), asset, vault, amount, limitPrice);
    }

    /// @inheritdoc IOwnMarket
    function fillOrder(Quote calldata quote, bytes calldata signature) external nonReentrant {
        if (quote.orderId == 0) revert QuoteOrderMismatch();

        Order storage order = _orders[quote.orderId];
        if (order.user == address(0)) revert OrderNotFound(quote.orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(quote.orderId);
        if (block.timestamp > order.expiry) revert OrderExpiredError(quote.orderId);
        if (quote.amount == 0) revert ZeroAmount();
        if (quote.price == 0) revert InvalidPrice();

        // The quote must describe the same order.
        if (
            quote.user != order.user || quote.vault != order.vault || quote.asset != order.asset
                || quote.orderType != order.orderType
        ) {
            revert QuoteTermsMismatch();
        }

        uint256 remaining = order.amount - order.filledAmount;
        if (quote.amount > remaining) revert FillExceedsRemaining(quote.orderId);

        // The quote price must respect the order's limit.
        if (order.orderType == OrderType.Mint) {
            if (quote.price > order.limitPrice) revert LimitNotSatisfied();
        } else {
            if (quote.price < order.limitPrice) revert LimitNotSatisfied();
        }

        {
            IOwnVault vaultContract = IOwnVault(order.vault);
            if (vaultContract.isEffectivelyPaused(order.asset)) revert AssetPaused(order.asset);
            if (vaultContract.isEffectivelyHalted(order.asset)) {
                if (order.orderType == OrderType.Mint) revert MintBlockedDuringHalt(order.asset);
                revert TradingHalted(order.asset);
            }
        }

        // Effects.
        _consumeQuote(quote, signature);
        order.filledAmount += quote.amount;
        uint256 newRemaining = remaining - quote.amount;
        if (newRemaining == 0) order.status = OrderStatus.Filled;

        // Interactions.
        uint256 amountOut = order.orderType == OrderType.Mint
            ? _settleMint(order.user, order.vault, order.asset, quote.amount, quote.price, true, quote.orderId)
            : _settleRedeem(order.user, order.vault, order.asset, quote.amount, quote.price, true, quote.orderId);

        emit OrderFilled(
            quote.orderId, quote.quoteId, IOwnVault(order.vault).vm(), quote.amount, amountOut, newRemaining
        );
    }

    /// @inheritdoc IOwnMarket
    function forceExecuteOrder(
        uint256 orderId,
        bytes calldata assetPriceData,
        bytes calldata collateralPriceData
    ) external payable nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId);
        if (order.orderType != OrderType.Redeem) revert ForceMintNotAllowed(orderId);

        IOwnVault vaultContract = IOwnVault(order.vault);
        if (block.timestamp < order.createdAt + vaultContract.claimThreshold()) {
            revert ForceWindowNotElapsed(orderId);
        }

        uint256 remaining = order.amount - order.filledAmount;

        // Resolve the settlement price (halt price during halt, else a fresh oracle proof).
        uint256 price = vaultContract.isEffectivelyHalted(order.asset)
            ? _resolveHaltPrice(order.vault, order.asset)
            : _verifyAssetPrice(order.asset, assetPriceData);
        if (price < order.limitPrice) revert PriceBelowMinimum();

        // Value the redemption in collateral terms.
        uint256 grossUsd = Math.mulDiv(remaining, price, PRECISION);
        uint256 grossCollateral = _convertToCollateral(order.vault, grossUsd, collateralPriceData);
        uint256 feeBps = IFeeCalculator(registry.feeCalculator()).getRedeemFee(order.asset, remaining);
        uint256 feeCollateral = Math.mulDiv(grossCollateral, feeBps, BPS, Math.Rounding.Ceil);
        uint256 netCollateral = grossCollateral - feeCollateral;

        // Effects.
        order.filledAmount = order.amount;
        order.status = OrderStatus.ForceExecuted;

        // Interactions: release collateral, burn escrowed eTokens, shrink exposure.
        vaultContract.releaseCollateral(order.user, netCollateral);
        IEToken(_activeToken(order.asset)).burn(address(this), remaining);
        vaultContract.updateExposure(order.asset, -int256(remaining), price);

        emit OrderForceExecuted(orderId, order.user, remaining, netCollateral);

        _refundETH();
    }

    /// @inheritdoc IOwnMarket
    function cancelOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId);

        uint256 remaining = order.amount - order.filledAmount;
        order.status = OrderStatus.Cancelled;
        _returnEscrow(order, remaining);

        emit OrderCancelled(orderId, msg.sender);
    }

    /// @inheritdoc IOwnMarket
    function expireOrder(
        uint256 orderId
    ) external nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId);
        if (block.timestamp <= order.expiry) revert ExpiryNotReached(orderId);

        uint256 remaining = order.amount - order.filledAmount;
        order.status = OrderStatus.Expired;
        _returnEscrow(order, remaining);

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
    function getUserOrders(
        address user
    ) external view returns (uint256[] memory) {
        return _userOrders[user];
    }

    /// @inheritdoc IOwnMarket
    function isQuoteUsed(
        bytes32 quoteDigest_
    ) external view returns (bool) {
        return _usedQuotes[quoteDigest_];
    }

    /// @inheritdoc IOwnMarket
    function quoteDigest(
        Quote calldata quote
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                quote.orderId,
                quote.user,
                quote.vault,
                quote.asset,
                quote.orderType,
                quote.amount,
                quote.price,
                quote.quoteId,
                quote.expiry,
                block.chainid,
                address(this)
            )
        );
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — quote verification
    // ──────────────────────────────────────────────────────────

    /// @dev Validate expiry, replay, and signer (an authorised quote signer of the vault),
    ///      then mark the quote used. The signer set is independent of the vault's operational
    ///      `vm` address, which remains the fund source/sink.
    function _consumeQuote(Quote calldata quote, bytes calldata signature) private {
        if (block.timestamp > quote.expiry) revert QuoteExpired();
        bytes32 digest = quoteDigest(quote);
        if (_usedQuotes[digest]) revert QuoteAlreadyUsed();
        address signer = digest.toEthSignedMessageHash().recover(signature);
        if (!IOwnVault(quote.vault).isQuoteSigner(signer)) revert InvalidQuoteSigner();
        _usedQuotes[digest] = true;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — settlement
    // ──────────────────────────────────────────────────────────

    /// @dev Settle a mint of `amountIn` stablecoins at `price`. When `fromEscrow` the stablecoins
    ///      are already held by this contract; otherwise they are pulled from `user`. Net goes to
    ///      the VM, fee to the vault; eTokens are minted to `user`. Returns the eToken amount minted.
    function _settleMint(
        address user,
        address vault,
        bytes32 asset,
        uint256 amountIn,
        uint256 price,
        bool fromEscrow,
        uint256 orderId
    ) private returns (uint256 eTokenAmount) {
        address paymentToken = IOwnVault(vault).paymentToken();
        uint256 feeAmount = Math.mulDiv(
            amountIn, IFeeCalculator(registry.feeCalculator()).getMintFee(asset, amountIn), BPS, Math.Rounding.Ceil
        );
        eTokenAmount = Math.mulDiv(
            (amountIn - feeAmount) * (10 ** (18 - IERC20Metadata(paymentToken).decimals())), PRECISION, price
        );

        // Projected utilization check against the exposure actually being added.
        {
            uint256 projectedUtil =
                IOwnVault(vault).projectedExposureUtilization(Math.mulDiv(eTokenAmount, price, PRECISION));
            uint256 maxUtil = IOwnVault(vault).maxUtilization();
            if (projectedUtil > maxUtil) revert UtilizationBreached(projectedUtil, maxUtil);
        }

        // Route stablecoins: net to VM, fee to vault.
        if (fromEscrow) {
            IERC20(paymentToken).safeTransfer(IOwnVault(vault).vm(), amountIn - feeAmount);
        } else {
            IERC20(paymentToken).safeTransferFrom(user, IOwnVault(vault).vm(), amountIn - feeAmount);
            if (feeAmount > 0) IERC20(paymentToken).safeTransferFrom(user, address(this), feeAmount);
        }
        if (feeAmount > 0) {
            IERC20(paymentToken).safeIncreaseAllowance(vault, feeAmount);
            IOwnVault(vault).depositFees(paymentToken, feeAmount);
            emit FeeCollected(orderId, paymentToken, feeAmount);
        }

        // Mint and record exposure.
        IEToken(_activeToken(asset)).mint(user, eTokenAmount);
        IOwnVault(vault).updateExposure(asset, int256(eTokenAmount), price);
    }

    /// @dev Settle a redeem of `amountIn` eTokens at `price`. The VM pays stablecoins (net to user,
    ///      fee to vault). When `fromEscrow` the eTokens are burned from this contract's escrow,
    ///      otherwise from `user`. Returns the net stablecoin payout to the user.
    function _settleRedeem(
        address user,
        address vault,
        bytes32 asset,
        uint256 amountIn,
        uint256 price,
        bool fromEscrow,
        uint256 orderId
    ) private returns (uint256 netPayout) {
        address paymentToken = IOwnVault(vault).paymentToken();
        address vmAddr = IOwnVault(vault).vm();
        uint256 feeAmount;
        {
            uint256 grossPayout =
                Math.mulDiv(amountIn, price, PRECISION * 10 ** (18 - IERC20Metadata(paymentToken).decimals()));
            feeAmount = Math.mulDiv(
                grossPayout,
                IFeeCalculator(registry.feeCalculator()).getRedeemFee(asset, amountIn),
                BPS,
                Math.Rounding.Ceil
            );
            netPayout = grossPayout - feeAmount;
        }

        IERC20(paymentToken).safeTransferFrom(vmAddr, user, netPayout);
        if (feeAmount > 0) {
            IERC20(paymentToken).safeTransferFrom(vmAddr, address(this), feeAmount);
            IERC20(paymentToken).safeIncreaseAllowance(vault, feeAmount);
            IOwnVault(vault).depositFees(paymentToken, feeAmount);
            emit FeeCollected(orderId, paymentToken, feeAmount);
        }

        // Burn the eTokens and shrink exposure.
        IEToken(_activeToken(asset)).burn(fromEscrow ? address(this) : user, amountIn);
        IOwnVault(vault).updateExposure(asset, -int256(amountIn), price);
    }

    /// @dev Return the unfilled escrow to the order owner.
    function _returnEscrow(Order storage order, uint256 remaining) private {
        if (remaining == 0) return;
        if (order.orderType == OrderType.Mint) {
            IERC20(IOwnVault(order.vault).paymentToken()).safeTransfer(order.user, remaining);
        } else {
            IERC20(_activeToken(order.asset)).safeTransfer(order.user, remaining);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — oracle helpers (force path only)
    // ──────────────────────────────────────────────────────────

    /// @dev Verify a fresh signed price proof for an asset, forwarding the oracle's ETH fee.
    function _verifyAssetPrice(bytes32 asset, bytes calldata priceData) private returns (uint256 price) {
        address oracleAddr = _getOracleForAsset(asset);
        if (oracleAddr == address(0)) revert AssetOracleNotSet(asset);
        IOracleVerifier oracle = IOracleVerifier(oracleAddr);
        uint256 fee = oracle.verifyFee(priceData);
        (price,) = oracle.verifyPrice{value: fee}(asset, priceData);
    }

    /// @dev Convert a USD value (18 decimals) to collateral units using the vault's collateral oracle.
    function _convertToCollateral(
        address vault,
        uint256 usdValue,
        bytes calldata collateralPriceData
    ) private returns (uint256) {
        bytes32 collatAsset = IOwnVault(vault).collateralOracleAsset();
        address oracleAddr = _getOracleForAsset(collatAsset);
        if (oracleAddr == address(0)) revert CollateralOracleNotSet();
        IOracleVerifier oracle = IOracleVerifier(oracleAddr);
        uint256 fee = oracle.verifyFee(collateralPriceData);
        (uint256 price,) = oracle.verifyPrice{value: fee}(collatAsset, collateralPriceData);

        // usdValue and price are 18-decimal, so this yields an 18-decimal collateral amount.
        // Scale down to the collateral token's decimals (floor — protocol-favorable).
        uint256 collateral18 = Math.mulDiv(usdValue, PRECISION, price);
        uint256 collatDecimals = IERC20Metadata(IOwnVault(vault).asset()).decimals();
        return collateral18 / (10 ** (18 - collatDecimals));
    }

    /// @dev Resolve the effective halt price for an asset (admin-set halt price, else latest oracle).
    function _resolveHaltPrice(address vault, bytes32 asset) private view returns (uint256 price) {
        price = IOwnVault(vault).getAssetHaltPrice(asset);
        if (price > 0) return price;

        address oracleAddr = _getOracleForAsset(asset);
        if (oracleAddr != address(0)) {
            (price,) = IOracleVerifier(oracleAddr).getPrice(asset);
        }
        if (price == 0) revert InvalidHaltPrice();
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — misc helpers
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

    /// @dev Resolve the active eToken for an asset via the AssetRegistry.
    function _activeToken(
        bytes32 asset
    ) private view returns (address) {
        return IAssetRegistry(registry.assetRegistry()).getActiveToken(asset);
    }

    /// @dev Resolve the oracle address for an asset via ProtocolRegistry.
    function _getOracleForAsset(
        bytes32 asset
    ) private view returns (address) {
        uint8 oracleType = IAssetRegistry(registry.assetRegistry()).getOracleType(asset);
        if (oracleType == 0) return registry.pythOracle();
        return registry.inhouseOracle();
    }

    /// @dev Refund any ETH left after oracle fees to the caller.
    function _refundETH() private {
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool ok,) = payable(msg.sender).call{value: remaining}("");
            if (!ok) revert ETHRefundFailed();
        }
    }
}
