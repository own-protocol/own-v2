// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateFundParams, FundMetadata, LockOption} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFund — an Own Curated Fund token and the basket that backs it
/// @notice The fund token is a plain ERC-20 backed by a basket of tokens held in this contract, any
///         idle USDG the fund holds, and the fund's own position in its USDG pool.
///
///         - NAV per token = (basket + idle USDG + the USDG in the fund's pool position) divided by
///           (supply minus the fund tokens in that position). The position is valued at the pool
///           TWAP, never the spot price.
///         - Redeem: burn fund tokens for a pro-rata slice of every basket asset, of idle USDG and of
///           the pool position (its USDG paid out, its fund tokens burned), at any time. The basket
///           part needs no oracle and nothing can pause it.
///         - Mint: deposit one basket asset at its oracle value, priced at the fund token's market
///           TWAP (optionally discounted in exchange for a lock), never below NAV.
///         - Fees: the protocol fee and the curator fee are charged in fund tokens on mints and
///           redeems (and in USDG on pool trades, by the hook). The curator fee goes to the fund's
///           curators module, which splits it among the curators.
///         - Portfolio changes (assets and target weights) come only from the fund's governor
///           (the weekly weight vote and listing proposals). The admin can swap the governor.
///         - The manager (the Own keeper) rebalances towards the targets through admin-allowed
///           routers, bounded by oracle value.
///         - Depositors' launch tokens cannot be transferred for the launch's lock period; they can
///           still be staked and redeemed.
interface IFund is IERC20 {
    /// @notice A locked mint.
    /// @param amount   Fund tokens locked (zero once claimed).
    /// @param unlockAt When they can be claimed.
    struct Lock {
        uint128 amount;
        uint64 unlockAt;
    }

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

    /// @notice Emitted on a mint with a basket asset.
    /// @param sender     Depositor.
    /// @param receiver   Receiver of the minted (or locked) fund tokens.
    /// @param asset      Asset deposited.
    /// @param amount     Amount received by the fund.
    /// @param shares     Fund tokens minted to the receiver (after fees).
    /// @param mintPrice  Price per fund token, 18 decimals USD.
    /// @param lockId     Lock index for the receiver, or type(uint256).max when unlocked.
    event Minted(
        address indexed sender,
        address indexed receiver,
        address indexed asset,
        uint256 amount,
        uint256 shares,
        uint256 mintPrice,
        uint256 lockId
    );

    /// @notice Emitted on a redeem.
    /// @param sender     Holder that redeemed.
    /// @param receiver   Receiver of the basket assets and USDG.
    /// @param shares     Fund tokens redeemed, including fees.
    /// @param amounts    Amount of each basket asset paid out, in {assets} order.
    /// @param usdgAmount USDG paid out (idle USDG plus the pool position slice).
    event Redeemed(
        address indexed sender, address indexed receiver, uint256 shares, uint256[] amounts, uint256 usdgAmount
    );

    /// @notice Emitted when fees are charged in fund tokens.
    /// @param protocolFee Fund tokens to the protocol fee recipient.
    /// @param curatorFee  Fund tokens to the curators module.
    event FeesCharged(uint256 protocolFee, uint256 curatorFee);

    /// @notice Emitted when a locked mint is claimed.
    /// @param account Owner of the lock.
    /// @param lockId  Lock index.
    /// @param amount  Fund tokens released.
    event LockClaimed(address indexed account, uint256 indexed lockId, uint256 amount);

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

    /// @notice Emitted when the curator fee changes.
    /// @param feeBps Fee, in basis points.
    event CuratorFeeSet(uint16 feeBps);

    /// @notice Emitted when an account's locked launch tokens change.
    /// @param account The account.
    /// @param locked  Fund tokens now locked.
    event LaunchLockSet(address indexed account, uint256 locked);

    /// @notice Emitted when the lock options change.
    /// @param options New options.
    event LockOptionsSet(LockOption[] options);

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

    /// @notice Emitted once, when the launch succeeds and the fund goes live.
    /// @param depositorUnlockAt When depositors' launch tokens become transferable.
    event Launched(uint64 depositorUnlockAt);

    /// @notice Caller is not the platform admin.
    error NotAdmin();

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

    /// @notice The asset is not in the basket, or has a zero target weight.
    /// @param asset The asset.
    error AssetNotMintable(address asset);

    /// @notice Basket asset list or weights are invalid.
    error InvalidBasket();

    /// @notice An asset with more than a dust balance cannot be removed from the basket.
    /// @param asset The asset.
    error AssetHasBalance(address asset);

    /// @notice The lock option does not exist.
    error InvalidLockOption();

    /// @notice A lock option is invalid.
    error InvalidLockOptions();

    /// @notice The curator fee is above its cap.
    error FeeTooHigh();

    /// @notice Output is below the caller's minimum.
    error Slippage();

    /// @notice `minAmountsOut` length does not match the basket.
    error LengthMismatch();

    /// @notice The lock is not claimable yet or was already claimed.
    /// @param lockId The lock.
    error LockNotClaimable(uint256 lockId);

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
    function setModules(
        address launch_,
        address staking_,
        address governor_,
        address curators_
    ) external;

    /// @notice Mark the fund live after a successful launch. Launch only, once.
    /// @param depositorUnlockAt_ When depositors' launch tokens become transferable.
    function markLaunched(
        uint64 depositorUnlockAt_
    ) external;

