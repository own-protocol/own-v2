# Own Protocol v2 — Audit Report & Remediation Status (Pass 5)

**Branch:** `OwnStakingV2` · **Last updated:** 2026-09-16

Multi-agent audit (solidity-auditor, 12-agent pipeline — 9 specialty attackers + 3 gap-hunters) of
the contracts added on this branch, plus a differential review of the `EUSDManager` additions.
IDs are stable across passes; `A5-` items are new in this pass. No finding in this pass overlaps or
reopens an earlier ID — both audited contracts are new to the codebase.

A **second 12-agent scan** (2026-09-16) covered the same contracts plus the full `EUSDManager`
(not just the branch diff) and the post-pass `unwind` surface. New items continue the `A5-` series
(A5-H-01, A5-M-03/04, A5-L-03/04/05); all seven were re-verified against source by the
orchestrator before booking, and A5-H-01 carries a 3/3-passing PoC.

A **third 12-agent scan** (2026-09-16) added `tokens/EUSD.sol` to scope and re-ran the full
staking/zap/manager surface post-remediation. New: A5-M-05 (extends A5-H-01), A5-L-06 (sharpens
the `_collateral` ops lead), and a reopened residual on A5-M-03. The scan's top EUSD report —
`crosschainBurn` burn+mint recycling of the `netBridgedIn` cap into bridge theft — deduplicated
against **Report 4 (audits/09-09-2026) I-05/I-06**, both Acknowledged there under the
trusted-bridge model; see the drop list under the third-scan leads. Every other third-scan
report also deduplicated into an existing entry.

### Scope

```
core/OwnStakingV2.sol        periphery/OwnStakeZap.sol
core/EUSDManager.sol (diff vs main: stakeZap wiring, depositFor/mintFor, setStakeZap)
tokens/EUSD.sol (third scan)
```

---

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 0     | 0     | 0    | —         |
| High     | 1     | 1     | 0    | —         |
| Medium   | 5     | 5     | 0    | —         |
| Low      | 6     | 3     | 0    | 3         |
| Info     | 1     | 0     | 0    | 1         |

| ID      | Severity | Finding                                                                 | Status    |
| ------- | -------- | ----------------------------------------------------------------------- | --------- |
| A5-H-01 | High     | Reward weight non-monotonic in staked eUSD under a convex boost curve   | Fixed     |
| A5-M-01 | Medium   | Permissionless `syncRewards` dilutes the reward stream with 1-wei dust  | Fixed     |
| A5-M-02 | Medium   | eUSD donation to the zap DoSes smaller `rebalance` calls                 | Fixed     |
| A5-M-03 | Medium   | Stale-price fallback prices weight-increasing stakes at a dead mark      | Fixed (incl. residual) |
| A5-M-04 | Medium   | Partial redemption bypasses the `minDebt` floor                          | Fixed     |
| A5-M-05 | Medium   | Convex curve segments make position-splitting weight-profitable          | Fixed     |
| A5-L-01 | Low      | Third-party boost flooring during oracle outage redistributes rewards    | Fixed     |
| A5-L-02 | Low      | Permitted 100% swap split in `stakeFromSpy` always reverts               | Fixed     |
| A5-L-03 | Low      | Stray SPY on the zap is swept into the next `stakeFromSpy` caller's CDP  | Fixed     |
| A5-L-04 | Low      | Permissionless `accrue` reorders the redemption queue                    | Acknowledged |
| A5-L-05 | Low      | `withdrawCollateral` skips the collateral-disabled gate                  | Acknowledged |
| A5-L-06 | Low      | Stray legacy eTokens deposit at the legacy-ratio valuation post-migration | Acknowledged |
| A5-I-01 | Info     | `mintFor` grants the zap standing debt-creation power over any position  | By design |

---

## A5-H-01 — Reward weight non-monotonic in staked eUSD under a convex curve (High, Fixed 2026-09-16)

Weight is `eusdStaked × boost(coverage)` with `coverage = moneyValue / eusdStaked`. On a curve
segment `f(c) = lo.boost + b·(c − lo.cov)`, weight as a function of staked eUSD has slope
`(lo.boost − b·lo.cov) / BPS` — negative whenever the segment is steeper than the ray from the
origin (`b·lo.cov > lo.boost`). The launch curve's convex top segment
(`(20000, 19000) → (30000, 36000)`: slope 1.7 vs ray 0.95) violates this, so with equal $MONEY:

