# Own Curated Funds

Basket-backed fund tokens that Own launches with a small set of curators. Each fund is an ERC-20
backed by a basket of Robinhood Chain tokens and stock tokens plus its own USDG pool position,
trades in its own Uniswap v4 pool against USDG, and pays stakers new tokens while it trades above
NAV. Curators and stakers set the basket weights in a weekly vote, and anyone can bribe that vote.

Design source: the "Own Curated Funds: launch, curators, weight votes and bribes" spec.

Updated 2026-10-07: Dutch-auction rebalancing with admin router swaps as the fallback, and the keeper-pushed price hub.

Updated 2026-10-12: the premium yield redesign (spec `plans/fund-premium-rebate-base-yield.md`): pool issuance, the locked direct mint with the Premium Boost, the Premium Pot, the boost reserve and step tiers. Lock options and the premium ceiling are gone. Updated 2026-10-14: the boost and the pot are held as fund tokens, not a dollar reserve (A6-M-12).

Updated 2026-10-15: fund pools open on Hookr (plan `plans/fund-pools-on-hookr.md`). Our own hook is upgradeable, which Uniswap's routing does not allow, so each fund's pool opens on Hookr's shared `HookrRoot` hook, which the Uniswap app and other routers already route. A per-fund `FundVenue` replaces `FundHook` and `FundTwapFeed`: the swap fee is Hookr's Directional Tax paid to the curators, issuance is a keeper call, the fund's price is its price-hub feed, and `migrate` moves the fund to a new pool (later, our own hook).

## Contracts (`src/funds/`)

| Contract | Role |
| --- | --- |
| `FundFactory` | UUPS. Platform admin hub: launcher whitelist (Own only by default), the protocol curator and its share (33.33% default, 50% cap), rebalance routers and limits, launch and governance defaults, premium defaults for new funds (mint lock and adjustment, boost share and speed, pot drip and share, issuance start and steps, yield tiers), staking yield cap (109,500 bps a year, i.e. 3% a day), curator cap (10), bribe cut (15%, 25% cap), bribe tokens, the listing eligibility list and the platform metadata. Owns the seven module beacons, so one call upgrades every fund. |
| `Fund` | Beacon proxy per fund. The fund token plus custody of the basket and idle USDG: the locked direct mint, redeem, the fund fee, rebalance, the depositor lock. NAV counts the pool position. |
| `FundLaunch` | Beacon proxy per fund. Deposit window (any basket token or USDG), early close at the target raise, early-deposit yield, overweight haircut, the fixed-supply split and pool seeding after the launch rebalance. |
| `FundStaking` | Beacon proxy per fund. Staked fund token (e.g. sOCF1) with step-tier yield set by the premium, the Premium Boost and mint lock of direct minters, the Premium Pot, the curators' yield minted on top, and staking of full-range Uniswap v4 LP position NFTs in the fund's pool. |
| `FundGovernor` | Beacon proxy per fund. Staked escrow, the weekly weight vote (gauge) and proposals to list or delist tokens and add, remove or replace curators. |
| `FundCurators` | Beacon proxy per fund. The curator set (with the protocol curator), the minimum curator stake and compliance, and the curators' income: the fund fee, the curator yield (30-day unlocks, forfeits on removal), split between the protocol curator and the others. It also says how a bribe cut is split (`bribeSplit`). |
| `FundBribes` | Beacon proxy per fund. Bribes on the weekly vote per token per week, and bribes on listing proposals. The curators' cut is paid out when the bribe is posted. |
| `FundVenue` | Beacon proxy per fund. Where the fund trades: opens its fund token / USDG pool through Hookr's launcher on `HookrRoot` with the fund's pool settings, holds the fund's position there (Hookr family member 0, owned by the venue), pays the swap tax out to the curators, issues into the pool (math in the linked `PoolIssuance` library) and migrates the fund to a new pool. |
| `FundOracle` | One price source per asset: a ticker on the protocol's `ChainlinkOracleVerifier` (the registry's INHOUSE_ORACLE: Chainlink while live, the in-house signer within a band of the last Chainlink answer while it is silent, so stocks stay priced over weekends), or a Chainlink-style feed (`FundPriceHub` feeds for tokens without Chainlink). A fund token's own market price is read through the same surface. |
| `FundPriceHub` | One for the platform. Keeper-pushed USD prices for basket assets with no Chainlink feed (Pons tokens, VIRTUAL): the keeper samples each token's Uniswap v4 pool, converts its pair (ETH, SPY, NVDA...) to USD with Chainlink and pushes a 30-minute TWAP. Only the keeper pushes. A price may move at most `maxMoveBps` (admin-set, 30% at deploy) per hour since that asset's last push, compounding; a bigger push is stored at the bound, so a real jump catches up over a few hours (a 10x in about 9 at 30%) and repeated pushes gain nothing. `createFeed(asset)` deploys a `FundPriceFeed` the oracle reads like any Chainlink aggregator. |
| `FundAuctions` | One for the platform. Dutch auctions for rebalancing after the pool is seeded (below). |
| `FundRedeemZap` | Redeem a fund token and swap the basket to USDG through allowed routers in one transaction. |
| `FundMintZap` | Pay one token, swap it through allowed routers into the slice a mint needs, mint, and refund what is left, in one transaction. Holds nothing between transactions. |

