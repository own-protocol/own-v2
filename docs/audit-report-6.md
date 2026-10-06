# Own Protocol v2 — Audit Report & Remediation Status (Pass 6)

**Branch:** `money-market-funds` · **Commit:** `3a96ffe` · **Last updated:** 2026-10-06

Multi-agent audit (solidity-auditor v4, 12-agent pipeline — 9 specialty attackers + 3 gap-hunters)
of every Own Curated Funds contract, run in **loop mode with 2 passes**: pass 2 was handed what
pass 1 found and told to spend its effort on new ground while still re-reporting anything it hit
again. IDs are new in this pass (`A6-`). **Nothing has been fixed** — every item below is Open
until it is reviewed and a fix is chosen.

Every one of the 24 agent runs (12 per pass) returned results. Seven pass-1 agents were blocked
by the API's `[reasoning_extraction]` safeguard on Opus and finished on Fable (see Coverage).
Sonnet and Opus 4.8 were never needed.

Each finding was traced against the source by the orchestrator before booking. The severity
column is the orchestrator's grading; the skill's own confidence score is shown per finding. The
skill's assembled report (all 15 scored findings, 25 leads, exact agent wording) is kept with
the run files under `.solidity-auditor/runs/20261006-102457/` on the machine that ran the scan
and is not committed.

### Scope

```
src/funds/Fund.sol            src/funds/FundBribes.sol       src/funds/FundCurators.sol
src/funds/FundFactory.sol     src/funds/FundGovernor.sol     src/funds/FundHook.sol
src/funds/FundLaunch.sol      src/funds/FundMintZap.sol      src/funds/FundOracle.sol
src/funds/FundRedeemZap.sol   src/funds/FundStaking.sol      src/funds/FundTwapFeed.sol
src/funds/libraries/EpochHistory.sol       src/funds/libraries/FullRangeLiquidity.sol
src/funds/libraries/FundRebalance.sol      src/funds/libraries/GaugeMath.sol
src/funds/libraries/PositionFees.sol       src/funds/libraries/ProposalBook.sol
script/funds/DeployFundsRobinhood.s.sol    script/funds/AddFundTwapFeedRobinhood.s.sol
script/funds/HookMiner.sol
```

21 files, 5,432 lines. Interfaces, tests and mocks were read for context only.

### Coverage

| # | Agent | Pass 1 | Pass 2 |
| - | ----- | ------ | ------ |
| 1 | math-precision | Opus (one reply cut by the classifier; finished) | Opus |
| 2 | access-control | Opus blocked → Fable blocked → **Fable** | Opus |
| 3 | economic-security | Opus blocked → **Fable** | Opus |
| 4 | execution-trace | Opus blocked → **Fable** | Opus |
| 5 | invariant | Opus blocked → **Fable** | Opus |
| 6 | periphery | Opus (last step cut; finished) | Opus |
| 7 | first-principles | Opus | Opus |
| 8 | asymmetry | Opus blocked → **Fable** | Opus |
| 9 | boundary | Opus blocked → **Fable** | Opus |
| 10 | numerical-gap | Opus (one line dropped; finished) | Opus |
| 11 | trust-gap | Opus blocked → **Fable** | Opus |
| 12 | flow-gap | Opus | Opus |

**24/24 agent runs returned.** Every block was `[reasoning_extraction]`. The skill's shared
rules ask each agent to print its private reasoning markers so the orchestrator can count them;
that request is what trips the safeguard. Retries (and all of pass 2) used the same bundle with
that one section reworded: the agents still apply the Feynman / Socratic / Inversion method, but
keep the working private and return only FINDING and LEAD blocks. With that change no agent was
blocked (7/7 retries and 12/12 pass-2 agents finished). The skill's own rule "never respawn a
dead agent" was overridden because every agent had to finish.

### Relation to the 2026-10-04 funds pass

- **A6-H-02** is a gap in the fix for 10-04 #3 (`faa45a6`, propose records per-epoch supply):
  the per-epoch record is zero for the launch epoch.
