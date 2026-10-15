// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateFundParams, FundInfo, FundMetadata, Valuation} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFund — an Own Curated Fund token and the basket that backs it
/// @notice The fund token is a plain ERC-20 backed by a basket of tokens held in this contract, any
///         idle USDG the fund holds, and the fund's own position in its USDG pool.
///
///         - NAV per token = (basket + idle USDG + the USDG in the fund's pool position) divided by
///           (supply minus the fund tokens in that position). The position is valued at the fund
///           token's oracle price (the pool TWAP, signed by Own's oracle and pushed by the keeper);
///           mints and redeems take whichever of the oracle and spot readings costs the caller.
///         - Promised payouts (direct minters' Premium Boosts and the Premium Pot) are fund tokens
///           minted when they are earned and held by the staking module until paid, so they count
///           in supply and share the fund's price moves like any other token. Unpaid boost tokens
///           that are forfeited are burned (NAV rises).
///         - Redeem: burn fund tokens for a pro-rata slice of every basket asset, of idle USDG and of
///           the pool position (its USDG paid out, its fund tokens burned), at any time. Nothing can
///           pause it, and it needs no price.
///         - Mint: deposit a slice of everything backing the fund (every basket asset and USDG, in
///           proportion), so no oracle values the deposit. Two doors:
///           - Direct mint: priced at the higher of the pool's spot price and TWAP, adjusted by a
///             signed admin setting, never below NAV, and staked at once for the receiver, locked
///             for the fund's mint lock, earning a Premium Boost (see {IFundStaking}). When the
///             admin's premium cap is set and the price would be above it, the mint is priced at
///             the cap instead and the tokens go to the receiver unlocked, with no boost, so any
///             premium above the cap can be arbitraged.
///           - Mint at NAV: priced at NAV, staked for the receiver and locked for the NAV mint lock
///             (6 months by default); redeemable at NAV meanwhile, no boost.
///           The mint zap builds the slice from a single token.
///         - Pool issuance: after buys lift the pool above NAV, the fund's venue sells new fund
///           tokens into the pool (see {IFundVenue-issue}); their USDG comes here, with part of the
///           premium set aside for the Premium Pot.
///         - Fee: the fund fee is charged in fund tokens on mints and redeems; on pool trades the
///           pool's swap tax is the fund fee (see {IFundVenue}). It all goes to the fund's curators
///           module, which splits it between the protocol curator and the other curators.
///         - Portfolio changes (assets and target weights) come only from the fund's governor
///           (the weekly weight vote and listing proposals). The admin can swap the governor.
///         - Rebalancing towards the targets runs through Dutch auctions (see {IFundAuctions}): the
///           manager (the Own keeper) opens lots, anyone fills them, bounded by oracle value. Router
///           swaps are the manager's tool only before the pool is seeded; after that they are an
///           admin fallback.
///         - Depositors' launch tokens cannot be transferred for the launch's lock period; they can
///           still be staked and redeemed.
interface IFund is IERC20 {
    /// @notice A swap between two basket assets.
    /// @param sellAsset    Asset sold.
    /// @param sellAmount   Maximum amount sold (the router is approved for exactly this).
    /// @param buyAsset     Asset bought.
    /// @param minBuyAmount Minimum amount bought.
    /// @param router       Admin-allowed router called with `data`.
    /// @param data         Router calldata.
    struct RebalanceParams {
        address sellAsset;
        uint256 sellAmount;
        address buyAsset;
        uint256 minBuyAmount;
        address router;
        bytes data;
    }

    /// @notice Emitted on a mint.
    /// @param sender     Depositor.
    /// @param receiver   Owner of the mint.
    /// @param navShares  Size of the slice deposited, in fund tokens at NAV.
    /// @param shares     Fund tokens for the receiver (after the fee).
    /// @param mintPrice  Price per fund token, 18 decimals USD.
    /// @param boost      Fund tokens minted to the staking module for the receiver's boost.
    event Minted(
        address indexed sender,
        address indexed receiver,
        uint256 navShares,
        uint256 shares,
        uint256 mintPrice,
        uint256 boost
    );

    /// @notice Emitted when the venue issues fund tokens into the pool.
    /// @param shares Fund tokens issued.
    /// @param pot    Fund tokens minted to the staking module for the Premium Pot.
    event Issued(uint256 shares, uint256 pot);

