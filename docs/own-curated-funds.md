# Own Curated Funds

Basket-backed fund tokens that Own launches with a small set of curators. Each fund is an ERC-20
backed by a basket of Robinhood Chain tokens and stock tokens plus its own USDG pool position,
trades in its own Uniswap v4 pool against USDG, and pays stakers new tokens while it trades above
NAV. Curators and stakers set the basket weights in a weekly vote, and anyone can bribe that vote.

Design source: the "Own Curated Funds: launch, curators, weight votes and bribes" spec (2026-10-01).

## Contracts (`src/funds/`)

| Contract | Role |
| --- | --- |
| `FundFactory` | UUPS. Platform admin hub: launcher whitelist (Own only by default), protocol fee (0.5% default, 5% cap), rebalance routers and limits, launch and governance defaults, staking yield cap (3% a day), curator cap (10), bribe cut (5%, 10% cap), bribe tokens, the listing eligibility list and the platform metadata. Owns the six module beacons, so one call upgrades every fund. |
| `Fund` | Beacon proxy per fund. The fund token plus custody of the basket and idle USDG: mint, redeem, locks, rebalance, the depositor lock. NAV counts the pool position. |
| `FundLaunch` | Beacon proxy per fund. Deposit window (any basket token or USDG), early close at the target raise, early-deposit yield, overweight haircut, the fixed-supply split and pool seeding after the launch rebalance. |
| `FundStaking` | Beacon proxy per fund. Staked fund token (e.g. sOCF1) with issuance set by a premium-based yield curve, and staking of full-range Uniswap v4 LP position NFTs in the fund's pool. |
| `FundGovernor` | Beacon proxy per fund. Staked escrow, the weekly weight vote (gauge) and proposals to list or delist tokens and add, remove or replace curators. |
| `FundCurators` | Beacon proxy per fund. The curator set, the minimum curator stake and compliance, and the curator fee split. It is the curator fee recipient. |
| `FundBribes` | Beacon proxy per fund. Bribes on the weekly vote per token per week, and bribes on listing proposals. |
| `FundHook` | One Uniswap v4 hook for every fund pool: USDG swap fees, admin-set LP fee, the TWAP, and the fund's own pool position. |
| `FundOracle` | Per-asset Chainlink-style feeds. A fund token's own market price is read through the same surface. |
| `FundTwapFeed` | Per fund. Serves the fund's pool TWAP (recorded by the hook) as an aggregator. |
| `FundRedeemZap` | Redeem a fund token and swap the basket to USDG through allowed routers in one transaction. |

## Launch

1. **Create.** `createFund` is open to the factory owner and whitelisted launchers (the whitelist
   is on and empty by default, so only Own launches). Own sets the name, symbol, logo and
   description, the basket and starting weights, the manager (the Own keeper), the curators (up to
   the cap) and curator fee (0 to 10%), the minimum curator stake, lock options, the yield curve,
   the mint premium ceiling, the minimum raise, the target raise (optional), the pool's USDG share
   (default 10%, at most 50%), the launch supply (default 100M) and the launch window (default 7
   days, 1 to 30 allowed). Only the admin can change the metadata, curator fee, lock options,
   yield curve and premium ceiling afterwards.
2. **Deposit window.** Anyone deposits any basket asset with a non-zero weight, or USDG, on its
   own. Deposits are final: there are no withdrawals.
   - **Early-deposit yield:** each deposit earns 0.5% a day of its amount until the close, paid as
     extra launch tokens out of the fixed supply.
   - `depositValues()` shows each asset's value against its target share, and `raisedValue()` the
     live total, so the launch page can flag overweight assets and track the target.
3. **Finalize** (anyone): at or after the end of the window (within 7 days), or earlier as soon as
   the deposits are worth the target raise. Assets are valued at closing oracle prices and USDG at
   $1: raise V. The target is checked at those closing prices.
   - If V is below the minimum raise the launch fails and everyone is refunded in full. If nobody
     finalizes within 7 days of the close, anyone can mark it failed.
   - **Overweight haircut:** USDG's target share of V is the pool share (10%) and the basket assets
     split the rest by weight. Value above an asset's (or USDG's) target is credited at 95%, since
     the fund pays to rebalance it. The withheld credit goes to the other depositors.
   - **Fixed supply S is split** so that the pool will open at 1.3 × NAV. The pool gets
     P = 10% of V in USDG and M = P·S / (1.3·V + P) tokens (about 7% of S); depositors share
     C = S − M in proportion to their points (closing value + early yield, after the haircut).
   - Everything deposited moves to the fund, depositors can claim, and their tokens are locked for
     7 days. NAV is V / C. The pool is not open yet.
