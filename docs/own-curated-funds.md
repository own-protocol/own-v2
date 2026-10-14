# Own Curated Funds

Basket-backed fund tokens that Own launches with a small set of curators. Each fund is an ERC-20
backed by a basket of Robinhood Chain tokens and stock tokens plus its own USDG pool position,
trades in its own Uniswap v4 pool against USDG, and pays stakers new tokens while it trades above
NAV. Curators and stakers set the basket weights in a weekly vote, and anyone can bribe that vote.

Design source: the "Own Curated Funds: launch, curators, weight votes and bribes" spec.

Updated 2026-10-07: Dutch-auction rebalancing with admin router swaps as the fallback, and the keeper-pushed price hub.

Updated 2026-10-12: the premium yield redesign (spec `plans/fund-premium-rebate-base-yield.md`): pool issuance, the locked direct mint with the Premium Boost, the Premium Pot, the boost reserve and step tiers. Lock options and the premium ceiling are gone.

## Contracts (`src/funds/`)

| Contract | Role |
| --- | --- |
| `FundFactory` | UUPS. Platform admin hub: launcher whitelist (Own only by default), the protocol curator and its share (33.33% default, 50% cap), rebalance routers and limits, launch and governance defaults, premium defaults for new funds (mint lock and adjustment, boost share and speed, pot drip and share, issuance start and steps, yield tiers), staking yield cap (109,500 bps a year, i.e. 3% a day), curator cap (10), bribe cut (15%, 25% cap), bribe tokens, the listing eligibility list and the platform metadata. Owns the six module beacons, so one call upgrades every fund. |
| `Fund` | Beacon proxy per fund. The fund token plus custody of the basket and idle USDG: the locked direct mint, redeem, the fund fee, the boost reserve, rebalance, the depositor lock. NAV counts the pool position and excludes the reserve. |
| `FundLaunch` | Beacon proxy per fund. Deposit window (any basket token or USDG), early close at the target raise, early-deposit yield, overweight haircut, the fixed-supply split and pool seeding after the launch rebalance. |
| `FundStaking` | Beacon proxy per fund. Staked fund token (e.g. sOCF1) with step-tier yield set by the premium, the Premium Boost and mint lock of direct minters, the Premium Pot, the curators' yield minted on top, and staking of full-range Uniswap v4 LP position NFTs in the fund's pool. |
| `FundGovernor` | Beacon proxy per fund. Staked escrow, the weekly weight vote (gauge) and proposals to list or delist tokens and add, remove or replace curators. |
| `FundCurators` | Beacon proxy per fund. The curator set (with the protocol curator), the minimum curator stake and compliance, and the curators' income: the fund fee, the curator yield (30-day unlocks, forfeits on removal), split between the protocol curator and the others. It also says how a bribe cut is split (`bribeSplit`). |
| `FundBribes` | Beacon proxy per fund. Bribes on the weekly vote per token per week, and bribes on listing proposals. The curators' cut is paid out when the bribe is posted. |
| `FundHook` | UUPS, upgraded by the registry ADMIN; the proxy sits at the mined hook address. One Uniswap v4 hook for every fund pool: the fund fee in USDG on swaps, pool issuance on buys above NAV (math in the linked `PoolIssuance` library), admin-set LP fee, the TWAP, and the fund's own pool position. |
| `FundOracle` | Per-asset Chainlink-style feeds. A fund token's own market price is read through the same surface. |
| `FundPriceHub` | One for the platform. Keeper-pushed USD prices for basket assets with no Chainlink feed (Pons tokens, VIRTUAL): the keeper samples each token's Uniswap v4 pool, converts its pair (ETH, SPY, NVDA...) to USD with Chainlink and pushes a 30-minute TWAP. A keeper push moving more than `maxMoveBps` (30% at deploy) is skipped; admin pushes are not bounded. `createFeed(asset)` deploys a `FundPriceFeed` the oracle reads like any Chainlink aggregator. |
| `FundAuctions` | One for the platform. Dutch auctions for rebalancing after the pool is seeded (below). |
| `FundTwapFeed` | Per fund. Serves the fund's pool TWAP (recorded by the hook) as an aggregator. |
| `FundRedeemZap` | Redeem a fund token and swap the basket to USDG through allowed routers in one transaction. |
| `FundMintZap` | Pay one token, swap it through allowed routers into the slice a mint needs, mint, and refund what is left, in one transaction. Holds nothing between transactions. |