- **A6-M-09** is the `stake` twin of 10-04 #2 (`unstake` moved the launch lock; fixed in
  `faa45a6`). `stake` still has the same shape.
- 10-04 Low #6 (any caller picks the close prices) and Low #7 (dust deposit blocks its own claim)
  were raised again; both are listed as leads. #6 only applies to the early-close path today,
  because A6-H-01 makes the late path revert.
- 10-04 Low #5 (curator who stakes every other week stays compliant) and Info #8 (createFund
  withdraw cutoff) were **not** raised again and were not re-checked.

---

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 0     | 0     | 0    | —         |
| High     | 2     | 0     | 2    | —         |
| Medium   | 9     | 0     | 9    | —         |
| Low      | 4     | 0     | 4    | —         |
| Info     | 0     | 0     | 0    | —         |

| ID      | Severity | Finding                                                                          | Conf | Status |
| ------- | -------- | -------------------------------------------------------------------------------- | ---- | ------ |
| A6-H-01 | High     | `finalize` reverts after `endTime`, so a launch without an early close always fails | 100 | Open |
| A6-H-02 | High     | Launch-epoch proposals count only escrowed power, so one holder passes any proposal | 90 | Open |
| A6-M-01 | Medium   | A 30-minute pool crash shrinks the redeem supply and over-pays the basket         | 75   | Open |
| A6-M-02 | Medium   | Right after seeding the position TWAP covers seconds; one block sets redeem supply | 75  | Open |
| A6-M-03 | Medium   | Dust bribes fill the 32 reward-token slots; later bribes in new tokens revert     | 90   | Open |
| A6-M-04 | Medium   | Compliance uses live supply, so mint → flip → redeem fails an honest curator      | 80   | Open |
| A6-M-05 | Medium   | A flip in the launch epoch uses up every curator's grace week                     | 80   | Open |
| A6-M-06 | Medium   | One premium reading prices up to 8 h of staking yield; caller picks the moment    | 80   | Open |
| A6-M-07 | Medium   | One paused / blacklisting basket token blocks every redeem                        | 80   | Open |
| A6-M-08 | Medium   | After `setGovernor`, bribers refund bribes that voters already claimed            | 75   | Open |
| A6-M-09 | Medium   | `stake` moves the caller's launch lock onto any receiver                          | 85   | Open |
| A6-L-01 | Low      | A bribe posted before a failed launch can never be refunded                       | 80   | Open |
| A6-L-02 | Low      | A reward token whose balance drops below `_reserved` blocks flip and curator changes | 75 | Open |
| A6-L-03 | Low      | Mint charges pool USDG at the TWAP, so a minter after a 30-minute dump underpays   | 65   | Open |
| A6-L-04 | Low      | Before seeding, every rebalance swap skips the daily volume cap (manager-only)    | lead | Open |

---

## A6-H-01 — `finalize` reverts after `endTime`, so a launch without an early close always fails (High, Open)

`FundLaunch._points` (`src/funds/FundLaunch.sol:393`), reached from `finalize` (`:178`).
Raised by 10/12 agents in pass 1 and 8/12 in pass 2; four agents ran a Foundry PoC on a scratch
copy (all pass).

`finalize` sets `closedAt = uint64(block.timestamp)` and then `_creditAndPoints` → `_points`:

```solidity
uint256 served = timeWeight - amount * (endTime - closedAt);
```

