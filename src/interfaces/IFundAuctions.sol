// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFundAuctions — Dutch-auction rebalancing for Own Curated Funds
/// @notice One auction house serves every fund. A fund's manager (the Own keeper) opens a lot:
///         sell up to an amount of one basket asset (or idle USDG) for another basket asset. The
///         price starts above the oracle rate and falls linearly to a floor below it over the
///         auction's duration; anyone fills any part at the current price, paying the fund first
///         and receiving the sold asset from it. The fund names the price, so fillers compete to
///         take a lot as soon as it is fairly priced: no front-running of a market order, and
///         fillers bring liquidity from any venue.
///
///         Bounds, the same as the manager's router swaps: the floor is the oracle rate less the
///         factory's maximum rebalance slippage, every fill is re-checked against the live oracle
///         with the same bound, and the value sold per fund is rate limited by the factory's daily
///         volume cap (refilling linearly over a day). Lots open only once the fund's pool is
///         seeded; the launch rebalance stays a router swap.
interface IFundAuctions {
    /// @notice An auction lot.
    /// @param fund       The fund selling.
    /// @param sellAsset  Asset sold (a basket asset or USDG).
    /// @param buyAsset   Asset bought (a basket asset).
    /// @param remaining  Amount of `sellAsset` still for sale.
    /// @param startTime  When the auction starts.
    /// @param endTime    When it ends (the price reaches the floor).
    /// @param startPrice `buyAsset` units per 1e18 units of `sellAsset` at the start.
    /// @param floorPrice `buyAsset` units per 1e18 units of `sellAsset` at the end.
    struct Lot {
        address fund;
        address sellAsset;
        address buyAsset;
        uint128 remaining;
        uint64 startTime;
        uint64 endTime;
        uint256 startPrice;
        uint256 floorPrice;
    }

    /// @notice Emitted when a lot opens.
    /// @param id         Lot id.
    /// @param fund       The fund selling.
    /// @param sellAsset  Asset sold.
    /// @param buyAsset   Asset bought.
    /// @param amount     Amount for sale.
    /// @param startPrice Start price (`buyAsset` units per 1e18 `sellAsset` units).
    /// @param floorPrice Floor price, same units.
    /// @param endTime    When the auction ends.
    event LotOpened(
        uint256 indexed id,
        address indexed fund,
        address sellAsset,
        address buyAsset,
        uint256 amount,
        uint256 startPrice,
        uint256 floorPrice,
        uint64 endTime
    );

    /// @notice Emitted on a fill.
    /// @param id     Lot id.
    /// @param filler The filler.
    /// @param sold   `sellAsset` paid out to the filler.
    /// @param paid   `buyAsset` paid into the fund.
    event LotFilled(uint256 indexed id, address indexed filler, uint256 sold, uint256 paid);

    /// @notice Emitted when the manager or the admin closes a lot early.
    /// @param id Lot id.
    event LotCancelled(uint256 indexed id);

    /// @notice Emitted when the auction parameters change.
    /// @param startPremiumBps Start price above the oracle rate, in basis points.
    /// @param duration        Auction length, in seconds.
    event AuctionConfigSet(uint16 startPremiumBps, uint32 duration);

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is neither the fund's manager nor the admin.
    error NotManager();

    /// @notice Not a fund of the factory.
    error NotFund();

    /// @notice The fund's pool is not seeded yet.
    error NotSeeded();

    /// @notice The assets are not a basket asset (or USDG) sold for a different basket asset.
    error InvalidAssets();

    /// @notice Premium or duration out of range.
    error InvalidConfig();

    /// @notice The lot does not exist, has ended, was cancelled or is sold out.
    /// @param id Lot id.
    error LotNotActive(uint256 id);

    /// @notice The fill asks for more than the lot has left.
    error ExceedsLot();

    /// @notice The fill would cost more than the filler's maximum.
    error Slippage();

    /// @notice The fill is worth less than the oracle bound allows right now.
    error BelowOracleBound();

    /// @notice The fill would take the fund's rebalance volume above its daily cap.
    error VolumeExceeded();

    /// @notice The fund received less than the fill's price.
    error PaymentShort();

    /// @notice Open a lot for `fund`, priced from the oracle now. Manager or admin.
    /// @param fund      The fund.
    /// @param sellAsset Basket asset or USDG to sell.
    /// @param buyAsset  Basket asset to buy.
    /// @param amount    Amount of `sellAsset` for sale.
    /// @return id Lot id.
    function openLot(address fund, address sellAsset, address buyAsset, uint256 amount) external returns (uint256 id);

    /// @notice Close a lot early. The fund's manager or the admin.
    /// @param id Lot id.
    function cancelLot(
        uint256 id
    ) external;

    /// @notice Buy part or all of a lot at its current price. The caller must have approved this
    ///         contract for the payment, which goes straight to the fund.
    /// @param id          Lot id.
    /// @param amount      Amount of `sellAsset` to buy.
    /// @param maxPayment  Most `buyAsset` the caller will pay.
    /// @return payment `buyAsset` paid.
    function fill(uint256 id, uint256 amount, uint256 maxPayment) external returns (uint256 payment);

    /// @notice Set the auction parameters. Admin only.
    /// @param startPremiumBps Start price above the oracle rate (at most 50%).
    /// @param duration        Auction length (15 minutes to 7 days).
    function setConfig(uint16 startPremiumBps, uint32 duration) external;

    /// @notice The factory whose funds this house serves.
    /// @return The factory.
    function factory() external view returns (address);

    /// @notice Start price above the oracle rate, in basis points.
    /// @return The premium.
    function startPremiumBps() external view returns (uint16);

    /// @notice Auction length, in seconds.
    /// @return The duration.
    function duration() external view returns (uint32);

    /// @notice A lot.
    /// @param id Lot id.
    /// @return The lot.
    function lot(
        uint256 id
    ) external view returns (Lot memory);

    /// @notice Number of lots ever opened.
    /// @return The count.
    function lotCount() external view returns (uint256);

    /// @notice A lot's price now: `buyAsset` units per 1e18 units of `sellAsset`.
    /// @param id Lot id.
    /// @return The price (reverts if the lot is not active).
    function currentPrice(
        uint256 id
    ) external view returns (uint256);

    /// @notice What buying `amount` of a lot costs now.
    /// @param id     Lot id.
    /// @param amount Amount of `sellAsset`.
    /// @return payment `buyAsset` due.
    function quote(uint256 id, uint256 amount) external view returns (uint256 payment);

    /// @notice A fund's rebalance volume through auctions after decay (USD, 18 decimals).
    /// @param fund The fund.
    /// @return The volume.
    function volumeOf(
        address fund
    ) external view returns (uint256);
}
