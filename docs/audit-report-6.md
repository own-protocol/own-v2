# Own Protocol v2 — Audit Report & Remediation Status (Pass 6)

**Branch:** `money-market-funds` · **First audited:** `3a96ffe` (2026-10-06) · **Re-audited:** `9fe95f7` (2026-10-13) · **Last updated:** 2026-10-13

Two rounds of the multi-agent solidity-auditor (v4, 12-agent pipeline: 9 specialty attackers + 3
gap-hunters), each run in **loop mode with 2 passes**: pass 2 was handed what pass 1 found and
told to spend its effort on new ground while still re-reporting anything it hit again.

- **Round 1 (2026-10-06, `3a96ffe`)** produced the original A6 report: 2 High, 9 Medium, 4 Low.
- **Round 2 (2026-10-13, `9fe95f7`)** ran after the yield redesign (`9d49d7c`, `cb3f43a`), the
  premium cap / mint at NAV / pool top-up (`199a94f`), the Dutch auctions and price hub, and the
  size/gas pass (`9fe95f7`). Before it ran, every open round-1 item was re-checked against the
  new code (see "Changes in this update"). Its results were then cross-checked against this
  report: findings that repeat an open item are noted under that item, and only fresh ones were
  added, with new IDs continuing the A6 numbering.

Every item is **Open** until it is reviewed and a fix is chosen. Nothing in this update changes
contract code.

Each finding was traced against the source by the orchestrator before booking. The severity
column is the orchestrator's grading; the skill's confidence score is shown per finding. The
round-2 assembled skill report (16 scored findings, 35 leads, exact wording) is at
`audits/solidity-auditor-run-2026-10-13.md` in the project files.

### Scope (round 2)

```
src/funds/Fund.sol            src/funds/FundAuctions.sol     src/funds/FundBribes.sol
src/funds/FundCurators.sol    src/funds/FundFactory.sol      src/funds/FundGovernor.sol
src/funds/FundHook.sol        src/funds/FundLaunch.sol       src/funds/FundMintZap.sol
src/funds/FundOracle.sol      src/funds/FundPriceFeed.sol    src/funds/FundPriceHub.sol
src/funds/FundRedeemZap.sol   src/funds/FundStaking.sol      src/funds/FundTwapFeed.sol
src/funds/libraries/EpochHistory.sol       src/funds/libraries/FullRangeLiquidity.sol
src/funds/libraries/FundRebalance.sol      src/funds/libraries/GaugeMath.sol
src/funds/libraries/LpPositions.sol        src/funds/libraries/PoolIssuance.sol
src/funds/libraries/ProposalBook.sol
script/funds/DeployFundsRobinhood.s.sol    script/funds/AddFundTwapFeedRobinhood.s.sol
script/funds/HookMiner.sol
```

25 files, 7,110 lines. Interfaces, tests and mocks were read for context only.

### Coverage

| Round | Pass 1 | Pass 2 |
| ----- | ------ | ------ |
| 1 (2026-10-06) | 12/12 returned: 5 on Opus, 7 on Fable after Opus `[reasoning_extraction]` blocks | 12/12 on Opus |
| 2 (2026-10-13) | 12/12 on Opus 5.5 | 12/12 on Opus 5.5 |

**48/48 agent runs returned across both rounds.** In round 2 no agent was blocked, so Fable 5.1,
Sonnet 5.5 and Opus 4.8 were never needed. Both rounds used the bundle with the skill's
"print reasoning markers" rule reworded to "apply the method, keep the working private, return
only FINDING and LEAD blocks", which is what stopped the round-1 blocks.

### Changes in this update (2026-10-13)

**Removed: fixed before this round.** Their write-ups are dropped; the fixes are in git.

| ID | Finding | Fixed in |
| -- | ------- | -------- |
| A6-H-01 | `finalize` reverted after `endTime` | `e4a69df` |
| A6-H-02 | Launch-epoch proposals counted only escrowed power | `e4a69df` |
| A6-M-05 | A flip in the launch epoch used up every curator's grace week | `e4a69df` |
| A6-L-02 | A reward token whose balance fell below `_reserved` blocked flip | `5db4443` (the "no unregister path" part lives on in A6-M-03) |

**Removed leads** (code changed, so they no longer apply):

- Dust deposit of a cheap asset divides by zero in `FundLaunch.claimable`: fixed in `894d35c`.
- Pending mint locks for whatever option sits at its index: `setLockOptions` and lock options
  were removed in the yield redesign.
- Manager routes each daily rebalance through its own pool, and a router call that triggers
  `collectLpFees` hides USDG sold: after seeding only the admin can make router swaps
  (`Fund.rebalance`), and before seeding there is no pool. The pre-seed manager window is
  A6-L-04.

**Re-checked and still open at `9fe95f7`:** A6-M-01, M-02, M-03, M-04, M-06, M-07, M-08, M-09,
L-01, L-03, L-04. Locations below are updated to the current code. Changes worth knowing:
A6-M-06 is smaller now that the yield curve is stepped (12% / 24% / 48% a year), and A6-L-03 is
partly closed because the pool-price mint uses the higher of spot and TWAP. Round 2 raised
M-01, M-02, M-03, M-04, M-06, M-08 and L-04 again on its own.

**Added from round 2:** A6-H-03, A6-M-10 to A6-M-14, A6-L-05 to A6-L-08, and the leads marked
*new* below.

---

## Status at a Glance

| Severity | Total | Fixed | Open | Acknowledged | By design |
| -------- | ----- | ----- | ---- | ------------ | --------- |
| Critical | 0 | 0 | 0 | 0 | 0 |
| High     | 3 | 2 | 1 | 0 | 0 |
| Medium   | 14 | 1 | 13 | 0 | 0 |
| Low      | 8 | 1 | 7 | 0 | 0 |
| Info     | 0 | 0 | 0 | 0 | 0 |
| **Total** | **25** | **4** | **21** | **0** | **0** |

