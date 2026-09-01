# Own Protocol v2 — Audit Report & Remediation Status (Pass 4 — eUSD CDP Module)

**Branch:** `stablecoin` · **Last updated:** 2026-09-01 · **Test suite:** 1327 passing (105 new for this module)

This pass is **scoped to the new eUSD CDP module** (EUSDManager + EUSD token) introduced on the
`stablecoin` branch; it does not re-tread the protocol-wide ground covered by `audit-report-3.md`,
whose findings and IDs remain canonical for the rest of the codebase. IDs are stable across
passes: `A4-` items below are never renumbered or reused, and any later pass that re-surfaces one
reopens the existing ID. Headline shape of the findings: the module's accounting, access control,
list integrity, and rounding all held under a 12-agent adversarial review; the substantive issues
fall into two clusters — **(1) an asymmetry in the redemption path** (`liquidate` fully clears a
position when the collateral cap fires, `_redeemFrom` does not) and **(2) a collateral-valuation
gap at the corporate-action seam** (`A4-H-02`, added in the re-review below): the module prices
collateral by ticker while custodying a fixed token address and has no split/migration hook, so a
routine stock split silently mis-values every position — plus a set of configuration / semantics
checks at the oracle and governance seams. The `A4-H-02` fix touches `EUSDManager` (in scope); its
alternative coordination option touches `AssetRegistry.migrateToken` (out of the original 2-file
scope), so the split seam is now treated as in-scope for this module.

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
| High     | 2     | 0     | 2    | 0         |
| Medium   | 1     | 0     | 1    | 0         |
| Low      | 8     | 0     | 7    | 1         |
| Info     | 5     | 0     | 0    | 5 (noted) |

| ID      | Severity | Finding                                                                  | Status                       |
| ------- | -------- | ------------------------------------------------------------------------ | ---------------------------- |
| A4-H-01 | High     | Partial redemption of underwater position strands unbacked debt at head  | **Open**                     |
| A4-H-02 | High     | Stock split re-denomination silently mis-values all eUSD collateral      | **Open**                     |
| A4-M-01 | Medium   | Redemption cannot skip an underwater head — peg anchor stalls            | **Open**                     |
| A4-L-01 | Low      | `mintPriceMaxAge` is a no-op inside the oracle's `clFreshWindow`         | **Open**                     |
| A4-L-02 | Low      | Sorted-list ordering drifts under lazy stability-fee accrual             | **Open**                     |
| A4-L-03 | Low      | No `minDebt` floor on the redemption path                                | **By design** — documented   |
| A4-L-04 | Low      | Oracle `maxAnchorAge` width vs liquidation bonus unverified              | **Open** (ops check)         |
| A4-L-05 | Low      | `setRiskParams` threshold raise assumes ADMIN sits behind the timelock   | **Open** (ops check)         |
| A4-L-06 | Low      | ADMIN/OPERATOR role namespace is protocol-global, not per-contract       | **Open** (confirm intent)    |
| A4-L-07 | Low      | `MINTER_ROLE` exclusivity not structurally enforced on EUSD              | **Open** (deploy-time assert)|
| A4-L-08 | Low      | eToken collateral dividends stranded in the manager (no claim path)      | **Open** (confirm reward model)|
| A4-I-01 | Info     | `_freshPrice` tolerates future-dated timestamps                          | **By design** — noted        |
| A4-I-02 | Info     | Fee rounds to zero but `feeIndexSnapshot` still advances                 | **By design** — noted        |
| A4-I-03 | Info     | Zero-fee redemption (no Liquity-style base rate)                         | **By design** — noted        |
| A4-I-04 | Info     | `debt * (BPS + bonus)` computed outside `mulDiv`'s 512-bit space         | **By design** — noted        |
| A4-I-05 | Info     | `EUSD.crosschainBurn` burns from an arbitrary `from` (trusted-bridge)    | **By design** — noted        |

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