## Launch

1. **Create.** `createFund` is open to admins and whitelisted launchers (the whitelist
   is on and empty by default, so only Own launches). Own sets the name, symbol and fund info (logo,
   description, website, X, Telegram and Discord links; all of it, with the platform metadata,
   reads back in one call, `getFundInfo()`), the basket and starting weights, the manager (the Own keeper), the curators (up to
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
   Until the pool is seeded the rebalance may buy USDG, and buying USDG up to P is free of the
   daily volume cap; every other swap counts toward it (the 2% per-swap loss bound always
   applies). The manager (or admin) then calls `seedPool()`, which adds P of the fund's USDG and
   fund tokens sized at the NAV then (times the launch premium) as the fund's position, so the pool
   opens at its premium over NAV even if the basket moved since the close. It needs a NAV price.
   Redemptions before seeding shrink P in proportion. Before seeding nobody can trade
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

- **Pool settings** are set per fund at creation (`CreateFundParams.pool`) and can change until
  the pool opens (`venue.setPoolSettings`): buy and sell tax (Hookr's Directional Tax, each at most
  10%, paid in USDG), Hookr's share of the tax (20% to 50%), the LP fee (at most 10%, to LPs only)
  and the tick spacing (default 60). They are frozen for the life of the pool. Example: 1.05% tax
  with Hookr at 23.81% and a 0.2% LP fee leaves about 0.8% to Own on every trade.
- The venue holds one full-range position for the fund. It counts toward NAV:
  NAV = (basket + idle USDG + the position's USDG) / (supply − the position's fund tokens), with the
  position valued at the fund token's oracle price: its `FundPriceHub` feed, the keeper's signed
  30-minute pool TWAP (`FundOracle.lastPrice`, at any age; the pool's opening price until the
  first push). Mints and redeems read the position at both that price and spot and take whichever
  costs the caller (the higher amounts for a mint, the lower for a redeem), so neither a move inside
  one block nor a move held and then reversed before the next push changes what they get.
- Depositors therefore get exactly what they brought at NAV, and premium buys from the pool raise
  NAV for every holder.
- **Redeem** pays a pro-rata slice of the basket, of the fund's idle USDG and of the position: the
  position's USDG out (capped at its value at the oracle price, so a pumped spot price cannot be drained; anything
  above the cap goes to the fund) and the matching fund tokens burned.
- LP fees the position earns go to the fund (USDG) or are burned (fund tokens) on
  `venue.collectLpFees()`. Outside LPs can add their own positions; only the fund's own position
  counts, and they share the LP fee, never the tax.
- **Tax:** Hookr books the tax in two queues per pool (buy and sell), frozen to pay the fund's
  `FundCurators`. `venue.collectTax()` (anyone; the keeper) pays both out; Hookr's share goes to
  Hookr.
