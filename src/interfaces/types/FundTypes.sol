// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FundTypes — shared types for Own Curated Funds

/// @dev Maximum number of basket assets (bounds every loop over a basket).
uint256 constant MAX_BASKET_ASSETS = 20;

/// @dev A 1e18-scaled share ("WAD"): 1e18 is the whole, e.g. every possible vote.
uint256 constant WAD = 1e18;

/// @dev Converts basis points to WAD.
uint256 constant BPS_TO_WAD = 1e14;

/// @notice A token's place in a fund's basket, kept in one storage slot.
/// @param listed    Whether the token is in the basket.
/// @param weightBps Target weight, in basis points.
struct BasketEntry {
    bool listed;
    uint16 weightBps;
}

/// @notice A mint-with-lock option: the minter accepts a lock on the minted fund tokens in exchange
///         for a discount to the fund token's market price.
/// @param duration    Lock length, in seconds (non-zero).
/// @param discountBps Discount to the market price, in basis points.
struct LockOption {
    uint32 duration;
    uint16 discountBps;
}

/// @notice One point on the staker-yield curve. Stakers earn, in new fund tokens, a yearly rate
///         interpolated linearly between the points around the fund's premium over NAV: nothing
///         below the first point, the last point's rate from the last point on. A hump (rising to
///         a peak, then falling to zero towards the mint ceiling) keeps yield from feeding a
///         runaway premium.
/// @param premiumBps     Premium, in basis points of NAV (strictly ascending across points).
/// @param rateBpsPerYear Yearly rate (APR) at that premium, in basis points of the staked balance
///                       (capped by the factory).
struct YieldPoint {
    uint16 premiumBps;
    uint32 rateBpsPerYear;
}

/// @notice Everything Own chooses when creating a fund.
/// @param name               Fund token name.
/// @param symbol             Fund token symbol.
/// @param logoURI            Logo URI.
/// @param description        Description.
/// @param assets             Basket assets (each must have an oracle feed; USDG is not allowed).
/// @param weightsBps         Starting target weight per asset; sums to 10 000.
/// @param manager            The Own keeper that rebalances the basket.
/// @param curators           Starting curators (at most the factory's curator cap).
/// @param feeBps             Fund fee on pool trades, mints and redeems, all paid to the curators
///                           (0 for the default 1%, at most 10%).
/// @param minCuratorStakeBps Share of supply each curator must keep staked in the governor.
/// @param minRaiseUsd        Minimum value (18 decimals USD) the launch must raise.
/// @param targetRaiseUsd     Raise at which the launch can close before the window ends (0 for none).
/// @param launchSupply       Fixed fund token supply created at launch (0 for the default 100M).
/// @param launchDuration     Deposit window length, in seconds (0 for the default 7 days).
/// @param poolUsdgBps        Share of the raise that seeds the pool in USDG (0 for the default 10%).
/// @param lockOptions        Mint-with-lock options.
/// @param yieldCurve         Staker-yield curve by premium.
/// @param maxPremiumBps      Mint premium ceiling, in basis points over NAV (0 for none).
struct CreateFundParams {
    string name;
    string symbol;
    string logoURI;
    string description;
    address[] assets;
    uint16[] weightsBps;
    address manager;
    address[] curators;
    uint16 feeBps;
    uint16 minCuratorStakeBps;
    uint256 minRaiseUsd;
    uint256 targetRaiseUsd;
    uint256 launchSupply;
    uint32 launchDuration;
    uint16 poolUsdgBps;
    LockOption[] lockOptions;
    YieldPoint[] yieldCurve;
    uint16 maxPremiumBps;
}

/// @notice Launch rules. The factory holds the defaults; each launch snapshots them with its own
///         duration, pool share and supply.
/// @param duration            Deposit window length, in seconds (1 to 30 days).
/// @param finalizeGrace       Time after the window closes within which finalization must happen,
///                            otherwise the launch can be marked failed and refunded.
/// @param poolUsdgBps         Share of the raise, in basis points, that seeds the pool in USDG; it is
///                            also USDG's target weight for the overweight haircut.
/// @param launchPremiumBps    Premium over NAV at which the pool opens.
/// @param earlyYieldBpsPerDay Extra launch tokens per day a deposit sits in the window, in basis
///                            points of its value.
/// @param overweightHaircutBps Haircut on deposit value above an asset's target weight of the raise.
/// @param depositorLock       How long depositors' launch tokens stay non-transferable.
struct LaunchConfig {
    uint32 duration;
    uint32 finalizeGrace;
    uint16 poolUsdgBps;
    uint16 launchPremiumBps;
    uint16 earlyYieldBpsPerDay;
    uint16 overweightHaircutBps;
    uint32 depositorLock;
}

/// @notice A fund's governance rules: the weekly weight vote and proposals.
/// @param curatorShareBps     Share of every vote held by the curators together (split equally).
/// @param minVoteBps          A token with less than this share of the vote is targeted at 0.
/// @param maxWeightBps        Cap on any token's target weight.
/// @param maxWeeklyShiftBps   Largest move of any weight in one week.
/// @param dropAfterEpochs     Consecutive weeks under `minVoteBps` after which a token is dropped.
/// @param quorumBps           Yes votes a listing or delisting needs, as a share of all possible votes.
/// @param curatorQuorumBps    Yes votes a curator change needs, as a share of all staked tokens.
/// @param votingPeriod        Proposal voting length, in seconds.
/// @param vetoPeriod          Wait after voting ends in which Own can veto, in seconds.
/// @param executionWindow     Time after the veto period within which a proposal must execute.
/// @param bribeLock           Unlock delay, in seconds, on withdrawals by accounts locked for bribes.
/// @param proposalThresholdUsd Stake (valued at NAV, 18 decimals USD) a non-curator needs to propose.
struct GovernanceConfig {
    uint16 curatorShareBps;
    uint16 minVoteBps;
    uint16 maxWeightBps;
    uint16 maxWeeklyShiftBps;
    uint8 dropAfterEpochs;
    uint16 quorumBps;
    uint16 curatorQuorumBps;
    uint32 votingPeriod;
    uint32 vetoPeriod;
    uint32 executionWindow;
    uint32 bribeLock;
    uint256 proposalThresholdUsd;
}

/// @title GovernanceConfigLib — bounds shared by the factory and every governor
library GovernanceConfigLib {
    /// @notice Whether `c` is within bounds.
    /// @param c The parameters.
    /// @return True if valid.
    function isValid(
        GovernanceConfig memory c
    ) internal pure returns (bool) {
        return c.curatorShareBps <= 5000 && c.minVoteBps <= 1000 && c.maxWeightBps >= 1000 && c.maxWeightBps <= 10_000
            && c.maxWeeklyShiftBps != 0 && c.maxWeeklyShiftBps <= 10_000 && c.dropAfterEpochs != 0 && c.quorumBps != 0
            && c.quorumBps <= 10_000 && c.curatorQuorumBps != 0 && c.curatorQuorumBps <= 10_000 && c.votingPeriod >= 1 hours
            && c.votingPeriod <= 30 days && c.vetoPeriod <= 30 days && c.executionWindow >= 1 hours
            && c.executionWindow <= 30 days && c.bribeLock <= 365 days;
    }
}

/// @notice Platform-wide metadata every fund carries.
/// @param name        Platform name, e.g. "Own Curated Funds".
/// @param description About the platform, Own and the MONEY token.
/// @param url         Platform link.
struct PlatformMetadata {
    string name;
    string description;
    string url;
}

/// @notice A fund's full metadata: its own fields plus the platform's.
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
