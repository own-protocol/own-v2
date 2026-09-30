// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FundTypes — shared types for MONEY Market Funds

/// @notice A mint-with-lock option: the minter accepts a lock on the minted fund tokens in exchange
///         for a discount to the fund token's market price.
/// @param duration    Lock length, in seconds (non-zero).
/// @param discountBps Discount to the market price, in basis points.
struct LockOption {
    uint32 duration;
    uint16 discountBps;
}

/// @notice One staker-yield tier: while the fund trades at a premium of at least `minPremiumBps`
///         over NAV, stakers earn `rateBpsPerWeek` of the staked balance, paid in new fund tokens.
/// @param minPremiumBps   Premium threshold, in basis points of NAV (ascending across tiers).
/// @param rateBpsPerWeek  Weekly rate, in basis points of the staked balance.
struct YieldTier {
    uint16 minPremiumBps;
    uint16 rateBpsPerWeek;
}

/// @notice Everything a launcher chooses when creating a fund.
/// @param name                 Fund token name.
/// @param symbol               Fund token symbol.
/// @param assets               Basket assets (each must have an oracle feed).
/// @param weightsBps           Target weight per asset; sums to 10 000.
/// @param manager              Creator address that manages the basket (weights, rebalances).
/// @param creatorFeeRecipient  Receives the creator fee.
/// @param creatorFeeBps        Creator fee on pool trades, mints and redeems (0 to 10%).
/// @param minGraduationUsd     Minimum basket value (18 decimals USD) the launch must raise.
/// @param lockOptions          Mint-with-lock options.
/// @param yieldTiers           Staker-yield tiers by premium.
struct CreateFundParams {
    string name;
    string symbol;
    address[] assets;
    uint16[] weightsBps;
    address manager;
    address creatorFeeRecipient;
    uint16 creatorFeeBps;
    uint256 minGraduationUsd;
    LockOption[] lockOptions;
    YieldTier[] yieldTiers;
}

/// @notice Launch parameters snapshotted into each launch when its fund is created.
/// @param duration           Deposit window length, in seconds.
/// @param finalizeGrace      Time after the window closes within which finalization must happen,
///                           otherwise the launch can be marked failed and refunded.
/// @param usdgRatioBps       USDG each depositor adds, as basis points of their basket deposit value.
/// @param launchPremiumBps   Premium over NAV at which the pool opens.
struct LaunchConfig {
    uint32 duration;
    uint32 finalizeGrace;
    uint16 usdgRatioBps;
    uint16 launchPremiumBps;
}