`endTime` and `closedAt` are both `uint64`, so `endTime - closedAt` is a checked `uint64`
subtraction. The comment assumes `closedAt <= endTime` ("an early close takes off the part never
served"), but that only holds on the early-close branch. `finalize` reverts `WindowOpen` before
`endTime` unless `targetRaiseUsd` is reached, so the normal close is at `block.timestamp >= endTime`.

- At `block.timestamp == endTime` exactly: succeeds.
- At `endTime + 1` up to `finalizeDeadline`: Panic `0x11`, every time.
- After `finalizeDeadline`: anyone calls `markFailed`; the raise is refunded.

With the default `targetRaiseUsd = 0` the only way a launch succeeds is a transaction landing
in the block whose timestamp equals `endTime` to the second — not something the keeper controls.
The failed branch (`raised < minRaiseUsd`) returns before `_creditAndPoints`, so only successful
raises are hit. No funds are lost (refunds work), but the first fund cannot launch. Every test
finalizes after `vm.warp(launch.endTime())` exactly (`test/helpers/FundTestBase.sol:193`,
`test/unit/FundLaunch.t.sol:170,188,203,213,221,239,357,722`), which hides it. Recovery after
deploy would need a Launch beacon upgrade.

**Suggested fix:** clamp the unserved time to zero —
`timeWeight - amount * (closedAt < endTime ? endTime - closedAt : 0)` — or store
`closedAt = min(block.timestamp, endTime)`. Add a test that finalizes at `endTime + 1`.

## A6-H-02 — Launch-epoch proposals count only escrowed power, so one holder passes any proposal (High, Open)

`FundGovernor.propose` (`src/funds/FundGovernor.sol:267`) with `FundStaking._recordSupply` and
`EpochHistory.set`. Pass 2 (math-precision) as a finding, trust-gap / invariant as leads;
orchestrator re-traced it.

`propose` snapshots `totalStake = max(_stakedSupplyNow(f, E), _totalPower.valueAt(E + 1))`, where
`_stakedSupplyNow(f, E) = max(staking.totalSupplyAt(E), _totalPower.valueAt(E))`.

In the launch epoch `E`, `totalSupplyAt(E)` is always **0**: the first staking record is written
at `finalize` as `_supply.set(E, min(valueAt(E) = 0, live), live)`, and `EpochHistory.set` skips
the push for `E` when the history is empty and `atCurrent == 0`, writing only `(E + 1, live)`.
Every later record in `E` repeats `min(0, live) = 0`. `_totalPower.valueAt(E)` is also 0, because
governor deposits count from the next epoch. So for a proposal made in `E`, `totalStake` is just
the escrowed power at `E + 1`.

Worked numbers (raise $1M, 100M supply, NAV ≈ $0.011): a holder escrows 454,546 shares (the
$5,000 `proposalThresholdUsd`) and is the first to escrow, then proposes `ReplaceCurator` in the
same epoch. `totalStake = 454,546`, so `castVote` gives them `1e18 × 454,546 / 454,546 = 100%`
of the vote — above the 20% curator quorum, with no "no" votes possible from holders who escrow
later (`DepositedAfterProposal`). Curator-change proposals give curators no slice. The attacker
takes a curator seat (and its fee income); `RemoveCurator` would also burn the removed curator's
vesting yield. The only defence is an Own veto inside the 1-day veto period. The same zero
denominator would let a `List` or `Delist` proposal pass on the staker slice with only the
curators' 30% able to oppose.

**Suggested fix:** include the live staked supply in the proposal denominator, e.g. take the
max with `staking.totalSupply()` (or skip the launch epoch for proposals). Re-check the gauge
tally (`_castVotes`) for the same zero record in `E`.

## A6-M-01 — A 30-minute pool crash shrinks the redeem supply and over-pays the basket (Medium, Open)

`Fund.redeem` → `_poolAndSupply` (`src/funds/Fund.sol:764`) → `FundHook.positionAmounts` at the
30-minute TWAP tick. Pass 1 boundary agent (finding); first-principles, math-precision and
invariant agents as leads on the same mechanism.

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
and spot amounts — i.e. use the smaller resulting `supply` only in the direction that cannot
over-pay — or price the basket legs with the same cap logic the USDG leg already has.

## A6-M-02 — Right after seeding the position TWAP covers seconds, so one block sets the redeem supply (Medium, Open)

`FundHook._positionTick` (`src/funds/FundHook.sol:471`). Raised by math-precision and
first-principles (pass 1) and invariant (pass 2); first-principles ran a PoC.

For the first 30 minutes after `seedPool`, `_twap` falls back to the oldest observation (the
seed), and `_positionTick` ignores `found`, so the "30-minute" mean can cover a few seconds. One
block held at a low tick moves it a long way, which feeds A6-M-01's `supply` directly without
the 30-minute hold. PoC (default fixture): sell half of 67,708 tokens right after seeding, buy
back 1 s later, redeem — **$76.6k paid vs $74.4k baseline for ~$330 of swaps**, loss on other
holders. Precondition: unlocked fund tokens at seed time, i.e. `depositorLock == 0` or `seedPool`
runs after `depositorUnlockAt` (depositor tokens are locked 7 days by default).

**Suggested fix:** until `POSITION_TWAP_WINDOW` of history exists, use the seed tick (or block
the pool slice of redeem/mint).

## A6-M-03 — Dust bribes fill the 32 reward-token slots; later bribes in new tokens revert (Medium, Open)

`FundCurators.registerRewardToken` (`src/funds/FundCurators.sol:146`), entered from
`FundBribes._pull` (`src/funds/FundBribes.sol:199-218`). Raised by 8 agents in pass 1 and 4 in pass
2; execution-trace ran a PoC (33rd registration reverts).

`_pull` accepts `reward == token` for any **eligible** asset, not only basket assets, and calls
`registerRewardToken(reward)` whenever `cut != 0`. At the default `bribeCutBps = 1500`, 7 wei
gives `cut = 1`, `net = 6`. Registration is permanent and capped at `MAX_REWARD_TOKENS = 32`. The
attacker posts `postBribe(X, epoch, X, 7)` for 32 eligible tokens before or after launch (no
`launched` check), and later reclaims the 6 wei per token with `refundBribe` because nobody can
vote for a non-basket token. Cost: gas plus 32 wei.

After that, every bribe whose reward token is not yet registered reverts `TooManyRewardTokens`
— including **MONEY** (allowed as a bribe token in `DeployFundsRobinhood.s.sol:82` but not a
core token) and a token team's listing bribe paid in its own token. Every `_distributeAll`
(flip, curator changes, claims) also loops 35 tokens forever. Precondition: at least 32 allowed
tokens (eligible + basket + bribe tokens) — likely with a tokenized-stock eligibility list.

**Suggested fix (pick one):** (A) in `_pull`, allow `reward == token` only for basket assets or
the open listing target; (B) exempt `isBribeToken` tokens from the cap, or skip the cut instead
of reverting when full; (C) add an admin path to unregister a token with zero balance and zero
reserve.

## A6-M-04 — Compliance uses live supply, so mint → flip → redeem fails an honest curator (Medium, Open)

`FundCurators.checkCompliance` (`src/funds/FundCurators.sol:159`). Raised by 3 agents in pass 2.

```solidity
uint256 required = Math.mulDiv(f.totalSupply(), minStakeBps, BPS, Math.Rounding.Ceil);
bool ok = gov.stakedAssetsAt(c, epoch) >= required;
```

The stake side is a past-epoch record; the supply side is live. `FundGovernor.flip` is
permissionless, so an attacker mints just before `flip` and redeems right after, in one
transaction. Example (100M supply, `minStakeBps = 50` → 500k required, curator C has 520k):
minting ~4M shares raises `required` to 520,000.005e18 and C fails. Two flips in a row (or one
call that runs two missed flips) set C non-compliant: C loses its income share in `_distribute`,
its base and silent vote slice in that flip's `_castVotes`, and its proposal votes. Cost ≈ the
1% mint + 1% redeem fee (≈$8k per flip at $0.10 NAV on that example), partly refunded if the
attacker is itself a curator. The reverse (redeem before flip so an under-staked curator passes)
also works.

Only live when `minStakeBps > 0`. Project memory says the minimum is 0 at launch, but the deploy
script comment documents 50 bps (`DeployFundsRobinhood.s.sol:36`).

**Suggested fix:** compare against a fund-supply checkpoint for the tallied epoch (an
`EpochHistory` of `Fund.totalSupply`, minimum-in-epoch like staking).

## A6-M-05 — A flip in the launch epoch uses up every curator's grace week (Medium, Open)

`FundGovernor.flip` (`src/funds/FundGovernor.sol:234`). Pass 2 math-precision.

`flip` needs only `launched`. On the first call `nextEpochToTally == 0`, so `e = current − 1`.
Anyone who calls `flip` during the launch epoch `E` makes it tally `E − 1`, where every curator's
`stakedAssetsAt` is 0 → `belowSince` is set for all of them (the grace week is spent). The
keeper's flip at `E + 1` tallies `E`, where power is still 0 (deposits count from the next
epoch) → `_setCompliant(c, false)` for every curator. For that week `_compliantCount == 0`, so
the protocol curator takes 100% of curator income (e.g. $5,000 of USDG fees instead of ~$1,667)
and curators have no proposal votes. Without the early call, the keeper's first flip still
checks the zero-stake epoch `E` and burns the grace week by itself. Only live when
`minStakeBps > 0`.