    /// @notice Mint fund tokens without a deposit: launch allocations and staker yield. Modules only.
    /// @param to     Receiver.
    /// @param amount Amount.
    function moduleMint(
        address to,
        uint256 amount
    ) external;

    /// @notice Lock `amount` more of `account`'s fund tokens until {depositorUnlockAt}. Launch and
    ///         staking only (launch claims, and unstaking locked stake). A no-op once unlocked.
    /// @param account The account.
    /// @param amount  Fund tokens to lock.
    function addLaunchLock(
        address account,
        uint256 amount
    ) external;

    /// @notice Release the part of `account`'s lock that staking `amount` would move out, so the
    ///         staking module can lock the stake instead. Staking only. Unlocked tokens move first.
    /// @param account The staker.
    /// @param amount  Fund tokens being staked.
    /// @return moved Locked fund tokens moving into staking.
    function releaseLaunchLock(
        address account,
        uint256 amount
    ) external returns (uint256 moved);

    /// @notice Mint fund tokens by depositing one basket asset.
    /// @param asset        Basket asset deposited (target weight above zero).
    /// @param amount       Amount deposited.
    /// @param lockOption   0 for no lock, otherwise 1 + index into {lockOptions}.
    /// @param minSharesOut Minimum fund tokens to the receiver, after fees.
    /// @param receiver     Receiver of the fund tokens (or owner of the lock).
    /// @return shares Fund tokens minted to the receiver or its lock.
    function mint(
        address asset,
        uint256 amount,
        uint256 lockOption,
        uint256 minSharesOut,
        address receiver
    ) external returns (uint256 shares);

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

    /// @notice Release unlocked locked mints to the caller.
    /// @param lockIds Lock indices.
    /// @return amount Fund tokens released.
    function claimLocks(
        uint256[] calldata lockIds
    ) external returns (uint256 amount);

    /// @notice Swap a basket asset (or idle USDG) into another basket asset through an allowed
    ///         router. Manager only. Each swap
    ///         may lose at most the factory's slippage bound in oracle value, and the value sold is
    ///         rate limited: at most the daily cap at once, with the allowance refilling linearly
    ///         over a day. This bounds what a manager can leak through bad fills.
    /// @param params Swap parameters.
    function rebalance(
        RebalanceParams calldata params
    ) external;

    /// @notice Replace the basket's asset list and target weights. Governor only, after launch.
    ///         Assets still held cannot be dropped (vote their weight to zero, rebalance out, then
    ///         drop them), except dust worth at most `DUST_BPS` of the basket, which is left behind.
    ///         New assets need an oracle feed.
    /// @param assets_     Assets.
    /// @param weightsBps_ Target weights (sum 10 000).
    function setTargetWeights(
        address[] calldata assets_,
        uint16[] calldata weightsBps_
    ) external;

    /// @notice Set the curator fee. Admin only.
    /// @param feeBps Fee, in basis points (capped at 10%).
    function setCuratorFee(
        uint16 feeBps
    ) external;

    /// @notice Replace the mint-with-lock options. Admin only.
    /// @param options New options.
    function setLockOptions(
        LockOption[] calldata options
    ) external;

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

    /// @notice Pause or unpause minting. Admin only. Redeeming cannot be paused.
    /// @param paused Whether minting is paused.
    function setMintPaused(
        bool paused
    ) external;

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

    /// @notice Curators module: the curator fee recipient.
    /// @return The curators module.
    function curators() external view returns (address);

    /// @notice Curator fee, in basis points.
    /// @return The fee.
    function curatorFeeBps() external view returns (uint16);

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

    /// @notice Mint-with-lock options.
    /// @return The options.
    function lockOptions() external view returns (LockOption[] memory);

    /// @notice Locks owned by `account`.
    /// @param account The owner.
    /// @return The locks.
    function locksOf(
        address account
    ) external view returns (Lock[] memory);

    /// @notice Backing value: basket, idle USDG and the pool position's USDG, 18 decimals USD.
    ///         Reverts if any asset's price is unavailable.
    /// @return The value.
    function totalValue() external view returns (uint256);

    /// @notice NAV per fund token, 18 decimals USD. Reverts if any asset's price is unavailable.
    /// @return The NAV.
    function navPerShare() external view returns (uint256);

    /// @notice Premium of the fund token's market TWAP over NAV.
    /// @return ok         Whether every price needed was available.
    /// @return premiumBps Premium in basis points (negative at a discount).
    function premiumBps() external view returns (bool ok, int256 premiumBps);

    /// @notice Quote a mint.
    /// @param asset      Basket asset.
    /// @param amount     Amount deposited.
    /// @param lockOption 0 for no lock, otherwise 1 + index into {lockOptions}.
    /// @return shares    Fund tokens to the receiver, after fees.
    /// @return mintPrice Price per fund token, 18 decimals USD.
    function previewMint(
        address asset,
        uint256 amount,
        uint256 lockOption
    ) external view returns (uint256 shares, uint256 mintPrice);

    /// @notice Quote a redeem (the USDG figure assumes the pool's spot price equals its TWAP).
    /// @param shares Fund tokens redeemed, fees included.
    /// @return amounts    Amount of each asset paid out, in {assets} order.
    /// @return usdgAmount USDG paid out.
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256[] memory amounts, uint256 usdgAmount);
}