### A4-H-02 (High) — A routine stock split silently mis-values every eUSD position by the split ratio

**Problem.** `EUSDManager` custodies collateral as a fixed **token address** balance
(`_positions[collateral][owner].collateral`, keyed by address; `_collateralConfigs[collateral]`
stores only `{ticker, enabled, exists}`) but values it by **ticker**: every ratio and seizure
computation runs `_ratioBps(coll, debt, price)` where `price = _oracle(cfg.ticker).getPrice(ticker)`
(`EUSDManager.sol:535–537`, call sites at `153`, `177`, `243/244`, `277`, `581/582`). It multiplies
the raw stored unit count by the **per-active-unit** ticker price and applies **no** legacy-ratio
factor. The module references none of `legacyRatioToActive` / `applySplit` / `getActiveToken` /
`convertLegacy` (verified: grep returns nothing) and has no split/migration hook.

When the admin performs a supported corporate action —
`AssetRegistry.migrateToken(ticker, newToken, ratio)` (`AssetRegistry.sol:127`) — the deposited
token becomes **legacy** (`_legacyRatio[oldToken] = ratio`, `:148`; `legacyRatioToActive(oldToken)`
now returns `ratio`), a new active token is installed, and `VaultManager.applySplit` atomically
re-denominates the internal mark (`_assetMark = mark·PRECISION/ratio`, `VaultManager.sol:432`). The
external price feed for the instrument (real split-adjusted SPY) reports the new per-active-unit
price. `migrateToken` is blocked only while the asset is **halted** (`:131`), *not* while open eUSD
positions reference the ticker, and `isValidToken(ticker, oldToken)` keeps returning `true` for the
legacy token (`:368–374`), so every existing position keeps operating — silently mispriced by
`ratio`. The position cannot self-heal: the legacy eToken is locked in the manager, and the manager
exposes no ratio-adjust / migrate / convert entry point.

Worked case (deployed-style params: MCR 150%, threshold 130%, bonus 5%). Position `coll = 2 eSPY`
(token `T0`), `debt = 800 eUSD`, minted at $600/share → value $1200, CR 150%. Admin runs a **2:1**
forward split: `migrateToken("SPY", T1, 2e18)`; the feed now reports $300 per new share; the
borrower still holds `2 T0` = `4 T1` = **$1200 true value**. `_ratioBps(2e18, 800e18, 300e18) =
mulDiv(mulDiv(2e18, 300e18, 1e18), 10000, 800e18) = mulDiv(600e18, 10000, 800e18) = 7500 bps` →
**75%** < 130% threshold, so a genuinely 150%-collateralized position is now liquidatable. Any
keeper `liquidate`s: `seized = mulDiv(800e18·10500, 1e18, 300e18·10000) = 2.8e18`, capped to
`p.collateral = 2e18` → burns 800 eUSD, receives `2 T0` (= `4 T1` = **$1200**) for **$800**, a
**+$400 (50%)** profit; the borrower loses their entire collateral including the full MCR buffer. A
**reverse** split inverts it: `_ratioBps` *over*-values the position by `ratio`, so the owner can
withdraw collateral or mint fresh eUSD against phantom backing → uncollateralized supply / bad debt.

The admin action is legitimate (a real corporate action the protocol explicitly supports); the
harm is realized by an **unprivileged amplifier** — any keeper (forward split) or the position
owner (reverse split) — the moment the split lands, so it clears the admin-action gate.

**Suggested fix (Option A — value legacy collateral through its active ratio):**

```diff
-        uint256 ratio = _ratioBps(p.collateral, p.debt, _freshPrice(cfg.ticker));
+        uint256 ratio = _ratioBps(_activeUnits(collateral, p.collateral), p.debt, _freshPrice(cfg.ticker));
```