| ID | Severity | Finding | Conf | Status |
| -- | -------- | ------- | ---- | ------ |
| A6-H-01 | High | `finalize` reverts after `endTime`, so a launch without an early close always fails | 100 | Fixed (`e4a69df`) |
| A6-H-02 | High | Launch-epoch proposals count only escrowed power, so one holder passes any proposal | 90 | Fixed (`e4a69df`) |
| A6-H-03 | High | A curator claim credits the claimed staked shares a second time | 90 | Open |
| A6-M-01 | Medium | A 30-minute pool crash shrinks the redeem supply and over-pays the basket | 75 | Open |
| A6-M-02 | Medium | Right after seeding the position TWAP covers seconds; one block sets redeem supply | 75 | Open |
| A6-M-03 | Medium | Dust bribes fill the 32 reward-token slots; later bribes in new tokens revert | 90 | Open |
| A6-M-04 | Medium | Compliance uses live supply, so mint → flip → redeem fails an honest curator | 80 | Open |
| A6-M-05 | Medium | A flip in the launch epoch uses up every curator's grace week | 80 | Fixed (`e4a69df`) |
| A6-M-06 | Medium | One premium reading prices up to 8 h of staking yield; caller picks the moment | 80 | Open |
| A6-M-07 | Medium | One paused / blacklisting basket token blocks every redeem | 80 | Open |
| A6-M-08 | Medium | After `setGovernor`, bribers refund bribes that voters already claimed | 75 | Open |
| A6-M-09 | Medium | `stake` moves the caller's launch lock onto any receiver | 85 | Open |
| A6-M-10 | Medium | Anyone can mint to any receiver and put a lock and a boost on it | 85 | Open |
| A6-M-11 | Medium | A stake made while NAV has no price takes pot drip it did not earn | 80 | Open |
| A6-M-12 | Medium | One stale basket price blocks every redeem while the reserve holds value | 80 | Open |
| A6-M-13 | Medium | The price keeper moves a hub price without limit by repeating pushes | 75 | Open |
| A6-M-14 | Medium | Other staked shares shield a boost after its minted shares are sold | 75 | Open |
| A6-L-01 | Low | A bribe posted before a failed launch can never be refunded | 80 | Open |
| A6-L-02 | Low | A reward token whose balance drops below `_reserved` blocks flip and curator changes | 75 | Fixed (`5db4443`) |
| A6-L-03 | Low | A mint at NAV after a 30-minute dump is charged at the TWAP pool reading | 65 | Open |
| A6-L-04 | Low | Before seeding, every rebalance swap skips the daily volume cap (manager-only) | 75 | Open |
| A6-L-05 | Low | The auction rate rounds down, so some lots start at the floor price | 75 | Open |
| A6-L-06 | Low | The pool opens at the close price after the basket has moved | 75 | Open |
| A6-L-07 | Low | A tiny direct mint makes a boost that never ends | 75 | Open |
| A6-L-08 | Low | A replaced protocol curator keeps the protocol vote on open proposals | 70 | Open |

---

## A6-H-03 — A curator claim credits the claimed staked shares a second time (High, Open, new 2026-10-13)

`FundCurators.claim` (`src/funds/FundCurators.sol:176`) with `notifyYield` (`:133`). Round 2,
pass 2: 7 of 12 agents, independently.

`claim` lowers `_reserved[token]` and **then** transfers the shares:

```solidity
_reserved[token] -= amount;
IERC20(token).safeTransfer(msg.sender, amount);
```

For the staking token, `FundStaking.transfer` first runs `_settleBefore(sender)`. When the
curators module has a boost, that accrues: `_accrue` mints curator shares and calls the
unguarded `notifyYield` → `_distribute`, which computes `fresh = balance − _reserved`. The
balance still holds `amount`, but `_reserved` no longer does, so the claimed shares are shared
out a second time (to `_protocolOwed` and every compliant curator). Then the transfer sends them
out, leaving `_reserved` above the balance by `amount`. `_forfeit` avoids exactly this ordering
("the shares leave `_reserved` only once they are gone"); `claim` does not.

The module gets a boost from anyone: `Fund.mint(dust, 0, receiver = curators module,
atNav = false)` while the fund trades above NAV (A6-M-10). With a dust payment the boost speed
rounds to zero and it never ends (A6-L-07). Cost: about $1 or less.

Worked numbers (protocol share 33.33%, curators X and Y compliant, module holds 9,000 staked
shares all owed: X 3,000, Y 3,000, protocol 3,000):

1. Attacker gives the module a dust boost.
2. X claims 3,000 in a new block. Inside the transfer the accrual re-shares ~3,000: protocol
   +1,000, X and Y +1,000 each (vesting). After the claim the module holds ~6,000 but owes ~9,000.
3. Y claims 3,000 the same way. The module holds ~3,000 but owes ~9,000.
4. The protocol curator's claim of ~5,000 reverts (insufficient balance). `_fresh` returns 0
   until the gap is filled, so the next ~6,000 of real curator income is credited to no one.
   Early claimers take later claimers' shares, every claim in a fresh block widens the gap, and
   `_forfeit` (curator removal) reverts once a vest exceeds the balance.

**Suggested fix:** in `claim`, move `_reserved[token] -= amount;` after the `safeTransfer`, as
`_forfeit` does. The A6-M-10 fix (no mints to fund modules) also removes the cheap trigger.

## A6-M-01 — A 30-minute pool crash shrinks the redeem supply and over-pays the basket (Medium, Open)

`Fund.redeem` (`src/funds/Fund.sol:290`) → `_redeemQuote` → `_poolAndSupplyAt` (`:837`) →
`FundHook.positionAmounts` (`src/funds/FundHook.sol:434`) at the 30-minute TWAP tick. Round 1:
boundary (finding) plus three leads. Round 2: raised again as a lead (`twap-supply-vs-spot`).