## Launch

1. **Create.** `createFund` is open to admins and whitelisted launchers (the whitelist
   is on and empty by default, so only Own launches). Own sets the name, symbol, logo and
   description, the basket and starting weights, the manager (the Own keeper), the curators (up to
   the cap; the protocol curator is a curator of every fund on top) and the fund fee (default 1%,
   at most 10%), the minimum curator stake, the yield tiers (empty takes the factory's), the minimum raise, the target raise (optional), the pool's USDG share (default 10%, at
   most 50%), the launch supply (default 100M) and the launch window (default 7 days, 1 to 30
   allowed). The premium settings start at the factory's defaults. Only the admin can change the
   metadata, fund fee, curator yield, yield tiers and premium settings afterwards.
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
   - **Fixed supply S is split** so that the pool opens at the launch premium over NAV
     (`launchPremiumBps`, 0 by default: the pool opens at NAV). The pool gets P = 10% of V in USDG
     and M = P·S / ((1 + launch premium)·V + P) tokens (about 9% of S at NAV); depositors share
     C = S − M in proportion to their points (closing value + early yield, after the haircut).
   - Everything deposited moves to the fund, depositors can claim, and their tokens are locked for
     7 days. NAV is V / C. The pool is not open yet.
4. **Launch rebalance and pool seeding.** The manager rebalances the fund to its target weights and
   to at least P of idle USDG, selling basket tokens for USDG if the USDG deposits fall short.
   Until the pool is seeded the rebalance may buy USDG and the daily volume cap does not apply
   (the 2% per-swap loss bound still does). The manager (or admin) then calls `seedPool()`, which
   adds P of the fund's USDG and the M tokens as the fund's position, so the pool opens at NAV (at
   the default launch premium). Redemptions before seeding shrink P and M in proportion. Before seeding nobody can trade
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
  position valued at the pool's 30-minute TWAP (falling back to the history it has). Mints and
  redeems read the position at both the TWAP and spot and take whichever costs the caller (the
  higher amounts for a mint, the lower for a redeem), so neither a move inside one block nor a move
  held for the TWAP window and then reversed changes what they get.
- Depositors therefore get exactly what they brought at NAV, and premium buys from the pool raise
  NAV for every holder.
- **Redeem** pays a pro-rata slice of the basket, of the fund's idle USDG and of the position: the
  position's USDG out (capped at its TWAP value, so a pumped spot price cannot be drained; anything
  above the cap goes to the fund) and the matching fund tokens burned.
- LP fees the position earns go to the fund (USDG) or are burned (fund tokens). Outside LPs can add
  their own positions; only the fund's own position counts.
- The position stays locked. The admin can resize it later, though by default it is set once at
  launch: `fund.increasePosition(usdgAmount)` moves idle USDG into it with matching fund tokens
  minted at the spot price (only while spot is within about 1% of the TWAP, so NAV does not move),
  and `hook.withdrawPosition(fund, liquidity)` takes part or all of it out, the proceeds always
  going back into the fund.

## Live

- **Locked direct mint (in kind):** `mint(navShares, minSharesOut, receiver, false)`. The minter brings
  `navShares / supply` (supply outside the pool position) of every basket asset's balance and of
  the fund's USDG (idle, the pool position's and issuance USDG not yet collected), each rounded up
  and scaled by backing over total value while the reserve holds anything, and receives
  `navShares × NAV / mintPrice` fund tokens, less the fund fee, where
  `mintPrice = max(max(spot, TWAP) × (1 + mintAdjustmentBps), NAV)`. The tokens are staked for the
  receiver and locked for `mintLock` (default 15 days, 0 allowed): they cannot be transferred or
  unstaked until then, but can be redeemed at NAV through `FundStaking.redeem`. One lock per
  account; a second mint locks the total until the share-weighted end, so a mint to someone else
  cannot hold their earlier shares longer than it pays for. The adjustment is signed (default 0,
  -50% to +100%) and the price is never below NAV. No oracle values the deposit, minters cannot
  pick what the fund buys, and a mint never dilutes holders. `previewMint(navShares, atNav)`
  returns `(shares, mintPrice, amounts, usdgAmount, locked)`. Minting needs the pool's price, so it
  opens once the pool is seeded.