**Suggested fix:** skip the compliance check (and the first tally) for epochs at or before the
launch epoch.

## A6-M-06 — One premium reading prices up to 8 h of staking yield; caller picks the moment (Medium, Open)

`FundStaking._accrue` (`src/funds/FundStaking.sol:337`). 4 agents in pass 1, 2 in pass 2.

`accrue()` is permissionless (and runs inside every stake/unstake). It reads `premiumBps()` once
and applies `rateForPremium(premium)` to `elapsed = min(now − lastAccrual, 8 h)`. A staker
waits until `lastAccrual` is ~8 h old and calls it while the 30-minute TWAP premium sits in a
high-rate band (or holds the pool price up for 30 minutes to put it there). Example: 10M staked,
cap 3%/day — one call at a 3,000 bps premium mints **100,000 fund tokens**; the same call a block
later at premium 0 mints none. Minted tokens dilute every non-staker. `maxPremiumBps` caps the
mint price but not the premium the yield curve reads. The reverse also works: anyone can call
`accrue` while the premium is below `curve[0]` or a feed is stale, and the 8-hour period is
consumed with zero yield (`lastAccrual` is written before the `ok` check).

**Suggested fix:** accrue against a time-weighted premium over the elapsed period, or cap
`elapsed` per reading to the TWAP window and let the keeper refresh; cap the premium the curve
reads at `maxPremiumBps`.

