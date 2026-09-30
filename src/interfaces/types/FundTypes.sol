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
///         over NAV, stakers earn `rateBpsPerDay` of the staked balance, paid in new fund tokens.
/// @param minPremiumBps  Premium threshold, in basis points of NAV (ascending across tiers).
/// @param rateBpsPerDay  Daily rate, in basis points of the staked balance (capped by the factory).
struct YieldTier {
    uint16 minPremiumBps;
    uint16 rateBpsPerDay;
}

/// @notice Everything a launcher chooses when creating a fund.
/// @param name                 Fund token name.
/// @param symbol               Fund token symbol.
/// @param logoURI              Logo URI chosen by the creator.
/// @param description          Description chosen by the creator.
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
    string logoURI;
    string description;
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

/// @notice Voting rules for a fund's portfolio changes, snapshotted into each proposal.
/// @param creatorPowerBps    Fixed share of the total vote held by the creator (the proposer).
/// @param passThresholdBps   Share of the total vote in favour needed to pass.
/// @param minUserSupportBps  Share of the total vote in favour that must come from holders.
/// @param votingPeriod       Voting length, in seconds.
/// @param executionDelay     Wait after voting ends before a passed proposal can execute (admin
///                           veto window).
/// @param executionWindow    Time after the delay within which it must execute, or it expires.
struct GovernanceConfig {
    uint16 creatorPowerBps;
    uint16 passThresholdBps;
    uint16 minUserSupportBps;
    uint32 votingPeriod;
    uint32 executionDelay;
    uint32 executionWindow;
}

/// @title GovernanceConfigLib — bounds shared by the factory and every governor
library GovernanceConfigLib {
    /// @notice Whether `c` is within bounds: the creator's share leaves room for holders, the
    ///         thresholds are reachable, and every period is between one hour and 30 days (the
    ///         delay may be zero).
    /// @param c The parameters.
    /// @return True if valid.
    function isValid(
        GovernanceConfig memory c
    ) internal pure returns (bool) {
        return c.creatorPowerBps < 10_000 && c.passThresholdBps != 0 && c.passThresholdBps <= 10_000
            && c.minUserSupportBps <= 10_000 - c.creatorPowerBps && c.votingPeriod >= 1 hours
            && c.votingPeriod <= 30 days && c.executionDelay <= 30 days && c.executionWindow >= 1 hours
            && c.executionWindow <= 30 days;
    }
}

/// @notice Platform-wide metadata every fund carries: what a MONEY Market Fund is and who runs it.
/// @param name        Platform name, e.g. "MONEY Market Funds by Own".
/// @param description About the platform, Own and the MONEY token.
/// @param url         Platform link.
struct PlatformMetadata {
    string name;
    string description;
    string url;
}

/// @notice A fund's full metadata: the creator's fields plus the platform's.
/// @param name        Fund token name.
/// @param symbol      Fund token symbol.
/// @param logoURI     Logo URI.
/// @param description Fund description.
/// @param platform    Platform metadata.
struct FundMetadata {
    string name;
    string symbol;
    string logoURI;
    string description;
    PlatformMetadata platform;
}