    /// @notice Emitted on a redeem.
    /// @param sender     Holder that redeemed.
    /// @param receiver   Receiver of the basket assets and USDG.
    /// @param shares     Fund tokens redeemed, including fees.
    /// @param amounts    Amount of each basket asset paid out, in {assets} order.
    /// @param usdgAmount USDG paid out (idle USDG plus the pool position slice).
    event Redeemed(
        address indexed sender, address indexed receiver, uint256 shares, uint256[] amounts, uint256 usdgAmount
    );

    /// @notice Emitted when the fund fee is charged in fund tokens.
    /// @param fee Fund tokens to the curators module.
    event FeesCharged(uint256 fee);

    /// @notice Emitted on a rebalance.
    /// @param sellAsset Asset sold.
    /// @param sold      Amount sold.
    /// @param buyAsset  Asset bought.
    /// @param bought    Amount bought.
    event Rebalanced(address indexed sellAsset, uint256 sold, address indexed buyAsset, uint256 bought);

    /// @notice Emitted when the basket's assets or target weights change.
    /// @param assets     Assets.
    /// @param weightsBps Target weights.
    event TargetWeightsSet(address[] assets, uint16[] weightsBps);

    /// @notice Emitted when the fund fee changes.
    /// @param feeBps Fee, in basis points.
    event FeeSet(uint16 feeBps);

    /// @notice Emitted when an account's locked launch tokens change.
    /// @param account The account.
    /// @param locked  Fund tokens now locked.
    event LaunchLockSet(address indexed account, uint256 locked);

    /// @notice Emitted when the mint settings change.
    /// @param lock          Lock on a direct mint's stake, in seconds.
    /// @param adjustmentBps Signed adjustment to the pool price, in basis points.
    /// @param maxPremiumBps Premium cap on a direct mint, in basis points (0 for none).
    event MintConfigSet(uint32 lock, int16 adjustmentBps, uint32 maxPremiumBps);

    /// @notice Emitted when the manager changes.
    /// @param manager New manager.
    event ManagerSet(address manager);

    /// @notice Emitted when the governor changes.
    /// @param governor New governor.
    event GovernorSet(address governor);

    /// @notice Emitted when the fund's metadata changes.
    /// @param name   Name.
    /// @param symbol Symbol.
    /// @param info   Logo, description and social links.
    event MetadataSet(string name, string symbol, FundInfo info);

    /// @notice Emitted when minting is paused or unpaused.
    /// @param paused Whether minting is paused.
    event MintPausedSet(bool paused);

