// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundMintGateway — mint a fund with USDG when part of the basket only exists on Base
/// @notice Robinhood Chain side of "mint with USDG". Basket assets sourced from Base (rZEC, rHYPE) have
///         no Robinhood pool, so this gateway keeps a stock of them funded by Own's float.
///
///         - Stock covers the order: one transaction. The user's USDG buys the Robinhood assets through
///           admin-allowed routers, pays for the stock at the oracle price plus a small markup, and the
///           fund is minted for the user through the factory's mint zap.
///         - Stock is short: the order is queued. Its Base-sourced part is paid now, at the oracle price
///           plus markup, so the user's USDG can be bridged to Base at once to buy those assets; the rest
///           of the USDG waits in the order. When the bought assets arrive over CCIP and restock the
///           gateway, a keeper fills the order with fresh swaps and the fund tokens are minted to the user
///           (about 30 minutes). Nothing else is asked of the user, who may cancel after {maxWait}.
///
///         USDG paid for stock is Own's float (`revenue`): the keeper bridges it to the Base gateway,
///         which buys and returns the assets. Own carries the price move while an order waits.
interface IFundMintGateway {
    /// @notice A router call.
    /// @param router   Admin-allowed router (the factory's allowlist).
    /// @param tokenIn  Token the router spends.
    /// @param amountIn Amount the router is approved for.
    /// @param data     Router calldata; output must come back to this contract.
    struct Swap {
        address router;
        address tokenIn;
        uint256 amountIn;
        bytes data;
    }

    /// @notice Queued order state.
    enum Status {
        None,
        Queued,
        Filled,
        Cancelled
    }

    /// @notice A queued order.
    /// @param receiver     Owner of the mint.
    /// @param status       State.
    /// @param atNav        Mint at NAV.
    /// @param createdAt    Queue time.
    /// @param fund         The fund.
    /// @param navShares    Size of the slice, in fund tokens at NAV.
    /// @param minSharesOut Minimum fund tokens for the receiver.
    /// @param usdg         USDG held for the Robinhood part of the basket.
    /// @param prepaid      USDG already paid for the Base-sourced part.
    /// @param assets       Base-sourced assets owed.
    /// @param owed         Amount of each owed, in `assets` order.
    struct Order {
        address receiver;
        Status status;
        bool atNav;
        uint64 createdAt;
        address fund;
        uint256 navShares;
        uint256 minSharesOut;
        uint256 usdg;
        uint256 prepaid;
        address[] assets;
        uint256[] owed;
    }

    /// @notice Emitted on a mint filled in the same transaction.
    /// @param fund     The fund.
    /// @param receiver Owner of the mint.
    /// @param usdgIn   USDG spent.
    /// @param shares   Fund tokens minted.
    event MintedNow(address indexed fund, address indexed receiver, uint256 usdgIn, uint256 shares);

    /// @notice Emitted when an order is queued.
    /// @param id       Order id.
    /// @param fund     The fund.
    /// @param receiver Owner of the mint.
    /// @param usdg     USDG held for the Robinhood part.
    /// @param prepaid  USDG paid for the Base-sourced part.
    event Queued(uint256 indexed id, address indexed fund, address indexed receiver, uint256 usdg, uint256 prepaid);

    /// @notice Emitted when a queued order is minted.
    /// @param id     Order id.
    /// @param shares Fund tokens minted.
    /// @param caller Keeper or receiver.
    event Filled(uint256 indexed id, uint256 shares, address indexed caller);

    /// @notice Emitted when a queued order is cancelled.
    /// @param id       Order id.
    /// @param refunded USDG returned.
    event Cancelled(uint256 indexed id, uint256 refunded);

    /// @notice Emitted when stock is added (by the owner or a CCIP arrival).
    /// @param asset  The asset.
    /// @param amount Amount added.
    event Restocked(address indexed asset, uint256 amount);

    /// @notice Emitted when the owner removes stock.
    /// @param asset  The asset.
    /// @param amount Amount removed.
    /// @param to     Recipient.
    event StockRemoved(address indexed asset, uint256 amount, address to);

    /// @notice Emitted when revenue USDG is bridged to the Base gateway.
    /// @param usdgIn  USDG deposited into Across.
    /// @param usdcOut USDC the fill pays the Base gateway.
    event RevenueBridged(uint256 usdgIn, uint256 usdcOut);

    /// @notice Emitted when revenue changes outside a sale (owner withdraw or a refunded bridge).
    /// @param revenue New revenue balance.
    event RevenueSynced(uint256 revenue);

    /// @notice Emitted when a keeper is allowed or removed.
    /// @param keeper  The keeper.
    /// @param allowed Whether it may fill orders and bridge revenue.
    event KeeperSet(address indexed keeper, bool allowed);

    /// @notice Emitted when an asset is marked Base-sourced or not.
    /// @param asset   The asset.
    /// @param allowed Whether the gateway stocks it.
    event BaseAssetSet(address indexed asset, bool allowed);

    /// @notice Emitted when settings change.
    /// @param markupBps  Markup on stock over the oracle price.
    /// @param maxWait    Seconds before a receiver may cancel a queued order.
    /// @param maxFeeBps  Bridge fee cap as a share of the USDG bridged.
    /// @param maxFeeFlat Bridge fee cap in USDG; the larger applies.
    /// @param fillWindow Seconds a relayer has to fill a revenue bridge.
    event SettingsSet(uint256 markupBps, uint64 maxWait, uint256 maxFeeBps, uint256 maxFeeFlat, uint32 fillWindow);