`redeem` divides each basket balance by `supply = totalSupply − poolTokens`, where `poolTokens`
is the fund's position valued at the **TWAP** tick. Only the USDG leg is capped (`usdgCap` in
`redeemPosition`); the basket legs are not. A holder sells fund tokens into the pool, holds the
crashed price for 30 minutes, buys back, and redeems in the same transaction: the TWAP still sees
the crash, so `poolTokens` is far above the real holding and `supply` is too small.

Numbers (100M supply, $900k basket + $100k USDG, 10% pool, attacker holds 20M): TWAP pool tokens
29.09M vs ~9.09M real → `supply` 70.91M instead of 90.91M → the attacker's 19.8M net shares take
27.9% of the basket instead of 21.8%: **$260.0k vs $217.8k fair, +$42k for ~$1.4k of swap fees**,
repeatable every ~60 minutes, paid by remaining holders. The open question is cost: the
attacker must keep the pool crashed for 30 minutes against arbitrage, and an arb who buys the
cheap tokens and redeems also pushes the TWAP back. Not run as a PoC.

**Suggested fix:** for redeem (and mint), count the pool's fund tokens as the larger of the TWAP
and spot amounts, i.e. use the smaller resulting `supply` only in the direction that cannot
over-pay, or price the basket legs with the same cap logic the USDG leg already has.

## A6-M-02 — Right after seeding the position TWAP covers seconds, so one block sets the redeem supply (Medium, Open)

`FundHook._positionTick` (`src/funds/FundHook.sol:632`) and `_twap` (`:639`). Round 1:
math-precision, first-principles (PoC), invariant. Round 2: raised again as a lead
(`young-pool-twap`).

For the first 30 minutes after `seedPool`, `_twap` falls back to the oldest observation (the
seed), and `_positionTick` ignores `found`, so the "30-minute" mean can cover a few seconds. One
block held at a low tick moves it a long way, which feeds A6-M-01's `supply` directly without
the 30-minute hold. PoC (round-1 fixture): sell half of 67,708 tokens right after seeding, buy
back 1 s later, redeem: **$76.6k paid vs $74.4k baseline for ~$330 of swaps**, loss on other
holders. Precondition: unlocked fund tokens at seed time, i.e. `depositorLock == 0` or
`FundLaunch.seedPool` (manager or admin) runs after `depositorUnlockAt` (depositor tokens are
locked 7 days by default).

**Suggested fix:** until `POSITION_TWAP_WINDOW` of history exists, use the seed tick (or block
the pool slice of redeem/mint).

## A6-M-03 — Dust bribes fill the 32 reward-token slots; later bribes in new tokens revert (Medium, Open)

`FundCurators.registerRewardToken` (`src/funds/FundCurators.sol:141`), entered from
`FundBribes._pull` (`src/funds/FundBribes.sol:199-219`). Round 1: 12 agent runs. Round 2: raised
again by 11 of 24 agent runs, unchanged in code.

`_pull` accepts `reward == token` for any **eligible** asset, not only basket assets, and calls
`registerRewardToken(reward)` whenever `cut != 0`. At the default `bribeCutBps = 1500`, 7 wei
gives `cut = 1`, `net = 6`. Registration is permanent and capped at `MAX_REWARD_TOKENS = 32`. The
attacker posts `postBribe(X, epoch, X, 7)` for 32 eligible tokens before or after launch (no
`launched` check), and later reclaims the 6 wei per token with `refundBribe` because nobody can
vote for a non-basket token. Cost: gas plus 32 wei.

After that, every bribe whose reward token is not yet registered reverts `TooManyRewardTokens`,
including **MONEY** (an allowed bribe token in `DeployFundsRobinhood.s.sol:132` but not a core
token) and a token team's listing bribe paid in its own token. Every `_distributeAll` (flip,
curator changes, claims) also loops the junk tokens forever. Precondition: at least 32 allowed
tokens (eligible + basket + bribe tokens), likely with a tokenized-stock eligibility list.

**Suggested fix (pick one or combine):** (A) in `_pull`, allow `reward == token` only for basket
assets or the open listing target; (B) exempt `isBribeToken` tokens from the cap, or skip the
cut instead of reverting when full; (C) add an admin path to unregister a token with zero balance
and zero reserve.

## A6-M-04 — Compliance uses live supply, so mint → flip → redeem fails an honest curator (Medium, Open)

`FundCurators.checkCompliance` (`src/funds/FundCurators.sol:153`). Round 1: 3 agents. Round 2:
raised again as a lead (`compliance-supply-timing`).

```solidity
uint256 required = Math.mulDiv(f.totalSupply(), minStakeBps, BPS, Math.Rounding.Ceil);
bool ok = gov.stakedAssetsAt(c, epoch) >= required;
```

The stake side is a past-epoch record; the supply side is live. `FundGovernor.flip` is
permissionless. Mints now land staked and locked, but `FundStaking.redeem` redeems locked stake
at NAV, so `mint(atNav)` → `flip` → `FundStaking.redeem` still works in one transaction.
Example (100M supply, `minStakeBps = 50` → 500k required, curator C has 520k): minting ~4M
shares raises `required` to 520,000.005e18 and C fails. Two flips in a row (or one call that
runs two missed flips) set C non-compliant: C loses its income share, its base and silent vote
slice in `_castVotes`, and its proposal votes. Cost ≈ the 1% mint + 1% redeem fee (≈$8k per flip
at $0.10 NAV on that example), partly refunded if the attacker is itself a curator. The reverse
(redeem before flip so an under-staked curator passes) also works.

Only live when `minStakeBps > 0`. Project memory says the minimum is 0 at launch, but the deploy
script comment still documents 50 bps (`DeployFundsRobinhood.s.sol:45`).

**Suggested fix:** compare against a fund-supply checkpoint for the tallied epoch (an
`EpochHistory` of `Fund.totalSupply`, minimum-in-epoch like staking).

