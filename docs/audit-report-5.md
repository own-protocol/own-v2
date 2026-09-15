# Own Protocol v2 — Audit Report & Remediation Status (Pass 5)

**Branch:** `OwnStakingV2` · **Last updated:** 2026-09-15

Multi-agent audit (solidity-auditor, 12-agent pipeline — 9 specialty attackers + 3 gap-hunters) of
the contracts added on this branch, plus a differential review of the `EUSDManager` additions.
IDs are stable across passes; `A5-` items are new in this pass. No finding in this pass overlaps or
reopens an earlier ID — both audited contracts are new to the codebase.

### Scope

```
core/OwnStakingV2.sol        periphery/OwnStakeZap.sol
core/EUSDManager.sol (diff vs main: stakeZap wiring, depositFor/mintFor, setStakeZap)
```

---

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 0     | 0     | 0    | —         |
| High     | 0     | 0     | 0    | —         |
| Medium   | 2     | 2     | 0    | —         |
| Low      | 2     | 2     | 0    | —         |
| Info     | 1     | 0     | 0    | 1         |

| ID      | Severity | Finding                                                                 | Status    |
| ------- | -------- | ----------------------------------------------------------------------- | --------- |
| A5-M-01 | Medium   | Permissionless `syncRewards` dilutes the reward stream with 1-wei dust  | Fixed     |
| A5-M-02 | Medium   | eUSD donation to the zap DoSes smaller `rebalance` calls                 | Fixed     |
| A5-L-01 | Low      | Third-party boost flooring during oracle outage redistributes rewards    | Fixed     |
| A5-L-02 | Low      | Permitted 100% swap split in `stakeFromSpy` always reverts               | Fixed     |
| A5-I-01 | Info     | `mintFor` grants the zap standing debt-creation power over any position  | By design |

---

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
- **Ops notes**: the zap has no rescue function ($MONEY or other tokens sent by mistake are
  stranded); the initializer-pinned `_collateral` bricks the zap's CDP entries after an OwnMarket
  re-denomination until upgraded; `_updateGlobal` index truncation dust is economically nil at
  18-decimal parameters.

## Attacked and held

Weight bookkeeping (`totalWeight == Σ eusdStaked·boostBps/BPS`, exact under truncation on every
path); zero-weight banking to `undistributed` with no first-staker sweep or renotify double-count;
`_accountedRewards ≥ Σ owed` (all rounding protocol-favoring); flash-boost defeated by re-snapshot
on every touch; the zap's swap leg confined to the caller's own in-flight slice (JIT exact
allowance, delta + non-zero `minMoneyOut`, `nonReentrant`, standing approvals unreachable from
router context); every on-behalf surface keys on `msg.sender`; `repay` burns from the caller by
authority (no allowance needed); non-upgradeable ReentrancyGuard behind the UUPS proxies benign.