- The position stays locked. The admin can resize it later, though by default it is set once at
  launch: `fund.increasePosition(usdgAmount)` moves idle USDG into it with matching fund tokens
  minted at the spot price (only while spot is within about 1% of the oracle price, so NAV does not
  move), and `venue.withdrawPosition(liquidity)` takes part or all of it out, the proceeds always
  going back into the fund.
- **Migration:** `venue.migrate(settings)` (admin) takes the whole position out and opens a new
  Hookr pool at the old pool's price with new settings (the tick spacing must differ, so the pool
  is new), only while spot is within about 1% of the oracle price. Staked LP positions in the old
  pool keep what they earned and stop earning (`FundStaking.poolMoved` bumps `lpEpoch`); LPs
  unstake and move themselves. There is no overlap window: announce the move ahead. A pool on our
  own hook later comes in as a venue upgrade.

## Live

- **Locked direct mint (in kind):** `mint(navShares, minSharesOut, receiver, false)`. The minter brings
  `navShares / supply` (supply outside the pool position) of every basket asset's balance and of
  the fund's USDG (idle, the pool position's and issuance USDG not yet collected), each rounded up,
  and receives
  `navShares × NAV / mintPrice` fund tokens, less the fund fee, where
  `mintPrice = max(max(spot, oracle price) × (1 + mintAdjustmentBps), NAV)`. The tokens are staked for the
  receiver and locked for `mintLock` (default 15 days, 0 allowed): they cannot be transferred or
  unstaked until then, but can be redeemed at NAV through `FundStaking.redeem`. One lock per
  account; a second mint locks the total until the share-weighted end. A locked or boosted mint
  goes only to the caller (`NotReceiver` otherwise; the factory's `mintZap` is the one exception,
  minting for its own caller), so nobody can put a lock or a boost on someone else. The adjustment is signed (default 0,
  -50% to +100%) and the price is never below NAV. No oracle values the deposit, minters cannot
  pick what the fund buys, and a mint never dilutes holders. `previewMint(navShares, atNav)`
  returns `(shares, mintPrice, amounts, usdgAmount, locked)`. Minting needs the pool's price, so it
  opens once the pool is seeded.
- **Premium cap:** `maxPremiumBps` per fund (0, the default, is no cap). When the pool price would
  put a direct mint above `NAV × (1 + maxPremiumBps)`, it is priced at the cap instead and the
  tokens go to the receiver unlocked, with no boost (the whole premium is backing), so anyone can
  mint at the cap and sell into the pool and arbitrage holds the price near it.
- **Mint at NAV:** `mint(navShares, minSharesOut, receiver, true)` prices the same slice at NAV
  (fee still charged). The tokens are staked for the receiver and locked for good, in a lock of
  their own that direct mints never join. The lock is on the staked shares, so the tier yield and
  pot they earn stay locked too. They vote and earn bribes like any escrowed stake, and the only way
  out is a redeem at NAV: they can never be transferred, unstaked or sold in the pool. No boost. For
  holders who want basket exposure without the premium game.
- **Mint settings:** the admin sets the mint lock, adjustment and premium cap per
  fund with `setMintConfig` (new funds take the factory's defaults); `setMintPaused` (operator or
  admin) closes both mint doors.
- **Premium Boost (direct mints only):** of a mint's premium over NAV in fund tokens (the
  `navShares` paid for less the tokens issued), `boostShareBps` (default 75%) is minted at once as
  the minter's boost tokens, held by the staking module, and the rest is backing. The boost is paid
  at `boostSpeedBpsPerYear` (default 75% a year) of `navShares`, as staked shares: a 2x mint is paid
  out in about 6 months, 10x in about 11, only while the tokens stay staked. Boost tokens count in
  supply and share the fund's price moves like any other token, so a boost is worth more if the
  fund rises and less if it falls. Payouts settle lazily (on every stake change, transfer, redeem
  or `settleBoost`) and need no price. Shares leaving the account (transfer, unstake, redeem) scale
  the boost down to what is still held, and the unpaid boost tokens are burned (NAV rises). A
  second mint settles the first and merges into it; a finished or forfeited boost never comes back.