```diff
+    /// @dev Rescale a stored (possibly legacy) collateral balance to active-token units so
+    ///      ticker-priced valuation stays correct across splits. Active token → legacyRatio 0 → identity.
+    function _activeUnits(address collateral, uint256 amount) private view returns (uint256) {
+        uint256 r = IAssetRegistry(registry.assetRegistry()).legacyRatioToActive(collateral);
+        return r == 0 ? amount : Math.mulDiv(amount, r, PRECISION);
+    }
```

Apply `_activeUnits` at every valuation/seizure site (`mint`, `withdrawCollateral`, `liquidate`,
`redeem`/`_redeemFrom`, `collateralRatioBps`). Note the seizure/transfer amount must stay in
**legacy-token** units for the `safeTransfer` while only the **value** math uses active units — so
scale the value inputs, not the transferred `seized` amount.

**Suggested fix (Option B — coordinate the split with the module):**

```diff
     // AssetRegistry.migrateToken, for any ticker with open eUSD positions:
+    // block migration while positions exist, OR notify the manager to atomically
+    // convertLegacy its held balance and rescale _positions[].collateral + totalCollateral by `ratio`,
+    // re-keying the config to the new active token.
+    if (address(eusdManager) != address(0) && eusdManager.hasOpenPositions(ticker)) {
+        eusdManager.onSplit(ticker, oldToken, newToken, ratio);
+    }
```

Option A is the smaller, self-contained change (no cross-contract callback, keeps the held balance
as legacy tokens and just values them correctly) and is preferred; Option B keeps stored collateral
in active-token units but requires an `onSplit` hook and re-keying, and touches `AssetRegistry`
(outside the original module scope).

**Tests.** No current test exercises a `migrateToken`/`applySplit` while an eUSD position is open.
Add: (a) forward-split → previously-healthy position must **not** become liquidatable; (b)
reverse-split → `withdrawCollateral`/`mint` must not admit phantom collateral; (c) an invariant
that a position's computed USD collateral value is split-invariant across a `migrateToken`.

**Overlaps.** Independent of the redemption cluster (A4-H-01 / A4-M-01 / A4-L-03); shares no code
path. The original Pass-4 scope (2 files, `AssetRegistry`/`VaultManager` read-only) is why this seam
was not covered — the defect nonetheless lives in `EUSDManager`'s valuation.

**Detected by** 3 of 12 agents (invariant, first-principles, flow-gap) — all as findings, with
matching numeric traces; re-review verified the mechanism directly against source.

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

### A4-L-08 (Low) — eToken collateral dividends accrue to the manager with no claim path

**Problem.** Collateral is protocol eTokens, which are dividend/reward-bearing (they expose
`claimableRewards` / `claimRewards` / `rewardToken`, and `OwnMarket.sweepDividends` claims them on
escrowed eTokens). While an eToken sits as CDP collateral, its dividends accrue to the
`EUSDManager` address (the current holder), but the manager has **no** claim, forward, or admin
sweep path — so that yield is stranded in the manager for the life of every loan, with no recovery
route. Depositors silently forfeit the dividend stream they would earn holding the eToken directly
(an asymmetry vs. the analogous `OwnMarket` escrow path, which *does* implement `sweepDividends`).
Value leak to depositors, no theft vector. If the reward model turns out to be **rebasing** rather
than claim-based, the impact is different and worse: `totalCollateral[c]` (updated only on
deposit/withdraw) would desync from the manager's real token balance — worth confirming.

**Suggested fix.** Add a permissioned `claimCollateralRewards(collateral)` that calls the eToken's
`claimRewards` and forwards the `rewardToken` to a fair destination (per-position accounting, or a
treasury/insurance sink by policy), mirroring `OwnMarket.sweepDividends`. First confirm the eSPY
reward mechanism (claimable vs. rebasing) — the reward-token source is out of this module's scope.

