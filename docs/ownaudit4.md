# Own Protocol v2 — Audit Report & Remediation Status (Pass 4 — eUSD CDP Module)

**Branch:** `stablecoin` · **Last updated:** 2026-09-01 · **Test suite:** 1327 passing (105 new for this module)

This pass is **scoped to the new eUSD CDP module** (EUSDManager + EUSD token) introduced on the
`stablecoin` branch; it does not re-tread the protocol-wide ground covered by `audit-report-3.md`,
whose findings and IDs remain canonical for the rest of the codebase. IDs are stable across
passes: `A4-` items below are never renumbered or reused, and any later pass that re-surfaces one
reopens the existing ID. Headline shape of the findings: the module's accounting, access control,
list integrity, and rounding all held under a 12-agent adversarial review; every substantive
issue clusters around **one asymmetry in the redemption path** — `liquidate` fully clears a
position when the collateral cap fires, `_redeemFrom` does not — plus a set of configuration /
semantics checks at the oracle and governance seams. No changes to existing contracts were in
scope or required.

```
Scope (2 files, ~560 LOC)
src/core/EUSDManager.sol
src/tokens/EUSD.sol

Excluded: all other src/ contracts (covered by audit-report-3.md), interfaces/, test/,
script/, lib/. Oracle (ChainlinkOracleVerifier) and ProtocolRegistry read only as
out-of-scope context for seam verification.
```

---

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 0     | —     | —    | —         |
| High     | 1     | 0     | 1    | 0         |
| Medium   | 1     | 0     | 1    | 0         |
| Low      | 7     | 0     | 6    | 1         |
| Info     | 4     | 0     | 0    | 4 (noted) |

| ID      | Severity | Finding                                                                  | Status                       |
| ------- | -------- | ------------------------------------------------------------------------ | ---------------------------- |
| A4-H-01 | High     | Partial redemption of underwater position strands unbacked debt at head  | **Open**                     |
| A4-M-01 | Medium   | Redemption cannot skip an underwater head — peg anchor stalls            | **Open**                     |
| A4-L-01 | Low      | `mintPriceMaxAge` is a no-op inside the oracle's `clFreshWindow`         | **Open**                     |
| A4-L-02 | Low      | Sorted-list ordering drifts under lazy stability-fee accrual             | **Open**                     |
| A4-L-03 | Low      | No `minDebt` floor on the redemption path                                | **By design** — documented   |
| A4-L-04 | Low      | Oracle `maxAnchorAge` width vs liquidation bonus unverified              | **Open** (ops check)         |
| A4-L-05 | Low      | `setRiskParams` threshold raise assumes ADMIN sits behind the timelock   | **Open** (ops check)         |
| A4-L-06 | Low      | ADMIN/OPERATOR role namespace is protocol-global, not per-contract       | **Open** (confirm intent)    |
| A4-L-07 | Low      | `MINTER_ROLE` exclusivity not structurally enforced on EUSD              | **Open** (deploy-time assert)|
| A4-I-01 | Info     | `_freshPrice` tolerates future-dated timestamps                          | **By design** — noted        |
| A4-I-02 | Info     | Fee rounds to zero but `feeIndexSnapshot` still advances                 | **By design** — noted        |
| A4-I-03 | Info     | Zero-fee redemption (no Liquity-style base rate)                         | **By design** — noted        |
| A4-I-04 | Info     | `debt * (BPS + bonus)` computed outside `mulDiv`'s 512-bit space         | **By design** — noted        |

---

## 1. Fixed Findings

None yet — this is the initial pass for the module.

---

## 2. Open Findings

### A4-H-01 (High) — Redemption retires more debt than the collateral it seizes, stranding an unbacked zero-collateral position at the list head