- staking 50% more eUSD principal earns ~21% *less* of the SPY stream (weight 2,850 vs 3,600 per
  the PoC's two $3,000-MONEY positions at 1,500 vs 1,000 eUSD);
- unstaking principal strictly *raises* weight (+26% while pulling 500 eUSD back out);
- the permissionless `stakeFor(victim, 0, eusd)` cuts a victim's weight ~21% at the cost of a
  gift the attacker cannot reclaim — refuting the interface's "staking for someone else only ever
  benefits them."

`_setCurve` validates coverage strictly increasing and boost non-decreasing but not the
weight-monotonicity condition. PoC: 3 tests, all passing against the unmodified contract with the
default test curve.

**Fix:** `_setCurve` now additionally requires `boost/coverage` non-increasing across knots
(`knots[i-1].boostBps × knots[i].coverageBps ≥ knots[i].boostBps × knots[i-1].coverageBps`,
segments from zero coverage exempt) — no segment may rise steeper than the ray from the origin,
which makes `weight = eusdStaked × boost(coverage)` provably non-decreasing in staked eUSD for
every acceptable curve. The test/launch curve is reshaped to
`(0, 0.1×) → (1.0, 1.2×) → (3.0, 3.6×)` — same floor, same 3.6× max, proportional above 1:1 —
which shifts launch economics only marginally (fully-covered cohort ~85% of the pot vs ~87%
before; mid-coverage stakers pick up the difference). Regression tests: more eUSD never weighs
less, unstaking eUSD never raises weight, a `stakeFor` gift never lowers the victim's weight, and
`setCurve` rejects the old convex shape.

**Hardening (2026-09-16):** `stakeFor` is additionally gated `onlyZap` — third-party deposits
into someone else's position had no use case beyond the zap, and closing the surface is defense
in depth should any future change re-create a way an unsolicited deposit harms its target
(forced boost re-snapshots remain possible via the by-design permissionless `refreshBoost`).

## A5-M-01 — Permissionless `syncRewards` dilutes the reward stream (Medium, Fixed 2026-09-15)

`OwnStakingV2.syncRewards` is ungated and routes any nonzero surplus through `_notify`, which
re-spreads the entire un-streamed remainder over a fresh full `rewardsDuration` window and resets
`periodFinish`. A 1-wei SPY donation therefore lets anyone repeatedly cut the live reward rate
(a single sync at day 6 of a 7-day stream cuts it 7×; daily dust syncs leave the batch on an
exponential tail that never completes), deferring rewards indefinitely and redistributing the tail
to whoever stays staked longest, at 1 wei + gas per call. 11 of 12 agents converged on this
independently. No principal at risk — severity is capped at reward-schedule griefing.

**Fix:** `syncRewards` now books the surplus into the existing `undistributed` bucket instead of
calling `_notify`; it re-enters the stream only via the operator-gated `renotifyUndistributed`.
Permissionless booking is preserved, but every window reset is operator-only. Regression test
proves a 1-wei donation + sync leaves `rewardRate`/`periodFinish` untouched and the batch
completes on its original schedule.

## A5-M-02 — eUSD donation DoSes smaller `rebalance` calls (Medium, Fixed 2026-09-15)

`OwnStakeZap.rebalance` reads `leftover = _eusd.balanceOf(address(this))` and emits
`eusdAmount - leftover` (checked arithmetic), assuming the zap held no eUSD at entry. A pre-loaded
donation `D` makes every rebalance whose repaid amount is below `D` revert on underflow — a DoS of
the deleveraging path exactly when it matters (a SPY drawdown). The griefing is recyclable at ~gas
cost: the attacker rebalances their own CDP with `repaid ≥ D` and pockets the swept leftover.

**Fix:** `leftover` is now computed as a balance delta from a pre-`unstakeFor` snapshot, so it is
exactly this call's unspent eUSD (`eusdAmount − repaid`) and can never exceed `eusdAmount` — the
underflow is structurally impossible and the event emits the true repaid amount. A pre-existing
donation is no longer swept to the next caller; it sits in the zap like any other stray token
(see the ops lead on the missing rescue function). Regression tests cover the DoS attempt and the
overshoot-with-donation event values.

## A5-M-03 — Stale-price fallback prices weight-increasing stakes at a dead mark (Medium, Fixed 2026-09-16)

Residual gap of the A5-L-01 fix. `priceMaxAge` bounds only the live read; the `lastMoneyPrice`
cache it falls back to carries no timestamp and never expires, and `_moneyPrice()` serves it to
*every* boost evaluation — including brand-new stakes. During an oracle-silence window after a
$MONEY crash (mark $1.00, spot $0.05), an attacker buys crashed MONEY on market and stakes it:
coverage snapshots at the dead mark, minting boosted weight at a 5× capital discount and skimming
the SPY stream from honest stakers for the whole outage. Full `unstake` never reads a price, so
the exit is riskless. The A5-L-01 rationale ("an outage can never re-floor an *existing*
snapshot") covers repricing existing positions, not creating new weight; the TWAP mitigation does
not help — the attack rides the feed going silent, not a manipulated mark. The permissionless
`refreshBoost` also lets anyone choose *which* mark gets cached (refresh at a peak just before the
feed ages out).

**Fix:** `_stakeFor` reverts `StaleMoneyPrice` whenever the call adds $MONEY and
`_liveMoneyPrice()` is unusable — new stake is never valued at the cached mark. Everything else
keeps the A5-L-01 behavior: exits and claims never read a price, `refreshBoost` and existing
snapshots reprice at the cache through an outage, and eUSD-only stakes need no price. The cost is
that adding $MONEY waits out an oracle outage — the fail-safe direction. Regression tests: stale
/ zero / aged price all revert the $MONEY leg, eUSD-only entry stays open, and the cache still
serves views and refreshes while refusing to price a new entry.

**Reopened — residual (third scan, 2026-09-16):** the fix gates only the $MONEY leg, but
`stake(0, eusd)` on a $MONEY-carrying position re-runs `_resnapshotBoost` at the cached mark, so
*new eUSD principal* also acquires weight priced off the dead mark — the fix's premise
("eUSD-only stakes need no price") holds only for positions with no $MONEY, and `refreshBoost`
cannot correct the snapshot during the outage (it reads the same cache). 5/12 agents converged.
Marginal weight of added eUSD is the segment's ray intercept `b_lo − s·c_lo`: under the current
launch curve this is 0 on the upper segment (it sits exactly on the ray) and 0.1× on the floor
segment, so the attack is **unprofitable today** — but it turns profitable under any admissible
curve with positive high-coverage intercepts, and the A5-M-05 concavity fix *increases* those
intercepts.

**Residual fix (2026-09-16):** the `_stakeFor` gate now reverts `StaleMoneyPrice` for any
addition touching a $MONEY exposure — new $MONEY, or new eUSD onto a position with
`moneyStaked != 0`. Additions to money-free positions and every exit/claim path stay price-free
(the never-gates-funds invariant is untouched). Regression tests: eUSD add on a money-holding
position reverts during an outage and reprices normally once the mark is live again; money-free
eUSD additions stay open; partial and full exits work through an outage.

## A5-M-04 — Partial redemption bypasses the `minDebt` floor (Medium, Fixed 2026-09-16)

`mint`, `mintFor`, `repay`, and `liquidate` all enforce `remaining == 0 || remaining ≥ minDebt`;
`_redeemFrom` is the only debt-reducing path with no floor — a partial redemption of
`headDebt − ε` leaves a *listed* position with dust debt (down to 1 wei). `minDebt` exists so
liquidating any position always clears keeper gas + bonus (eusd-qa.md); dusted positions fall
below that floor permanently, and since redemption is ~value-neutral at the anchor price, one
recycled bankroll can dust successive list heads at ~gas cost. Liquity cancels partial redemptions
that would leave a trove below minimum net debt for exactly this reason.

**Fix:** `_redeemFrom` clamps a partial redemption that would leave `0 < remaining < minDebt` to
leave exactly `minDebt` (mirroring `repay`'s rule); when even the clamp yields nothing redeemable
(a head already at `minDebt` facing a sub-minDebt request), it returns zeros and the redeem walk
stops rather than dusting — Liquity's cancel-the-last-partial semantics. Redemptions are never
blocked, only shorted by at most `minDebt` at the tail of a walk; the underwater-residual path
(off-list, collateral-backed portion only) is untouched. Regression tests: dust-leaving partial
clamps to exactly `minDebt`, the shortfall cascade across positions, and the minDebt-head stop.

## A5-M-05 — Convex curve segments make position-splitting weight-profitable (Medium, Fixed 2026-09-16)

Extends A5-H-01. The ray condition guarantees weight is monotone in staked eUSD, but not that
`W(e, m) = e·f(m·p/e)` is superadditive — that requires `f` globally concave with
`knots[0].coverageBps == 0`, a strictly stronger property `_setCurve` never checks. The reshaped
launch curve `(0, 0.1×) → (1.0, 1.2×) → (3.0, 3.6×)` has segment slopes 1.1 then 1.2 — a convex
kink at coverage 1.0 that passes the ray check at exact equality — so splitting pays **today**:
a staker at coverage 1.0 who moves all $MONEY to a sliver address at coverage 3.0 (boost 3.6×)
and parks the remaining eUSD at floor gains ~5.5% total weight for identical capital; other
admissible flat-floor-then-steep curves reach +13–25% (worked examples in the scan). Zero-sum
against merged/honest stakers for the life of the curve; no sybil cost beyond a second address.

**Fix (2026-09-16) — by design simplification, not more validation.** The knot machinery
(`Knot` struct, `_setCurve` and its four validation rules, `_evalCurve` interpolation) is deleted
from the core and replaced with an admin-swappable `IBoostCalculator` strategy contract; launch
calculator is `LinearBoostCalculator(floor 0.1×, max 3.6×, maxCoverage 3.0)` — a straight ramp,
whose weight `min(floor·eusd + slope·moneyValue, max·eusd)` is a minimum of linear functions,
hence concave and superadditive: splitting a position across accounts can never gain weight, so
the exploit class is structurally impossible rather than validated away. The core keeps four
guardrails: results are clamped to `maxBoostBps`; a reverting calculator never gates a touch
(the position keeps its last snapshot — exits always work, `previewBoost` surfaces
`BoostCalculatorFailed`); the calculator is a pure view fed `moneyValue` by the core (no oracle
deps, no reentry); and swaps don't retro-touch snapshots (permissionless `refreshBoost`
reprices, same as `setCurve` before). **Norm adopted:** calculator swaps are security-critical —
review any new calculator (knots, steps, or otherwise) with core-contract rigor for
splitting-neutrality and monotonicity before setting it; on-chain validation no longer attempts
to enforce economic safety. Regression tests: swap-and-reprice, zero/non-admin swap reverts, and
broken-calculator behavior (snapshot held, exits open, preview reverts). The A5-M-03 residual
gate ships alongside, closing the stale-mark interaction for any future calculator shape.

## A5-L-01 — Third-party boost flooring during oracle outage (Low, Fixed 2026-09-15)

Whenever `_moneyPrice()` returned 0 (feed stale > `priceMaxAge`, unset, zero, or reverting), the
permissionless `refreshBoost([victims])` — or a 1-wei `stakeFor(victim, …)` — re-snapshotted any
account's boost at the curve floor regardless of its real $MONEY coverage. An eUSD-only staker
(already at floor, nothing to lose) could floor every boosted competitor at gas cost and capture
their share of the stream for the outage.

**Fix (on-chain):** the contract caches `lastMoneyPrice` — the latest usable oracle mark — on
every boost re-snapshot, and `_moneyPrice()` falls back to that cache whenever the live read is
unusable. An outage repricing therefore holds positions at the last known mark; the curve floor
applies only before any usable mark has ever been seen (fresh deployment with a dead feed).
Regression tests cover both the outage hold and cache tracking.

**Fix (oracle-side, pending ops):** the `MONEY` ticker consumed for boosts is to be published as a
**TWAP mark**, not spot — window managed off-chain by the oracle service (~3-day window at launch
during price discovery, widening to ~7 days as volatility settles; tunable without contract
changes). Rationale: $MONEY is expected to swing ±100% intraday early on, and boost snapshots are
per-touch, so spot pricing made boost a timing game (reprice rivals at wicks, self-reprice at
pumps). A multi-day TWAP moves at most ~1/window-days of a daily move, killing the extractable
edge of `refreshBoost` timing and blunting thin-market mark manipulation — a pump must be
sustained for days, not minutes, to move coverage. Trade-off (accepted): boosts lag live coverage
by ~half the window, symmetrically for all stakers and in the conservative direction during
run-ups. An epoch-price design (single shared weekly reprice) was considered and dropped in favor
of TWAP + cache — same fairness, less machinery, no roll moment to defend.

## A5-L-02 — Permitted 100% swap split always reverts (Low, Fixed 2026-09-15)

`OwnStakeZap.stakeFromSpy` admits `spyForMoney == spyAmount` (`InvalidSplit` checks strict `>`), but
the tail unconditionally routed the residual SPY balance into `OwnMarket.psmMint`, which reverts
`ZeroAmount()` when the router consumes the full slice — the documented-valid all-to-$MONEY split
could never execute. Functional defect only, no fund risk.

**Fix:** `_buildCdpAndStake` runs the psmMint/depositFor legs only when the residual SPY is
nonzero, making the 100% split work instead of banning it. The `mintFor` leg still runs when
requested — a full-swap caller may mint against existing CDP headroom, gated by the manager's own
MCR/minDebt/ceiling checks. Partial router fills still sweep the remainder into collateral.
Regression tests cover the plain full swap and full swap + mint-against-headroom.

## A5-L-03 — Stray SPY on the zap swept into the next caller's CDP (Low, Fixed 2026-09-16)

`stakeFromSpy` passes `_spy.balanceOf(address(this))` into `_buildCdpAndStake` while
`stakeFromSpyAndMoney` and `compound` pass exact amounts, so any SPY resting on the zap (a
mis-sent user transfer) is PSM-minted into whoever next calls `stakeFromSpy` — claimable with a
1-wei `spyAmount` and withdrawable from their CDP. The in-code rationale (a partial router fill
becomes the caller's collateral) justifies sweeping the *caller's own* remainder, not
pre-existing balances. Corrects the first-scan ops note: stray SPY is *not* stranded — it is an
MEV race; stray $MONEY/eUSD remain stranded (delta-excluded, no rescue function). Impact is
redistribution of already-lost funds, never theft from custody.

**Fix:** `stakeFromSpy` now snapshots the zap's SPY balance before pulling the caller's tokens
and PSM-mints only the delta — the caller's tokens plus their own unswapped remainder, never a
pre-existing balance (same pattern as `moneyBefore`/`balBefore`). The zap also gains an
ADMIN-only `rescueToken` (no protected list — it holds no funds between transactions, so any
resting balance is a mis-send), making stranded SPY/$MONEY/eUSD recoverable instead of
stuck-or-raced. Regression tests: a donation is not swept into the next caller's CDP, rescue is
admin-gated and returns the donation.

## A5-L-04 — Permissionless `accrue` reorders the redemption queue (Low, Acknowledged 2026-09-16)

The sorted list keys on `collateral / storedDebt`, and `_accrue` folds pending stability fees
into stored debt only for the touched position — so the permissionless
`accrue(collateral, victim, hint)` re-prices one position against stale peers and drags it toward
`listHead`, letting an attacker aim redemptions at a chosen victim (and dodge them by never
touching their own position) at gas cost. Displacement is bounded by `feeRate × staleness`
(~2%/yr at the launch fee), so any two positions within that band of each other can be reordered
at will; being redeemed is ~value-neutral at the anchor price, which caps this at ordering
unfairness rather than extraction — hence Low.

**Acknowledged (2026-09-16):** accepted as-is. Redemption (not liquidation — liquidation ignores
the list and always prices live debt) is roughly value-neutral to the redeemed position, only
near-ties within the fee-sized band (stabilityFeeBps × staleness, ~2%/yr at launch params) can be
flipped, and the touched position's higher number is its true debt — the skew is asymmetric
measurement, not fabrication. Candidate fixes if revisited: sort on `currentDebt` (small diff,
makes `accrue` order-neutral) or index-normalised debt storage (structural). Revisit if the
stability fee is raised materially above launch levels.

## A5-L-05 — `withdrawCollateral` skips the collateral-disabled gate (Low, Acknowledged 2026-09-16)

The `p.debt > 0` branch checks `mintPaused`, price freshness and MCR — but not `cfg.enabled`,
while `mint`/`mintFor` revert `CollateralDisabled` (the comment says "same gates as minting").
A debtor on an admin-disabled collateral can therefore strip their buffer down to MCR, increasing
protocol exposure on exactly the asset the disable lever was meant to cap. A trading pause or
halt on the ticker still closes the path (`_freshPrice` reverts on both), so only the
disabled-but-live state is exposed; harm additionally needs a subsequent price move — hence Low.

**Acknowledged (2026-09-16):** accepted as-is. The withdrawal is still MCR-gated at a fresh
price, so the borrower cannot go below MCR — they are thinning their own buffer and taking on
their own liquidation risk; protocol-level backstops remain (`setMintPaused`, and the
VaultManager trading pause/halt both close this path via `_freshPrice`). One-line fix
(`CollateralDisabled` in the debt-bearing branch) stands ready if the disable lever ever needs to
be a hard exposure cap.

## A5-L-06 — Stray legacy eTokens deposit at the legacy-ratio valuation post-migration (Low, Acknowledged 2026-09-16 — third scan)

Sharpens the known ops lead (initializer-pinned `_collateral`). After an AssetRegistry migration,
`psmMint` credits the zap in the *new* active token while `depositFor` pulls the frozen old
address — normally the already-booked revert-DoS. But if the zap holds ≥ `minted` of the *old*
token (mis-sends accumulated before an admin `rescueToken`), the deposit **succeeds** against the
legacy units, and `_effectivePrice` values them at `legacyRatioToActive` (4× after a 4:1 split):
the caller banks over-valued collateral the protocol eats, while their freshly-minted new-token
units strand on the zap. (Same corporate-action family as Report 4 H-02 — stock-split
mis-valuation in the manager, fixed there via the legacy-ratio machinery this variant abuses
from the zap side.) Requires a migration plus an unrescued stray balance in the same window —
hence Low. Fix would be the ops lead's: resolve the active token from the registry at call time
(closes the DoS and this variant together).

**Acknowledged (2026-09-16):** accepted as-is. The zap is UUPS-replaceable, and a split is a
planned admin-sequenced event during which the zap is upgraded/replaced anyway — the split
runbook (`docs/deployment-robinhood.md`) now includes rescuing stray SPY from the zap and
upgrading it inside the same maintenance window, which closes both the revert-DoS and the
mis-valuation variant operationally. Revisit only if a collateral with real split risk is ever
onboarded (policy prefers split-averse index ETFs).

## A5-I-01 — `mintFor` standing zap power (Info, By design — accepted 2026-09-15)

While `EUSDManager.stakeZap` is set, the zap address can call `mintFor(anyOwner, …)` at any time:
debt lands on `owner`, eUSD is paid to the caller, and the manager checks only solvency gates
(fresh price + MCR, minDebt, ceiling, pause) — not owner consent. The per-transaction,
self-initiated property users experience is enforced solely by the zap's code (it only ever passes
its own `msg.sender` as `owner`).

**Accepted rationale:** the zap's UUPS upgrade and `setStakeZap` sit behind the same delayed ADMIN
that can upgrade `EUSDManager` itself, so the whitelist grants no party any power it lacks — a
hostile admin could mint arbitrarily via a manager upgrade regardless. Consequences of acceptance:

- **Every OwnStakeZap upgrade is security-critical for EUSDManager.** A zap logic change that
  passes anything other than its own `msg.sender` as `owner` converts the whitelist into blanket
  debt-creation against any position with spare collateral above MCR. Review zap upgrades with
  core-contract rigor.
- `setStakeZap` must only ever point at a contract upholding the `owner == msg.sender` invariant.
- Rejected alternatives (2026-09-15): per-user opt-in authorization, opt-in with EIP-712 sig
  variant, per-mint EIP-712 signatures — declined to preserve single-transaction UX and avoid
  added surface.

## EUSDManager diff review (clean)

`depositFor`/`mintFor` carry every gate of the self-service `deposit`/`mint` paths (collateral
enablement, pause, minDebt, ceiling, fresh-price MCR, accrual, reindex) plus a `ZeroAddress` owner
check. `stakeZap` is appended last in storage (layout snapshot updated); `onlyZap` with an unset
zap correctly disables the surface; events attribute to `owner`. No findings.

The second scan (2026-09-16) extended coverage to the **full** EUSDManager, not just the branch
diff — A5-M-04, A5-L-04 and A5-L-05 live in pre-branch code surfaced by that wider scope.

## Post-pass additions (not covered by the 12-agent scan)

- **`OwnStakeZap.unwind(hint)`** (added 2026-09-15, after the pass): one-transaction exit — claims
  rewards, unstakes the full position, accrues then repays the CDP debt in full (shortfall beyond
  the unstaked eUSD, typically stability fees, is pulled from the caller), returns $MONEY, SPY and
  surplus eUSD. Collateral withdrawal stays a direct call by design — a `withdrawCollateralFor`
  zap surface was considered and REJECTED to keep the zap's standing powers minimal (it would
  extend A5-I-01 from "create debt" to "move collateral"). `unwind` composes only pre-audited
  surfaces (`claimFor`/`unstakeFor` zap-gated with owner = msg.sender, permissionless `accrue`,
  `repay` burning from the caller), uses the same delta accounting as the fixed `rebalance`, and
  is `nonReentrant` — but it had not been through a full agent pass at the time. *Covered by the
  second scan (2026-09-16): traced across all debt/stake branches, delta accounting exact,
  immune to donations, third-party repay front-runs, and the accrual/minDebt edge (it re-reads
  debt after `accrue`). Clean, save the uncapped-shortfall lead below.*
- **`OwnStakeZap.depositAndMint(spyAmount, eusdToMint, hint)`** (added 2026-09-16, after both
  scans): CDP-only entry for the "borrow now, stake later" journey — PSM-mints the caller's SPY
  into collateral, deposits it, and mints eUSD against the position straight to the caller's
  wallet; either leg may be zero (deposit-only, or mint-only against existing headroom). This is
  the first zap surface that releases eUSD to a wallet rather than staking it; the debt still
  only ever lands on `msg.sender`, amounts are exact (no balance reads), and it composes only
  pre-audited surfaces (`psmMint`, `depositFor`, `mintFor` + a `safeTransfer` of the exact
  minted amount). Not yet through an agent pass — include in the next one.

## Leads (not scored — trails for manual review)

- **SPY wrapper token semantics vs. reward accounting** (8/12 agents): `notifyRewardAmount` books
  `_accountedRewards += amount` assuming exact delivery, and `syncRewards` computes
  `held − accounted` under "held ≥ accounted always". A transfer fee, downward rebase, or admin
  clawback on the Gen-2 wrapper (admin powers unverified) permanently bricks `syncRewards` and
  socializes a shortfall onto the last claimants — High if the token can misbehave. A balance-delta
  receipt in `notifyRewardAmount` removes the assumption.
- **Thin-market $MONEY mark → boost inflation**: boost (to 3.6×) snapshots the in-house price;
  a short pump locks in outsized stream share until refreshed. Bounded by the oracle's band limits.
  *Mitigated 2026-09-15: the MONEY ticker becomes a multi-day TWAP mark (see A5-L-01), so moving
  coverage requires sustaining a pump for days, not minutes.*
- **Partial unstakes do read a price** via `_resnapshotBoost`, contradicting the "unstaking never
  reads a price" NatSpec (only full exits skip it); `timestamp + priceMaxAge` sits outside the
  try/catch. Reachable only with a hostile registry-swapped oracle.
- **Swap-router configuration constraint**: `stakeFromSpy` credits `moneyOut` by balance delta from
  caller-controlled calldata on the admin-set router. Safe with the exact JIT allowance, but a
  generic multicall-executor router would let third parties' standing approvals to that router be
  credited as an attacker's swap output. Constrain router choice at deployment.
- **Ops notes**: ~~the zap has no rescue function~~ *resolved with A5-L-03 (2026-09-16): the zap
  now has an ADMIN `rescueToken` and no entry can spend a resting balance*; the
  initializer-pinned `_collateral` bricks the zap's CDP entries (`stakeFromSpy`,
  `stakeFromSpyAndMoney`, `compound`) after an OwnMarket re-denomination until a UUPS upgrade —
  verified in the second scan: `psmMint` mints the live `_activeToken` while the zap's only admin
  setter is `setSwapRouter`, and the initializer approvals cover only the old token; exits are
  unaffected. `_updateGlobal` index truncation dust is economically nil at 18-decimal parameters.

