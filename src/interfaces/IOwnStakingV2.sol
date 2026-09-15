// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOwnStakingV2 — Dual-asset staking with a curve-boosted SPY reward stream
/// @notice Stake eUSD (the earning principal) alongside $MONEY (the multiplier). Each position's
///         reward weight is `eusdStaked × boost`, where the boost is read off an admin-set
///         piecewise-linear curve over the position's coverage ratio — the oracle-priced value of
///         its staked $MONEY relative to its staked eUSD. SPY rewards stream in linearly
///         (Synthetix-style index) from an admin-set reward source, pulled by the operator within
///         the source's live ERC-20 allowance.
interface IOwnStakingV2 {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice One point of the boost curve.
    /// @param coverageBps Coverage ratio (staked $MONEY value / staked eUSD value), 10_000 = 1:1.
    /// @param boostBps    Boost multiplier at that coverage, 10_000 = 1.0x.
    struct Knot {
        uint64 coverageBps;
        uint64 boostBps;
    }

    /// @notice A user's staking position.
    /// @param moneyStaked     $MONEY units staked (18 decimals).
    /// @param eusdStaked      eUSD units staked (18 decimals).
    /// @param boostBps        Boost snapshot taken at the last touch (10_000 = 1.0x).
    /// @param rewardIndexPaid Global reward index at the last settlement (PRECISION-scaled).
    /// @param rewardsOwed     Settled, claimable SPY (18 decimals).
    struct Position {
        uint256 moneyStaked;
        uint256 eusdStaked;
        uint256 boostBps;
        uint256 rewardIndexPaid;
        uint256 rewardsOwed;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when a user stakes either or both legs.
    /// @param user     Position owner.
    /// @param money    $MONEY added.
    /// @param eusd     eUSD added.
    /// @param boostBps Boost snapshot after the stake.
    event Staked(address indexed user, uint256 money, uint256 eusd, uint256 boostBps);

    /// @notice Emitted when a user unstakes either or both legs.
    /// @param user     Position owner.
    /// @param money    $MONEY removed.
    /// @param eusd     eUSD removed.
    /// @param boostBps Boost snapshot after the unstake.
    event Unstaked(address indexed user, uint256 money, uint256 eusd, uint256 boostBps);

    /// @notice Emitted when settled SPY rewards are paid out.
    /// @param user   Position owner.
    /// @param to     Recipient of the SPY.
    /// @param amount SPY paid.
    event Claimed(address indexed user, address indexed to, uint256 amount);

    /// @notice Emitted when a position's boost is re-snapshotted at the current oracle price.
    /// @param user        Position owner.
    /// @param oldBoostBps Boost before the refresh.
    /// @param newBoostBps Boost after the refresh.
    event BoostRefreshed(address indexed user, uint256 oldBoostBps, uint256 newBoostBps);

    /// @notice Emitted when new SPY enters the reward stream.
    /// @param source Where the SPY came from (reward source, this contract for sync/re-notify).
    /// @param amount SPY folded into the stream.
    /// @param rate   New PRECISION-scaled reward rate (SPY-wei × PRECISION per second).
    event RewardNotified(address indexed source, uint256 amount, uint256 rate);

    /// @notice Emitted when directly-transferred SPY is folded into the stream.
    /// @param amount Surplus SPY absorbed.
    event RewardsSynced(uint256 amount);

    /// @notice Emitted when rewards accrued over a zero-weight stretch re-enter the stream.
    /// @param amount SPY re-notified.
    event UndistributedRenotified(uint256 amount);

    /// @notice Emitted when the boost curve is replaced.
    /// @param knots The new curve.
    event CurveSet(Knot[] knots);

    /// @notice Emitted when the global eUSD deposit cap changes.
    /// @param cap New cap in eUSD (0 = uncapped).
    event StakeCapSet(uint256 cap);

    /// @notice Emitted when the hard boost cap changes.
    /// @param maxBoostBps New cap (10_000 = 1.0x).
    event MaxBoostSet(uint256 maxBoostBps);

    /// @notice Emitted when the reward stream window changes.
    /// @param duration New window in seconds.
    event RewardsDurationSet(uint256 duration);

    /// @notice Emitted when the boost-price staleness bound changes.
    /// @param maxAge New max accepted $MONEY price age in seconds.
    event PriceMaxAgeSet(uint256 maxAge);

    /// @notice Emitted when the reward source changes.
    /// @param source New reward source (the treasury Safe).
    event RewardSourceSet(address indexed source);