- **Premium cap:** `maxPremiumBps` per fund (0, the default, is no cap). When the pool price would
  put a direct mint above `NAV × (1 + maxPremiumBps)`, it is priced at the cap instead and the
  tokens go to the receiver unlocked, with no boost (the whole premium is backing), so anyone can
  mint at the cap and sell into the pool and arbitrage holds the price near it.
- **Mint at NAV:** `mint(navShares, minSharesOut, receiver, true)` prices the same slice at NAV
  (fee still charged). The tokens are staked for the receiver and locked for `navMintLock` (default
  6 months, up to 2 years) in a lock of their own that direct mints never join; meanwhile they earn
  tier yield and the pot and can be redeemed at NAV, but not transferred or unstaked. No boost. For
  holders who want basket exposure without the premium game.
- **Mint settings:** the admin sets the mint lock, adjustment, NAV mint lock and premium cap per
  fund with `setMintConfig` (new funds take the factory's defaults); `setMintPaused` (operator or
  admin) closes both mint doors.
- **Premium Boost (direct mints only):** of a mint's payment above NAV, `boostShareBps` (default
  75%) goes into the fund's reserve as the minter's budget and the rest is backing. The budget is
  paid back in dollars at `boostSpeedBpsPerYear` (default 75% a year) of the mint payment, as staked
  fund tokens at NAV: a 2x mint is repaid in about 6 months, 10x in about 11, only while the tokens
  stay staked. Payouts settle lazily (on every stake change, transfer, redeem or `settleBoost`),
  and each moves the same dollars from the reserve into backing, so NAV does not move. Shares
  leaving the account (transfer, unstake, redeem) scale the boost down to what is still held, and
  the unpaid part goes to backing (NAV rises). A second mint settles the first and merges into it;
  a finished or forfeited boost never comes back.
- **Pool issuance:** on a pool buy starting above `NAV × (1 + issuanceStartBps)` (default 1.01x),
  the hook fills part of the buy with newly issued fund tokens at the pool's own average price, so
  the price moves as if supply grew by the density per price doubling: 1% of supply below 2x NAV,
  2% from 2x, 3% from 5x (up to 8 admin-set steps, `setIssuance`). Exact-in and exact-out buys both
  issue; sells never do. Of the premium over NAV on issued tokens, `potShareBps` (default 75%)
  goes to the Premium Pot and the rest is backing. The USDG for issued tokens is held as pool
  manager claims and counted in the position until the next `collectLpFees` or redeem.
- **Premium Pot:** pot dollars sit in the reserve and drip linearly to all stakers over
  `potDripPeriod` (default 7 days; each top-up re-spreads what is left over a new period) through
  the vault's share price, minting the dripped dollars' worth of fund tokens at NAV, so NAV does not
  move. Variable, never promised. With less than one whole share staked the drip goes to backing.
- **Reserve:** boost budgets and the pot, held in dollars. It is excluded from NAV and from
  redeems, so redeemers never take it and outstanding boosts stay funded however many holders
  leave. While it holds anything, redeems need basket prices to scale their claim.
- **Mint zap:** `FundMintZap.zapMint` takes one token, runs the caller's swaps through
  admin-allowed routers into the slice, mints (direct or at NAV) for the receiver, and
  refunds whatever is left. The minter pays the swap slippage, not the fund's holders.
- **Redeem** at any time, as above. It needs no oracle and cannot be paused.
- **Fee.** One fund fee (default 1%, admin-set per fund with `setFee`, at most 10%) on pool trades
  (in USDG through the hook), mints and redeems (in fund tokens). All of it goes to `FundCurators`;
  there is no separate protocol fee.