**Problem.** `EUSDManager._redeemFrom` caps `seized` at `p.collateral` but subtracts the full
`repaid` from `p.debt`. Partially redeeming an underwater position therefore leaves
`debt > 0, collateral == 0`. The surviving node is re-sorted via `_reindex → _insertNode`, whose
key is `mulDiv(p.collateral, PRECISION, p.debt) = 0` — the minimum — so it is pinned permanently
at `listHead`. Every subsequent `redeem` must consume the head first: `seized` caps at `0`, so the
redeemer burns eUSD for zero collateral, and any redeemer with a non-zero `minCollateralOut`
reverts `SlippageExceeded` and cannot redeem at all. `liquidate` cannot clear it either (burn full
debt for zero collateral — a pure loss no keeper takes), and the owner has no incentive to
`closePosition` (burn debt to recover nothing). The residual is unbacked eUSD counted in
`totalDebt`. Contrast `liquidate`, which handles the same collateral cap by clearing the **full**
debt — that asymmetry is the root cause. Note also that `minCollateralOut` is token-denominated,
not value-denominated, so the creating redeemer's slippage guard does not fire on the value loss.

Worked case (deployed-style params, MCR 150%, threshold 130%): position `coll = 2 eSPY`,
`debt = 1000 eUSD`, minted at $750 (CR 150%). Price gaps to $400 → collateral worth $800 < debt
(underwater; liquidation already unprofitable). Redeemer burns 600 eUSD:
`repaid = 600e18`, `seized = 600e18·1e18/400e18 = 1.5e18` — fine; but a second redeemer burning
600 eUSD against the remaining `coll = 0.5e18, debt = 400e18`… `repaid = 400e18`,
`seized = 1e18 → capped to 0.5e18`; position ends `debt = 0? no — with repaid = 400e18 the debt
clears`. The zombie arises when `repaid < p.debt` at the cap: first redeemer burns **500** eUSD
instead → `seized = 1.25e18 → capped to 2e18? no, 1.25 < 2` … the general reachable case:
`amount ∈ [collValue, debt)`. E.g. redeem `800 eUSD`: `seized = 2e18` (capped exactly),
`p.debt = 200e18`, `p.collateral = 0` → reinserted at head with ratio 0. The next 200 eUSD of
*every* future redemption is a pure toll, or a hard revert under slippage protection. An attacker
can manufacture this deliberately at fair-value cost (they redeem at par; the toll lands on
everyone after them).

**Suggested fix (Option A — cap `repaid` to the collateral-backed value and retire the node):**

```diff
         repaid = maxAmount > p.debt ? p.debt : maxAmount;
         seized = Math.mulDiv(repaid, PRECISION, price);
-        if (seized > p.collateral) seized = p.collateral;
+        if (seized > p.collateral) {
+            // Underwater: redeem only the collateral-backed portion; the
+            // unbacked residual is liquidation/backstop territory and the
+            // exhausted node must not re-enter the list.
+            seized = p.collateral;
+            repaid = Math.mulDiv(seized, price, PRECISION);
+        }
         ...
-        if (p.debt == 0) {
+        if (p.debt == 0 || p.collateral == 0) {
             _removeNode(collateral, owner);
```

Preserves `eusd.totalSupply() == totalDebt` exactly; the unbacked residual stays on the books,
off-list, attributable, and clearable by repay/close/liquidation-at-a-loss or a future backstop.
The redeemer is never over-charged, so `minCollateralOut` regains its meaning.

**Suggested fix (Option B — realize the residual as bad debt):**

```diff
         if (p.debt == 0) {
             _removeNode(collateral, owner);
             if (p.collateral == 0) delete _positions[collateral][owner];
+        } else if (p.collateral == 0) {
+            badDebt += p.debt;
+            totalDebt -= p.debt;
+            _removeNode(collateral, owner);
+            delete _positions[collateral][owner];
         } else {
```

Requires redefining the supply invariant to `totalSupply == totalDebt + badDebt` (or a
treasury-funded burn) — a conscious accounting decision, not a drop-in.