    /// @notice Emitted when a non-protocol token is rescued.
    /// @param token  Token rescued.
    /// @param to     Recipient.
    /// @param amount Amount rescued.
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the whitelisted zap changes.
    /// @param zap New zap address (address(0) disables the zap surface).
    event ZapSet(address indexed zap);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero.
    error ZeroAmount();
    /// @notice Caller lacks the ADMIN role.
    error OnlyAdmin();
    /// @notice Caller lacks the OPERATOR role.
    error OnlyOperator();
    /// @notice The stake would push total staked eUSD past the cap.
    /// @param totalAfter Total staked eUSD after the stake.
    /// @param cap        Current cap.
    error StakeCapExceeded(uint256 totalAfter, uint256 cap);
    /// @notice Unstake amount exceeds the position's staked balance.
    error InsufficientStake();
    /// @notice The curve is malformed: fewer than two knots, coverage not strictly increasing,
    ///         boost decreasing, or a boost above the hard cap.
    error InvalidCurve();
    /// @notice No un-accounted SPY balance to sync.
    error NothingToSync();
    /// @notice No undistributed rewards to re-notify.
    error NoUndistributed();
    /// @notice The token cannot be rescued (reward or staked asset).
    error ProtectedToken(address token);
    /// @notice Caller is not the whitelisted zap.
    error OnlyZap();

    // ──────────────────────────────────────────────────────────
    //  User actions
    // ──────────────────────────────────────────────────────────

    /// @notice Stake $MONEY and/or eUSD. Settles pending rewards, then re-snapshots the boost at
    ///         the current oracle price. A stale, zero, or missing $MONEY price floors the boost
    ///         (first curve knot) until the next refresh — staking never reverts on price.
    /// @param money $MONEY to add (may be zero).
    /// @param eusd  eUSD to add (may be zero; both zero reverts).
    function stake(uint256 money, uint256 eusd) external;

    /// @notice Unstake $MONEY and/or eUSD. Settles pending rewards, then re-snapshots the boost.
    ///         Needs no oracle price — a full exit always works.
    /// @param money $MONEY to remove (may be zero).
    /// @param eusd  eUSD to remove (may be zero; both zero reverts).
    function unstake(uint256 money, uint256 eusd) external;

    /// @notice Pay out the caller's settled SPY rewards.
    /// @param to Recipient of the SPY.
    /// @return amount SPY paid.
    function claim(
        address to
    ) external returns (uint256 amount);

    /// @notice Unstake everything and claim in one call.
    function exit() external;

    /// @notice Stake $MONEY and/or eUSD pulled from the caller into `owner`'s position.
    ///         Permissionless: staking for someone else only ever benefits them. Same rules as
    ///         {stake}, including the eUSD cap and the boost re-snapshot.
    /// @param owner Position owner credited with the stake.
    /// @param money $MONEY to add (may be zero).
    /// @param eusd  eUSD to add (may be zero; both zero reverts).
    function stakeFor(address owner, uint256 money, uint256 eusd) external;

    // ──────────────────────────────────────────────────────────
    //  Zap surface (whitelisted zap only)
    // ──────────────────────────────────────────────────────────

    /// @notice Unstake from `owner`'s position with the tokens paid to the caller. Zap only —
    ///         on-behalf withdrawal surface reachable solely through the whitelisted zap, whose
    ///         only use is rebalancing: the unstaked eUSD immediately repays `owner`'s CDP debt
    ///         in the same transaction, so `owner`'s health only improves.
    /// @param owner Position owner to unstake from.
    /// @param money $MONEY to remove (may be zero).
    /// @param eusd  eUSD to remove (may be zero; both zero reverts).
    function unstakeFor(address owner, uint256 money, uint256 eusd) external;

    /// @notice Pay `owner`'s settled SPY rewards to the caller. Zap only — the zap converts the
    ///         SPY to CDP collateral for `owner` in the same transaction (compounding).
    /// @param owner Position owner whose rewards are claimed.
    /// @return amount SPY paid to the caller.
    function claimFor(
        address owner
    ) external returns (uint256 amount);

    /// @notice Permissionlessly re-snapshot boosts at the current oracle price, settling each
    ///         position at its old weight first. Called by the keeper after price moves; any user
    ///         can refresh any position in either direction.
    /// @param users Positions to refresh.
    function refreshBoost(
        address[] calldata users
    ) external;