    /// @notice Emitted when an operator sweeps a token that is not backing.
    /// @param token  The token.
    /// @param to     Recipient.
    /// @param amount Amount sent.
    event Swept(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted once, when the launch succeeds and the fund goes live.
    /// @param depositorUnlockAt When depositors' launch tokens become transferable.
    event Launched(uint64 depositorUnlockAt);

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is neither a fund operator nor a fund admin.
    error NotOperator();

    /// @notice Caller is not the factory.
    error NotFactory();

    /// @notice Caller is not the manager, a fund operator or a fund admin.
    error NotManager();

    /// @notice Caller is not the governor.
    error NotGovernor();

    /// @notice A metadata field is empty or too long.
    error InvalidMetadata();

    /// @notice Caller is not the launch or staking module.
    error NotModule();

    /// @notice Caller is not the launch module.
    error NotLaunch();

    /// @notice Caller is not the staking module.
    error NotStaking();

    /// @notice Caller is not the factory's auction house.
    error NotAuctions();

    /// @notice Caller is not the fund's venue.
    error NotVenue();

    /// @notice The transfer would move launch tokens that are still locked.
    error LaunchTokensLocked();

    /// @notice The redeem is larger than the supply backed by the basket.
    error RedeemTooLarge();

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice An amount is zero.
    error ZeroAmount();

    /// @notice Modules are already set.
    error ModulesAlreadySet();

    /// @notice The fund has not launched yet.
    error NotLaunched();

    /// @notice The fund has already launched.
    error AlreadyLaunched();

    /// @notice Minting is paused.
    error MintPaused();

    /// @notice The fund has no supply outside its pool position, so there is nothing to take a
    ///         slice of.
    error EmptyFund();

    /// @notice Basket asset list or weights are invalid.
    error InvalidBasket();

    /// @notice The token is backing (a basket asset, USDG or the fund token) and cannot be swept.
    /// @param token The token.
    error NotSweepable(address token);

    /// @notice An asset with more than a dust balance cannot be removed from the basket.
    /// @param asset The asset.
    error AssetHasBalance(address asset);

    /// @notice The mint lock or adjustment is out of bounds.
    error InvalidMintConfig();

    /// @notice The fund fee is above its cap.
    error FeeTooHigh();

    /// @notice Output is below the caller's minimum.
    error Slippage();

    /// @notice `minAmountsOut` length does not match the basket.
    error LengthMismatch();

    /// @notice The router is not allowed.
    error RouterNotAllowed();

    /// @notice The rebalance call failed.
    error RebalanceCallFailed();

    /// @notice The rebalance sold more than allowed, reduced another asset or lost too much value.
    error RebalanceInvalid();

    /// @notice The rebalance would exceed the daily volume cap.
    error RebalanceVolumeExceeded();

    /// @notice The price oracle has no fresh price for the fund token.
    error NoMarketPrice();

    /// @notice A locked or boosted mint must go to the caller (or come through the mint zap).
    error NotReceiver();

    /// @notice The governor before the current one still holds staked shares.
    error PreviousGovernorHoldsStake();

    /// @notice Initialise a fund proxy. Called once by the factory.
    /// @param params Fund parameters (launch and staking fields are ignored here).
    function initialize(
        CreateFundParams calldata params
    ) external;

    /// @notice Wire the per-fund modules. Factory only, once.
    /// @param launch_   Launch module.
    /// @param staking_  Staking module.
    /// @param governor_ Governor.
    /// @param curators_ Curators module (the curator fee recipient).
    /// @param venue_    Venue (where the fund trades).
    function setModules(
        address launch_,
        address staking_,
        address governor_,
        address curators_,
        address venue_
    ) external;

    /// @notice Send idle USDG to the venue to seed the fund's pool. Launch only.
    /// @param amount USDG amount.
    function sendPoolUsdg(
        uint256 amount
    ) external;

    /// @notice Mark the fund live after a successful launch. Launch only, once.
    /// @param depositorUnlockAt_ When depositors' launch tokens become transferable.
    function markLaunched(
        uint64 depositorUnlockAt_
    ) external;

    /// @notice Mint fund tokens without a deposit: launch allocations and staker yield. Modules only.
    /// @param to     Receiver.
    /// @param amount Amount.
    function moduleMint(address to, uint256 amount) external;

    /// @notice Lock `amount` more of `account`'s fund tokens until {depositorUnlockAt}. Launch and
    ///         staking only (launch claims, and unstaking locked stake). A no-op once unlocked.
    /// @param account The account.
    /// @param amount  Fund tokens to lock.
    function addLaunchLock(address account, uint256 amount) external;

    /// @notice Release the part of `account`'s lock that staking `amount` would move out, so the
    ///         staking module can lock the stake instead. Staking only. Unlocked tokens move first.
    /// @param account The staker.
    /// @param amount  Fund tokens being staked.
    /// @return moved Locked fund tokens moving into staking.
    function releaseLaunchLock(address account, uint256 amount) external returns (uint256 moved);

    /// @notice Mint: deposit a slice of the fund worth `navShares` at NAV (that share of every
    ///         basket asset's balance and of the fund's USDG, idle plus the pool position's, each
    ///         rounded up). Pulled from the caller, which must have
    ///         approved the fund; {previewMint} gives the amounts.
    ///         - Direct mint (`atNav` false): at the pool price; the fund tokens are staked for the
    ///           receiver and locked for {mintLock} (see {IFundStaking-stakeMinted}), and the
    ///           receiver earns a Premium Boost of the staking module's boost share of the premium
    ///           paid over NAV. If {maxPremiumBps} caps the price, the tokens go to the receiver
    ///           unlocked instead, with no boost.
    ///         - Mint at NAV (`atNav` true): at NAV; staked for the receiver and locked for good, with
    ///           the yield it earns: it can only leave by a redeem at NAV, never be sold. No boost.
    ///         A staked (locked or boosted) mint reverts {NotReceiver} unless the receiver is the
    ///         caller or the caller is the factory's mint zap.
    /// @param navShares    Size of the slice, in fund tokens at NAV. The receiver gets this scaled
    ///                     down by the mint price over NAV, less the fee.
    /// @param minSharesOut Minimum fund tokens for the receiver, after the fee.
    /// @param receiver     Owner of the mint.
    /// @param atNav        Mint at NAV instead of the pool price.
    /// @return shares Fund tokens for the receiver.
    function mint(
        uint256 navShares,
        uint256 minSharesOut,
        address receiver,
        bool atNav
    ) external returns (uint256 shares);

    /// @notice Mint fund tokens the venue issues into the pool, whose USDG the venue pays here, and
    ///         mint `pot` fund tokens to the staking module for the Premium Pot. Venue only.
    /// @param to     Receiver of the fund tokens: the pool manager for an issue, the venue to add
    ///               them to the fund's position.
    /// @param shares Fund tokens minted.
    /// @param pot    Fund tokens for the pot.
    function venueIssue(address to, uint256 shares, uint256 pot) external;

    /// @notice Redeem fund tokens for a pro-rata slice of every basket asset, of idle USDG and of
    ///         the fund's pool position. The position slice pays its USDG (at most its value at
    ///         the oracle price, so moving the spot price cannot inflate it) and burns its fund tokens.
    /// @param shares        Fund tokens redeemed, fees included.
    /// @param receiver      Receiver of the basket assets and USDG.
    /// @param minAmountsOut Per-asset minimum, in {assets} order (empty to skip).
    /// @param minUsdgOut    Minimum USDG paid out.
    /// @return amounts    Amount of each asset paid out, in {assets} order.
    /// @return usdgAmount USDG paid out.
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut
    ) external returns (uint256[] memory amounts, uint256 usdgAmount);

