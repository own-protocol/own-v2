// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IEToken} from "../interfaces/IEToken.sol";
import {IOracleVerifier} from "../interfaces/IOracleVerifier.sol";
import {IOwnMarket} from "../interfaces/IOwnMarket.sol";
import {IOwnVault} from "../interfaces/IOwnVault.sol";
import {IProtocolRegistry} from "../interfaces/IProtocolRegistry.sol";
import {IReserveVault} from "../interfaces/IReserveVault.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {BPS, Order, OrderStatus, OrderType, PRECISION, PsmConfig, Quote} from "../interfaces/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
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
contract OwnMarket is IOwnMarket, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ──────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────

    /// @dev EIP-712 typehash for signer-issued quotes.
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(uint256 orderId,address user,bytes32 asset,uint8 orderType,uint256 amount,uint256 price,uint256 quoteId,uint256 expiry)"
    );

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
    ) EIP712("Own Protocol", "1") {
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
        _pullExact(escrowToken, address(this), amount);

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

        // Mint fills open new exposure; gate on active asset like execute/placeOrder. Redeem winds down.
        if (order.orderType == OrderType.Mint) _validateAsset(order.asset);

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

        IVaultManager vmgr = _vaultManager();
        // Collateral source is protocol-designated per asset; the redeemer cannot pick an arbitrary
        // vault. address(0) (the default) disables force-execution for the asset (fail-safe).
        address designated = vmgr.forceExecuteVault(order.asset);
        if (designated == address(0)) revert ForceExecuteVaultNotSet();
        if (vault != designated) revert VaultNotDesignated(vault, designated);
        if (!vmgr.isRegisteredVault(vault)) revert VaultNotRegistered(vault);
        if (vmgr.isVaultExcluded(vault)) revert VaultExcludedFromPool(vault);
        // Pause and halt both disable the force path.
        if (vmgr.isTradingPaused(order.asset)) revert AssetPaused(order.asset);
        if (vmgr.isAssetHalted(order.asset)) revert ForceDisabledDuringHalt(order.asset);
        // A zero claim threshold (pre-deploy default) disables force-execution entirely.
        uint256 threshold = vmgr.claimThreshold();
        if (threshold == 0) revert ForceNotEnabled();
        if (block.timestamp < order.createdAt + threshold) {
            revert ForceWindowNotElapsed(orderId);
        }

        uint256 remaining = order.amount - order.filledAmount;

        // Fresh price required: the current oracle price must still satisfy the order's limit, so a
        // stale favorable print can't be exercised after the market has moved. Payout settles at the
        // limit (bare oracle price, no maker spread).
        (uint256 currentPrice, uint256 assetTs) = _verifyAssetPrice(order.asset, assetPriceData);
        if (_isStale(assetTs, registry.priceMaxAge())) revert StaleAssetPrice();
        if (currentPrice < order.limitPrice) revert PriceBelowMinimum();

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

        IVaultManager vmgr = _vaultManager();
        if (!vmgr.isAssetHalted(asset)) revert AssetNotHalted(asset);
        uint256 haltPrice = vmgr.assetHaltPrice(asset);
        if (haltPrice == 0) revert InvalidHaltPrice();
        address haltAddr = vmgr.haltRedeemAddress();
        if (haltAddr == address(0)) revert HaltRedeemAddressNotSet();

        address pay = _paymentToken();
        payout = Math.mulDiv(eTokenAmount, haltPrice, PRECISION * _tokenScale(pay));

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

        IAssetRegistry ar = _assetRegistry();
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

    // ──────────────────────────────────────────────────────────
    //  PSM — 1:1 wrapper reserve mint / redeem
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    function psmMint(
        bytes32 asset,
        address wrapper,
        uint256 wrapperAmount
    ) external nonReentrant returns (uint256 eTokenAmount) {
        if (wrapperAmount == 0) revert ZeroAmount();
        _validateAsset(asset);
        _checkTradeable(asset, OrderType.Mint); // pause blocks; halt blocks minting

        // Wrapper leg must be fresh; the asset leg is enforced by openExposure below.
        (address reserveVault, uint256 ratio) = _psmContext(asset, wrapper, true);

        // Pull the wrapper straight into the reserve; escrow accounting assumes sent == received.
        _pullExact(wrapper, reserveVault, wrapperAmount);

        IVaultManager vmgr = _vaultManager();
        // Mark the new reserve before the exposure gate (matched mint is util-neutral).
        vmgr.pullCollateralPrice(reserveVault);

        // Wrapper units → 18-dec → eTokens at the derived ratio (floor — protocol-favorable).
        eTokenAmount = Math.mulDiv(wrapperAmount * _tokenScale(wrapper), ratio, PRECISION);
        if (eTokenAmount == 0) revert ZeroAmount();

        vmgr.openExposure(asset, eTokenAmount);
        IEToken(_activeToken(asset)).mint(msg.sender, eTokenAmount);

        emit PsmMinted(msg.sender, asset, wrapper, wrapperAmount, eTokenAmount, ratio);
    }

    /// @inheritdoc IOwnMarket
    function psmRedeem(
        bytes32 asset,
        address wrapper,
        uint256 eTokenAmount
    ) external nonReentrant returns (uint256 wrapperAmount) {
        if (eTokenAmount == 0) revert ZeroAmount();
        IVaultManager vmgr = _vaultManager();
        if (vmgr.isTradingPaused(asset)) revert AssetPaused(asset);
        // Halted assets redeem in-kind at the frozen halt mark; the live wrapper leg must be fresh.
        (address reserveVault, uint256 ratio) = _psmContext(asset, wrapper, vmgr.isAssetHalted(asset));

        // eTokens → wrapper units at the derived ratio (floor — protocol-favorable).
        wrapperAmount = Math.mulDiv(eTokenAmount, PRECISION, ratio) / _tokenScale(wrapper);
        if (wrapperAmount == 0) revert ZeroAmount();

        // Burn, shrink exposure, then release reserve (bounded by the vault's balance).
        IEToken(_activeToken(asset)).burn(msg.sender, eTokenAmount);
        vmgr.closeExposure(asset, eTokenAmount);
        IReserveVault(reserveVault).releaseCollateral(msg.sender, wrapperAmount);

        emit PsmRedeemed(msg.sender, asset, wrapper, eTokenAmount, wrapperAmount, ratio);
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
    //  Maintenance
    // ──────────────────────────────────────────────────────────

    /// @inheritdoc IOwnMarket
    /// @dev eTokens escrowed in resting redeem orders accrue dividends to the market; per-order
    ///      attribution is infeasible (global accumulator), so they sweep to the treasury.
    function sweepDividends(
        address eToken
    ) external nonReentrant returns (uint256 amount) {
        if (!_assetRegistry().isValidToken(IEToken(eToken).ticker(), eToken)) {
            revert InvalidEToken(eToken);
        }
        amount = IEToken(eToken).claimableRewards(address(this));
        if (amount == 0) revert NoDividendsToSweep();

        IEToken(eToken).claimRewards();
        address treasury = registry.treasury();
        IERC20(IEToken(eToken).rewardToken()).safeTransfer(treasury, amount);

        emit EscrowDividendsSwept(eToken, treasury, amount);
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
        // EIP-712: chainId + verifyingContract live in the domain separator.
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    quote.orderId,
                    quote.user,
                    quote.asset,
                    quote.orderType,
                    quote.amount,
                    quote.price,
                    quote.quoteId,
                    quote.expiry
                )
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
        address signer = digest.recover(signature);
        IVaultManager vmgr = _vaultManager();
        if (!vmgr.isSigner(signer)) revert InvalidQuoteSigner();
        maker = vmgr.signerLinkedAddress(signer);
        _usedQuotes[digest] = true;
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — settlement
    // ──────────────────────────────────────────────────────────

    /// @dev Bound the settle price to ±settleBandBps of the keeper-refreshed VaultManager mark,
    ///      capping the damage a leaked signer key can inflict per unit of size. Applies to the
    ///      execute/fill settle paths only; force-execute (oracle limit price) and redeemHalted
    ///      (fixed halt price) are intentionally exempt. Reverts {PriceOutOfBand} when breached.
    function _checkSettleBand(bytes32 asset, uint256 price) private view {
        IVaultManager vmgr = _vaultManager();
        uint256 mark = vmgr.assetMark(asset);
        // No mark → openExposure/closeExposure already reverts (PriceUnavailable); nothing to bound.
        if (mark == 0) return;
        // Both legs must bound against a keeper-fresh mark. The mint leg's openExposure enforces
        // maxMarkAge; closeExposure (redeem/exit) is intentionally stale-tolerant, so the band — the
        // leaked-key damage cap — must enforce freshness itself, else a redeem can settle within
        // ±band of a stale mark.
        if (block.timestamp - vmgr.assetMarkUpdatedAt(asset) > vmgr.maxMarkAge()) {
            revert StaleSettleMark(asset);
        }
        uint256 band = vmgr.settleBandBps();
        uint256 diff = price > mark ? price - mark : mark - price;
        if (diff * BPS > mark * band) revert PriceOutOfBand(asset, price, mark, band);
    }

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
        _checkSettleBand(asset, price);

        // Escrow fills settle in the token escrowed at placement (payToken == order.escrowToken),
        // so a later payment-token change cannot mismatch the escrow.
        eTokenAmount = Math.mulDiv(amountIn * _tokenScale(payToken), PRECISION, price);

        // Atomic check + commit of global exposure (asset cap + global utilisation) before any
        // external token movement, so a breach reverts cleanly with no side effects.
        _vaultManager().openExposure(asset, eTokenAmount);

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
        _checkSettleBand(asset, price);

        address pay = _paymentToken();
        netPayout = Math.mulDiv(amountIn, price, PRECISION * _tokenScale(pay));

        IERC20(pay).safeTransferFrom(maker, user, netPayout);

        // Burn the eTokens and shrink global exposure.
        IEToken(_activeToken(asset)).burn(fromEscrow ? address(this) : user, amountIn);
        _vaultManager().closeExposure(asset, amountIn);
    }

    /// @dev Return the unfilled escrow to the order owner.
    function _returnEscrow(Order storage order, uint256 remaining) private {
        if (remaining == 0) return;
        _pushOrSweep(order.escrowToken, order.user, remaining);
    }

    /// @dev Push tokens to `to`; if the transfer fails (e.g. a USDC/USDT blocklist freeze of the
    ///      recipient), sweep to the protocol treasury for off-chain resolution instead of
    ///      bricking cancel/expire. The treasury (governance multisig) is assumed non-freezable.
    function _pushOrSweep(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        IERC20(token).safeTransfer(registry.treasury(), amount);
        emit EscrowSweptToTreasury(to, token, amount);
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
        return _verifyPaidPrice(oracleAddr, asset, priceData);
    }

    /// @dev Verify a signed price proof against `oracleAddr`, forwarding the oracle's ETH fee.
    function _verifyPaidPrice(
        address oracleAddr,
        bytes32 asset,
        bytes calldata priceData
    ) private returns (uint256 price, uint256 timestamp) {
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
        bytes32 collatAsset = _vaultManager().vaultCollateralAsset(vault);
        address oracleAddr = _getOracleForAsset(collatAsset);
        if (oracleAddr == address(0)) revert CollateralOracleNotSet();
        (uint256 price, uint256 timestamp) = _verifyPaidPrice(oracleAddr, collatAsset, collateralPriceData);

        // Collateral is released now, so its price must be current.
        if (_isStale(timestamp, registry.priceMaxAge())) revert StaleCollateralPrice();

        // usdValue and price are 18-decimal, so this yields an 18-decimal collateral amount.
        // Scale down to the collateral token's decimals (floor — protocol-favorable).
        return Math.mulDiv(usdValue, PRECISION, price) / _tokenScale(IOwnVault(vault).asset());
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — PSM helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Resolve a wrapper's PSM config and derive the conversion ratio (eTokens per wrapper
    ///      unit, 1e18) = wrapper oracle price / asset mark. Enforces the fail-closed ratio-jump
    ///      guard and records the ratio used.
    /// @param requireFreshWrapperPrice True on paths priced off a live wrapper leg (mint;
    ///        halted redeem).
    function _psmContext(
        bytes32 asset,
        address wrapper,
        bool requireFreshWrapperPrice
    ) private returns (address reserveVault, uint256 ratio) {
        IAssetRegistry ar = _assetRegistry();
        PsmConfig memory cfg = ar.getPsmConfig(asset, wrapper); // reverts PsmNotConfigured
        if (cfg.paused) revert PsmIsPaused(asset, wrapper);
        reserveVault = cfg.reserveVault;

        IVaultManager vmgr = _vaultManager();
        bytes32 wrapperTicker = vmgr.vaultCollateralAsset(reserveVault);
        (uint256 wrapperPrice, uint256 priceTs) =
            IOracleVerifier(_getOracleForAsset(wrapperTicker)).getPrice(wrapperTicker);
        if (wrapperPrice == 0) revert WrapperPriceUnavailable(wrapperTicker);
        if (requireFreshWrapperPrice && _isStale(priceTs, vmgr.maxMarkAge())) {
            revert StaleWrapperPrice(wrapperTicker);
        }

        uint256 mark = vmgr.assetMark(asset);
        if (mark == 0) revert AssetMarkUnavailable(asset);

        ratio = Math.mulDiv(wrapperPrice, PRECISION, mark);
        if (ratio == 0) revert InvalidPrice();

        // Fail-closed ratio-jump guard: unset bound disables PSM mint/redeem.
        uint256 bound = ar.ratioJumpBoundBps();
        if (bound == 0) revert RatioGuardNotConfigured();
        uint256 last = cfg.lastUsedRatio;
        if (last != 0) {
            uint256 diff = ratio > last ? ratio - last : last - ratio;
            if (diff * BPS > last * bound) revert RatioJumpExceeded(asset, wrapper, ratio, last);
        }
        if (ratio != last) ar.notePsmRatio(asset, wrapper, ratio);
    }

    // ──────────────────────────────────────────────────────────
    //  Internal — misc helpers
    // ──────────────────────────────────────────────────────────

    /// @dev Trading-status gate shared by execute/fill/place: revert if the asset's trading is
    ///      paused, or if it is halted (mint blocked; redeem routed through {redeemHalted}).
    function _checkTradeable(bytes32 asset, OrderType orderType) private view {
        IVaultManager vmgr = _vaultManager();
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
        if (!_assetRegistry().isActiveAsset(asset)) {
            revert AssetNotActive(asset);
        }
    }

    /// @dev Resolve and validate the global payment token.
    function _paymentToken() private view returns (address token) {
        token = _vaultManager().paymentToken();
        if (token == address(0)) revert PaymentTokenNotSet();
    }

    /// @dev Resolve the active eToken for an asset via the AssetRegistry.
    function _activeToken(
        bytes32 asset
    ) private view returns (address) {
        return _assetRegistry().getActiveToken(asset);
    }

    /// @dev Resolve the oracle address for an asset via ProtocolRegistry.
    function _getOracleForAsset(
        bytes32 asset
    ) private view returns (address) {
        uint8 oracleType = _assetRegistry().getOracleType(asset);
        if (oracleType == 0) return registry.pythOracle();
        return registry.inhouseOracle();
    }

    /// @dev Resolve the VaultManager from the protocol registry.
    function _vaultManager() private view returns (IVaultManager) {
        return IVaultManager(registry.vaultManager());
    }

    /// @dev Resolve the AssetRegistry from the protocol registry.
    function _assetRegistry() private view returns (IAssetRegistry) {
        return IAssetRegistry(registry.assetRegistry());
    }

    /// @dev 10^(18 − token decimals); all supported tokens have <= 18 decimals.
    function _tokenScale(
        address token
    ) private view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(token).decimals());
    }

    /// @dev Pull exactly `amount` of `token` from the caller to `to` (rejects fee-on-transfer).
    function _pullExact(address token, address to, uint256 amount) private {
        uint256 balBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransferFrom(msg.sender, to, amount);
        if (IERC20(token).balanceOf(to) - balBefore != amount) revert FeeOnTransferNotSupported(token);
    }

    /// @dev True if `ts` is in the future or older than `maxAge`.
    function _isStale(uint256 ts, uint256 maxAge) private view returns (bool) {
        return ts > block.timestamp || block.timestamp - ts > maxAge;
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