- **Pool issuance:** `venue.issue()` (anyone; the keeper calls it after buys) mints new fund tokens
  and sells them into the pool while it trades above `NAV × (1 + issuanceStartBps)` (default
  1.01x). It sells until the pool and supply are where issuing the density along the rise would
  have left them: the tokens issued since the anchor (the price after the last full issue, or
  lower if the price was seen lower since) equal the density per price doubling over the rise, 1%
  of supply below 2x NAV, 2% from 2x, 3% from 5x (up to 8 admin-set steps, `venue.setIssuance`).
  An hourly cap (`hourlyCapBps`, default 5% of supply, draining over the hour) bounds each run;
  what it cuts short stays due. The sale pays the LP fee and Hookr's sell tax like any sell. The
  USDG goes straight to the fund. Of the premium over NAV on issued tokens, `potShareBps` (default
  75%) is minted as fund tokens at NAV for the Premium Pot and the rest is backing. Between a buy
  and the next `issue`, anyone can sell at the higher price first.
- **Premium Pot:** pot tokens are held by the staking module and drip linearly into the vault
  over `potDripPeriod` (default 7 days; each top-up re-spreads what is left over a new period),
  raising the share price. The drip needs no price, so it never piles up while feeds are stale.
  Variable, never promised. With less than one whole share staked the drip is burned into backing.
- **Mint zap:** `FundMintZap.zapMint` takes one token, runs the caller's swaps through
  admin-allowed routers into the slice, mints (direct or at NAV) for the caller, and
  refunds whatever is left. The admin registers it with `factory.setMintZap`. The minter pays the swap slippage, not the fund's holders.
- **Redeem** at any time, as above. It needs no oracle and cannot be paused. If one basket token
  can't be transferred (paused, or blacklisting the fund), `redeemSkipping` names it to leave out:
  that slice is forfeited and stays in the fund for the remaining holders.
- **Fee.** One fund fee (default 1%, admin-set per fund with `setFee`, at most 10%) on mints and
  redeems (in fund tokens), and the pool tax on trades (in USDG, set per pool, above). All of it
  goes to `FundCurators`; there is no separate protocol fee.
- **Staking (tier yield):** stakers earn a yearly rate (APR) set by the oracle price's premium to
  NAV, paid by minting new fund tokens (capped by the factory's `maxYieldRateBpsPerYear`, 109,500
  bps a year, i.e. 3% a day, by default; at most 3,650,000). The tiers are up to 8 (premium,
  `rateBpsPerYear`) levels, stepped: each level's rate holds until the next level, no yield below
  the first level (so never below NAV). Defaults: 12% APR from NAV, 24% from 1.25x NAV, 48% from
  2x NAV; the base may be 0 with the upper levels still paying. Each accrual pays the time since
  the last one at the lower of the rate read now and the rate read then, so no single reading
  prices a stretch on its own; while the premium can't be read the time waits and is paid once a
  price is back. The keeper accrues hourly.
- **Curator yield:** on top of the stakers' yield, `FundStaking` mints the curators 15%
  (`curatorYieldBps`, admin-set per fund with `setCuratorYield`, at most 50%) of what stakers earn,
  so stakers keep the full curve rate. An optional yearly cap, in bps of the staked balance, limits
  it (0, the default, is uncapped). It is paid to `FundCurators` as staking shares, so it stays
  staked.