**Tests.** `test_redeem_underwaterHead_capsSeizure` covers the full-consumption case only; **no
regression test yet exercises the partial-consumption zombie path** (`amount` strictly between
collateral value and debt, then a second redemption). Add one alongside the fix, plus an
invariant: no listed node with `collateral == 0`.

**Residual.** Even after Option A, a *near*-zero-collateral underwater head still short-changes
redeemers (see A4-M-01) — Option A removes the toll booth but not the stall.

**Overlaps.** A4-L-03 (missing `minDebt` floor) is the enabling half; Option A supersedes the
need for a floor on this path. A4-M-01 is the non-degenerate sibling.

**Detected by** 8 of 12 agents (math-precision, execution-trace, periphery, asymmetry, boundary,
numerical-gap as findings; trust-gap, first-principles as leads).

### A4-M-01 (Medium) — Redemption cannot skip an underwater head, so the peg anchor stalls exactly when liquidation is unprofitable

**Problem.** `redeem` consumes strictly from `listHead` with no skip mechanism. Any head with
CR < 100% short-changes redeemers; a redeemer protecting themselves with an accurate
`minCollateralOut` always reverts and cannot reach healthy positions behind the head. This bites
precisely in the crash regime where liquidating that head (CR < 100% + bonus = 105%) is also
loss-making, so no rational actor clears the blockage and the peg-defense path is inert while
eUSD trades below par. The interface documents the short-change ("protect with
`minCollateralOut`") but not the resulting blocking behavior.

**Suggested fix.** Decision needed rather than a mechanical patch — options, roughly in order of
preference: (a) accept and document explicitly, relying on the 130%→105% band making
liquidation profitable well before heads go underwater (the gap only jumps it on extreme
closed-market moves); (b) let `redeem` take a `startHint` that may skip positions with
CR < 100% (skipped heads remain liquidation targets); (c) add a backstop/insurance path that
clears sub-100% heads. Option (b) is small and keeps riskiest-first semantics for all solvent
positions.

**Tests.** None currently assert redemption behavior with an underwater head *ahead of* healthy
positions under a non-zero `minCollateralOut`.

**Overlaps.** Worst case (CR = 0) is A4-H-01; fixing H-01 does not resolve this.

**Detected by** 4 of 12 agents (economic-security, execution-trace, periphery, trust-gap).

### A4-L-01 (Low) — `mintPriceMaxAge` is silently a no-op while a Chainlink answer is inside `clFreshWindow`

**Problem.** `ChainlinkOracleVerifier.getPrice` reports `block.timestamp` as the price timestamp
whenever the feed answer is younger than `clFreshWindow` (4h in the documented config), so
`_freshPrice`'s `block.timestamp > ts + maxAge` bound can never fire in that window: a 5-minute
`mintPriceMaxAge` actually admits prices up to `clFreshWindow` old. Exposure is bounded — the
feed's 0.5% deviation trigger while live, and the 150%/130% closed-market buffer for the first
`clFreshWindow` hours after close — and the semantics are protocol-wide (PSM and BorrowManager
consume the same reads). The defect is that the admin-facing knob does not mean what it appears
to mean.

**Suggested fix.** Either document on `setMintPriceMaxAge` that the effective bound is
`max(mintPriceMaxAge, oracle clFreshWindow)` for the Chainlink leg, or expose the raw observation
timestamp from the oracle and bound against that. No change if the current semantics are
confirmed as intended.

**Detected by** 1 of 12 agents (first-principles).

### A4-L-02 (Low) — Sorted-list ordering drifts from true risk under lazy fee accrual

**Problem.** The list is keyed on *stored* `collateral/debt`; `_accrue` folds pending stability
fees into a position's debt only when that position is touched and never re-sorts neighbors, so
`_insertNode` compares fee-inclusive against fee-stale debts. A borrower who never touches their
position keeps its debt understated, drifts tailward, and preferentially dodges redemption onto
freshly-touched equal-risk positions. Drift is bounded by `stabilityFeeBps × elapsed` (≈2%/yr at
launch params); redemption still pays par, so this is fairness/ordering only. Acknowledged in the
interface NatSpec ("bounded by the stability fee rate").

**Suggested fix.** Sort on fee-invariant principal (exclude accrued fees from the ordering key),
or accept and keep the fee low. Revisit before ever raising `stabilityFeeBps` materially.

**Detected by** 6 of 12 agents (invariant, first-principles, asymmetry, boundary, numerical-gap,
flow-gap) — all as leads; no fund-loss path completed.

### A4-L-04 / A4-L-05 / A4-L-06 / A4-L-07 (Low, ops) — configuration & wiring checks

- **A4-L-04.** Verify on the deployed oracle config that `maxAnchorAge` (anchor usability window
  used by the stale-tolerant exit paths) cannot span a price move larger than
  `liquidationBonusBps` in normal regimes, or a keeper can over-seize on a stale-low tick. Also
  noted: a *total* oracle outage freezes liquidation and redemption together (repay/close still
  work) — standard dependency, monitor it.
- **A4-L-05.** `setRiskParams` can raise `liquidationThresholdBps` and instantly expose the
  reclassified band to permissionless bonus-paying liquidation. Benign iff the registry ADMIN
  role actually sits behind the timelock — verify the wiring on-chain before launch.
- **A4-L-06.** `onlyAdmin`/`onlyOperator` resolve protocol-global `keccak256("ADMIN")`/
  `keccak256("OPERATOR")` (consistent with ChainlinkOracleVerifier et al.). Confirm this matches
  the intended access-control scoping for the module.
- **A4-L-07.** The `totalSupply == totalDebt` invariant assumes EUSDManager is the *sole*
  `MINTER_ROLE` holder; the token cannot structurally enforce it. Add a deploy-time assertion
  (exactly one role member = the manager) to `DeployEusdRobinhood.s.sol` and to monitoring.

---

## 3. By-Design / Withdrawn

- **A4-L-03 — No `minDebt` floor on redemption.** Explicitly documented in `IEUSDManager`
  ("a partial redemption may leave the last position below minDebt"); Liquity-class behavior.
  Impact is dust-position list bloat only. A4-H-01 Option A removes the only harmful instance
  (the zero-collateral case). Decision: accepted.
- **A4-I-01 — Future-dated timestamp tolerance in `_freshPrice`.** Deliberate (`if
  (block.timestamp > ts + maxAge)` avoids underflow); both oracle legs already reject or clamp
  future timestamps. Defense-in-depth only.
- **A4-I-02 — Fee truncates to zero but snapshot advances.** Sub-wei-per-touch treasury dust at
  realistic debts (minDebt floor makes it unreachable in practice). Accepted.
- **A4-I-03 — Zero-fee redemption.** Consistent with the protocol decision to drop fee
  machinery from the roadmap; redeemed borrowers receive fair value. Churn-dampening (Liquity
  base rate) can be added later if redemption volume warrants it.
- **A4-I-04 — `debt * (BPS + bonus)` outside `mulDiv`'s 512-bit space.** Overflow requires
  debt ≈ 1.77e72 (1.77e54 eUSD). Not reachable; accepted.

---

## 4. Low Findings

Covered above as A4-L-01 … A4-L-07 (this pass keeps low write-ups inline in §2/§3 given the
module scope; statuses in the master index are authoritative).

---

## 5. Leads

**Redemption economics**

- Underwater-head incentive stall (economic-security): both the redemption and liquidation paths
  become loss-making on the same position simultaneously — the classic Liquity bad-debt
  assumption. Tracked via A4-M-01.

**Noted, no action**

- Token-denominated (not value-denominated) `minCollateralOut` — behaves correctly once A4-H-01
  Option A caps `repaid`; revisit only if Option B is chosen.
- Sub-`minDebt` dust nodes as a gas-griefing surface during mass redemption — bounded by the
  attacker paying par to create them.

---

## 6. Migration / ops checklist (open)

- [ ] A4-H-01 — implement Option A (or decide Option B accounting), add partial-underwater
      regression test + "no listed node with zero collateral" invariant, re-run full suite.
- [ ] A4-M-01 — decide accept/skip-hint/backstop for underwater heads; document the decision in
      the interface NatSpec either way.
- [ ] A4-L-01 — confirm intended freshness semantics; document effective bound on
      `setMintPriceMaxAge` or add a strict-timestamp oracle read.
- [ ] A4-L-04 — check deployed `maxAnchorAge` vs `liquidationBonusBps` on Robinhood config.
- [ ] A4-L-05 — verify registry ADMIN grant for EUSDManager is timelock-gated before launch.
- [ ] A4-L-06 — confirm global-role scoping is intended for this module.
- [ ] A4-L-07 — add deploy-time sole-minter assertion to `DeployEusdRobinhood.s.sol`; assert
      registry `TREASURY` is non-zero before first mint (fee accrual mints there).

---

## 7. Verified sound (no finding)

Attacked and held, across 12 independent adversarial agents:

- **Conservation:** `eusd.totalSupply() == totalDebt == Σ stored position debt` on every path
  (mint, repay, close, liquidate, redeem, fee accrual — treasury fee-mint pairs exactly with
  `totalDebt += fee`). `totalCollateral[c] == Σ position collateral == token balance`.
- **Sorted-list integrity:** attacker-supplied `hint`s cannot corrupt ordering (placement is
  always re-validated by the forward walk; stale/self/unlisted hints are ignored);
  `debt > 0 ⟺ listed` holds across all mutators; `listSize`/link consistency verified.
- **Access control:** every state-changer correctly gated; no storage written by both guarded and
  unguarded paths; no initializer surface (non-upgradeable); `EUSD.burn` is allowance-free but
  every call site burns only from `msg.sender` — no confused-deputy path.
- **Rounding:** all floors favor the protocol/counterparty (`_ratioBps`, redemption `seized`,
  liquidation `seized`, fee accrual); no attacker-favorable rounding, no zero-rounding extraction.
- **Reentrancy/CEI:** `nonReentrant` on all token-moving entry points; only trusted no-hook
  tokens (eUSD, validated 18-dec eTokens) are called; no fee-on-transfer surface exists.
- **Liquidation solvency at threshold:** `_validateRatios` (`mcr ≥ threshold ≥ BPS + bonus`)
  guarantees fresh mints are never instantly liquidatable and threshold liquidations are solvent;
  self-liquidation extracts no bonus.
- **Fee-rate changes:** `setStabilityFee` settles the global index at the old rate first — no
  retroactive repricing.
- **Oracle scale/replay:** 18-dec price consumption matches OwnMarket's pattern; exits'
  stale-anchor tolerance is hard-bounded by the oracle's own `maxAnchorAge`/`inhouseMaxStaleness`
  (consistent with the PSM freshness design, which is intentional and previously adjudicated).

---

## 8. Verification notes

- Methodology: 12 parallel adversarial agents (math-precision, access-control,
  economic-security, execution-trace, invariant, periphery, first-principles, asymmetry,
  boundary + 3 cross-lens gap-hunters) over the 2-file scope, followed by dedup and a four-gate
  validation pass (execution / reachability / trigger / impact). A4-H-01 had 8-agent
  convergence; A4-L-02 had 6; single-agent items were gate-checked individually.
- Trap for future passes: the interface NatSpec documents the *short-change* on underwater
  redemption but not the *persistence* of the drained node — do not mistake the documented
  trade-off for coverage of A4-H-01.
- Severity here is impact × likelihood and is stated independently of the report's confidence
  scores; A4-L-04/L-05 escalate to Medium if the respective config checks fail.
- Rate configuration-dependent items against the deployed Robinhood config
  (`broadcast/…/run-latest.json`), not `script/` alone, once the module ships.