## A6-M-06 — One premium reading prices up to 8 h of staking yield; caller picks the moment (Medium, Open)

`FundStaking._accrue` (`src/funds/FundStaking.sol:497`). Round 1: 6 agent runs. Round 2: raised
again as a lead (`caller-timed-premium-reading`).

`accrue()` is permissionless (and runs inside every stake, unstake and boosted transfer). It
reads `premiumBps()` once and applies `rateForPremium(premium)` to `elapsed = min(now −
lastAccrual, 8 h)`. A staker waits until `lastAccrual` is ~8 h old and calls it while the
30-minute TWAP premium sits in a higher tier (or holds the pool price up for 30 minutes to put
it there).

Since the yield redesign the curve is stepped (default 12% a year at a premium of 0, 24% from
25%, 48% from 100%), so the swing is smaller than in round 1. Example: 50M staked; one call at a
100% premium instead of 0 adds 36% × 8/8,760 × 50M ≈ **16,400 fund tokens** that dilute every
non-staker. The reverse also works: a call while the premium is below the first tier or a feed
is stale consumes the 8 hours with zero yield (`lastAccrual` is written before the `ok` check;
the NatSpec now calls this intended).

**Suggested fix:** accrue against a time-weighted premium over the elapsed period, or cap
`elapsed` per reading to the TWAP window and have the keeper accrue every ~30 minutes; pay each
chunk at the lower of the rate at its start and its end.

## A6-M-07 — One paused / blacklisting basket token blocks every redeem (Medium, Open)

`Fund.redeem` (`src/funds/Fund.sol:290`). Round 1: economic-security, invariant.

The redeem loop calls `safeTransfer` for every basket asset with `amounts[i] != 0` and has no
way to skip one. If one tokenized stock pauses transfers or blacklists the fund, every `redeem`,
`FundStaking.redeem` and `FundRedeemZap.redeemToUsdg` reverts for every holder, and the NAV
floor disappears. The token cannot be removed: `flip` → `setBasket` reverts `AssetHasBalance`
unless it is dust (`FundRebalance.sol:226`), `sweep` refuses listed tokens (`Fund.sol:423`), and
neither a rebalance nor an auction can sell it because the transfer itself fails. The same
transfer in `FundLaunch.finalize` blocks finalisation. The docs say redeem "cannot be paused".
A6-M-12 is a second way to the same effect.

**Suggested fix:** let the caller name assets to skip (forfeiting that slice to remaining
holders), or credit a failed transfer to the receiver as a later claim.

## A6-M-08 — After `setGovernor`, bribers refund bribes that voters already claimed (Medium, Open)

`FundBribes.refundBribe` (`src/funds/FundBribes.sol:88`), `claimListingBribe` (`:125`) and the
other listing-bribe paths, all through `_governor()` (`:221`). Round 1: trust-gap, boundary.
Round 2: raised again by 2 agents as findings, with the listing variant worked through.

`FundBribes` reads `IFund(fund).governor()` live, but its ledgers are keyed only by epoch or
proposal id. `claimBribe` never lowers `_bribes` or `_bribesBy`. After the admin's documented
upgrade path `Fund.setGovernor(G2)`: epoch E's 1,000 USDG bribe was 60% claimed under G1. G2's
first flip tallies E with empty bribe votes, so `refundBribe` sees `bribeVotes == 0` and the
briber takes back the full net, part of it from other bribers' pools, while the remaining voters
can no longer claim. Listing variant (round 2): proposal ids restart on G2, so a yes voter on G2
proposal #0 claims the listing bribe posted for G1 proposal #0, and the G1 briber's refund
reverts. Admin-triggered, but the harm is taken by unprivileged bribers and voters.

**Suggested fix:** key bribe ledgers by the governor that was live when the bribe was posted,
and refuse claims and refunds against a different governor (or migrate them explicitly).

## A6-M-09 — `stake` moves the caller's launch lock onto any receiver (Medium, Open)

`FundStaking._stake` (`src/funds/FundStaking.sol:471-489`). Round 1: 8 agent runs.

`_stake` releases the caller's launch lock (`releaseLaunchLock(msg.sender, assets)`) and puts it
on `receiver` (`_addLock(receiver, locked)`). `unstake` refuses this
(`lockedAfter != lockedBefore && receiver != msg.sender`); `stake` has no matching check. A
holder of launch-locked tokens stakes for:

- **the curators module**: the donated shares count as fresh income and are shared out, but the
  module's last `locked` worth of staked-share claims revert `SharesLocked` until
  `depositorUnlockAt` (default 7 days, max 30);
- **an admin-listed ERC-4626 wrapper**: its last withdrawals revert until unlock;
- **the Uniswap v4 PoolManager** (sync → stake → settle inside `unlock`): credits the caller,
  so launch-locked value could be swapped out through any sFUND pool. Not proven; needs an sFUND
  pool with outside liquidity.

The cost is the gifted stake. This is the `stake` twin of 10-04 Medium #2. A6-M-10 is the same
shape through `Fund.mint`, with a longer lock, and its fix is separate.

**Suggested fix:** in `_stake`, revert `SharesLocked` when `moved != 0 && receiver != msg.sender`.

## A6-M-10 — Anyone can mint to any receiver and put a lock and a boost on it (Medium, Open, new 2026-10-13)

`Fund.mint` (`src/funds/Fund.sol:242`) → `_stakeMinted` → `FundStaking.stakeMinted`
(`src/funds/FundStaking.sol:173`) → `_joinMintLock`, with the effect in `FundCurators._forfeit`
(`src/funds/FundCurators.sol:328`). Round 2: 2 agents in pass 1, 6 in pass 2.

`mint` checks only `receiver != address(0)`. The staked shares, the mint lock (180 days for a mint
at NAV, `mintLock` for a direct mint) and, for a direct mint above NAV, a boost all land on
`receiver`. Effects:

- **Curator removal reverts.** A NAV mint to the curators module puts a 180-day lock on its
  shares. `_distribute` shares the gift out as income, so a curator's vest grows, and `_forfeit`
  → `FundStaking.unstake(vest)` reverts because `_held < shares + mintLocked`. Example: module
  holds 1,000 shares (X's vest); a 99-share gift makes X's vest 1,033, and
  `1,099 < 1,033 + 99` → `SharesLocked`. `removeCurator`, `replaceCurator` and the governance
  proposals that call them revert for as long as the gift share exceeds the module's other
  balance. A curator facing removal can do this for a fraction of its own income.
- **The last staked-share claims revert** until the lock ends.
- **A holder's own lock stretches.** A mint equal to a holder's NAV-locked balance with 1 day
  left gives all of it a share-weighted end ~90.5 days out.
- **The curators module gets a boost,** which is the trigger for A6-H-03.
- Same for an admin-listed vote wrapper (lead in round 2).

A6-M-09's fix (in `_stake`) does not cover this path.

**Suggested fix (pick one or combine):** (A) revert when `receiver` is a module of the fund
(curators, staking, launch, governor); (B) require `receiver == msg.sender` for a mint that
creates a lock or a boost, or keep a lock someone else creates separate from the receiver's.

## A6-M-11 — A stake made while NAV has no price takes pot drip it did not earn (Medium, Open, new 2026-10-13)

`FundStaking._releasePot` (`src/funds/FundStaking.sol:563`). Round 2: 1 agent in pass 1,
1 in pass 1 (boundary), 1 in pass 2.

`_checkpointPot` keeps moving the drip into `potPending`, but `_releasePot` returns early while
`nav == 0`, which happens whenever any basket feed is stale (`Valuation.nav` needs every price).
Staking still works during that time (`_stake` → `_accrue` skips without reverting), and a
direct stake has no lock. When the price returns, the whole `potPending` goes into the vault's
share price at once, shared by whoever is staked at that moment.

Numbers: Chainlink stock feeds go quiet from about Friday 20:00 to Monday 00:00 UTC. With a basket
feed staleness under that gap, NAV has no price all weekend. Pot $70,000 over 7 days → 52 h
moves ~$21,700 into `potPending`. 1M shares are staked; the attacker stakes 1M liquid tokens on
Sunday night, calls `accrue()` when the feed returns, and unstakes: **+~$10.8k for minutes of
staking**, taken from stakers who held all weekend.

**Suggested fix:** while NAV is unavailable, keep the drip time in `potLeft` (move
`_potUpdatedAt` forward without moving dollars into `potPending`), or refuse a new stake while
`potPending > 0`.

## A6-M-12 — One stale basket price blocks every redeem while the reserve holds value (Medium, Open, new 2026-10-13)

`Fund._claim` (`src/funds/Fund.sol:706`), reached from `redeem`, `FundStaking.redeem` and
`FundRedeemZap`. Round 2: 2 agents as findings, 4 as leads.

While `reserveUsd > 0`, `_claim` calls `_totalValue` → `_basketValue(..., soft = false)` →
`o.price(a)` for every held basket asset, and that reverts on a stale or missing feed. Any
direct mint above NAV (boost budget) or any pool issuance (pot) makes `reserveUsd > 0`, and
boosts take months to pay out, so in practice the reserve is never empty. Then one stale feed
stops every in-kind redeem, though the pro-rata exit itself needs no price. Triggers: the weekend
gap of stock feeds (if staleness is set below it), or a `FundPriceHub` asset whose real move is
over `maxMoveBps` so the keeper's push is rejected and `updatedAt` ages.

This was a build choice in the yield redesign (reserve held in dollars), and
`docs/own-curated-funds.md:147` says so, but `:151` ("It needs no oracle and cannot be paused")
and `:312` ("Redeem depends on neither") say the opposite. A6-M-07 reaches the same effect through
a frozen token.

**Suggested fix (pick one):** (A) value the basket with `tryPrice` in `_claim` and count an
unpriced asset at zero, which only shrinks the redeemer's claim (holders are protected, and
`minAmountsOut` protects the redeemer); (B) hold the reserve in kind (fund tokens or a basket
slice) so redeem needs no price. Either way, fix the docs.

## A6-M-13 — The price keeper moves a hub price without limit by repeating pushes (Medium, Open, new 2026-10-13)

`FundPriceHub.pushPrices` (`src/funds/FundPriceHub.sol:48`). Round 2: 8 agents in pass 1, 5 in
pass 2.

The keeper is meant to be bounded ("bounded per push by `maxMoveBps`",
`docs/own-curated-funds.md:308`). The bound compares each new price with `p.price`, the last
stored price, and nothing reads `p.updatedAt`. So the keeper repeats an asset in one call
(`[X, X, X, …]`) or sends several calls in one block, and each step passes. With the deploy
value `HUB_MAX_MOVE_BPS = 3000`: nine +30% steps take X to 10.6x in one transaction; seven −30%
steps take it to 0.08x. The price is stored as fresh.

Impact with a compromised or buggy keeper key: in the same transaction anyone can call the
permissionless `FundLaunch.finalize`, which fixes close prices from the oracle. Example: honest
deposits $900k of A, attacker deposits $100k of hub asset X; X pushed 10.6x → the attacker gets
~54% of the depositor supply instead of ~10% and redeems ~$540k of basket. The same price feeds
auction rates and floors, the rebalance slippage bound, and the reserve scaling in mint/redeem.
Keeper-only, so not an open attack; listed because the bound is the documented control on the
keeper.

**Suggested fix:** reject a keeper push for an asset whose `updatedAt == block.timestamp`, or
scale the allowed move by the time since `updatedAt` (e.g. `maxMoveBps` per hour).

## A6-M-14 — Other staked shares shield a boost after its minted shares are sold (Medium, Open, new 2026-10-13)