## A6-M-07 — One paused / blacklisting basket token blocks every redeem (Medium, Open)

`Fund.redeem` (`src/funds/Fund.sol:285`). Economic-security (pass 1), invariant (pass 2).

The redeem loop calls `safeTransfer` for every basket asset with `amounts[i] != 0` and has no
way to skip one. If one tokenized stock pauses transfers or blacklists the fund, every `redeem`
and `FundRedeemZap.redeemToUsdg` reverts for every holder — the NAV floor disappears. The token
cannot be removed: `flip` → `_setBasket` reverts `AssetHasBalance` unless it is ≤ 0.1% dust,
`sweep` refuses listed tokens (`NotSweepable`), and `rebalance` cannot sell it because the
transfer itself fails. The same transfer in `FundLaunch.finalize` blocks finalisation. The docs
say redeem "cannot be paused".

**Suggested fix:** let the caller name assets to skip (forfeiting that slice to remaining
holders), or credit a failed transfer to the receiver as a later claim.

## A6-M-08 — After `setGovernor`, bribers refund bribes that voters already claimed (Medium, Open)

`FundBribes.refundBribe` (`src/funds/FundBribes.sol:88`) and the listing-bribe twins. Trust-gap
(finding) and boundary (lead) in pass 2.

`FundBribes` reads `IFund(fund).governor()` live, but its ledgers are keyed only by epoch or
proposal id. `claimBribe` never lowers `_bribes` or `_bribesBy`. After the admin's documented
upgrade path `Fund.setGovernor(G2)`: epoch 100's 1,000 USDG bribe was 90% claimed under G1; G2's
first flip sets `nextEpochToTally = 102`, so for epoch 100 `isTallied` is false and `100 < 102`
→ refundable. The briber takes back the full 1,000 USDG — 900 of it from other bribers' pools —
and the last 10% of voters can no longer claim (`EpochNotTallied`). Listing variant: proposal ids
restart on G2, so a briber of G1 proposal #0 proposes and cancels G2 #0 and refunds in full.
Admin-triggered, but the harm is taken by unprivileged bribers (race / retroactive amplifier).