    /// @notice {redeem}, leaving out the basket assets in `skip`: for when one of them cannot be
    ///         transferred (paused, or blacklisting the fund). The skipped slices are forfeited and
    ///         stay in the fund for the remaining holders.
    /// @param shares        Fund tokens redeemed, fees included.
    /// @param receiver      Receiver of the basket assets and USDG.
    /// @param minAmountsOut Per-asset minimum, in {assets} order (empty to skip).
    /// @param minUsdgOut    Minimum USDG paid out.
    /// @param skip          Basket assets not paid out.
    /// @return amounts    Amount of each asset paid out, in {assets} order (zero for a skipped one).
    /// @return usdgAmount USDG paid out.
    function redeemSkipping(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256 minUsdgOut,
        address[] calldata skip
    ) external returns (uint256[] memory amounts, uint256 usdgAmount);

    /// @notice Burn caller's fund tokens without redeeming (raises NAV for everyone else).
    /// @param amount Amount.
    function burn(
        uint256 amount
    ) external;

    /// @notice Swap a basket asset (or idle USDG) into another basket asset through an allowed
    ///         router. The manager before the pool is seeded (the launch rebalance), a fund operator
    ///         or admin at any time. Each swap
    ///         may lose at most the factory's slippage bound in oracle value, and the value sold is
    ///         rate limited: at most the daily cap at once, with the allowance refilling linearly
    ///         over a day. This bounds what a manager or operator can leak through bad fills. Until the fund's
    ///         pool is seeded (the launch rebalance) a swap may also buy USDG, and the cap does not
    ///         apply.
    /// @param params Swap parameters.
    function rebalance(
        RebalanceParams calldata params
    ) external;

    /// @notice Pay `amount` of `asset` to the filler of an auction lot, after the auction house has
    ///         collected the fill's payment into the fund. Auction house only.
    /// @param asset  Basket asset or USDG sold.
    /// @param to     The filler.
    /// @param amount Amount sold.
    function auctionPayout(address asset, address to, uint256 amount) external;

    /// @notice Replace the basket's asset list and target weights. Governor only, after launch.
    ///         Assets still held cannot be dropped (vote their weight to zero, rebalance out, then
    ///         drop them), except dust worth at most `DUST_BPS` of the basket, which is left behind.
    ///         New assets need an oracle feed.
    /// @param assets_     Assets.
    /// @param weightsBps_ Target weights (sum 10 000).
    function setTargetWeights(address[] calldata assets_, uint16[] calldata weightsBps_) external;

    /// @notice Set the fund fee, charged on pool trades, mints and redeems and paid to the
    ///         curators. Admin only.
    /// @param feeBps Fee, in basis points (capped at 10%).
    function setFee(
        uint16 feeBps
    ) external;