`FundStaking._forfeit` (`src/funds/FundStaking.sol:635`). Round 2 pass 2: numerical-gap.

The design says selling or moving staked tokens forfeits the unpaid boost. `_forfeit` checks
`held >= b.shares`, where `held` is **all** the account's staked shares (plus governor escrow),
not the shares the boost was paid for. So shares the account held before the mint, or bought
since, shield the boost.

Numbers (NAV $1, market $1.25, defaults): a $1M direct mint stakes 792,000 shares with a
$150,000 budget paid over ~73 days. After the 15-day mint lock ~$119k is unpaid. The minter also
holds 792,000 other staked shares, unstakes the 792,000 boosted ones and sells them at ~$1.25:
`held = 792,000 >= 792,000`, nothing is forfeited, and the remaining ~$119k keeps paying out from
the reserve. Without the other shares it would go to backing. Also, `if (b.usdLeft == 0)
b.shares = 0` lets shares from a finished boost shield the next one.

**Suggested fix:** record the account's staked holdings before each boosted mint and forfeit when
holdings fall below that baseline plus `b.shares`.

## A6-L-01 — A bribe posted before a failed launch can never be refunded (Low, Open)

`FundBribes.postBribe` (`src/funds/FundBribes.sol:55`) / `refundBribe` (`:88`). Round 1:
execution-trace.

`postBribe` does not check `launched`. If the launch fails, `flip` reverts `NotLaunched` forever,
so no epoch is ever tallied and `nextEpochToTally` stays 0: `refundBribe` is `NotRefundable`
(`epoch < 0`) and `claimBribe` is `EpochNotTallied`. The net bribe stays in `FundBribes` with no
exit; the cut has already gone to the curators module.

**Suggested fix:** revert `postBribe` (and `postListingBribe`) until `launched`, or refund when
the launch status is Failed.

## A6-L-03 — A mint at NAV after a 30-minute dump is charged at the TWAP pool reading (Low, Open)

`Fund._mintQuote` (`src/funds/Fund.sol:605`) and `_mintAmounts` (`:644`). Round 1:
economic-security (finding at 65), invariant (lead).

The mint mirror of A6-M-01. Since round 1 the pool-price mint uses the higher of spot and TWAP
(`_poolMintPrice`, `:631`), so a dump can no longer lower the direct mint price. What is left:
the in-kind amounts and the NAV for a mint at NAV still use `_poolAndSupplyAt`, which values
the pool at the TWAP tick. Dump, wait 30 minutes, buy back, mint at NAV in the same block → the
TWAP-valued pool USDG (which scales with √price) and supply are off in the minter's favour when
`poolUsdgBps` is high. Round-1 model on $1M TVL: break-even at defaults (`poolUsdgBps` 1000, fee
100 bps); profitable at `poolUsdgBps` 3000–5000 or fee 10 bps. A NAV mint is locked 180 days but
can be redeemed at once through `FundStaking.redeem`.

**Suggested fix:** the A6-M-01 fix shape (charge the larger of the spot and TWAP pool USDG).

## A6-L-04 — Before seeding, every rebalance swap skips the daily volume cap (Low, Open)

`FundRebalance.rebalance` (`src/funds/libraries/FundRebalance.sol:64,100`), via `Fund.rebalance`
(`src/funds/Fund.sol:330`). Round 1: trust-gap (PoC), invariant. Round 2: raised again by 4
agent runs.

`launching = !hook.isSeeded(fund)` exempts **all** swaps from `_trackVolume`, not only the
intended USDG buys, and the manager may router-swap only in that window. Round-1 PoC: 40 round
trips at 98.5% of oracle value in one block took `totalValue` from 80,000 to 35,256 (−56%).
Round 2 framed it as theft: a manager contract finalizes and loops A → USDG → A swaps through a
pool it owns; 20 legs at 2% keep 0.98^20 = 66.8% of the basket. Selling the USDG reserved for
the pool also makes `FundLaunch.seedPool` revert `InsufficientPoolUsdg`, and `seedPool` is
manager-or-admin only with no deadline, so the manager decides when the window ends.

**Suggested fix:** track volume while launching too (keep only the buy-USDG allowance), or cap
the total sold before seeding at a one-time launch allowance.

## A6-L-05 — The auction rate rounds down, so some lots start at the floor price (Low, Open, new 2026-10-13)

`FundAuctions.openLot` (`src/funds/FundAuctions.sol:84-91`). Round 2: 2 leads in pass 1, a
finding in pass 2.

`rate = mulDiv(pSell · 10^dBuy, 1e18, pBuy · 10^dSell)` is an integer number of buy units per
1e18 sell units. For a low-priced sell asset against a high-priced buy asset it keeps only a few
digits. Example: sell an 18-decimal $0.0123 token for 8-decimal $100k WBTC: true rate 12.3 →
12; start = floor(12 × 1.02) = 12; floor = ceil(12 × 0.97) = 12. The auction never descends: a
filler takes the lot at once 2.4% under oracle value, and the `_checkValue` 3% bound passes. A
true rate of 10.99 → 10 is 9% low, so every fill reverts and the lot never fills. Bounded by the
3% floor check and the daily auction cap.

**Suggested fix:** keep the rate at 1e36 scale, or compute the payment at fill time from both
prices and decimals in one `mulDiv`.

## A6-L-06 — The pool opens at the close price after the basket has moved (Low, Open, new 2026-10-13)

`FundLaunch.seedPool` (`src/funds/FundLaunch.sol:210-226`). Round 2 pass 2: two agents (leads,
promoted).

`finalize` fixes `poolUsdg` and `poolShares` so the pool opens at NAV (times `launchPremiumBps`)
at the close. `seedPool` rescales them for supply changes only, never for value changes, and
seeding waits for the manager's rebalance. If the basket rises before seeding, the pool opens
below NAV and a buyer takes cheap pool tokens and redeems them at NAV, paid by holders through
the fund's own position. Example: $10M raise, 10% pool, basket +20% before seeding → ~$7.4k
gross from one trade; ~$50k at +50%. A6-M-02 makes the first redeem worse in the same block.