    /// @notice Book SPY transferred directly to this contract (donations, alternative fee
    ///         routing) into the undistributed bucket. Permissionless — it re-enters the
    ///         stream only via the operator's {renotifyUndistributed}, so a dust surplus can
    ///         never reset the streaming window.
    /// @return amount Surplus SPY absorbed.
    function syncRewards() external returns (uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Operator
    // ──────────────────────────────────────────────────────────

    /// @notice Pull `amount` SPY from the reward source and stream it over `rewardsDuration`,
    ///         folding in any unstreamed remainder. Bounded on-chain by the reward source's live
    ///         ERC-20 allowance to this contract. OPERATOR only.
    /// @param amount SPY to pull and stream.
    function notifyRewardAmount(
        uint256 amount
    ) external;

    /// @notice Re-stream rewards that accrued while total weight was zero. OPERATOR only.
    /// @return amount SPY re-notified.
    function renotifyUndistributed() external returns (uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Admin (via ProtocolRegistry roles)
    // ──────────────────────────────────────────────────────────

    /// @notice Replace the boost curve. Knots must be strictly increasing in coverage,
    ///         non-decreasing in boost, at least two, and capped by `maxBoostBps`.
    /// @param knots The new curve.
    function setCurve(
        Knot[] calldata knots
    ) external;

    /// @notice Set the global cap on total staked eUSD (0 = uncapped).
    /// @param cap New cap in eUSD.
    function setStakeCap(
        uint256 cap
    ) external;

    /// @notice Set the hard boost cap applied over any curve.
    /// @param maxBoostBps_ New cap (non-zero).
    function setMaxBoost(
        uint256 maxBoostBps_
    ) external;

    /// @notice Set the reward stream window. Any in-flight remainder re-streams over the new
    ///         window from now, so the rate never jumps discontinuously for stakers.
    /// @param duration New window in seconds (non-zero).
    function setRewardsDuration(
        uint256 duration
    ) external;

    /// @notice Set the max accepted $MONEY price age for boost snapshots.
    /// @param maxAge New bound in seconds (non-zero).
    function setPriceMaxAge(
        uint256 maxAge
    ) external;

    /// @notice Set the reward source `notifyRewardAmount` pulls from (the treasury Safe).
    /// @param source New source (non-zero).
    function setRewardSource(
        address source
    ) external;

    /// @notice Set the whitelisted zap allowed to call {unstakeFor}/{claimFor}
    ///         (address(0) disables both).
    /// @param zap_ New zap address.
    function setZap(
        address zap_
    ) external;

    /// @notice Rescue a token that is neither the reward asset nor a staked asset.
    /// @param token  Token to rescue.
    /// @param to     Recipient.
    /// @param amount Amount to transfer.
    function rescueToken(address token, address to, uint256 amount) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice A user's full position.
    function position(
        address user
    ) external view returns (Position memory);

    /// @notice A user's settled plus accrued-but-unsettled SPY rewards.
    function earned(
        address user
    ) external view returns (uint256);

    /// @notice A user's current boost snapshot (10_000 = 1.0x).
    function boostBps(
        address user
    ) external view returns (uint256);

    /// @notice The boost a hypothetical position would snapshot at the current boost price
    ///         (live oracle mark, or the last usable mark during an outage). Returns the floor
    ///         boost only before any usable mark has ever been seen.
    /// @param money $MONEY staked.
    /// @param eusd  eUSD staked.
    function previewBoost(uint256 money, uint256 eusd) external view returns (uint256);

    /// @notice Current $MONEY price used for boosts (18 decimals): the live oracle mark when
    ///         usable, else {lastMoneyPrice}. Zero only before any usable mark has been seen.
    function moneyPrice() external view returns (uint256);

    /// @notice Last usable $MONEY mark cached on a boost re-snapshot (18 decimals). Boosts
    ///         reprice against this during an oracle outage so an outage never floors them.
    function lastMoneyPrice() external view returns (uint256);

    /// @notice The boost curve.
    function curve() external view returns (Knot[] memory);

    /// @notice Sum of all position weights (eusdStaked × boost / BPS).
    function totalWeight() external view returns (uint256);

    /// @notice Total eUSD staked across all positions.
    function totalEusdStaked() external view returns (uint256);

    /// @notice Total $MONEY staked across all positions.
    function totalMoneyStaked() external view returns (uint256);

    /// @notice Current PRECISION-scaled reward rate (SPY-wei × PRECISION per second).
    function rewardRate() external view returns (uint256);

    /// @notice Timestamp the current reward stream ends.
    function periodFinish() external view returns (uint256);

    /// @notice Reward stream window applied to each notify.
    function rewardsDuration() external view returns (uint256);

    /// @notice SPY accrued while total weight was zero, awaiting re-notify.
    function undistributed() external view returns (uint256);

    /// @notice Global cap on total staked eUSD (0 = uncapped).
    function stakeCap() external view returns (uint256);

    /// @notice Hard boost cap applied over any curve.
    function maxBoostBps() external view returns (uint256);

    /// @notice Max accepted $MONEY price age for boost snapshots (seconds).
    function priceMaxAge() external view returns (uint256);

    /// @notice Address `notifyRewardAmount` pulls SPY from (the treasury Safe).
    function rewardSource() external view returns (address);

    /// @notice The whitelisted zap (address(0) = none).
    function zap() external view returns (address);
}