    /// @notice Set the mint settings. Admin only.
    /// @param lock          Lock on a direct mint's stake, in seconds (0 to 365 days).
    /// @param adjustmentBps Signed adjustment to the pool price, in basis points (-5 000 to 10 000):
    ///                      positive is a markup, negative a discount. The price is never below NAV.
    /// @param maxPremiumBps Premium over NAV a direct mint pays at most, in basis points (0 for
    ///                      no cap).
    function setMintConfig(uint32 lock, int16 adjustmentBps, uint32 maxPremiumBps) external;

    /// @notice Replace the governor, e.g. with a quadratic, futarchy or bribe-market module.
    ///         Admin only. The old governor becomes {previousGovernor}, whose escrow still counts
    ///         towards each staker's holdings; reverts while the governor before it still holds
    ///         staked shares.
    /// @param governor_ New governor.
    function setGovernor(
        address governor_
    ) external;

    /// @notice Update the fund's name, symbol and info (logo, description, social links). Admin only.
    /// @param name_   Name (1 to 64 bytes).
    /// @param symbol_ Symbol (1 to 16 bytes).
    /// @param info_   Logo, description and social links.
    function setMetadata(string calldata name_, string calldata symbol_, FundInfo calldata info_) external;

    /// @notice Replace the manager. Admin only.
    /// @param manager_ New manager.
    function setManager(
        address manager_
    ) external;

    /// @notice Move `usdgAmount` of idle USDG into the fund's pool position, with matching fund
    ///         tokens minted into it (see {IFundVenue-increasePosition}). Admin only; the launch adds
    ///         the position once and this is optional. The venue's `withdrawPosition` reduces it.
    /// @param usdgAmount Idle USDG to add.
    /// @return liquidity Liquidity added.
    function increasePosition(
        uint256 usdgAmount
    ) external returns (uint128 liquidity);

    /// @notice Close or open the mint doors (direct and at NAV). Operator or admin. Redeeming
    ///         cannot be paused.
    /// @param paused Whether minting is paused.
    function setMintPaused(
        bool paused
    ) external;

    /// @notice Send the fund's whole balance of a token that is not backing to the factory's sweep
    ///         recipient (the registry treasury unless the admin set another wallet): tokens sent to
    ///         the fund by mistake, dust left by a dropped asset, or rewards paid out by a basket
    ///         asset (e.g. stock tokens) for redistribution. Operator (registry FUND_OPERATOR or FUND_ADMIN).
    ///         Basket assets, USDG and the fund token cannot be swept.
    /// @param token The token.
    /// @return amount Amount sent.
    function sweep(
        address token
    ) external returns (uint256 amount);

    /// @notice The factory.
    /// @return The factory.
    function factory() external view returns (address);

    /// @notice The Own keeper that rebalances the basket.
    /// @return The manager.
    function manager() external view returns (address);

    /// @notice The governor, the only source of portfolio changes.
    /// @return The governor.
    function governor() external view returns (address);

    /// @notice The governor replaced by the last {setGovernor}; stakers can still withdraw from it.
    /// @return The previous governor (zero if never replaced).
    function previousGovernor() external view returns (address);

    /// @notice The fund's venue, the only contract that knows where the fund trades.
    /// @return The venue.
    function venue() external view returns (address);

    /// @notice Everything about the fund in one read: name, symbol, logo, description, social links
    ///         and the platform's metadata.
    /// @return The fund info.
    function getFundInfo() external view returns (FundMetadata memory);

    /// @notice Launch module.
    /// @return The launch.
    function launch() external view returns (address);

    /// @notice Staking module.
    /// @return The staking vault.
    function staking() external view returns (address);

    /// @notice Whether the launch succeeded.
    /// @return True once live.
    function launched() external view returns (bool);

    /// @notice Whether minting is paused.
    /// @return True while paused.
    function mintPaused() external view returns (bool);

    /// @notice Lock on a direct mint's stake, in seconds.
    /// @return The lock.
    function mintLock() external view returns (uint32);

    /// @notice Signed adjustment to the pool price a direct mint pays, in basis points.
    /// @return The adjustment.
    function mintAdjustmentBps() external view returns (int16);