4. **Launch rebalance and pool seeding.** The manager rebalances the fund to its target weights and
   to at least P of idle USDG, selling basket tokens for USDG if the USDG deposits fall short.
   Until the pool is seeded the rebalance may buy USDG and the daily volume cap does not apply
   (the 2% per-swap loss bound still does). The manager (or admin) then calls `seedPool()`, which
   adds P of the fund's USDG and the M tokens as the fund's position, so the pool opens at 1.3 ×
   NAV. Redemptions before seeding shrink P and M in proportion. Before seeding nobody can trade
   or mint and stakers earn nothing; redeeming works.
5. **Auto-stake, no claim needed.** At the close the launch stakes the whole depositor allocation,
   so it earns staker yield from then on (once the pool gives a market price) and, until its
   owners vote, counts as silent stake whose weekly votes follow the curators. Anyone (the keeper)
   calls `distribute(accounts)` to push each depositor's staked shares, locked for 7 days; a
   depositor can also `claim` their own, staked or as fund tokens. Locked shares and tokens cannot
   be transferred or sold for 7 days, but they can be escrowed in the governor and redeemed at
   NAV. Unstaking during the lock keeps the tokens locked and pays only to the staker's own
   account. Tokens bought later are never locked.

## The fund's pool position

- The hook holds one full-range position per fund for the fund. It counts toward NAV:
  NAV = (basket + idle USDG + the position's USDG) / (supply − the position's fund tokens), with the
  position valued at the pool's 30-minute TWAP (falling back to the history it has), never at spot.
- Depositors therefore get exactly what they brought at NAV, and premium buys from the pool raise
  NAV for every holder.
- **Redeem** pays a pro-rata slice of the basket, of the fund's idle USDG and of the position: the
  position's USDG out (capped at its TWAP value, so a pumped spot price cannot be drained; anything
  above the cap goes to the fund) and the matching fund tokens burned.
- LP fees the position earns go to the fund (USDG) or are burned (fund tokens). Outside LPs can add
  their own positions; only the fund's own position counts.
- The position stays locked. In rare cases the admin can withdraw part or all of it, and the
  proceeds always go back into the fund.

## Live

- **Mint** with any basket asset at `max(min(marketTWAP, ceiling) × (1 − lockDiscount), NAV)`, where
  `ceiling = NAV × (1 + maxPremium)`. A lock option earns its discount and holds the tokens until it
  expires. A mint is never priced below NAV.
- **Premium ceiling.** Set per fund by the admin (e.g. 100% = 2x NAV; 0 turns it off). When the
  market trades above it, anyone can mint at the ceiling and sell into the pool, so arbitrage holds
  the price near the ceiling, and every such mint adds backing (NAV per token rises). While the
  ceiling binds, a mint may not take its asset above its target weight, so arbitrageurs cannot skew
  the basket with whichever asset is cheapest for them.
- **Redeem** at any time, as above. It needs no oracle and cannot be paused.
- **Fees.** The protocol fee (0.5%) and the curator fee (set per fund) on pool trades (in USDG
  through the hook), mint and redeem (in fund tokens). The curator fee goes to `FundCurators`.
- **Staking:** while the market TWAP trades at a premium to NAV, stakers earn a daily rate read off
  the fund's yield curve, paid by minting new fund tokens (capped by the factory's yield cap, 3% a
  day by default). The curve is up to 8 (premium, daily rate) points, interpolated linearly: no
  yield below the first point, the last point's rate past the last point. The intended shape is a
  hump, for example 0 at NAV, about 1% a week from a 10% to a 30% premium, then down to 0 at the
  ceiling, so yield draws stakers in at a moderate premium and stops fuelling a runaway one. No
  yield at or below NAV. Yield accrues every 8 hours at most.