- **Staking (tier yield):** stakers earn a yearly rate (APR) set by the market TWAP's premium to
  NAV, paid by minting new fund tokens (capped by the factory's `maxYieldRateBpsPerYear`, 109,500
  bps a year, i.e. 3% a day, by default; at most 3,650,000). The tiers are up to 8 (premium,
  `rateBpsPerYear`) levels, stepped: each level's rate holds until the next level, no yield below
  the first level (so never below NAV). Defaults: 12% APR from NAV, 24% from 1.25x NAV, 48% from
  2x NAV; the base may be 0 with the upper levels still paying. Yield accrues every 8 hours at
  most.
- **Curator yield:** on top of the stakers' yield, `FundStaking` mints the curators 15%
  (`curatorYieldBps`, admin-set per fund with `setCuratorYield`, at most 50%) of what stakers earn,
  so stakers keep the full curve rate. An optional yearly cap, in bps of the staked balance, limits
  it (0, the default, is uncapped). It is paid to `FundCurators` as staking shares, so it stays
  staked.
- **LP staking:** LPs stake their Uniswap v4 position NFT in `FundStaking` (`stakePosition`, or
  send it with the PositionManager's `safeTransferFrom`). Only full-range positions in the fund's
  pool qualify, so every staked position holds the same fund tokens per unit of liquidity and one
  yield-per-liquidity counter pays them all fairly. A staked position earns the staking rate on the
  fund tokens it holds, valued at the pool's 30-minute TWAP; its USDG side earns nothing. The yield
  is minted with the stakers' yield, held in `FundStaking` and claimed in fund tokens
  (`claimPositionYield`, or on `unstakePosition`). The position's swap fees stay the LP's: they can
  collect them while staked (`collectPositionFees`) or after unstaking. Staked positions do not
  vote and earn no bribes, and no curator yield is minted on top of their yield. The admin can
  return a position NFT that reached `FundStaking` without
  being staked (`recoverPosition`).
- **Rebalancing (Dutch auctions):** once the pool is seeded the manager (Own keeper) rebalances by
  opening auction lots in `FundAuctions`: sell an amount of one basket asset (or idle USDG) for
  another basket asset. The price starts 2% above the oracle rate and falls linearly over 4 hours
  to a floor 3% below it (admin-set with `setConfig`: start premium up to 50%, floor discount up to
  10%, 15 minutes to 7 days); anyone buys any part of a lot at the current price, paying the fund
  first. The fund names its price, so nobody can front-run a market order and fillers bring
  liquidity from any venue. Every fill is re-checked against the live oracle with the same floor
  discount and counts toward a 10%-of-the-basket daily cap (a running
  total that drains at the full cap per day), tracked separately from router swaps. The manager or
  the admin can cancel a lot.
- **Router swaps (admin fallback):** after seeding only the admin can swap between basket assets,
  and from idle USDG into them, through admin-allowed routers: at most 2% loss of oracle value per
  swap and at most 10% of the basket a day. Before seeding the manager uses the same swaps for the
  launch rebalance (above). Assets worth up to 0.1% of the basket count as dust.

## Curators

- **Protocol curator.** One address on the factory (`setProtocolCurator`, admin-updatable) is a
  curator of every fund: always compliant, no minimum stake, outside the curator cap, and it cannot
  be added, removed or replaced. Its share is 33.33% (`setProtocolCuratorShare`, at most 50%): a
  third of the curators' 30% vote slice (10% of the vote), a third of the silent staker votes, and a
  third of all curator income. Its income is claimable at once.
- Up to 10 other curators per fund (admin-set cap). Own can add them directly up to the cap;
  proposals can add, remove or replace them. No minimum: with no other curators, the protocol
  curator still holds its 10% of the vote.
- **Income.** `FundCurators` receives the fund fee (fund tokens and USDG) and the curator yield
  (staking shares). The protocol curator takes its third and the compliant curators split the rest
  equally, claiming with `claim(token)`. While no other curator is compliant, the protocol curator
  takes all of it. The bribe cut is split the same way but paid out at once (see Bribes).
- **Curator yield vesting.** Staking shares unlock in fixed 30-day periods aligned to Unix time:
  what a curator earns in a period is claimable once it ends (`lockedYieldOf` shows what is still
  locked). A curator removed mid-period forfeits that period's locked shares: they are unstaked and
  the fund tokens burned, raising NAV. Earlier periods stay claimable.
- **Minimum stake:** each curator other than the protocol curator must keep a dollar amount of
  fund tokens staked in the governor (`minStakeUsd`, admin-set per fund, 0 for none), valued at NAV.
  It is checked at every weekly flip against the curator's recorded stake for the week, with one
  week of grace; a curator out of compliance loses their vote slice (it counts as silent) and their
  income share. A flip with no NAV price (a stale feed) changes nobody's standing. Mints and redeems
  happen at NAV, so they cannot move anyone across the line.

## Weekly weight vote (gauge)

- Epochs run a week and flip Thursday 00:00 UTC. Anyone (the keeper in practice) calls
  `governor.flip()`; skipped weeks are tallied one call at a time, oldest first. Governance starts
  the week after launch: launch stake only counts from then, so the first flip tallies that week
  and proposals open in it.
- **Who votes.** Curators together hold 30% of the vote as base slices: the protocol curator a third
  of it (10% of the vote), every other compliant curator an equal part of the rest. Stakers hold
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
  curators and are cast the way each one voted: the protocol curator takes a third, the other
  compliant curators split the rest equally. What is still silent (a curator who did not vote, a
  non-compliant curator's slice, or the others' part when none of them is compliant) counts as a
  vote to keep the current weights. Stakers who vote always keep their own share. Curators earn no bribes
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

- **Who can propose:** any curator (the protocol curator included), or anyone with at least $5k (admin-set) of staked tokens
  escrowed, valued at NAV. One open proposal per proposer.
- **Kinds:** list a token (it must have an oracle feed and be on the admin's eligibility list; it
  joins at weight 0), delist a token (target forced to 0, removed once dust), and add, remove or
  replace a curator (within the cap; never the protocol curator).
- **Voting** runs 3 days with the same 30:70 split, measured against all staked tokens in the
  week the proposal opens. The protocol curator votes with its third of the curator slice; the
  other curators in the proposal's snapshot that are still compliant split the rest equally.
  Curators do not vote on curator changes; stakers decide those alone. Only stake escrowed before
  the proposal opened can vote.
- **Passing:** yes beats no, and yes is at least the quorum: 20% of all possible votes
  (`quorumBps`) for listings and delistings, and `curatorQuorumBps` (default 20%) of all staked
  tokens for curator changes. Own can veto during the next day, then anyone executes within 7 days.
  Execution re-checks that the change is still valid.

## Bribes

- **Weight-vote bribes:** anyone can post a bribe on a basket token for the current or a future
  week, in an admin-listed bribe token (USDG, MONEY) or the bribed token itself when it is a basket
  asset or eligible for listing. The curators' cut (15% by default, at most 25%) is taken when it is
  posted and paid out in the same transaction: the protocol curator its third, the curators
  compliant at that moment the rest equally (a curator that cannot receive the token forfeits its
  part to the protocol curator). Nothing is tracked per bribe token. After the flip, the locked stake that voted for the token that week claims in proportion
  to its votes. Curator base slices never earn bribes; a curator earns only on their own locked
  stake. If no locked stake voted for it, or that week was never tallied, the briber takes it back.
- **Listing bribes:** anyone can post a bribe on an open listing proposal, on the same terms. Locked
  yes stake shares it if the listing executes; otherwise (defeated, vetoed, cancelled, expired, or
  executed with no locked yes stake) the briber takes it back.

## Trust and limits

- **Admin (ProtocolRegistry `ADMIN` role, the same admins as eUSD):** no fund contract stores
  its own admin; each checks the registry on every call, so granting or revoking `ADMIN` there
  (through the timelocked `PROTOCOL_ADMIN`) changes who administers every fund at once. Admins
  upgrade the factory, the hook and all modules; set the price oracle and feeds, the protocol
  curator and its share, the whitelist, routers, the LP fee, the curator cap, the bribe cut and
  tokens, the eligibility list, the yield cap, governance rules and each fund's fee, curator
  yield, minimum curator stake, yield tiers, mint lock and adjustment, boost and pot settings and
  pool issuance; set the premium defaults for new funds; add and remove
  curators (never the protocol curator); veto proposals; can delist a token directly; can
  withdraw the pool position back into the fund; set the sweep recipient
  (`factory.setSweepRecipient`; the registry treasury until set).
- **Operator (registry `OPERATOR` role, or an admin):** pauses and unpauses fund mints and launch
  deposits, and sweeps tokens the fund holds that are not backing (stray tokens, a dropped asset's
  dust, rewards a basket asset pays out such as stock tokens) to the sweep recipient, never a basket
  asset, USDG or the fund token. Redeeming cannot be paused.
- **Manager (Own keeper):** trusted only within the rebalance bounds above. After seeding it only
  opens and cancels auction lots; it can no longer swap. Between the launch
  close and pool seeding it is trusted more: no daily volume cap, only the 2% per-swap bound, so
  it should finish the launch rebalance and seed promptly. Its launch jobs are `finalize()` as
  soon as the window ends or the target raise is reached, then the rebalance, `seedPool()` and
  `distribute()` in batches.
- **Price keeper:** pushes hub prices for assets without a Chainlink feed, bounded per push by
  `maxMoveBps`; the admin can push any price to recover from a large real move.
- **Oracle feeds:** basket prices come from admin-set feeds (Chainlink, or `FundPriceHub` feeds),
  whose decimals are read once when the feed is set (set it again if they ever change);
  the fund's market price and the position value come from its own pool TWAP. Mint deposits are taken in kind, so no oracle values
  them (the oracles only set NAV and the mint price). Redeem depends on neither.
- **USDG:** treated as $1.
- **Hook address:** the hook must be deployed (CREATE2-mined) at an address whose low bits encode
  `beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta`.
  The Uniswap v4 PoolManager on Robinhood Chain is `0x8366a39cc670b4001a1121b8f6a443a643e40951`
  and the PositionManager (LP position NFTs, set in the `FundStaking` implementation) is
  `0x58daec3116aae6d93017baaea7749052e8a04fa7`.

## Deployment

`script/funds/DeployFundsRobinhood.s.sol` deploys the oracle, the six module implementations (the
`Fund` implementation takes USDG in its constructor and only initializes from a factory with the
same USDG), the factory (with `PROTOCOL_CURATOR` as the protocol curator), the hook (mining its CREATE2 salt with
`script/funds/HookMiner.sol`), the redeem and mint zaps, the auction house and the price hub (with
`PRICE_KEEPER` as its keeper), all administered by the ProtocolRegistry at
`PROTOCOL_REGISTRY_ROBINHOOD`. It wires the hook, the auction house and platform metadata and
allows USDG (and MONEY, if given) as bribe tokens when the deployer holds `ADMIN`; otherwise it
prints those calls for an admin's Safe. After a fund launches,
`script/funds/AddFundTwapFeedRobinhood.s.sol` deploys its TWAP feed and registers it in the oracle.

## Tests

- `test/unit/Fund*.t.sol` run against a real v4 PoolManager, deployed from precompiled bytecode in
  `test/helpers/v4/PoolManagerBytecode.sol` (v4-core pins solc 0.8.26; this repo pins 0.8.28).
- `test/invariant/FundInvariant.t.sol` checks that mints, pool buys, redeems, unstakes and boost
  settlements never lower NAV per token (beyond the position valuation's rounding) and that the
  reserve always equals the boost budgets and pot still owed.
- `test/unit/FundPremium.t.sol` covers pool issuance, the Premium Boost, the Premium Pot, the
  locked mint and the premium settings.
- `test/unit/FundStakingLp.t.sol` uses `test/helpers/MockPositionManager.sol`;
  `test/fork/FundLpStakingRobinhoodFork.t.sol` (needs `ROBINHOOD_RPC`) mints, stakes, trades
  against, collects fees from and unstakes a position through the live PositionManager.