**Suggested fix:** key bribe ledgers by the governor that was live when the bribe was posted,
and refuse claims and refunds against a different governor (or migrate them explicitly).

## A6-M-09 — `stake` moves the caller's launch lock onto any receiver (Medium, Open)

`FundStaking._stake` (`src/funds/FundStaking.sol:323-327`). 2 agents in pass 1, 6 in pass 2.

`_stake` releases the caller's launch lock (`releaseLaunchLock(msg.sender, assets)`) and puts it
on `receiver` (`_addLock(receiver, locked)`). `unstake` refuses this
(`lockedAfter != lockedBefore && receiver != msg.sender`); `stake` has no matching check. A
holder of launch-locked tokens stakes for:

- **the curators module** — the donated shares count as fresh income and are shared out, but the
  module's last `locked` worth of staked-share claims revert `SharesLocked` until
  `depositorUnlockAt` (default 7 days, max 30); a `_forfeit` unstake then moves the lock onto the
  module's fund-token fee balance, blocking those claims too;
- **an admin-listed ERC-4626 wrapper** — its last withdrawals revert until unlock;
- **the Uniswap v4 PoolManager** (sync → stake → settle inside `unlock`) — credits the caller,
  so launch-locked value could be swapped out through any sFUND pool. Not proven; needs an sFUND
  pool with outside liquidity.

The cost is the gifted stake. This is the `stake` twin of 10-04 Medium #2.

**Suggested fix:** in `_stake`, revert `SharesLocked` when `moved != 0 && receiver != msg.sender`.

## A6-L-01 — A bribe posted before a failed launch can never be refunded (Low, Open)

`FundBribes.postBribe` / `refundBribe`. Pass 2 execution-trace.

`postBribe` does not check `launched`. If the launch fails, `flip` reverts `NotLaunched` forever,
so no epoch is ever tallied and `nextEpochToTally` stays 0: `refundBribe` is `NotRefundable`
(`epoch < 0`) and `claimBribe` is `EpochNotTallied`. The net bribe stays in `FundBribes` with no
exit; the cut has already gone to the curators module.

**Suggested fix:** revert `postBribe` (and `postListingBribe`) until `launched`, or refund when
the launch status is Failed.

## A6-L-02 — A reward token whose balance drops below `_reserved` blocks flip and curator changes (Low, Open)

`FundCurators._distribute` (`src/funds/FundCurators.sol:404`) and `_distributeAll`. 4 agents in
pass 1, 1 in pass 2.

`fresh = balanceOf(this) − _reserved[token]` is checked math, and `_distributeAll` reads every
registered token with no try/catch inside `checkCompliance` (so inside `flip`), curator changes
and claims. A registered stock token that rebases down, reverse-splits by rebase, or is clawed
back by its issuer — or whose `balanceOf` reverts — makes all of those revert for every caller,
and A6-M-03 shows anyone can register eligible tokens. Not confirmed that any eligible token
behaves this way.

**Suggested fix:** `fresh = bal > reserved ? bal − reserved : 0`, clamp `_reserved` down to the
balance, and add an unregister path.

## A6-L-03 — Mint charges pool USDG at the TWAP, so a minter after a 30-minute dump underpays (Low, Open)

`Fund._mintAmounts` (`src/funds/Fund.sol:583`). Economic-security (pass 1, finding at confidence
65); invariant (pass 2, lead).