**Detected by** 4 of 12 agents (periphery, first-principles, invariant, trust-gap) — all as leads;
depends on the eToken reward model, which was not in the review bundle.

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
- **A4-I-05 — `EUSD.crosschainBurn(from, amount)` burns from an arbitrary `from`.** The call is
  allowance-free and consent-free: authorization is solely the caller's per-bridge burn rate limit
  (`_consumeLimit(false, amount)`), so any admin-authorized bridge can destroy any holder's eUSD up
  to its per-window `burnMaxLimit`. This is the standard xERC20 / ERC-7802 trusted-bridge model —
  admin-gated `setBridgeLimits`, rate-limited, and launch-disabled (`maxNetBridgedIn = 0`, no bridge
  limits set) — so it is accepted as-is; flagged so the bridge-trust assumption is explicit and
  re-reviewed whenever a transport is authorized. **Note:** the NatSpec claim that "a bridge only
  burns from the user who asked it to bridge" is an off-chain trust assumption, *not* an on-chain
  guarantee — correct the wording or move to a user-signed / allowance-gated burn if third-party
  burn is not intended. Distinct from the plain `EUSD.burn`, which is `msg.sender`-only (see §7).

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
- [ ] A4-H-02 — implement Option A (`_activeUnits` scaling at all valuation/seizure sites) or
      decide Option B (`onSplit` hook / block-migration-with-open-positions); add forward- and
      reverse-split regression tests + a split-invariant-value invariant; re-run full suite.
      **Treat as a launch blocker for using any split-eligible eToken as eUSD collateral.**
- [ ] A4-M-01 — decide accept/skip-hint/backstop for underwater heads; document the decision in
      the interface NatSpec either way.
- [ ] A4-L-01 — confirm intended freshness semantics; document effective bound on
      `setMintPriceMaxAge` or add a strict-timestamp oracle read.
- [ ] A4-L-04 — check deployed `maxAnchorAge` vs `liquidationBonusBps` on Robinhood config.
- [ ] A4-L-05 — verify registry ADMIN grant for EUSDManager is timelock-gated before launch.
- [ ] A4-L-06 — confirm global-role scoping is intended for this module.
- [ ] A4-L-07 — add deploy-time sole-minter assertion to `DeployEusdRobinhood.s.sol`; assert
      registry `TREASURY` is non-zero before first mint (fee accrual mints there).
- [ ] A4-L-08 — confirm the eSPY eToken reward model (claimable vs. rebasing); if claimable, add a
      permissioned `claimCollateralRewards` mirroring `OwnMarket.sweepDividends`; if rebasing,
      additionally reconcile `totalCollateral` against real balance.

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
  unguarded paths; no initializer surface (non-upgradeable). The plain `EUSD.burn` is allowance-free
  but burns only from `msg.sender` — no confused-deputy path. (The separate
  `EUSD.crosschainBurn(from, …)` *does* burn from an arbitrary account under the trusted-bridge
  model — see A4-I-05; not covered by this line.)
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
- Re-review addendum (same date): A4-H-02, A4-L-08, and A4-I-05 were added after a follow-up
  12-agent pass over the full branch diff (including the `OwnMarket` UUPS conversion and
  `ForceExecuteLib`, both cleared). A4-H-02 had 3-agent convergence with matching numeric traces
  and was additionally verified directly against `EUSDManager`/`AssetRegistry`/`VaultManager`
  source (the `migrateToken`/`applySplit` seam sits outside the original 2-file scope, which is why
  the initial pass did not reach it). The `OwnMarket` UUPS/EIP-712/`ReentrancyGuard`-behind-proxy
  setup and the `ForceExecuteLib` delegatecall extraction were traced and found sound.
- Trap for future passes: the interface NatSpec documents the *short-change* on underwater
  redemption but not the *persistence* of the drained node — do not mistake the documented
  trade-off for coverage of A4-H-01.
- Severity here is impact × likelihood and is stated independently of the report's confidence
  scores; A4-L-04/L-05 escalate to Medium if the respective config checks fail.
- Rate configuration-dependent items against the deployed Robinhood config
  (`broadcast/…/run-latest.json`), not `script/` alone, once the module ships.