### Second-scan leads (2026-09-16)

- **Rewards-only `exit()` reverts** (6/12 agents): a fully-unstaked position with
  `rewardsOwed > 0` reverts `ZeroAmount` in `_unstake(0,0)` before `_claim` runs; `claim()` works,
  and `unwind` special-cases exactly this state. One-line fix: skip the unstake leg when both
  amounts are zero.
- **`sweepCollateralRewards` trusts the pre-claim preview** (4 agents): transfers the
  `claimableRewards()` amount read *before* `claimRewards()` and ignores the claim's return value,
  with no check that `rewardToken` is not itself a listed collateral. Exact today (EToken settles
  identically in both), but `amount = claimRewards()` removes the latent
  pay-treasury-from-custody path.
- **`_claim` never re-snapshots boost**: the only position-touching path that skips
  `_resnapshotBoost`, so a claim-only staker keeps a peak-priced boost indefinitely; mitigated
  only by unincentivized third-party `refreshBoost` (and blunted by the TWAP mark).
- **`unwind` shortfall pull has no caller cap**: pulls `debt − eusdStaked` against the user's
  standing eUSD approval with no `maxShortfall` parameter — the one zap surface without a
  caller-supplied bound.
- **`stakeFromSeusd` has no min-out** on the ERC-4626 redeem; safe only while sEUSD's share price
  is guaranteed non-decreasing.
