// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateFundParams, FundMetadata} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFund — an Own Curated Fund token and the basket that backs it
/// @notice The fund token is a plain ERC-20 backed by a basket of tokens held in this contract, any
///         idle USDG the fund holds, and the fund's own position in its USDG pool.
///
///         - NAV per token = (basket + idle USDG + the USDG in the fund's pool position - the
///           reserve) divided by (supply minus the fund tokens in that position). The position is
///           valued at the pool TWAP, never the spot price.
///         - Reserve: a dollar amount of the fund's holdings set aside for promised payouts (direct
///           minters' Premium Boost budgets and the Premium Pot). It is not counted in NAV and
///           redeems never take it; the staking module moves it into backing as it pays out (each
///           payout mints tokens at NAV, so NAV does not move) or as boosts are forfeited (NAV rises).
///         - Redeem: burn fund tokens for a pro-rata slice of every basket asset, of idle USDG and of
///           the pool position (its USDG paid out, its fund tokens burned), at any time, less the
///           reserve's part. Nothing can pause it; while the reserve holds anything it needs every
///           basket price.
///         - Mint: deposit a slice of everything backing the fund (every basket asset and USDG, in
///           proportion), so no oracle values the deposit. It is priced at the higher of the pool's
///           spot price and TWAP, adjusted by a signed admin setting, never below NAV, and staked at
///           once for the receiver, locked for the fund's mint lock. The minter earns a Premium
///           Boost on it (see {IFundStaking}). The mint zap builds the slice from a single token.
///         - Pool issuance: on buys above NAV the hook fills part of the buy with new fund tokens;
///           their USDG comes here, with part of the premium set aside for the Premium Pot.
///         - Fee: one fund fee is charged in fund tokens on mints and redeems (and in USDG on pool
///           trades, by the hook). It all goes to the fund's curators module, which splits it
///           between the protocol curator and the other curators.
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
    /// @param receiver   Owner of the staked, locked mint.
    /// @param navShares  Size of the slice deposited, in fund tokens at NAV.
    /// @param shares     Fund tokens staked for the receiver (after the fee).
    /// @param mintPrice  Price per fund token, 18 decimals USD.
    /// @param boostUsd   Boost budget reserved for the receiver, 18 decimals USD.
    event Minted(
        address indexed sender,
        address indexed receiver,
        uint256 navShares,
        uint256 shares,
        uint256 mintPrice,
        uint256 boostUsd
    );

    /// @notice Emitted when the hook issues fund tokens into a pool buy.
    /// @param shares Fund tokens issued.
    /// @param potUsd Premium added to the reserve for the Premium Pot, 18 decimals USD.
    event Issued(uint256 shares, uint256 potUsd);

    /// @notice Emitted when the staking module moves reserve into backing.
    /// @param usd    Reserve released, 18 decimals USD.
    /// @param shares Fund tokens minted to the staking module against it (zero for a forfeit).
    event ReserveReleased(uint256 usd, uint256 shares);

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

    /// @notice Emitted when the direct mint settings change.
    /// @param lock          Lock on a direct mint's stake, in seconds.
    /// @param adjustmentBps Signed adjustment to the pool price, in basis points.
    event MintConfigSet(uint32 lock, int16 adjustmentBps);

    /// @notice Emitted when the manager changes.
    /// @param manager New manager.
    event ManagerSet(address manager);

    /// @notice Emitted when the governor changes.
    /// @param governor New governor.
    event GovernorSet(address governor);

    /// @notice Emitted when the fund's metadata changes.
    /// @param name        Name.
    /// @param symbol      Symbol.
    /// @param logoURI     Logo URI.
    /// @param description Description.
    event MetadataSet(string name, string symbol, string logoURI, string description);

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

    /// @notice Caller is neither a protocol operator nor an admin.
    error NotOperator();

    /// @notice Caller is not the factory.
    error NotFactory();

    /// @notice Caller is not the manager.
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

    /// @notice Caller is not the pool hook.
    error NotHook();

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
    function setModules(address launch_, address staking_, address governor_, address curators_) external;

    /// @notice Send idle USDG to the hook to seed the fund's pool. Launch only.
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

    /// @notice Direct mint: deposit a slice of the fund worth `navShares` at NAV (that share of
    ///         every basket asset's balance and of the fund's USDG, idle plus the pool position's,
    ///         the reserve's part left out, each rounded up). Pulled from the caller, which must have
    ///         approved the fund; {previewMint} gives the amounts. The fund tokens are staked for the
    ///         receiver and locked for {mintLock} (see {IFundStaking-stakeMinted}); the receiver earns
    ///         a Premium Boost of the staking module's boost share of the premium paid over NAV.
    /// @param navShares    Size of the slice, in fund tokens at NAV. The receiver gets this scaled
    ///                     down by the mint price over NAV, less the fee.
    /// @param minSharesOut Minimum fund tokens staked for the receiver, after the fee.
    /// @param receiver     Owner of the stake.
    /// @return shares Fund tokens staked for the receiver.
    function mint(uint256 navShares, uint256 minSharesOut, address receiver) external returns (uint256 shares);

    /// @notice Mint fund tokens the hook issues into a pool buy, whose USDG the hook has paid here,
    ///         and set `potUsd` of it aside in the reserve for the Premium Pot. Hook only.
    /// @param shares Fund tokens minted to the hook.
    /// @param potUsd Premium for the pot, 18 decimals USD.
    function hookIssue(uint256 shares, uint256 potUsd) external;

    /// @notice Move `usd` of the reserve into backing, minting `shares` to the staking module
    ///         against it (a boost or pot payout at NAV), or none for a forfeit. Staking only.
    /// @param usd    Reserve released, 18 decimals USD.
    /// @param shares Fund tokens minted to the staking module.
    function releaseReserve(uint256 usd, uint256 shares) external;

    /// @notice Redeem fund tokens for a pro-rata slice of every basket asset, of idle USDG and of
    ///         the fund's pool position. The position slice pays its USDG (at most its TWAP value,
    ///         so moving the spot price cannot inflate it) and burns its fund tokens.
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

    /// @notice Burn caller's fund tokens without redeeming (raises NAV for everyone else).
    /// @param amount Amount.
    function burn(
        uint256 amount
    ) external;

    /// @notice Swap a basket asset (or idle USDG) into another basket asset through an allowed
    ///         router. The manager before the pool is seeded (the launch rebalance), the admin at
    ///         any time: after seeding, rebalancing runs through auctions and this is the admin's
    ///         fallback. Each swap
    ///         may lose at most the factory's slippage bound in oracle value, and the value sold is
    ///         rate limited: at most the daily cap at once, with the allowance refilling linearly
    ///         over a day. This bounds what a manager can leak through bad fills. Until the fund's
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

    /// @notice Set the direct mint settings. Admin only.
    /// @param lock          Lock on a direct mint's stake, in seconds (0 to 365 days).
    /// @param adjustmentBps Signed adjustment to the pool price, in basis points (-5 000 to 10 000):
    ///                      positive is a markup, negative a discount. The price is never below NAV.
    function setMintConfig(uint32 lock, int16 adjustmentBps) external;

    /// @notice Replace the governor, e.g. with a quadratic, futarchy or bribe-market module.
    ///         Admin only.
    /// @param governor_ New governor.
    function setGovernor(
        address governor_
    ) external;

    /// @notice Update the fund's name, symbol, logo and description. Admin only.
    /// @param name_        Name (1 to 64 bytes).
    /// @param symbol_      Symbol (1 to 16 bytes).
    /// @param logoURI_     Logo URI (at most 512 bytes).
    /// @param description_ Description (at most 2 000 bytes).
    function setMetadata(
        string calldata name_,
        string calldata symbol_,
        string calldata logoURI_,
        string calldata description_
    ) external;

    /// @notice Replace the manager. Admin only.
    /// @param manager_ New manager.
    function setManager(
        address manager_
    ) external;

    /// @notice Close or open the direct mint door. Operator or admin. Redeeming cannot be paused.
    /// @param paused Whether minting is paused.
    function setMintPaused(
        bool paused
    ) external;

    /// @notice Send the fund's whole balance of a token that is not backing to the factory's sweep
    ///         recipient (the registry treasury unless the admin set another wallet): tokens sent to
    ///         the fund by mistake, dust left by a dropped asset, or rewards paid out by a basket
    ///         asset (e.g. stock tokens) for redistribution. Operator (registry OPERATOR or ADMIN).
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

    /// @notice Logo URI.
    /// @return The URI.
    function logoURI() external view returns (string memory);

    /// @notice Fund description.
    /// @return The description.
    function description() external view returns (string memory);

    /// @notice Full metadata: the fund's fields plus the platform's.
    /// @return The metadata.
    function metadata() external view returns (FundMetadata memory);

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

    /// @notice Holdings set aside for promised payouts (boost budgets and the Premium Pot), 18
    ///         decimals USD. Not counted in NAV.
    /// @return The reserve.
    function reserveUsd() external view returns (uint256);

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

    /// @notice The fund's pool position at the pool TWAP.
    /// @return usdgAmount USDG in the position.
    /// @return fundTokens Fund tokens in the position.
    function positionAmounts() external view returns (uint256 usdgAmount, uint256 fundTokens);

    /// @notice Supply that NAV is spread over: total supply minus the fund tokens in the fund's
    ///         pool position (at the pool TWAP).
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

    /// @notice Value held: basket, idle USDG and the pool position's USDG, 18 decimals USD, reserve
    ///         included. Reverts if any asset's price is unavailable.
    /// @return The value.
    function totalValue() external view returns (uint256);

    /// @notice NAV per fund token, 18 decimals USD, reserve excluded. Reverts if any asset's price
    ///         is unavailable.
    /// @return The NAV.
    function navPerShare() external view returns (uint256);

    /// @notice NAV per fund token without reverting.
    /// @return ok     Whether every price needed was available and NAV is non-zero.
    /// @return nav    NAV per fund token, 18 decimals USD.
    /// @return supply Supply outside the fund's pool position.
    function tryNav() external view returns (bool ok, uint256 nav, uint256 supply);

    /// @notice Premium of the fund token's market TWAP over NAV.
    /// @return ok         Whether every price needed was available.
    /// @return premiumBps Premium in basis points (negative at a discount).
    function premiumBps() external view returns (bool ok, int256 premiumBps);

    /// @notice Quote a direct mint.
    /// @param navShares  Size of the slice, in fund tokens at NAV.
    /// @return shares     Fund tokens staked for the receiver, after the fee.
    /// @return mintPrice  Price per fund token, 18 decimals USD.
    /// @return amounts    Amount of each basket asset the mint pulls, in {assets} order.
    /// @return usdgAmount USDG the mint pulls.
    function previewMint(
        uint256 navShares
    ) external view returns (uint256 shares, uint256 mintPrice, uint256[] memory amounts, uint256 usdgAmount);

    /// @notice Quote a redeem (the USDG figure assumes the pool's spot price equals its TWAP).
    /// @param shares Fund tokens redeemed, fees included.
    /// @return amounts    Amount of each asset paid out, in {assets} order.
    /// @return usdgAmount USDG paid out.
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256[] memory amounts, uint256 usdgAmount);
}