The mint mirror of A6-M-01: `_mintAmounts` charges `(idle + poolUsdg_TWAP) × navShares / supply`.
Dump, wait 30 minutes, buy back, mint in the same block → the TWAP-valued pool USDG (which scales
with √price) is understated, and `mintPrice` floors at NAV. Modelled on $1M TVL: break-even at
defaults (`poolUsdgBps` 1000, fee 100 bps, ≈ +$1.1k); **+$39.9k** at `poolUsdgBps` 5000;
+$27.1k at fee 10 bps; +$70.4k at `poolUsdgBps` 3000 and fee 10 bps. Same arbitrage deterrent as
A6-M-01. The same fix shape applies (charge the larger of spot and TWAP pool USDG).

## A6-L-04 — Before seeding, every rebalance swap skips the daily volume cap (Low, Open)

`FundRebalance.rebalance` (`src/funds/libraries/FundRebalance.sol:44,64`). Trust-gap (pass 1,
PoC on a scratch copy) and invariant (pass 2). Manager-only, so the skill scores it a lead; it is
listed because the cap is meant to bound the keeper.

`launching = !hook.isSeeded(fund)` exempts **all** swaps from `_trackVolume`, not only the
intended USDG buys. PoC: 40 NET ↔ TSLA round trips at 98.5% of oracle value in one block took
`totalValue` from 80,000 to 35,256 (−56%). Selling the USDG reserved for the pool then makes
`seedPool` revert `InsufficientPoolUsdg`, so the exemption never ends; `seedPool` is gated to the
manager or owner.

**Suggested fix:** track volume while launching too (keep only the buy-USDG allowance), or add a
seed deadline after which anyone may seed.

---

## Leads (not scored — trails for manual review)

- **Unstake + restake in one epoch lowers the recorded supply** — `FundStaking._recordSupply`.
  The recorded supply is the epoch minimum, so restaking 60M of 100M lifts escrowed voters from
  7% to 17.5% of the gauge tally and of new proposal denominators. Gain not measured. (2 agents)
- **One curator's slice is 20.001%, enough for the 20% quorum alone** — `ProposalBook._curatorVotes`.
  With defaults (30% slice, protocol share 33.33%) a single non-protocol curator gets 2.0001e17
  votes and can list or delist without staker support; only a staker "no" above 20% or the veto
  stops it. Intent not confirmed.
- **One wei of bribe-locked votes takes the whole bribe and blocks its refund** —
  `FundBribes.refundBribe` / `claimListingBribe`. Refund needs zero bribe votes; `_share` has no
  minimum. Cost: 1 wei + a 28-day withdrawal delay. (2 agents)
- **After a governor swap, old escrow stops counting for the lock** — `FundStaking._update` reads
  the live governor's `escrowOf`; a launch-locked staker could free its lock. Not run.
- **After a governor swap, voters cannot claim epochs the old governor tallied** —
  `FundBribes.claimBribe`. Same root as A6-M-08.
- **Uncollected LP fees are left out of NAV and counted in supply** — `Fund.mint`. A minter just
  before `collectLpFees` gets a share of pending fees; gain beats the fund fee only when pending
  fees exceed it. LP fee is 0 by default. (2 agents)
- **Pending mint locks for whatever option sits at its index** — `Fund.mint` after
  `setLockOptions`; `minSharesOut` does not bound the lock duration. Admin-triggered. (2 agents)
- **Propose measures next-epoch power against current-epoch supply** — `FundGovernor.propose`
  outside the launch epoch: stake + escrow + propose in one epoch votes against a denominator
  without that stake (e.g. 529k instead of ~925k to pass a listing). Admin veto applies.
- **Stale basket feed through the grace period turns a successful raise into a refund** —
  `FundLaunch.markFailed`; `finalize` uses the hard `price()` for every launch asset. (2 agents)