- **`psmMint` output unfloored in zap entries**: `minted` feeds `depositFor` with no floor while
  the PSM spread is operator-mutable; dust `compound` reverts with a bare `ZeroAmount`.
- **`initialize` enforces no token assumptions** (OwnStakingV2): no `decimals() == 18` or
  address-distinctness asserts; a 6-decimal reward token would silently zero the entire stream
  (`accruedScaled / weight` floors to 0 every second).
- **Underwater-redemption residual is economically unclearable**: the off-list `coll = 0,
  debt > 0` residual seizes nothing when liquidated, so only altruistic repay clears it, and it
  permanently consumes `debtCeiling` headroom. Governance-recoverable (raise the ceiling /
  treasury repay) — surfaced once as ops.
- **De-risking freezes on a dead feed before halt**: `_anchorPrice`'s live branch reverts once the
  oracle's hard window lapses on a not-yet-halted asset, freezing `liquidate`/`redeem` until an
  admin halts; exposure window = admin reaction time (repay/close stay open).
- **Minor**: `_accrue` grows `totalDebt` past `debtCeiling` (fees aren't new exposure — likely
  intended; blocks new mints until it falls back under); `_anchorPrice`'s halted branch lacks the
  `price == 0` guard the live branch has (unreachable — `haltAsset` rejects zero — but free to
  add); the A5-I-01 rationale for rejecting `withdrawCollateralFor` ("don't extend zap powers to
  moving funds") reads inconsistently with `unstakeFor` already moving staked principal to the
  zap — resolve the documented trust model one way or the other.

### Third-scan leads (2026-09-16, scope + `tokens/EUSD.sol`)

- **No deployment scripts for the new proxies**: unlike every other UUPS contract in `script/`,
  OwnStakingV2/OwnStakeZap have no atomic `new ERC1967Proxy(impl, initData)` deploy; a two-step
  deploy is initializer-front-runnable (attacker-supplied registry → ADMIN → `_authorizeUpgrade`
  takeover). Write the scripts before deployment.
- **"Unlimited" bridge limit permanently bricks the bridge**: `EUSD._available` computes
  `maxLimit * elapsed`, which overflows for `maxLimit` near `uint256.max` — and `setBridgeLimits`
  re-enters the same expression while settling the old config, so an over-limit bridge can never
  be reconfigured or de-authorized. Bound `maxLimit` (or saturate the multiply);
  `type(uint256).max` is the idiomatic "no limit" an operator will eventually reach for.
- **`setSwapRouter` accepts protocol addresses**: pointed at `_staking`/`_eusdManager`, user
  `swapData` would reach `onlyZap` surfaces as the zap. Admin-misconfig only — reject known
  protocol addresses in the setter (defense in depth on the existing router-constraint lead).
  Related refinements to that lead: router-resident dust is creditable to a caller via
  sweep-style router commands, and the swap leg assumes SPY tolerates `approve`-to-zero.
- **`setMinDebt` vs live heads**: raising `minDebt` above an existing head's debt makes every
  sub-head redemption hit the A5-M-04 stop until that node repays or is liquidated — check the
  live list before raising the parameter.
- **Anchor price ignores the trading pause**: `redeem`/`liquidate` price at `_anchorPrice` while
  `isTradingPaused` blocks the debtor's fresh-price levers (mint/withdraw) — consistent with the
  exits-never-gated rule and the accepted psmRedeem stance, and Report 4 L-06 already
  acknowledged the stale-anchor-exit family (`maxAnchorAge` width vs bonus); the
  pause-specifically nuance is the one residual question. Confirm as design.
- **`setMintPaused` NatSpec says "only gates mint"** but `mintPaused` also blocks indebted
  partial withdrawals — the gate itself is the deliberate Report 4 L-16 fix (withdraw-with-debt
  escaping the `mintPaused` lever), so this is a one-line NatSpec correction only.
- **Fee accrual on unbacked residuals**: permissionless `accrue` keeps minting stability-fee eUSD
  to treasury against `coll = 0` residuals — unbacked supply on top of the known
  ceiling-consumption note; skip fee minting on zero-collateral positions or write residuals off.
- **`initialize` asserts (append to second-scan lead)**: also assert $MONEY `decimals() == 18`
  and document the oracle's 1e18 MONEY scale — `_boostFor`'s coverage math silently mis-scales by
  1e12 otherwise.
- **Entry-vs-fallback price age**: the $MONEY entry gate accepts marks up to `priceMaxAge` (24h)
  old — second-order given the TWAP mark, but a split entry-age (tight) vs fallback-age (loose)
  removes the day-old-"live"-mark window.

**Duplicates dropped (third scan → existing entries):**

- **Bridge `crosschainBurn` recycles the `netBridgedIn` cap into theft** (3/12 agents, sized High
  if a bridge is armed) → **Report 4 (audits/09-09-2026) I-05 + I-06, Acknowledged (Info)**.
  Report 4 already found both halves — allowance-free burn under the trusted-bridge model (I-05)
  and burn+mint pairing evading the global cap, including the wider variant where organic
  outflows through honest bridges grant every other bridge cumulative mint headroom (I-06) —
  and accepted them because bridging is **launch-disabled** (no bridge limits set,
  `maxNetBridgedIn = 0`) with an explicit re-review gate before any transport is armed, treating
  per-window `min(mintMaxLimit, burnMaxLimit)` as the theft budget. The third scan's independent
  High-if-armed sizing reinforces that gate; Report 4's recorded fix direction (per-bridge net
  tracking) matches the scan's. Not re-booked. **Ops rule adopted (2026-09-16):** EUSD is
  non-upgradeable, so bridging may only ever be armed through a protocol-owned gateway contract
  that enforces holder consent on burns and fronts the actual transport — never by granting
  limits to an external bridge address directly. Documented in `docs/protocol.md` ("EUSD token &
  bridging — Arming rule").

Other drops → existing pass-5 entries: SPY wrapper reward-accounting trust
(→ first-scan lead; re-confirmed by 5/12 agents — still the top pre-launch verification item),
`sweepCollateralRewards` pre-claim preview (→ second-scan lead; two third-scan agents verified it
exact against the current EToken), rewards-only `exit()` revert (→ second-scan lead),
`timestamp + priceMaxAge` outside the try/catch (→ second-scan lead), `refreshBoost` missing
`nonReentrant` + unincentivized-keeper (→ attacked-and-held / second-scan notes),
redemption-queue fee drift (→ A5-L-04, acknowledged), `withdrawCollateral` disabled gate
(→ A5-L-05, acknowledged), zap `_collateral` migration DoS (→ ops lead; sharpened as A5-L-06),
minDebt-head redemption stop (→ A5-M-04 designed semantics; new nuance kept as the `setMinDebt`
lead), notify/index truncation dust (→ ops note), cached mark never expiring (→ A5-M-03/L-01
design notes), `stakeFromSpyAndMoney` nominal-amount SPY pulls (→ subsumed by the SPY
token-semantics lead: fee-taking SPY breaks those paths DoS-only).

## Attacked and held

Weight bookkeeping (`totalWeight == Σ eusdStaked·boostBps/BPS`, exact under truncation on every
path); zero-weight banking to `undistributed` with no first-staker sweep or renotify double-count;
`_accountedRewards ≥ Σ owed` (all rounding protocol-favoring); flash-boost defeated by re-snapshot
on every touch; the zap's swap leg confined to the caller's own in-flight slice (JIT exact
allowance, delta + non-zero `minMoneyOut`, `nonReentrant`, standing approvals unreachable from
router context); every on-behalf surface keys on `msg.sender`; `repay` burns from the caller by
authority (no allowance needed); non-upgradeable ReentrancyGuard behind the UUPS proxies benign.

Second scan additionally attacked and held: `unwind` (all branches, see above); redeem-loop
termination (every iteration zeroes debt or delists the head — no head-pinning, no spin);
`_insertNode` hint manipulation (a hostile hint cannot mis-order the sorted list);
`_seizure` pro-rata cap (partial liquidation can never thin the survivor's ratio, bonus not
extractable from needed collateral); `_accountedRewards` conservation across all six
writers/readers; `stakeFor`-based griefing other than A5-H-01 (donations are strictly
attacker-funded); `refreshBoost`'s missing `nonReentrant` (oracle `getPrice` is `view` →
staticcall — worth pinning with a comment if the interface ever changes); index truncation
griefing (PRECISION scaling bounds losses to dust at 18-decimal parameters).
