// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {Order, OrderStatus, OrderType, PRECISION, Quote} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OwnMarket — RFQ order execution marketplace
/// @notice Orders settle against firm, signer-issued quotes authorised by the global signer
///         registry on VaultManager. Mint proceeds flow to the signer's linked settlement
///         address; redeem payouts come from it. All orders use the single global payment token.
///         Market orders execute atomically; limit / redeem orders rest on-chain (escrowing the
///         input) and are filled — possibly partially — by a relayer carrying a signed quote.
///         Redeem orders additionally let the user force execution at the oracle price after the
///         global claim threshold, releasing the order's bound vault collateral as recourse against
///         an unresponsive maker. Trading pause blocks execution and force-execute; a permanently
///         halted asset blocks both and is redeemed via {redeemHalted} from the halt redeem address.
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
        _validateAsset(quote.asset);
        _checkTradeable(quote.asset, quote.orderType);

        // Effects: consume the quote before any value movement.
        address maker = _consumeQuote(quote, signature);

        uint256 amountOut = quote.orderType == OrderType.Mint
            ? _settleMint(quote.user, maker, quote.asset, quote.amount, quote.price, false, _paymentToken())
            : _settleRedeem(quote.user, maker, quote.asset, quote.amount, quote.price, false);

        emit OrderExecuted(
            quote.quoteId, quote.user, maker, quote.asset, uint8(quote.orderType), quote.amount, amountOut
        );
    }

    // ──────────────────────────────────────────────────────────
    //  Resting orders (limit / redeem)
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function placeOrder(
        bytes32 asset,
        OrderType orderType,
        uint256 amount,
        uint256 limitPrice,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (limitPrice == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        _validateAsset(asset);
        _checkTradeable(asset, orderType);

        address escrowToken = orderType == OrderType.Mint ? _paymentToken() : _activeToken(asset);

        orderId = _nextOrderId++;
        _orders[orderId] = Order({
            orderId: orderId,
            user: msg.sender,
            asset: asset,
            orderType: orderType,
            amount: amount,
            filledAmount: 0,
            limitPrice: limitPrice,
            createdAt: block.timestamp,
            expiry: expiry,
            status: OrderStatus.Open,
            escrowToken: escrowToken
        });
        _userOrders[msg.sender].push(orderId);

        // Escrow accounting assumes sent == received; reject fee-on-transfer tokens.
        uint256 balBefore = IERC20(escrowToken).balanceOf(address(this));
        IERC20(escrowToken).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(escrowToken).balanceOf(address(this)) - balBefore != amount) {
            revert FeeOnTransferNotSupported(escrowToken);
        }

        emit OrderPlaced(orderId, msg.sender, uint8(orderType), asset, amount, limitPrice);
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
        if (quote.user != order.user || quote.asset != order.asset || quote.orderType != order.orderType) {
            revert QuoteTermsMismatch();
        }

        // A redeem order escrowed in a now-legacy token cannot be filled; the owner cancels/expires
        // to recover the original token and converts it.
        if (order.orderType == OrderType.Redeem && order.escrowToken != _activeToken(order.asset)) {
            revert OrderTokenMigrated(quote.orderId);
        }

        uint256 remaining = order.amount - order.filledAmount;
        if (quote.amount > remaining) revert FillExceedsRemaining(quote.orderId);

        // The quote price must respect the order's limit.
        if (order.orderType == OrderType.Mint) {
            if (quote.price > order.limitPrice) revert LimitNotSatisfied();
        } else {
            if (quote.price < order.limitPrice) revert LimitNotSatisfied();
        }

        _checkTradeable(order.asset, order.orderType);

        // Effects.
        address maker = _consumeQuote(quote, signature);
        order.filledAmount += quote.amount;
        uint256 newRemaining = remaining - quote.amount;
        if (newRemaining == 0) order.status = OrderStatus.Filled;

        // Interactions.
        uint256 amountOut = order.orderType == OrderType.Mint
            ? _settleMint(order.user, maker, order.asset, quote.amount, quote.price, true, order.escrowToken)
            : _settleRedeem(order.user, maker, order.asset, quote.amount, quote.price, true);

        emit OrderFilled(quote.orderId, quote.quoteId, maker, quote.amount, amountOut, newRemaining);
    }

    /// @inheritdoc IOwnMarket
    function forceExecuteOrder(
        uint256 orderId,
        address vault,
        bytes calldata assetPriceData,
        bytes calldata collateralPriceData
    ) external payable nonReentrant {
        Order storage order = _orders[orderId];
        if (order.user == address(0)) revert OrderNotFound(orderId);
        if (order.user != msg.sender) revert OnlyOrderOwner(orderId);
        if (order.status != OrderStatus.Open) revert InvalidOrderStatus(orderId);
        if (order.orderType != OrderType.Redeem) revert ForceMintNotAllowed(orderId);
        // A redeem order escrowed in a now-legacy token cannot be force-executed; cancel to recover.
        if (order.escrowToken != _activeToken(order.asset)) revert OrderTokenMigrated(orderId);

        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        if (!vmgr.isRegisteredVault(vault)) revert VaultNotRegistered(vault);
        if (vmgr.isVaultExcluded(vault)) revert VaultExcludedFromPool(vault);
        // Pause and halt both disable the force path.
        if (vmgr.isTradingPaused(order.asset)) revert AssetPaused(order.asset);
        if (vmgr.isAssetHalted(order.asset)) revert ForceDisabledDuringHalt(order.asset);
        if (block.timestamp < order.createdAt + vmgr.claimThreshold()) {
            revert ForceWindowNotElapsed(orderId);
        }

        uint256 remaining = order.amount - order.filledAmount;

        // Asset proof must fall in the order's window and reach the limit; payout settles at the limit.
        // Window-scoped (not fresh) by design — VM-failure recourse.
        (uint256 reachedPrice, uint256 assetTs) = _verifyAssetPrice(order.asset, assetPriceData);
        if (assetTs < order.createdAt || assetTs > block.timestamp) revert AssetPriceProofOutsideWindow();
        if (reachedPrice < order.limitPrice) revert PriceBelowMinimum();

        uint256 grossUsd = Math.mulDiv(remaining, order.limitPrice, PRECISION);
        uint256 grossCollateral = _convertToCollateral(vault, grossUsd, collateralPriceData);

        // Effects.
        order.filledAmount = order.amount;
        order.status = OrderStatus.ForceExecuted;

        // Interactions: release collateral, burn escrowed eTokens, shrink global exposure.
        IOwnVault(vault).releaseCollateral(order.user, grossCollateral);
        IEToken(_activeToken(order.asset)).burn(address(this), remaining);
        vmgr.closeExposure(order.asset, remaining);

        emit OrderForceExecuted(orderId, order.user, remaining, grossCollateral);

        _refundETH();
    }

    /// @inheritdoc IOwnMarket
    function redeemHalted(bytes32 asset, uint256 eTokenAmount) external nonReentrant returns (uint256 payout) {
        if (eTokenAmount == 0) revert ZeroAmount();

        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        if (!vmgr.isAssetHalted(asset)) revert AssetNotHalted(asset);
        uint256 haltPrice = vmgr.assetHaltPrice(asset);
        if (haltPrice == 0) revert InvalidHaltPrice();
        address haltAddr = vmgr.haltRedeemAddress();
        if (haltAddr == address(0)) revert HaltRedeemAddressNotSet();

        address pay = _paymentToken();
        payout = Math.mulDiv(eTokenAmount, haltPrice, PRECISION * 10 ** (18 - IERC20Metadata(pay).decimals()));

        // Pull stables from the halt fund to the caller, burn the eTokens, shrink global exposure.
        IERC20(pay).safeTransferFrom(haltAddr, msg.sender, payout);
        IEToken(_activeToken(asset)).burn(msg.sender, eTokenAmount);
        vmgr.closeExposure(asset, eTokenAmount);

        emit OrderRedeemedHalted(msg.sender, asset, eTokenAmount, payout);
    }

    /// @inheritdoc IOwnMarket
    function convertLegacy(
        bytes32 asset,
        address legacyToken,
        uint256 amount
    ) external nonReentrant returns (uint256 newAmount) {
        if (amount == 0) revert ZeroAmount();

        IAssetRegistry ar = IAssetRegistry(registry.assetRegistry());
        address active = ar.getActiveToken(asset);
        if (legacyToken == active || !ar.isValidToken(asset, legacyToken)) revert NotLegacyToken(legacyToken);
        uint256 ratio = ar.legacyRatioToActive(legacyToken);
        if (ratio == 0) revert RatioNotSet(legacyToken);

        // 1:ratio re-denomination — exposure is split-invariant (handled by VaultManager.applySplit),
        // so no open/close exposure here. Intentionally allowed while trading is paused/halted so
        // legacy holders can always reach the active token (and thus redemption).
        newAmount = Math.mulDiv(amount, ratio, PRECISION);
        if (newAmount == 0) revert ZeroAmount();

        IEToken(legacyToken).burn(msg.sender, amount);
        IEToken(active).mint(msg.sender, newAmount);

        emit LegacyConverted(msg.sender, asset, legacyToken, amount, newAmount);
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

    /// @dev Validate expiry, replay, and signer (an authorised global signer), then mark the
    ///      quote used. Returns the signer's linked settlement address (mint sink / redeem source).
    function _consumeQuote(Quote calldata quote, bytes calldata signature) private returns (address maker) {
        if (block.timestamp > quote.expiry) revert QuoteExpired();
        bytes32 digest = quoteDigest(quote);
        if (_usedQuotes[digest]) revert QuoteAlreadyUsed();
        address signer = digest.toEthSignedMessageHash().recover(signature);
        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        if (!vmgr.isSigner(signer)) revert InvalidQuoteSigner();
        maker = vmgr.signerLinkedAddress(signer);
        _usedQuotes[digest] = true;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — settlement
    // ──────────────────────────────────────────────────────────

    /// @dev Settle a mint of `amountIn` stablecoins at `price`. When `fromEscrow` the stablecoins
    ///      are already held by this contract; otherwise they are pulled from `user`. The full
    ///      amount goes to the maker (signer's linked address); eTokens are minted to `user`.
    function _settleMint(
        address user,
        address maker,
        bytes32 asset,
        uint256 amountIn,
        uint256 price,
        bool fromEscrow,
        address payToken
    ) private returns (uint256 eTokenAmount) {
        // Escrow fills settle in the token escrowed at placement (payToken == order.escrowToken),
        // so a later payment-token change cannot mismatch the escrow.
        eTokenAmount = Math.mulDiv(amountIn * (10 ** (18 - IERC20Metadata(payToken).decimals())), PRECISION, price);

        // Atomic check + commit of global exposure (asset cap + global utilisation) before any
        // external token movement, so a breach reverts cleanly with no side effects.
        IVaultManager(registry.vaultManager()).openExposure(asset, eTokenAmount);

        // Route the full stablecoin amount to the maker (spread captured offchain).
        if (fromEscrow) {
            IERC20(payToken).safeTransfer(maker, amountIn);
        } else {
            IERC20(payToken).safeTransferFrom(user, maker, amountIn);
        }

        // Mint the eTokens to the user.
        IEToken(_activeToken(asset)).mint(user, eTokenAmount);
    }

    /// @dev Settle a redeem of `amountIn` eTokens at `price`. The maker pays the full stablecoin
    ///      payout to `user`. When `fromEscrow` the eTokens are burned from this contract's escrow,
    ///      otherwise from `user`. Returns the stablecoin payout to the user.
    function _settleRedeem(
        address user,
        address maker,
        bytes32 asset,
        uint256 amountIn,
        uint256 price,
        bool fromEscrow
    ) private returns (uint256 netPayout) {
        address pay = _paymentToken();
        netPayout = Math.mulDiv(amountIn, price, PRECISION * 10 ** (18 - IERC20Metadata(pay).decimals()));

        IERC20(pay).safeTransferFrom(maker, user, netPayout);

        // Burn the eTokens and shrink global exposure.
        IEToken(_activeToken(asset)).burn(fromEscrow ? address(this) : user, amountIn);
        IVaultManager(registry.vaultManager()).closeExposure(asset, amountIn);
    }

    /// @dev Return the unfilled escrow to the order owner.
    function _returnEscrow(Order storage order, uint256 remaining) private {
        if (remaining == 0) return;
        IERC20(order.escrowToken).safeTransfer(order.user, remaining);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — oracle helpers (force path only)
    // ──────────────────────────────────────────────────────────

    /// @dev Verify a fresh signed price proof for an asset, forwarding the oracle's ETH fee.
    function _verifyAssetPrice(
        bytes32 asset,
        bytes calldata priceData
    ) private returns (uint256 price, uint256 timestamp) {
        address oracleAddr = _getOracleForAsset(asset);
        if (oracleAddr == address(0)) revert AssetOracleNotSet(asset);
        IOracleVerifier oracle = IOracleVerifier(oracleAddr);
        uint256 fee = oracle.verifyFee(priceData);
        (price, timestamp) = oracle.verifyPrice{value: fee}(asset, priceData);
    }

    /// @dev Convert a USD value (18 decimals) to collateral units using the vault's collateral oracle.
    function _convertToCollateral(
        address vault,
        uint256 usdValue,
        bytes calldata collateralPriceData
    ) private returns (uint256) {
        bytes32 collatAsset = IVaultManager(registry.vaultManager()).vaultCollateralAsset(vault);
        address oracleAddr = _getOracleForAsset(collatAsset);
        if (oracleAddr == address(0)) revert CollateralOracleNotSet();
        IOracleVerifier oracle = IOracleVerifier(oracleAddr);
        uint256 fee = oracle.verifyFee(collateralPriceData);
        (uint256 price, uint256 timestamp) = oracle.verifyPrice{value: fee}(collatAsset, collateralPriceData);

        // Collateral is released now, so its price must be current.
        if (timestamp > block.timestamp || block.timestamp - timestamp > registry.priceMaxAge()) {
            revert StaleCollateralPrice();
        }

        // usdValue and price are 18-decimal, so this yields an 18-decimal collateral amount.
        // Scale down to the collateral token's decimals (floor — protocol-favorable).
        uint256 collateral18 = Math.mulDiv(usdValue, PRECISION, price);
        uint256 collatDecimals = IERC20Metadata(IOwnVault(vault).asset()).decimals();
        return collateral18 / (10 ** (18 - collatDecimals));
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — misc helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Trading-status gate shared by execute/fill/place: revert if the asset's trading is
    ///      paused, or if it is halted (mint blocked; redeem routed through {redeemHalted}).
    function _checkTradeable(bytes32 asset, OrderType orderType) private view {
        IVaultManager vmgr = IVaultManager(registry.vaultManager());
        if (vmgr.isTradingPaused(asset)) revert AssetPaused(asset);
        if (vmgr.isAssetHalted(asset)) {
            if (orderType == OrderType.Mint) revert MintBlockedDuringHalt(asset);
            revert TradingHalted(asset);
        }
    }

    /// @dev Validate that the asset is active in the AssetRegistry.
    function _validateAsset(
        bytes32 asset
    ) private view {
        if (!IAssetRegistry(registry.assetRegistry()).isActiveAsset(asset)) {
            revert AssetNotActive(asset);
        }
    }

    /// @dev Resolve and validate the global payment token.
    function _paymentToken() private view returns (address token) {
        token = IVaultManager(registry.vaultManager()).paymentToken();
        if (token == address(0)) revert PaymentTokenNotSet();
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