    /// @notice Premium over NAV a direct mint pays at most, in basis points (0 for no cap).
    /// @return The cap.
    function maxPremiumBps() external view returns (uint32);

    /// @notice Curators module: the fund fee recipient.
    /// @return The curators module.
    function curators() external view returns (address);

    /// @notice Fund fee, in basis points.
    /// @return The fee.
    function feeBps() external view returns (uint16);

    /// @notice When depositors' launch tokens become transferable (0 before launch).
    /// @return The timestamp.
    function depositorUnlockAt() external view returns (uint64);

    /// @notice Fund tokens of `account` that are still launch-locked (meaningful only before
    ///         {depositorUnlockAt}).
    /// @param account The account.
    /// @return The locked amount.
    function launchLocked(
        address account
    ) external view returns (uint256);

    /// @notice Idle USDG held by the fund.
    /// @return The amount.
    function idleUsdg() external view returns (uint256);

    /// @notice The fund's pool position at the fund token's oracle price.
    /// @return usdgAmount USDG in the position.
    /// @return fundTokens Fund tokens in the position.
    function positionAmounts() external view returns (uint256 usdgAmount, uint256 fundTokens);

    /// @notice Supply that NAV is spread over: total supply minus the fund tokens in the fund's
    ///         pool position (at the fund token's oracle price).
    /// @return The supply.
    function effectiveSupply() external view returns (uint256);

    /// @notice Whether `asset`'s balance is dust: worth at most `DUST_BPS` of the basket, so it can
    ///         be dropped from the basket.
    /// @param asset The asset.
    /// @return True if it can be dropped.
    function isDust(
        address asset
    ) external view returns (bool);

    /// @notice Basket assets.
    /// @return The assets.
    function assets() external view returns (address[] memory);

    /// @notice Whether `asset` is in the basket.
    /// @param asset The asset.
    /// @return True if in the basket.
    function isAsset(
        address asset
    ) external view returns (bool);

    /// @notice Target weight of `asset`, in basis points.
    /// @param asset The asset.
    /// @return The weight.
    function targetWeightBps(
        address asset
    ) external view returns (uint16);

    /// @notice Value held: basket, idle USDG and the pool position's USDG, 18 decimals USD.
    ///         Reverts if any asset's price is unavailable.
    /// @return The value.
    function totalValue() external view returns (uint256);

    /// @notice NAV per fund token, 18 decimals USD. Reverts if any asset's price is unavailable.
    /// @return The NAV.
    function navPerShare() external view returns (uint256);

    /// @notice NAV per fund token without reverting.
    /// @return ok     Whether every price needed was available and NAV is non-zero.
    /// @return nav    NAV per fund token, 18 decimals USD.
    /// @return supply Supply outside the fund's pool position.
    function tryNav() external view returns (bool ok, uint256 nav, uint256 supply);

    /// @notice The fund's holdings at oracle prices with the supply and market price,
    ///         from which NAV and the premium follow (see {ValuationLib}). Never reverts.
    /// @return The valuation.
    function valuation() external view returns (Valuation memory);

    /// @notice Premium of the fund token's market TWAP over NAV.
    /// @return ok         Whether every price needed was available.
    /// @return premiumBps Premium in basis points (negative at a discount).
    function premiumBps() external view returns (bool ok, int256 premiumBps);

    /// @notice Quote a mint.
    /// @param navShares  Size of the slice, in fund tokens at NAV.
    /// @param atNav      Quote a mint at NAV instead of the pool price.
    /// @return shares     Fund tokens for the receiver, after the fee.
    /// @return mintPrice  Price per fund token, 18 decimals USD.
    /// @return amounts    Amount of each basket asset the mint pulls, in {assets} order.
    /// @return usdgAmount USDG the mint pulls.
    /// @return locked     Whether the tokens are staked and locked (false when the premium cap
    ///                    prices the mint).
    function previewMint(
        uint256 navShares,
        bool atNav
    )
        external
        view
        returns (uint256 shares, uint256 mintPrice, uint256[] memory amounts, uint256 usdgAmount, bool locked);

    /// @notice Quote a redeem (the USDG figure takes the lower of the TWAP and spot readings).
    /// @param shares Fund tokens redeemed, fees included.
    /// @return amounts    Amount of each asset paid out, in {assets} order.
    /// @return usdgAmount USDG paid out.
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256[] memory amounts, uint256 usdgAmount);
}
