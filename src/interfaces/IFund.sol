// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreateFundParams, LockOption} from "./types/FundTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFund — a MONEY Market Fund token and the basket that backs it
/// @notice The fund token is a plain ERC-20 whose supply is backed by a basket of tokens held in
///         this contract. NAV per token is the basket's oracle value divided by the full supply,
///         including tokens locked in the pool and in staking.
///
///         - Redeem: burn fund tokens for a pro-rata slice of every basket asset, at any time.
///           Needs no oracle and cannot be paused.
///         - Mint: deposit one basket asset at its oracle value, priced at the fund token's market
///           TWAP (optionally discounted in exchange for a lock), never below NAV.
///         - Fees: the protocol fee and the creator fee are charged in fund tokens on mints and
///           redeems (and in USDG on pool trades, by the hook).
///         - The manager (creator) sets target weights and rebalances through admin-allowed
///           routers, bounded by oracle value.
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
    /// @param sender   Holder that redeemed.
    /// @param receiver Receiver of the basket assets.
    /// @param shares   Fund tokens redeemed, including fees.
    /// @param amounts  Amount of each basket asset paid out, in {assets} order.
    event Redeemed(address indexed sender, address indexed receiver, uint256 shares, uint256[] amounts);

    /// @notice Emitted when fees are charged in fund tokens.
    /// @param protocolFee Fund tokens to the protocol fee recipient.
    /// @param creatorFee  Fund tokens to the creator fee recipient.
    event FeesCharged(uint256 protocolFee, uint256 creatorFee);

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

    /// @notice Emitted when the creator fee changes.
    /// @param feeBps    Fee, in basis points.
    /// @param recipient Recipient.
    event CreatorFeeSet(uint16 feeBps, address recipient);

    /// @notice Emitted when the lock options change.
    /// @param options New options.
    event LockOptionsSet(LockOption[] options);

    /// @notice Emitted when the manager changes.
    /// @param manager New manager.
    event ManagerSet(address manager);

    /// @notice Emitted when minting is paused or unpaused.
    /// @param paused Whether minting is paused.
    event MintPausedSet(bool paused);

    /// @notice Emitted once, when the launch succeeds and the fund goes live.
    event Launched();

    /// @notice Caller is not the platform admin.
    error NotAdmin();

    /// @notice Caller is not the factory.
    error NotFactory();

    /// @notice Caller is not the manager.
    error NotManager();

    /// @notice Caller is not the launch or staking module.
    error NotModule();

    /// @notice Caller is not the launch module.
    error NotLaunch();

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

    /// @notice An asset with a balance cannot be removed from the basket.
    /// @param asset The asset.
    error AssetHasBalance(address asset);

    /// @notice The lock option does not exist.
    error InvalidLockOption();

    /// @notice A lock option is invalid.
    error InvalidLockOptions();

    /// @notice The creator fee is above its cap.
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

    /// @notice Wire the launch and staking modules. Factory only, once.
    /// @param launch_  Launch module.
    /// @param staking_ Staking module.
    function setModules(
        address launch_,
        address staking_
    ) external;

    /// @notice Mark the fund live after a successful launch. Launch only, once.
    function markLaunched() external;

    /// @notice Mint fund tokens without a deposit: launch allocations and staker yield. Modules only.
    /// @param to     Receiver.
    /// @param amount Amount.
    function moduleMint(
        address to,
        uint256 amount
    ) external;

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

    /// @notice Redeem fund tokens for a pro-rata slice of every basket asset.
    /// @param shares        Fund tokens redeemed, fees included.
    /// @param receiver      Receiver of the basket assets.
    /// @param minAmountsOut Per-asset minimum, in {assets} order (empty to skip).
    /// @return amounts Amount of each asset paid out, in {assets} order.
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external returns (uint256[] memory amounts);

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

    /// @notice Swap between two basket assets through an allowed router. Manager only. Each swap
    ///         may lose at most the factory's slippage bound in oracle value, and the value sold per
    ///         rolling day is capped, which bounds what a manager can leak through bad fills.
    /// @param params Swap parameters.
    function rebalance(
        RebalanceParams calldata params
    ) external;

    /// @notice Replace the basket's asset list and target weights. Manager only, after launch.
    ///         Assets still held cannot be dropped; new assets need an oracle feed.
    /// @param assets_     Assets.
    /// @param weightsBps_ Target weights (sum 10 000).
    function setTargetWeights(
        address[] calldata assets_,
        uint16[] calldata weightsBps_
    ) external;

    /// @notice Set the creator fee. Admin only (the creator cannot change it).
    /// @param feeBps    Fee, in basis points (capped).
    /// @param recipient Recipient.
    function setCreatorFee(
        uint16 feeBps,
        address recipient
    ) external;

    /// @notice Replace the mint-with-lock options. Admin only.
    /// @param options New options.
    function setLockOptions(
        LockOption[] calldata options
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

    /// @notice The creator managing the basket.
    /// @return The manager.
    function manager() external view returns (address);

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

    /// @notice Creator fee, in basis points.
    /// @return The fee.
    function creatorFeeBps() external view returns (uint16);

    /// @notice Creator fee recipient.
    /// @return The recipient.
    function creatorFeeRecipient() external view returns (address);

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

    /// @notice Basket value, 18 decimals USD. Reverts if any asset's price is unavailable.
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

    /// @notice Quote a redeem.
    /// @param shares Fund tokens redeemed, fees included.
    /// @return amounts Amount of each asset paid out, in {assets} order.
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256[] memory amounts);
}