- **LP staking:** LPs stake their Uniswap v4 position NFT in `FundStaking` (`stakePosition`, or
  send it with the PositionManager's `safeTransferFrom`). Only full-range positions in the fund's
  pool qualify, so every staked position holds the same fund tokens per unit of liquidity and one
  yield-per-liquidity counter pays them all fairly. A staked position earns the staking rate on the
  fund tokens it holds, valued at the fund token's oracle price; its USDG side earns nothing. The yield
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

## Public curation

- `governor.setPublicCuration(bool)` (admin) switches a fund between admin curation and the public
  vote. New funds start with it off, until a fund is big enough for active curation to be worth it.
- **Off:** nobody votes on weights or raises, votes on or executes proposals, curators and stakers
  alike. The admin sets the whole basket at once with `governor.curate(assets, weightsBps)`: add
  tokens (on the eligibility list, with an oracle feed), drop tokens (once their balance is dust)
  and set any weights, with none of the vote's cap, minimum or weekly move. The weekly flip still
  runs but only checks curator compliance; the weights stay where the admin put them. No bribes can
  be posted, and a week flipped while off pays none (its bribes go back to the briber).
- **Curators are unchanged:** the admin adds, removes and replaces them directly, and fees, curator
  yield, the protocol curator's share and compliance (minimum stake only) all work as usual. Only
  the bribe cut is zero while off, as there are no bribes.
- **On:** the vote and proposals below run as usual, starting from the current weights and moving
  at most the weekly limit. Allocations set before curation was turned off count again until changed.

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

- **Weight-vote bribes:** once the fund has launched, anyone can post a bribe on a basket token
  for the current or a future week, in an admin-listed bribe token (USDG, MONEY) or the bribed token itself when it is a basket
  asset or eligible for listing. The curators' cut (15% by default, at most 25%) is taken when it is
  posted and paid out in the same transaction: the protocol curator its third, the curators
  compliant at that moment the rest equally (a curator that cannot receive the token forfeits its
  part to the protocol curator). Nothing is tracked per bribe token. After the flip, the locked stake that voted for the token that week claims in proportion
  to its votes. Curator base slices never earn bribes; a curator earns only on their own locked
  stake. If no locked stake voted for it, or that week was never tallied, the briber takes it back.
- **Listing bribes:** anyone can post a bribe on an open listing proposal, on the same terms. Locked
  yes stake shares it if the listing executes; otherwise (defeated, vetoed, cancelled, expired, or
  executed with no locked yes stake) the briber takes it back.
- **Governor swaps:** every bribe stays with the governor live when it was posted; claims, refunds
  and the views name that governor, so a new governor neither reopens old bribes nor mixes up
  proposal ids. A bribe for a week the old governor never tallied can be taken back. Staked
  tokens still in the old governor keep counting as their owner's (for locks and boosts) until
  withdrawn; a second swap waits until the governor before the current one holds no stake.

## Trust and limits

- **Admin (ProtocolRegistry `ADMIN` role, the same admins as eUSD):** no fund contract stores
  its own admin; each checks the registry on every call, so granting or revoking `ADMIN` there
  (through the timelocked `PROTOCOL_ADMIN`) changes who administers every fund at once. Admins
  upgrade the factory and all modules (the venue included); set the price oracle and feeds, the protocol
  curator and its share, the whitelist, routers, each pool's settings before it opens, the curator cap, the bribe cut and
  tokens, the eligibility list, the yield cap, governance rules and each fund's fee, curator
  yield, minimum curator stake, yield tiers, mint lock and adjustment, boost and pot settings and
  pool issuance; set the premium defaults for new funds; add and remove
  curators (never the protocol curator); veto proposals; can delist a token directly; turn public
  curation off and on and, while it is off, set each fund's basket and weights directly; can
  withdraw the pool position back into the fund; migrate a fund to a new pool; set the sweep recipient
  (`factory.setSweepRecipient`; the registry treasury until set).
- **Operator (registry `OPERATOR` role, or an admin):** pauses and unpauses fund mints and launch
  deposits, and sweeps tokens the fund holds that are not backing (stray tokens, a dropped asset's
  dust, rewards a basket asset pays out such as stock tokens) to the sweep recipient, never a basket
  asset, USDG or the fund token. Redeeming cannot be paused.
- **Manager (Own keeper):** trusted only within the rebalance bounds above. After seeding it only
  opens and cancels auction lots; it can no longer swap. Between the launch
  close and pool seeding it may also buy the pool's USDG free of the daily volume cap, so it
  should finish the launch rebalance and seed promptly. Its launch jobs are `finalize()` as
  soon as the window ends or the target raise is reached, then the rebalance, `seedPool()` and
  `distribute()` in batches.
- **Price keeper:** pushes hub prices for assets without a Chainlink feed, bounded by `maxMoveBps`
  per hour since each asset's last push. The admin sets the bound and the keeper and cannot push
  prices.
- **Oracle feeds:** basket prices come from admin-set sources: `setVerifierFeed(asset, ticker,
  staleness)` for assets with Chainlink (read through the in-house verifier, so its weekend quotes
  count), or `setFeed(asset, feed, staleness)` for `FundPriceHub` feeds, whose decimals are read once
  when the feed is set (set it again if they ever change);
  the fund's market price and the position value come from its own hub feed (the keeper's signed
  pool TWAP). Mint deposits are taken in kind, so no oracle values
  them (the oracles only set NAV and the mint price). Redeem depends on neither.