- **LP staking:** LPs stake their Uniswap v4 position NFT in `FundStaking` (`stakePosition`, or
  send it with the PositionManager's `safeTransferFrom`). Only full-range positions in the fund's
  pool qualify, so every staked position holds the same fund tokens per unit of liquidity and one
  yield-per-liquidity counter pays them all fairly. A staked position earns the staking rate on the
  fund tokens it holds, valued at the pool's 30-minute TWAP; its USDG side earns nothing. The yield
  is minted with the stakers' yield, held in `FundStaking` and claimed in fund tokens
  (`claimPositionYield`, or on `unstakePosition`). The position's swap fees stay the LP's: they can
  collect them while staked (`collectPositionFees`) or after unstaking. Staked positions do not
  vote and earn no bribes. The admin can return a position NFT that reached `FundStaking` without
  being staked (`recoverPosition`).
- **Rebalancing:** the manager (Own keeper) swaps between basket assets, and from idle USDG into
  them, through admin-allowed routers: at most 2% loss of oracle value per swap, and at most 10% of
  the basket a day (a running total that drains at the full cap per day). Assets worth up to 0.1%
  of the basket count as dust. The launch rebalance before the pool opens is the exception above.

## Curators

- Up to 10 per fund (admin-set cap). Own can add them directly up to the cap; proposals can add,
  remove or replace them. No minimum: with no curators, stakers hold the whole vote.
- The curator fee is split equally among the curators in compliance, who claim it from
  `FundCurators` in fund tokens and USDG. Fees that arrive while nobody is compliant wait for the
  next compliant curator.
- **Minimum stake:** each curator must keep at least 0.5% of supply (admin-set per fund, 10% cap)
  staked in the governor. It is checked at every weekly flip with one week of grace; a curator out
  of compliance loses their vote slice (it counts as silent) and their fee share.

## Weekly weight vote (gauge)

- Epochs run a week and flip Thursday 00:00 UTC. Anyone (the keeper in practice) calls
  `governor.flip()`; skipped weeks are tallied one call at a time, oldest first.
- **Who votes.** Curators together hold 30% of the vote, split equally, as base slices. Stakers hold
  70%: each staker's votes are worth 70% × (its staked tokens escrowed in the governor ÷ all staked
  tokens). Staked tokens that are not escrowed, and unstaked tokens, do not vote. A curator's own
  escrowed stake votes on the staker side as well. "All staked tokens" is the week's record: new
  stake counts from the next week, unstaking leaves at once, so staking just before a flip changes
  nothing.
- **Escrow.** Stakers deposit staked fund tokens (or an admin-listed ERC-4626 wrapper of them).
  A deposit counts from the next epoch. A withdrawal stops counting at once and unlocks at the next
  flip, or at the end of any proposal the account voted on if later. Escrowed stake keeps earning
  staker yield.
- **Bribe lock.** An account can call `lockForBribes()` to lock its escrow for bribes, from the
  current week on. Only locked stake earns bribes. The lock is rolling and one-way: every later
  withdrawal unlocks 4 weeks (`bribeLock`, admin-set per fund, at most a year) after it is
  requested. Unlocked escrow still votes; it just earns no bribes.
- **Allocations** spread an account's votes over basket tokens and carry over until changed.
- **At the flip,** staker votes that were not cast (including staked tokens not escrowed) follow the
  curators: they are split equally among the compliant curators and cast the way each one voted.
  What is still silent (a curator who did not vote, or no compliant curator) counts as a vote to
  keep the current weights. Stakers who vote always keep their own share. Curators earn no bribes
  on these votes. Proposals do not work this way: there, votes not cast count for nobody. Then:
  1. a token with under 2% of the vote is targeted at 0;
  2. no token is targeted above 25% (or 1 / the number of tokens, if higher); the excess goes to the
     others pro rata;
  3. every weight moves the same fraction of the way to its target so that none moves more than
     5 points;
  4. a token at weight 0 that is delisted, or has been under 2% for 4 weeks in a row, leaves the
     basket once its balance is dust.
- With low staker turnout the curators steer most of the basket, within the guardrails above.
  Stakers check them by voting their own stake and by replacing curators through proposals.

## Proposals