**Suggested fix:** in `seedPool`, re-price the seed from the current NAV (keep the USDG, size the
fund-token side at the current NAV), or refuse to seed when the close-time price is off current
NAV by more than a tolerance.

## A6-L-07 — A tiny direct mint makes a boost that never ends (Low, Open, new 2026-10-13)

`FundStaking.stakeMinted` (`src/funds/FundStaking.sol:192`). Round 2: lead in pass 1, finding
plus lead in pass 2.

`usdPerSec += mulDiv(paymentUsd, boostSpeedBpsPerYear, BPS * YEAR)` rounds to 0 when
`paymentUsd` is below ~4.2e7 wei-USD (at 7,500 bps), while `budgetUsd` is still above 0 at any
premium. The boost then never pays and never ends: the budget stays in `reserveUsd` forever
(keeping A6-M-12 live), and the receiver stays "boosted", so every transfer of its shares
accrues first. That is the cheapest trigger for A6-H-03. Amounts are dust on their own.

**Suggested fix:** in `stakeMinted`, revert (or skip the boost) when `budgetUsd != 0` and the
added speed is 0.

## A6-L-08 — A replaced protocol curator keeps the protocol vote on open proposals (Low, Open, new 2026-10-13)

`ProposalBook._curatorVotes` (`src/funds/libraries/ProposalBook.sol:316`). Round 2 pass 2:
access-control.

The protocol branch checks only `msg.sender == cs[0]`, the protocol curator recorded when the
proposal opened; other curators are checked live. After `FundFactory.setProtocolCurator(P2)`
(for example because P's key leaked), P can still cast the protocol slice (0.3 × 33.33% ≈ 10% of
the vote, half of the 20% quorum) on every open List or Delist proposal, and P2 casts nothing
(it reverts `NoVotingPower` without escrow). Admin-triggered; the old key acts in the window.

**Suggested fix:** give the protocol slice only when `msg.sender` is the live
`protocolCurator()`.

---

## Leads (not scored — trails for manual review)

Carried from round 1 and still present at `9fe95f7` unless marked *new*.

- **Unstake + restake in one epoch lowers the recorded supply** — `FundStaking._recordSupply`.
  The recorded supply is the epoch minimum, so restaking 60M of 100M lifts escrowed voters from
  7% to 17.5% of the gauge tally and of new proposal denominators. Gain not measured.
- ***New:* a burn of old shares keeps its weight in the epoch supply** —
  `FundStaking._recordSupply`. After a mint of X in the epoch, burning Y ≤ X old shares leaves the
  record unchanged, so voting stakers get a smaller share of the tally. No attacker profit shown.
- **One curator's slice is 20.001%, enough for the 20% quorum alone** —
  `ProposalBook._curatorVotes`. With defaults (30% slice, protocol share 33.33%) a single
  non-protocol curator can list or delist without staker support; only a staker "no" above 20% or
  the veto stops it. Intent not confirmed.
- **One wei of bribe-locked votes takes the whole bribe and blocks its refund** —
  `FundBribes.claimBribe` / `refundBribe` / `claimListingBribe`. Refund needs zero bribe votes;
  `_share` has no minimum. Raised again in round 2.
- **After a governor swap, old escrow stops counting** — `FundStaking._update` / `_held` read the
  live governor's `escrowOf`: a launch-locked staker could free its lock, and (round 2) a boosted
  holder who moves one share loses the whole boost.
- ***New:* after a governor swap, every curator shows zero stake** —
  `FundCurators.checkCompliance` reads the new governor, whose first flip re-tallies the last
  epoch, so all curators can lose compliance and the protocol curator takes all income.
- **After a governor swap, voters cannot claim epochs the old governor tallied** —
  `FundBribes.claimBribe`. Same root as A6-M-08.
- **Uncollected LP fees are left out of NAV and counted in supply** — `Fund._poolAndSupplyAt` /
  `FundHook.positionAmounts`. Mint at NAV → `collectLpFees` → `FundStaking.redeem` in one block.
  At a 0.3% LP fee the gap was ~0.3% of NAV after 10 idle days, below the 2% fees.
- **Propose measures next-epoch power against current-epoch supply** — `ProposalBook.propose`:
  stake + escrow + propose in one epoch votes against a denominator without that stake, so
  quorum is reached with less. Raised again in round 2.
- **Stale basket feed through the grace period turns a successful raise into a refund** —
  `FundLaunch.markFailed`; `finalize` uses the hard `price()` for every launch asset.
- **Anyone picks the moment that fixes every launch close price** — `FundLaunch.finalize`, now
  callable at any time from `endTime` to `finalizeDeadline` (since the A6-H-01 fix), and early
  once the target is met. A depositor closes at its asset's peak, or a caller forces Failed near
  `minRaiseUsd`. Raised by 3 agents in round 2.
- **Launch pays recorded amounts** — `FundLaunch.refund` / `finalize`; a balance-lowering stock
  token blocks finalize and the last refunds.
- **Delisted token keeps its weight when every other token is under the minimum vote** —
  `GaugeMath.targets`; the `total == 0` fallback ignores `delisted`.
- **Remainder rounding can hold a target-zero token at 1 bps** — `GaugeMath.move`; with all
  remainders 0 the leftover goes to index 0. Delays `_drop`.
- **`previewRedeem` overstates USDG when spot < TWAP** — integrators that copy it into
  `minUsdgOut` get reverts. No loss. Raised again in round 2.
- **Lowering spot before someone's redeem moves value to other holders** —
  `FundHook.redeemPosition` (removal at spot, pay at `min(spot, TWAP cap)`). Profit not shown.