- **USDG:** treated as $1.
- **Hookr:** pools live on Hookr's contracts (unaudited): launcher
  `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`, root `0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`,
  rules `0x4a71c270b1520F94064268102AebD744b0DE7942`, Directional Tax
  `0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F`, fixed in the venue implementation. A launch fee,
  if Hookr ever charges one, is paid as `msg.value` to `seedPool` and `migrate`.
  The Uniswap v4 PoolManager on Robinhood Chain is `0x8366a39cc670b4001a1121b8f6a443a643e40951`
  and the PositionManager (LP position NFTs, set in the `FundStaking` implementation) is
  `0x58daec3116aae6d93017baaea7749052e8a04fa7`.

## Deployment

`script/funds/DeployFundsRobinhood.s.sol` deploys the oracle, the seven module implementations (the
`Fund` and `FundVenue` implementations take USDG in their constructors and only initialize from a
factory with the same USDG; the venue's also takes the Hookr addresses), the factory (with
`PROTOCOL_CURATOR` as the protocol curator), the redeem and mint zaps, the auction house and the
price hub (with `PRICE_KEEPER` as its keeper), all administered by the ProtocolRegistry at
`PROTOCOL_REGISTRY_ROBINHOOD`. It wires the auction house and platform metadata and
allows USDG (and MONEY, if given) as bribe tokens when the deployer holds `ADMIN`; otherwise it
prints those calls for an admin's Safe. When a fund's pool opens, the admin creates its hub feed
(`hub.createFeed(fund)`) and registers it in the oracle (`oracle.setFeed`), and the keeper pushes
its pool TWAP with the other hub prices. Keeper jobs per fund: `venue.issue()` after buys,
`venue.collectTax()`, `venue.collectLpFees()`, the hub push and `staking.accrue()`.

## Tests

- `test/unit/Fund*.t.sol` run against a real v4 PoolManager, deployed from precompiled bytecode in
  `test/helpers/v4/PoolManagerBytecode.sol` (v4-core pins solc 0.8.26; this repo pins 0.8.28), with
  `test/helpers/MockHookr.sol` standing in for Hookr's launcher and tax (hookless pools; test
  swaps book the tax in its queues). `test/unit/FundVenue.t.sol` covers the pool settings, seeding,
  tax, valuation, redeems and migration.
- `test/fork/FundHookrRobinhoodFork.t.sol` (needs `ROBINHOOD_RPC`) launches a fund on Hookr's live
  contracts, trades it through Uniswap's Universal Router, pays the tax to the curators, issues,
  redeems and migrates.
- `test/invariant/FundInvariant.t.sol` checks that mints, pool buys, redeems, unstakes and boost
  settlements never lower NAV per token (beyond the position valuation's rounding) and that the
  staking module holds exactly the stakes plus the boost and pot tokens still owed.
- `test/unit/FundPremium.t.sol` covers pool issuance, the Premium Boost, the Premium Pot, the
  locked mint and the premium settings.
- `test/unit/FundStakingLp.t.sol` uses `test/helpers/MockPositionManager.sol`;
  `test/fork/FundLpStakingRobinhoodFork.t.sol` (needs `ROBINHOOD_RPC`) mints, stakes, trades
  against, collects fees from and unstakes a position through the live PositionManager.