    /// @notice The fund was not created by the factory.
    error NotFund();

    /// @notice A router is not allowed.
    error RouterNotAllowed();

    /// @notice A router call failed.
    error SwapFailed();

    /// @notice Output is below the minimum.
    error Slippage();

    /// @notice A required address or amount is zero.
    error ZeroAddress();

    /// @notice USDG in does not cover the stock and the fund's USDG slice.
    error InsufficientUsdg();

    /// @notice Caller may not fill this order.
    error NotKeeper();

    /// @notice Caller is not the order's receiver.
    error NotReceiver();

    /// @notice The order is not queued.
    error NotQueued();

    /// @notice Stock does not cover the order yet.
    error InsufficientStock();

    /// @notice The order cannot be cancelled yet.
    error TooEarly();

    /// @notice Revenue does not cover the amount.
    error InsufficientRevenue();

    /// @notice Caller is not the CCIP Router.
    error NotRouter();

    /// @notice The bridge fee is above the cap, or the output above the input.
    error BridgeFeeTooHigh();

    /// @notice A parameter is out of range.
    error InvalidParam();

    /// @notice Mint `fund` with USDG, now if stock covers the Base-sourced part, else queued.
    /// @param fund         The fund.
    /// @param usdgIn       USDG pulled from the caller; anything unused is refunded.
    /// @param swaps        Purchases of the Robinhood assets with USDG (used only when minted now).
    /// @param navShares    Size of the slice, in fund tokens at NAV.
    /// @param minSharesOut Minimum fund tokens for the caller.
    /// @param atNav        Mint at NAV instead of the pool price.
    /// @return shares Fund tokens minted now (zero when queued).
    /// @return id     Queued order id (zero when minted now).
    function mint(
        address fund,
        uint256 usdgIn,
        Swap[] calldata swaps,
        uint256 navShares,
        uint256 minSharesOut,
        bool atNav
    ) external returns (uint256 shares, uint256 id);

    /// @notice Mint a queued order once stock covers it (keeper or receiver).
    /// @param id        Order id.
    /// @param swaps     Purchases of the Robinhood assets with the order's USDG.
    /// @param navShares Slice to mint, at most the order's (less if the basket moved); the minimum scales.
    /// @return shares Fund tokens minted.
    function fill(uint256 id, Swap[] calldata swaps, uint256 navShares) external returns (uint256 shares);

    /// @notice Cancel a queued order after {maxWait}, refunding all its USDG (receiver only).
    /// @param id Order id.
    function cancel(
        uint256 id
    ) external;

    /// @notice Bridge revenue USDG to the Base gateway through Across (keeper).
    /// @param usdgIn         USDG deposited.
    /// @param usdcOut        USDC the relayer pays on Base (from a fresh Across quote).
    /// @param quoteTimestamp Timestamp of that quote.
    function bridgeRevenue(uint256 usdgIn, uint256 usdcOut, uint32 quoteTimestamp) external;

    /// @notice Count USDG the gateway holds beyond orders and revenue (a refunded bridge) as revenue.
    function syncRevenue() external;

    /// @notice Add stock from the caller (owner).
    /// @param asset  A Base-sourced asset.
    /// @param amount Amount.
    function addStock(address asset, uint256 amount) external;

    /// @notice Remove stock (owner).
    /// @param asset  The asset.
    /// @param amount Amount.
    /// @param to     Recipient.
    function removeStock(address asset, uint256 amount, address to) external;

    /// @notice Withdraw revenue USDG (owner).
    /// @param amount Amount.
    /// @param to     Recipient.
    function withdrawRevenue(uint256 amount, address to) external;

    /// @notice Allow or remove a keeper (owner).
    /// @param keeper  The keeper.
    /// @param allowed Whether it may fill orders and bridge revenue.
    function setKeeper(address keeper, bool allowed) external;

    /// @notice Mark an asset Base-sourced or not (owner).
    /// @param asset   The asset.
    /// @param allowed Whether the gateway stocks it.
    function setBaseAsset(address asset, bool allowed) external;

    /// @notice Change the settings (owner).
    /// @param markupBps  Markup on stock, at most 5%.
    /// @param maxWait    Seconds before a cancel, between 1 hour and 7 days.
    /// @param maxFeeBps  Bridge fee cap, at most 10%.
    /// @param maxFeeFlat Bridge fee cap in USDG.
    /// @param fillWindow Seconds a relayer has to fill, at least 10 minutes.
    function setSettings(
        uint256 markupBps,
        uint64 maxWait,
        uint256 maxFeeBps,
        uint256 maxFeeFlat,
        uint32 fillWindow
    ) external;

    /// @notice USDG cost of `amount` of Base-sourced `asset` from stock (oracle price plus markup).
    /// @param asset  The asset.
    /// @param amount Amount.
    /// @return USDG cost.
    function stockCost(address asset, uint256 amount) external view returns (uint256);

    /// @notice A queued order.
    /// @param id Order id.
    /// @return The order.
    function getOrder(
        uint256 id
    ) external view returns (Order memory);

    /// @notice Stock held of `asset`.
    /// @param asset The asset.
    /// @return Amount.
    function stock(
        address asset
    ) external view returns (uint256);

    /// @notice USDG owed to Own's float (bridgeable to Base).
    /// @return Amount.
    function revenue() external view returns (uint256);

    /// @notice USDG held for queued orders.
    /// @return Amount.
    function queuedUsdg() external view returns (uint256);
}