- **Who can propose:** any curator, or anyone with at least $5k (admin-set) of staked tokens
  escrowed, valued at NAV. One open proposal per proposer.
- **Kinds:** list a token (it must have an oracle feed and be on the admin's eligibility list; it
  joins at weight 0), delist a token (target forced to 0, removed once dust), and add, remove or
  replace a curator (within the cap).
- **Voting** runs 3 days with the same 30:70 split, measured against all staked tokens in the
  week the proposal opens. Curators do not vote on curator changes; stakers decide those alone. Only stake
  escrowed before the proposal opened can vote.
- **Passing:** yes beats no, and yes is at least 20% of all possible votes. Own can veto during the
  next day, then anyone executes within 7 days. Execution re-checks that the change is still valid.

## Bribes

- **Weight-vote bribes:** anyone can post a bribe on a basket token for the current or a future
  week, in an admin-listed token (USDG, MONEY) or the bribed token itself. Own takes 5% when it is
  posted. After the flip, the locked stake that voted for the token that week claims in proportion
  to its votes. Curator base slices never earn bribes; a curator earns only on their own locked
  stake. If no locked stake voted for it, or that week was never tallied, the briber takes it back.
- **Listing bribes:** anyone can post a bribe on an open listing proposal, on the same terms. Locked
  yes stake shares it if the listing executes; otherwise (defeated, vetoed, cancelled, expired, or
  executed with no locked yes stake) the briber takes it back.

## Trust and limits

- **Admin (factory owner):** upgrades all modules; sets fees, the whitelist, routers, the LP fee,
  the curator cap, the bribe cut and tokens, the eligibility list, governance rules and each fund's
  curator fee, minimum curator stake, lock options, yield curve and premium ceiling; adds and
  removes curators;
  vetoes proposals; can delist a token directly; can withdraw the pool position back into the fund;
  can sweep tokens the fund holds that are not backing (stray tokens, a dropped asset's dust), but
  never a basket asset, USDG or the fund token.
- **Manager (Own keeper):** trusted only within the rebalance bounds above. Between the launch
  close and pool seeding it is trusted more: no daily volume cap, only the 2% per-swap bound, so
  it should finish the launch rebalance and seed promptly. Its launch jobs are `finalize()` as
  soon as the window ends or the target raise is reached, then the rebalance, `seedPool()` and
  `distribute()` in batches.
- **Oracle feeds:** basket prices come from admin-set feeds; the fund's market price and the
  position value come from its own pool TWAP. Redeem depends on neither.
- **USDG:** treated as $1.
- **Hook address:** the hook must be deployed (CREATE2-mined) at an address whose low bits encode
  `beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta`.
  The Uniswap v4 PoolManager on Robinhood Chain is `0x8366a39cc670b4001a1121b8f6a443a643e40951`
  and the PositionManager (LP position NFTs, set in the `FundStaking` implementation) is
  `0x58daec3116aae6d93017baaea7749052e8a04fa7`.

## Deployment

`script/funds/DeployFundsRobinhood.s.sol` deploys the oracle, the six module implementations, the
factory, the hook (mining its CREATE2 salt with `script/funds/HookMiner.sol`) and the redeem zap,
wires the hook and platform metadata, allows USDG (and MONEY, if given) as bribe tokens, and hands
ownership to `FUNDS_ADMIN` (two-step). After a fund launches,
`script/funds/AddFundTwapFeedRobinhood.s.sol` deploys its TWAP feed and registers it in the oracle.

## Tests

- `test/unit/Fund*.t.sol` run against a real v4 PoolManager, deployed from precompiled bytecode in
  `test/helpers/v4/PoolManagerBytecode.sol` (v4-core pins solc 0.8.26; this repo pins 0.8.28).
- `test/invariant/FundInvariant.t.sol` checks that mints and redeems never lower NAV per token
  (beyond the position valuation's rounding) and that locked mints stay fully held.
- `test/unit/FundStakingLp.t.sol` uses `test/helpers/MockPositionManager.sol`;
  `test/fork/FundLpStakingRobinhoodFork.t.sol` (needs `ROBINHOOD_RPC`) mints, stakes, trades
  against, collects fees from and unstakes a position through the live PositionManager.