- **Anyone picks the early-close moment that fixes every close price** — `FundLaunch.finalize`
  (10-04 Low #6, now early-close only). (2 agents)
- **Dust deposit of a cheap asset divides by zero in that depositor's claim** —
  `FundLaunch.claimable`; self-harm plus any `distribute` batch that includes the account
  (10-04 Low #7). (6 agents)
- **Launch pays recorded amounts** — `FundLaunch.refund` / `finalize`; a balance-lowering stock
  token blocks finalize and the last refunds.
- **Delisted token keeps its weight when every other token is under the minimum vote** —
  `GaugeMath.targets`; the `total == 0` fallback ignores `delisted`. (2 agents)
- **Remainder rounding can hold a target-zero token at 1 bps** — `GaugeMath.move`; with all
  remainders 0 the leftover goes to index 0. Delays `_drop`. (3 agents)
- **`previewRedeem` overstates USDG when spot < TWAP** — integrators that copy it into
  `minUsdgOut` get reverts. No loss.
- **Lowering spot before someone's redeem moves value to other holders** — `FundHook.redeemPosition`
  (removal at spot, pay at `min(spot, TWAP cap)`). Profit not shown.
- **An extreme tick held across one second moves the 30-minute TWAP by ~5%** — `FundHook._observe`;
  feeds `premiumBps` (uncapped by `maxPremiumBps`) and `_poolAndSupply`. Cost not priced.
- **Manager routes each daily rebalance through its own pool** — `FundRebalance.rebalance`;
  up to 2% × 10%/day ≈ 0.2% of TVL a day inside the documented bounds.
- **Router call that triggers `collectLpFees` hides USDG sold** — `FundRebalance._swapDeltas`;
  the inflow lowers the measured sell, beating the 2% check. LP fee 0 by default.
- **`zapMint` accepts USDG / basket tokens as routers** — `FundMintZap.zapMint` only rejects
  `router == fund`, unlike the redeem zap and rebalance; if the admin ever allows such a router,
  anyone spends other users' allowances to the zap.
- **`claimable` omits an unlocked vest of a non-compliant curator** — `FundCurators.claimable`
  view shows less than `claim` pays.
- **Admin setters that apply retroactively** — `setProtocolCuratorShare` splits income that
  arrived before it (and changes live curator vote weight); `FundFactory.setMaxYieldRate` prices
  up to 8 h of yield earned before it; `FundGovernor.setWrapper` removal leaves deposited wrapper
  power in votes, bribes and compliance. Admin-only.

## Attacked and held

Checked by at least one agent and found consistent:

- Fund mint/redeem rounding: ceil on deposit, floor on payout; minted fund tokens never exceed
  `navShares`; `RedeemTooLarge` holds.
- In-block TWAP manipulation: the accumulator adds the current tick for 0 seconds in the same
  block; the `usdgCap` plus burning pool tokens at spot leaves no same-block profit.
- Seeding after pre-seed redeems: the USDG reduction telescopes exactly.
- `GaugeMath`: weights never sum above 10,000, so `BPS − sum` cannot underflow; each token
  gets at most one remainder point.
- Vote, bribe and listing-bribe aggregates: `_bribeVotes` equals the sum of
  `floor(power × bps / BPS)` through `_setPower`, `_applyAlloc` and `lockForBribes`; claims never
  exceed the bribe.
- `FundCurators`: epoch-boundary vesting, `_reserved` vs debts, and the reentrant
  `_forfeit` → unstake → `notifyYield` ordering.
- `FundStaking`: virtual-share offsets, curator-cut pricing in `_accrue`, curator and LP yield
  accounting; launch locks cannot be moved through the governor, a wrapper, LP or a zap (only
  through `stake`, A6-M-09).
- `EpochHistory` set/valueAt ordering and pending-checkpoint pop; `requestWithdrawal` keeps
  `next ≥ active`.
- `FullRangeLiquidity` seed amounts never exceed what is provided; `PositionFees` action bytes
  match v4-periphery; `FundHook` fee signs, signed tick rounding and `PositionInfo` offsets.
- `FundTwapFeed` / `FundOracle` decimal scaling and overflow bounds; `HookMiner` flag mask.
- Mint and redeem zaps: no issue beyond the router lead above.