- **An extreme tick held across one second moves the 30-minute TWAP by ~5%** —
  `FundHook._observe`; feeds `premiumBps` (A6-M-06) and `_poolAndSupplyAt` (A6-M-01).
- **`zapMint` accepts USDG / basket tokens as routers** — `FundMintZap.zapMint` only rejects
  `router == fund`, unlike the redeem zap and rebalance; if the admin ever allows such a router,
  anyone spends other users' allowances to the zap.
- **`claimable` omits an unlocked vest of a non-compliant curator** — `FundCurators.claimable`
  view shows less than `claim` pays. Raised again in round 2.
- **Admin setters that apply retroactively** — `setProtocolCuratorShare` splits income that
  arrived before it (round 2 also: `setProtocolCurator` hands unclaimed `_protocolOwed` to the
  new address); `FundFactory.setMaxYieldRate` prices up to 8 h of yield earned before it;
  `FundGovernor.setWrapper` removal leaves deposited wrapper power in votes, bribes and
  compliance. Admin-only.
- ***New:* the mint pause does not stop pool issuance** — `Fund.hookIssue` /
  `FundHook.beforeSwap` never read `mintPaused`, so pool buys keep minting fund tokens and adding
  to the pot during a pause, at whatever NAV the oracle shows. Intent not confirmed.
- ***New:* each issuance buy restarts the pot drip for the whole pot** — `FundStaking.addPot`.
  Documented ("each top-up re-spreads what is left"), but dust buys can keep delaying the pot.
- ***New:* the TWAP feed always reports the current block as `updatedAt`** —
  `FundTwapFeed.latestRoundData`; `consult` accepts a checkpoint of any age, so the oracle's
  staleness bound never rejects an old pool price after days without swaps. No gain shown.
- ***New:* a new NAV mint joins an expiring lock and unlocks in days** —
  `FundStaking._joinMintLock`. 10M NAV-locked shares with 1 h left plus a 1M NAV mint unlock
  together in ~16 days, not 180. Profit after fees not computed.
- ***New:* the speed of a finished boost pays later boost budgets** — `FundStaking.stakeMinted`
  keeps one `usdPerSec` per account, so a large earlier mint pays a later budget ~10x faster.
  The reserve already holds the budget, so no holder loss was found.
- ***New:* the holder picks the NAV at which a boost turns into tokens** —
  `FundStaking._settleBoost` is permissionless and converts at the NAV of the call. Gain not sized.
- ***New:* a buy above NAV and a sell back fund the pot from holders** — `PoolIssuance.issue`:
  75% of the issued premium goes to the reserve, while the fund's position buys the tokens back
  near spot. Net gain after fees not simulated.
- ***New:* a stale price moves part of the reserve to a minter or redeemer** —
  `Fund._mintQuote` / `_claim` scale the slice by `(T − R) / T` at oracle prices. Below the 2%
  round-trip fees in the numbers tried; grows with the reserve share.
- ***New:* redeem burns shares and pays zero when the reserve exceeds the value** —
  `Fund.redeem`: `_claim` returns 0 when `total <= reserveUsd`; a caller with no minimums loses
  the shares.
- ***New:* redeem sends basket tokens before it reduces the pool position** — `Fund.redeem`; a
  token transfer callback would read NAV with the full `poolUsdg` against a smaller supply. No
  basket token with a callback found.
- ***New:* mint at NAV works between finalize and `seedPool`** — `Fund.mint`; `IFundLaunch` says
  nobody can mint until the pool is seeded. No loss found.
- ***New:* lots open in any direction and the manager fills at the floor** —
  `FundAuctions.openLot` does not check lots against target weights; ~0.3% of the basket a day
  could leave within the daily cap. Manager trust model not confirmed.
- ***New:* exact-output swaps pay the fund fee on the net USDG amount** — `FundHook.beforeSwap` /
  `afterSwap`: the effective rate is f/(1+f), so at the 1% default a trader saves ~1% of the fee.
- ***New:* several missed epochs tally in one block** — `FundGovernor.flip`; each call moves
  weights by the weekly shift, so after four missed weeks they move 2,000 bps at once.
- ***New:* every flip reverts if a kept basket asset loses its feed** — `FundRebalance.setBasket`
  needs `hasFeed` for every asset, not only new ones. Admin-triggered.

## Attacked and held (round 1, re-confirmed where round 2 touched the same code)

- Fund mint/redeem rounding: ceil on deposit, floor on payout; minted fund tokens never exceed
  `navShares`; `RedeemTooLarge` holds.
- In-block TWAP manipulation: the accumulator adds the current tick for 0 seconds in the same
  block; the `usdgCap` plus burning pool tokens at spot leaves no same-block profit.
- Seeding after pre-seed redeems: the USDG reduction telescopes exactly.
- `GaugeMath`: weights never sum above 10,000, so `BPS − sum` cannot underflow; each token gets
  at most one remainder point.
- Vote, bribe and listing-bribe aggregates: `_bribeVotes` equals the sum of
  `floor(power × bps / BPS)`; claims never exceed the bribe.
- `FundCurators`: epoch-boundary vesting and the reentrant `_forfeit` → unstake → `notifyYield`
  ordering (but not the same callback inside `claim`, A6-H-03).
- `FundStaking`: virtual-share offsets, curator-cut pricing in `_accrue`, curator and LP yield
  accounting.
- `EpochHistory` set/valueAt ordering; `requestWithdrawal` keeps `next ≥ active`.
- `FullRangeLiquidity` seed amounts never exceed what is provided; `FundHook` fee signs, signed
  tick rounding and `PositionInfo` offsets.
- `FundTwapFeed` / `FundOracle` decimal scaling and overflow bounds; `HookMiner` flag mask.
- Round 2, periphery: `LpPositions`, `PoolIssuance`, `FundPriceFeed`, the zaps and the deploy
  scripts showed no provable defect beyond the items above.
