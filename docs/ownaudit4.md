# Own Protocol v2 — Audit Report & Remediation Status (Pass 4 — eUSD CDP Module)

**Branch:** `stablecoin` · **Last updated:** 2026-09-02 · **Test suite:** 1430 passing excl. fork suites (+2 for A4-M-06; +42 across the H-01 / H-02 / M-02 / M-03 / M-04, L-08 / L-10 / L-11 / L-12 / L-13 / L-14 and I-09 / I-10 fixes)

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
checks at the oracle and governance seams. **Round 3 (2026-09-02, both scopes re-run) adds three
Mediums:** `A4-M-06` (partial liquidation below 1 + bonus manufactures unbacked eUSD — **fixed** same day, Option A);
`A4-M-07` and `A4-M-08` were raised as Mediums but **reassessed to Low and acknowledged** (M-07 self-corrects
on the next `accrue`; M-08's unclaimed-premium backlog is realized continuously by ordinary LP activity, so
nothing sizeable accumulates to capture). It also reopened `A4-L-12` (the clamp fix had opened a share-capture leg — **re-fixed** 2026-09-03 by gating entries while under-collateralised) and added `A4-L-19` (the PSM ratio's compromised-signer damage bound is ≈2× the band and the jump guard is walkable — **acknowledged**, fix folded into the next oracle/PSM deploy), and corrects three §6 ledger entries. The `A4-H-02` fix touches `EUSDManager` (in scope); its
alternative coordination option touches `AssetRegistry.migrateToken` (out of the original 2-file
scope), so the split seam is now treated as in-scope for this module.

```
Scope (original pass: 2 files, ~560 LOC)
src/core/EUSDManager.sol
src/tokens/EUSD.sol

Staking addendum (2026-09-02): + src/tokens/StakedEUSD.sol, src/core/OwnIncentives.sol,
and the EUSDManager/EUSD deltas since commit c10c9fd (UUPS conversion, token rename).
Findings from that pass carry IDs A4-M-02, A4-L-09…L-12, A4-I-06…I-08.

Excluded: all other src/ contracts (covered by audit-report-3.md), interfaces/, test/,
script/, lib/. Oracle (ChainlinkOracleVerifier) and ProtocolRegistry read only as
out-of-scope context for seam verification.
```

---

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 0     | —     | —    | —         |
| High     | 2     | 2     | 0    | 0         |
| Medium   | 6     | 5     | 0    | 1         |
| Low      | 21    | 9     | 0    | 12        |
| Info     | 20    | 2     | 0    | 18 (noted)|

| ID      | Severity | Finding                                                                  | Status                       |
| ------- | -------- | ------------------------------------------------------------------------ | ---------------------------- |
| A4-H-01 | High     | Partial redemption of underwater position strands unbacked debt at head  | **Fixed** (2026-09-02)       |
| A4-H-02 | High     | Stock split re-denomination silently mis-values all eUSD collateral      | **Fixed** (2026-09-02)       |
| A4-M-01 | Medium   | Redemption cannot skip an underwater head — peg anchor stalls            | **Fixed** via A4-H-01        |
| A4-M-02 | Medium   | OwnIncentives pays retroactive OWN on balances from unhooked windows     | **Fixed** (2026-09-02)       |
| A4-M-03 | Medium   | Full-debt-only liquidation can be starved of eUSD liquidity (no partial) | **Fixed** (2026-09-02)       |
| A4-M-04 | Medium   | Halted collateral valued at live feed — unbacked mint above halt price   | **Fixed** (2026-09-02)       |
| A4-M-05 | Medium   | Force-execute on PSM-backed asset: vault LPs pay, maker collects surplus | **By design** — trusted maker; widened round 3 (self-quote) |
| A4-M-06 | Medium   | Partial liquidation below 1 + bonus seizes the full bonus — manufactures unbacked eUSD | **Fixed** (2026-09-02)       |
| A4-M-07 | Medium→Low | Window-open premium is caller-timed, but self-corrects on the next `accrue` | **Acknowledged** (reassessed 2026-09-03) |
| A4-M-08 | Medium→Low | JIT yield capture when the best-effort claim is blocked; backlog stays small under normal LP flow | **Acknowledged** (reassessed 2026-09-03) |
| A4-L-01 | Low      | `mintPriceMaxAge` is a no-op inside the oracle's `clFreshWindow`         | **Fixed** (docs, 2026-09-02) |
| A4-L-02 | Low      | Sorted-list ordering drifts under lazy stability-fee accrual             | **By design** — documented   |
| A4-L-03 | Low      | No `minDebt` floor on the redemption path                                | **By design** — documented   |
| A4-L-04 | Low      | Oracle `maxAnchorAge` width vs liquidation bonus unverified              | **By design** — stale-anchor exits |
| A4-L-05 | Low      | `setRiskParams` threshold raise assumes ADMIN sits behind the timelock   | **Acknowledged** — launch checklist |
| A4-L-06 | Low      | ADMIN/OPERATOR role namespace is protocol-global, not per-contract       | **By design** — protocol-wide |
| A4-L-07 | Low      | `MINTER_ROLE` exclusivity not structurally enforced on EUSD              | **Fixed** (script assert)    |
| A4-L-08 | Low      | eToken collateral dividends stranded in the manager (no claim path)      | **Fixed** (2026-09-02)       |
| A4-L-09 | Low      | `setPartner` + permissionless sweep can redirect any holder's accrued OWN| **Acknowledged** — ADMIN trust |
| A4-L-10 | Low      | Disabled collateral blocks defensive top-ups while liquidation stays live| **Fixed** (2026-09-02)       |
| A4-L-11 | Low      | sEUSD seed / `totalSupply > 0` before streaming unenforced — 0-share trap| **Fixed** (2026-09-02)       |
| A4-L-12 | Low      | Bridge `crosschainBurn` vs sEUSD vault: socialized loss + vault DoS; clamp then opened a share-capture leg | **Fixed** (2026-09-03) — entry gated while under-collateralised |
| A4-L-13 | Low      | Force-execution ignores `order.expiry` (reopens A3-L-03's expiry half)   | **Fixed** (2026-09-02)       |
| A4-L-14 | Low      | `withdrawCollateral` with debt escapes `mintPaused`/`enabled` levers     | **Fixed** (2026-09-02)       |
| A4-L-15 | Low      | Code-less incentivesController bricks sEUSD (try/catch ≠ extcodesize)    | **Fixed** with A4-M-02       |
| A4-L-16 | Low      | `haltAsset` price is operator-set, unbounded, and permanent              | **Acknowledged** — ops; VM immutable; widened round 3 (EUSDManager path) |
| A4-L-17 | Low      | Pending-deposit escrow counted as vault collateral by pool health gates  | **By design** — dup, accepted tail risk |
| A4-L-18 | Low      | Rate setters reprice the elapsed accrual window (no accrue-first)        | **Acknowledged** — no fix    |
| A4-L-19 | Low      | PSM ratio under signer compromise: damage ≈ 2× `bandBps`, jump guard walkable | **Acknowledged** (2026-09-03) — fix at next oracle/PSM deploy |
| A4-I-01 | Info     | `_freshPrice` tolerates future-dated timestamps                          | **By design** — noted        |
| A4-I-02 | Info     | Fee rounds to zero but `feeIndexSnapshot` still advances                 | **By design** — noted        |
| A4-I-03 | Info     | Zero-fee redemption (no Liquity-style base rate)                         | **By design** — noted        |
| A4-I-04 | Info     | `debt * (BPS + bonus)` computed outside `mulDiv`'s 512-bit space         | **By design** — noted        |
| A4-I-05 | Info     | `EUSD.crosschainBurn` burns from an arbitrary `from` (trusted-bridge)    | **By design** — noted        |
| A4-I-06 | Info     | Bridge burn+mint pairing evades the `netBridgedIn` global cap            | **By design** — noted        |
| A4-I-07 | Info     | OWN sent directly to OwnIncentives (not via `fund`) is unrecoverable     | **By design** — noted        |
| A4-I-08 | Info     | `recoverReserve` can pull reserve backing accrued-but-unclaimed OWN      | **By design** — noted        |
| A4-I-09 | Info     | Zero-amount `crosschainMint/Burn` lets any EOA emit spoofed bridge events| **Fixed** (2026-09-02)       |
| A4-I-10 | Info     | `setBridgeLimits` resets remaining to max — instant window refill        | **Fixed** (2026-09-02)       |
| A4-I-11 | Info     | Stability-fee accrual bypasses `debtCeiling`                             | **Acknowledged**             |
| A4-I-12 | Info     | `_verifyInhouseProof` lacks the per-asset staleness bound of `updatePrice`| **Acknowledged**             |
| A4-I-13 | Info     | `ReserveVault.skimExcess` pays surplus to `msg.sender` (hot key)         | **Acknowledged**             |
| A4-I-14 | Info     | `LendingRouter.deposit` bypasses the pool supplier allowlist (shim vault)| **Acknowledged**             |
| A4-I-15 | Info     | `EToken.updateName` breaks the cached ERC-2612 permit domain             | **Acknowledged**             |
| A4-I-16 | Info     | `_lastPremiumBps` zero-sentinel collides with a real 0 observation       | **Acknowledged**             |
| A4-I-17 | Info     | `setChainlinkConfig` keeps the old in-house `_prices` cache              | **Acknowledged**             |
| A4-I-18 | Info     | `OwnIncentives.setDistribution` emission unbounded (ledger said bounded)  | **Acknowledged** — ledger corrected |
| A4-I-19 | Info     | `setBridgeLimits` enabling a zero side of a live bridge starts it empty   | **Acknowledged** — fail-safe |
| A4-I-20 | Info     | `setIncentivesController(current)` retires the live controller in place  | **Acknowledged** — footgun   |

---

## 1. Fixed Findings

### A4-H-01 (High) — Redemption retires more debt than the collateral it seizes, stranding an unbacked zero-collateral position at the list head — **Fixed**

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

**Fix (Option A, 2026-09-02).** `_redeemFrom` now caps `repaid` to the seized collateral's value
at the redemption price whenever the collateral cap fires, so a redeemer is never charged for
collateral they do not receive; the unbacked residual stays on the owner's books, off-list,
still counted in `totalDebt` (supply invariant untouched) and clearable by repay / close /
liquidation / top-up. List membership is now **link-derived** (`_isListed`: head or has a
predecessor) instead of inferred from `debt > 0`, since the fix introduces a legitimate
debt-only off-list state: `_reindex` drops the `wasListed` parameter and inserts only when
`debt > 0 && collateral > 0`; `repay`, `closePosition` and `liquidate` no longer assume
membership; and the `_insertNode` hint check uses `_isListed(hint)` (a stale hint pointing at an
off-list residual previously would have linked the new node behind a detached predecessor —
attacker-reachable, since `hint` is caller-supplied). The redemption walk continues past the
drained head in the same call.

**Tests.** `test_redeem_underwaterHead_capsSeizure` (updated: burn capped at $800, 200 residual
off-list), `test_redeem_underwaterHead_partial_residualOffList_noToll` (the zombie path plus a
second redemption at fair value), `test_redeem_underwaterHead_walkContinues_fairValue` (an
accurate `minCollateralOut` holds across an underwater head into healthy positions),
`test_redeem_residual_repayClosesLiquidatesAndRelists` (stale hint at the residual ignored;
partial repay stays off-list; top-up re-lists; liquidate unlinks), and
`test_redeem_residual_liquidateAndClose_offList`. Invariant `invariant_listSortedAndComplete`
now asserts no listed node has `collateral == 0` and that the list holds exactly the
`debt > 0 && collateral > 0` positions.

**Residual.** The unbacked debt residual itself (Option B's bad-debt question) remains an
accounting/backstop decision, not a liveness issue. Note for A4-M-01: with the walk continuing
past a drained head at fair value, the "accurate `minCollateralOut` always reverts" stall no
longer reproduces (see `test_redeem_underwaterHead_walkContinues_fairValue`); A4-M-01 should be
re-validated against the fixed code before any further change.

**Overlaps.** A4-L-03 (missing `minDebt` floor) is the enabling half; Option A supersedes the
need for a floor on this path. A4-M-01 is the non-degenerate sibling.

**Detected by** 8 of 12 agents (math-precision, execution-trace, periphery, asymmetry, boundary,
numerical-gap as findings; trust-gap, first-principles as leads).

### A4-H-02 (High) — A routine stock split silently mis-values every eUSD position by the split ratio — **Fixed**

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

**Fix (Option A, 2026-09-02).** New private `_effectivePrice(collateral, price)` in
`EUSDManager` scales the per-active-unit ticker price by `legacyRatioToActive(collateral)` (ratio
0 → identity), mirroring `BorrowManager._effectivePrice`. It is applied inside the two price
helpers `_freshPrice` / `_anchorPrice` (both now take `collateral`), so every valuation site —
`withdrawCollateral`, `mint`, `liquidate`, `redeem`, `collateralRatioBps` — is covered by
construction. The price is scaled rather than the unit count, so seizure/transfer amounts stay in
the token actually held. `addCollateral` rejects already-legacy tokens (`LegacyCollateral`). No
storage change; `AssetRegistry` / `VaultManager` untouched. Side effects considered and
documented: the window between `migrateToken` landing and the feed moving is off by `ratio` in
one direction — migrate-first over-values (safe: nothing falsely liquidatable, redeemers protected
by `minCollateralOut`), feed-first under-values (unsafe). The ordering, mint/deposit freeze, and
legacy-disable steps are now written up as the **eUSD collateral policy & split runbook** in
`docs/deployment-robinhood.md`, which also states the collateral-selection preference
(low-volatility index ETFs unlikely to be re-denominated). Floor rounding on non-integer ratios
errs against the debtor, consistent with `_ratioBps`. The sorted-list key (units per debt unit)
is per token address, so ordering is unaffected.

**Tests.** Unit (mock registry gains `setLegacyRatio`): `test_split_forward_positionValueAndRatioUnchanged`,
`test_split_forward_redeemPaysLegacyUnitsAtFairValue`,
`test_split_forward_liquidationSeizesLegacyUnitsAtEffectivePrice`,
`test_split_reverse_noPhantomWithdrawOrMint`, `test_split_mintAgainstLegacy_usesEffectivePrice`,
`test_addCollateral_legacyToken_reverts`. Integration (`test/integration/EusdSplitFlow.t.sol`,
real `AssetRegistry.migrateToken` + `VaultManager.applySplit`): runbook-order forward split with
value invariance before/after the feed moves, redeem/withdraw in legacy units at fair value,
reverse split admits no phantom backing, and a two-hop migration (re-based ratio) with
`addCollateral` rejecting the legacy token and accepting the active one.

**Overlaps.** Independent of the redemption cluster (A4-H-01 / A4-M-01 / A4-L-03); shares no code
path. The original Pass-4 scope (2 files, `AssetRegistry`/`VaultManager` read-only) is why this seam
was not covered — the defect nonetheless lives in `EUSDManager`'s valuation.

**Round-1/2 re-review (2026-09-02).** Re-confirmed by 4 of 12 round-1 agents and 8 of 12
round-2 agents — the most-converged open issue in the codebase. Sharpest additional facts:
`BorrowManager._effectivePrice` already implements the exact `legacyRatioToActive` scaling
(house pattern exists; EUSDManager is the sole eToken pricer without it), `addCollateral`
accepts **already-legacy** tokens today (`isValidToken` passes them), so the mispricing is
reachable without any migration; and the victim's `withdrawCollateral` rescue is blocked by the
same wrong price. Fix Option A should also reject legacy tokens in `addCollateral`.

**Detected by** 3 of 12 agents (invariant, first-principles, flow-gap) — all as findings, with
matching numeric traces; re-review verified the mechanism directly against source.

### A4-M-01 (Medium) — Redemption cannot skip an underwater head, so the peg anchor stalls exactly when liquidation is unprofitable — **Fixed** (via A4-H-01)

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

**Resolution (2026-09-02).** Re-validated against the A4-H-01 fix and closed without a
separate change. The stall depended on an underwater head short-changing the redeemer while
staying in the list. Under the fixed `_redeemFrom`, an underwater head is redeemed value for
value (the burn is capped at its collateral's worth), it leaves the list in the same call, and
the walk continues to the next position at full value — so a redeemer receives exactly $1 of
collateral per eUSD across the walk and an accurate `minCollateralOut` holds. None of options
(a)/(b)/(c) is needed; redemption itself now absorbs underwater heads rather than being blocked
by them. Residual: the unbacked debt left on the drained owner's books is a backstop/accounting
decision, tracked under A4-H-01's residual (Option B question), not a liveness issue.

**Tests.** `test_redeem_underwaterHead_walkContinues_fairValue` — underwater head ahead of a
healthy position, redeemed with an exact non-zero `minCollateralOut` (`amount / price`), asserts
full fair-value payout and that the walk reached the healthy position.

**Overlaps.** Worst case (CR = 0) was A4-H-01; the same fix closes both.

**Detected by** 4 of 12 agents (economic-security, execution-trace, periphery, trust-gap).

### A4-M-02 (Medium) — OwnIncentives pays retroactive OWN on sEUSD balances acquired while the hook is detached — **Fixed**

**Problem.** `OwnIncentives.claim` / `sweepPartner` / `earned` read the holder's **live**
`balanceOf` and apply the full index delta since the holder's `_userIndex` snapshot, on the
stated assumption (the comment in `claim`) that "every supply change was checkpointed by the
hook." That assumption is enforced nowhere: `StakedEUSD.incentivesController` defaults to
`address(0)`, is admin-clearable/swappable at any time (`setIncentivesController`), and the
hook call in `_update` is `try/catch`-wrapped. During any window in which the controller is
not attached — deploy mis-sequencing (`setDistribution` before `setIncentivesController`) or a
mid-campaign detach/swap — sEUSD balances move with **no** checkpoint, so a balance acquired in
the window claims the entire historical index on its current size. Transfers also go unhooked,
so the same sEUSD can be shuttled across fresh addresses (`_userIndex = 0`) and claimed from
each until `rewardReserve` is empty; honest holders are diluted and later claimers hit
`RewardShortfall`. The admin action (wiring/detach) is legitimate; the theft is executed by an
unprivileged claimer the moment the window exists (race amplifier).

Worked case: emission 0.1 OWN/s, controller detached (or not yet attached) for 24h while
claims keep advancing `_index` against live supply. Attacker mints 1,000,000 sEUSD (half of
the 2M live supply) and calls `claim` in one tx: `_accrue` credits ≈4,320 OWN for zero seconds
of holding; shuttle the sEUSD to a fresh address and repeat until the reserve is drained.

Note: forcing the un-checkpointed state *while attached* via gas-griefing the `try/catch` was
independently proven infeasible by five agents (EIP-150: an OOG'd ~50k-gas hook leaves ~1/64 ≈
&lt;1k gas, far below what `super._update` needs, so the whole transfer reverts) — the
detach/late-attach window is the only reachable trigger.

**Suggested fix (Option A — freeze accrual while detached):**

```diff
     function claim(address to) external override nonReentrant returns (uint256 paid) {
         if (to == address(0)) revert ZeroAddress();
-        _updateGlobal(_sEusd.totalSupply());
-        _accrue(msg.sender, _sEusd.balanceOf(msg.sender));
+        if (StakedEUSD(address(_sEusd)).incentivesController() == address(this)) {
+            _updateGlobal(_sEusd.totalSupply());
+            _accrue(msg.sender, _sEusd.balanceOf(msg.sender));
+        }
         paid = _pay(msg.sender, to);
```

(mirror in `sweepPartner` and `earned`) — already-accrued OWN stays claimable, but emission and
per-user accrual freeze the moment the contract stops being the wired controller.

**Suggested fix (Option B — guard the wiring seams):** `setDistribution` reverts unless
`sEusd.incentivesController() == address(this)`; `StakedEUSD.setIncentivesController` refuses
to clear/replace a controller whose campaign is live (`emissionPerSecond > 0 &&
distributionEnd > block.timestamp`); document the decommission order (`setDistribution(0,·)` →
settle → `recoverReserve` → detach). Options compose: A alone closes the theft, B alone closes
the window.

**Fix (2026-09-02).** Reproduced first (PoC: campaign live, controller detached for a day,
attacker deposits and claims 43,200 OWN for zero seconds held, shuttles to a fresh address and
claims 43,200 again — more than the day's emission). Option A alone was judged insufficient:
freezing while detached only defers the replay to re-attach, when the first hook advances the
index over the whole gap against unseen balances. Fix closes every seam so no window exists:
(1) `OwnIncentives` freezes when not the wired controller — `claim` / `sweepPartner` / `earned`
skip `_updateGlobal` + `_accrue` unless `IStakedEUSD(sEusd).incentivesController() == this`,
paying only already-accrued OWN (Option A); (2) `setDistribution` with non-zero emission reverts
`NotAttached` unless wired (closes distribute-before-attach); (3) `StakedEUSD.setIncentivesController`
retires the outgoing controller permanently (`_retiredControllers`, `ControllerRetired`) so a
detached controller's index can never be replayed, and rejects code-less targets
(`ControllerNotContract`, = A4-L-15). Replacement (the planned OWN-token migration lever) and
clearing to zero (emergency lever for a broken controller) both remain available. Cost to
holders on migration: a holder who never settles during the announced claim window forfeits only
the tail since their last checkpoint; it stays in the old reserve, recoverable. Runbook: "OWN
incentives controller — wiring & migration" in `docs/deployment-robinhood.md`. New minimal
`IStakedEUSD` interface (one getter). sEUSD gains one mapping (not deployed; no layout concern).

**Tests.** `test_setDistribution_unattached_reverts`, `test_depositBeforeAttach_noRetroactiveAccrual`,
`test_migration_oldControllerFreezes_newStartsClean` (decommission order; old pays nothing on
post-swap balances, new starts synced), `test_detachedWindow_shuttleClaim_paysNothing` (the PoC,
now zero), `test_setIncentivesController_guards` (EOA rejected, retired rejected after replace and
after clear). `test_transfersSurviveBrokenController` moved to a fresh sEUSD.

**Detected by** 11 of 12 agents (economic-security, execution-trace, trust-gap, flow-gap as
findings with matching traces; math-precision, access-control, invariant, first-principles,
asymmetry, boundary, numerical-gap as leads).



### A4-L-15 (Low) — A code-less incentives controller bricks every sEUSD transfer despite the try/catch — **Fixed** (with A4-M-02)

**Problem.** `StakedEUSD._update` wraps `handleAction` in `try/catch` precisely so "a controller
fault can never block sEUSD transfers" — but for a high-level call to an address with no code,
solc's extcodesize check reverts in the **caller's** frame, outside what `try/catch` can catch.
`setIncentivesController` accepts any address, so an EOA / typo / not-yet-deployed CREATE
address bricks every transfer, mint, and burn (deposits, withdrawals, money-market liquidations
of sEUSD) until admin resets it. Admin-misconfig trigger, admin-recoverable — hardening grade,
but it directly falsifies the wrapper's stated guarantee.

**Fix (2026-09-02).** `setIncentivesController` reverts `ControllerNotContract` for any non-zero
target with no code (landed with the A4-M-02 wiring guards). Test:
`test_setIncentivesController_guards` sets an EOA and asserts the revert.

**Detected by** 1 of 12 agents (boundary).

### A4-M-03 (Medium) — Full-debt-only liquidation can be starved of eUSD liquidity — **Fixed**

**Problem.** `liquidate` burns the position's **entire** `p.debt` from the caller in one call;
there is no partial liquidation. A large borrower can therefore make themselves structurally
unliquidatable: mint near the `debtCeiling` and hoard (or bridge out) the minted eUSD. When the
position turns unsafe, no other actor can assemble `p.debt` eUSD — the circulating supply
outside the whale is smaller than the debt, and a would-be liquidator cannot mint liquidation
liquidity because the whale filled the ceiling (`DebtCeilingExceeded`; on closed markets
`StaleMintPrice` blocks minting anyway while `liquidate` stays open). Redemption can only shave
the position with whatever eUSD circulates, and stalls entirely once it is underwater
(A4-H-01/A4-M-01 territory). Raising the ceiling is a delayed ADMIN action, so the window spans
the crash. Worked case: ceiling 1M, whale mints 800k against $1.2M collateral and hoards it;
200k circulates elsewhere; a 40% drop leaves $720k backing 800k debt and no path to burn 800k
in one call.

**Fix (2026-09-02).** Partial liquidation: `liquidate(collateral, owner, amount, hint)` repays
`min(amount, debt)` (`type(uint256).max` = full) with the same bonus math pro-rata, capped at
the collateral. A partial that would leave `0 < remaining < minDebt` reverts
`BelowMinimumDebt` (same rule as `repay`); the remainder is re-sorted via `_reindex` with the
caller's hint (a collateral-exhausted underwater remainder goes off-list, per A4-H-01). Surplus
collateral is refunded to the owner only on a full close. No close factor: a fixed 5% bonus
under a 130% threshold does not need one. Seizure math moved to `_seizure` (stack depth).
Impact note recorded at validation: after A4-H-01, redemption already shaves the whale's head
position with any circulating eUSD, so the peg anchor was not starved — only the penalised
keeper path was; partial liquidation removes the precondition entirely. Interface + QA doc
updated; 13 call sites migrated (`type(uint256).max, address(0)`).

**Tests.** `test_liquidate_partial_improvesRatioAndRelists` (0.7 eSPY seized for 400 eUSD at
$600, no refund, head re-sorted at exactly 130%), `test_liquidate_partial_belowMinDebt_reverts`
(and exactly-minDebt remainder allowed), `test_liquidate_zeroAmount_reverts`,
`test_liquidate_whale_clearedInChunks` (10,000 debt cleared by a keeper who never holds more
than 1,000 eUSD). Invariant handler now liquidates partially whenever a keeper cannot fund the
full debt.

**Detected by** 1 of 12 agents (economic-security); mechanics verified directly against source
(full-debt burn in `liquidate`, ceiling check in `mint`).

### A4-M-04 (Medium) — Halted collateral is valued at the live feed, enabling unbacked minting above the halt price — **Fixed**

**Problem.** `EUSDManager` contains no reference to VaultManager halt or pause state (verified
by grep), while `ForceExecuteLib._validateForce` explicitly blocks both. When an asset is
halted, its eToken's only realizable value is the frozen `assetHaltPrice`
(`OwnMarket.redeemHalted`), but the Chainlink feed keeps printing the live stock price. If the
live price runs above `MCR × haltPrice`, an attacker can buy halted eTokens near halt value,
deposit them, `mint` at the live-price valuation, and abandon the position — the eUSD is
unbacked, and no rational liquidator clears it (the seized eTokens are redeemable only at
`haltPrice`, below the debt burned). Worked case: halt $100, live rallies to $160, MCR 150% →
1,000 eTokens bought for ~$100k mint 106,666 eUSD → +$6,666 per 1,000 tokens, scaling with the
rally. Softer variant: any live > halt overvalues existing positions. The instant
`setMintPaused` lever is global and reactive; `setCollateralEnabled` is delayed ADMIN.
Cross-ref A4-H-02: same valuation-binding root class, different seam (halt vs split).

**Fix (2026-09-02).** Both wings closed in the two price helpers. `_freshPrice` (mint,
withdraw-with-debt) reverts `CollateralHalted` when `VaultManager.isAssetHalted(ticker)`.
`_anchorPrice` (liquidate, redeem, ratio views) returns `assetHaltPrice` (legacy-ratio scaled)
for a halted asset **without consulting the oracle** — the halt price is the eToken's only
redeemable value (`OwnMarket.redeemHalted`), matching `BorrowManager.settleHaltedPosition`, and
skipping the feed is what keeps exits alive once it dies (round-2 wing). Chose the halt price
over `min(oracle, halt)`: the oracle carries no information about a halted eToken's value, and
depending on it would re-open the feed-death brick. Deposits stay allowed (defensive top-up).
No dedicated wind-down function: with correct pricing, repay / close / liquidate / redeem
already unwind positions and holders route seized/returned eTokens to `redeemHalted`. Ops rule
recorded (runbook + QA): delist an eUSD collateral only via `haltAsset`; a feed that dies
without a halt bricks exits until one is set (unchanged, protocol-wide behavior).

**Tests.** Unit (new `MockVaultManager` wired into the unit + invariant fixtures):
`test_halt_mintAndWithdrawWithDebt_revert`, `test_halt_attackerCannotMintAgainstLiveValuation`
(the worked case, live $160 vs halt $100 → mint refused),
`test_halt_exitsValueAtHaltPrice_feedDead` (feed zeroed; redeem and liquidate settle exactly at
the halt price), `test_halt_liveAboveHalt_doesNotOvervalue`, `test_halt_repayAndCloseStillWork`.
Integration: `test_halt_realVaultManager_windDownOnly` against the real `VaultManager.haltAsset`.

**Hardening addendum (same day, user-requested, not an audit finding).** `_freshPrice` also
reverts `CollateralPaused` while `VaultManager.isTradingPaused(ticker)` — mint and
withdraw-with-debt wait for resume, exits are never pause-gated (consistent with
`BorrowManager`: no new borrows on a paused asset, liquidation ungated because nothing freezes
the price). Tests: `test_pause_mintAndWithdrawWithDebt_revert_exitsOpen`,
`test_pause_realVaultManager_blocksMintOnly`.

**Detected by** 2 of 12 agents (economic-security as finding; execution-trace tied the variant
to the A4-H-02 root cause). **Round-2 addendum:** the seam has a second wing — once a
halted/delisted asset's feeds die past `maxAnchorAge`, `_anchorPrice` reverts and `liquidate`/
`redeem`/`withdrawCollateral`-with-debt all brick for that collateral while debt remains
outstanding (only `closePosition` works), so undercollateralized positions become permanently
unliquidatable. The halt gate fix should pair with a wind-down path for existing positions.

### A4-L-01 (Low) — `mintPriceMaxAge` is silently a no-op while a Chainlink answer is inside `clFreshWindow` — **Fixed** (docs)

**Problem.** `ChainlinkOracleVerifier.getPrice` reports `block.timestamp` as the price timestamp
whenever the feed answer is younger than `clFreshWindow` (4h in the documented config), so
`_freshPrice`'s `block.timestamp > ts + maxAge` bound can never fire in that window: a 5-minute
`mintPriceMaxAge` actually admits prices up to `clFreshWindow` old. Exposure is bounded — the
feed's 0.5% deviation trigger while live, and the 150%/130% closed-market buffer for the first
`clFreshWindow` hours after close — and the semantics are protocol-wide (PSM and BorrowManager
consume the same reads). The defect is that the admin-facing knob does not mean what it appears
to mean.

**Resolution (2026-09-02).** Semantics confirmed as intended (Chainlink hybrid: an answer
younger than `clFreshWindow` is deviation-bounded while the feed is live, so reporting it as
current is sound; bounding on the raw timestamp would push mints onto the in-house leg during
normal hours). Documented on `RiskParams.mintPriceMaxAge` and `setMintPriceMaxAge`: effective
bound on the Chainlink leg is `max(mintPriceMaxAge, clFreshWindow)`; the knob bites on the
in-house leg and on older Chainlink answers. No code change.

**Detected by** 1 of 12 agents (first-principles).

### A4-L-07 (Low, ops) — `MINTER_ROLE` exclusivity not structurally enforced on EUSD — **Fixed** (script)

The `totalSupply == totalDebt` invariant assumes EUSDManager is the *sole* `MINTER_ROLE`
holder; the token cannot structurally enforce it (plain `AccessControl`, no enumeration).
**Fix (2026-09-02):** `DeployEusdRobinhood.s.sol` now asserts, on the freshly deployed token,
that the manager holds `MINTER_ROLE` and that neither the deployer nor the token admin does, and
that the deployer no longer holds `DEFAULT_ADMIN_ROLE`. Monitoring on `RoleGranted(MINTER_ROLE)`
remains an ops item.

### A4-L-08 (Low) — eToken collateral dividends accrue to the manager with no claim path — **Fixed**

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

**Fix (2026-09-02).** Reward model confirmed claim-based (`EToken.depositRewards` /
`claimRewards`, rewards-per-share accumulator, non-rebasing — `totalCollateral` cannot desync),
and live-relevant: eSPY on Robinhood has `rewardToken` set. New permissionless
`sweepCollateralRewards(collateral)` claims the manager's accrued rewards and forwards them to
the protocol treasury — the same destination rule as `OwnMarket.sweepDividends` and the borrow
manager's collateral-dividend sweep (collateral dividends are protocol revenue while custodied).
Reverts `NoRewardsToSweep` when nothing is claimable. Tests:
`test_sweepCollateralRewards_forwardsToTreasury` (real `EToken`, 40% of a $1000 dividend lands
in treasury, collateral accounting untouched), `test_sweepCollateralRewards_nothingToSweep_reverts`.

**Detected by** 4 of 12 agents (periphery, first-principles, invariant, trust-gap) — all as leads;
depends on the eToken reward model, which was not in the review bundle.

### A4-L-10 (Low) — Disabled collateral blocks defensive top-ups while liquidation stays live — **Fixed**

**Problem.** `deposit` applies the `cfg.enabled` gate unconditionally, but `liquidate` has no
enabled gate. After `setCollateralEnabled(c, false)` (a legitimate de-listing/migration lever),
an indebted borrower cannot top up collateral — their only risk-*decreasing* lever other than
sourcing eUSD to repay — while keepers can still liquidate at the bonus. In a drawdown during a
de-listing window, a borrower holding spare eTokens is forced into an avoidable liquidation and
pays `liquidationBonusBps` to the keeper (the unprivileged amplifier). Pre-existing pass-4-scope
code; surfaced by the staking-pass re-review.

**Fix (2026-09-02).** As suggested: `deposit` now reverts `CollateralDisabled` only when the
caller has no debt on that collateral, so an existing debtor may always top up. `mint` keeps its
unconditional `enabled` gate, so a disabled collateral admits no new debt from anyone. NatSpec
on `deposit`, `setCollateralEnabled` and the error updated. Test:
`test_setCollateralEnabled_debtorCanTopUp_noNewExposure` (liquidatable debtor tops up and
becomes safe; the same debtor cannot mint; a debt-free holder cannot deposit).

**Detected by** 2 of 12 agents (trust-gap as finding, asymmetry as lead).

### A4-L-14 (Low) — `withdrawCollateral` with debt outstanding escapes both emergency levers — **Fixed**

**Problem.** For an indebted position, withdrawing collateral is risk-increasing with exactly a
mint's shape (same `_freshPrice` + MCR gate), yet it checks neither `mintPaused` nor
`cfg.enabled`. During a bad-oracle-price incident (leaked signer / erroneous print — the threat
the protocol's settle bands exist for), ops can throw `setMintPaused(true)` and
`setCollateralEnabled(false)` and debtors can still extract collateral against the inflated
price down to MCR, leaving undercollateralized debt behind; the identical extraction via `mint`
is blocked. Worked case: price pushed 2×, position 100 eTokens/$50 debt at MCR 150% withdraws
62.5 tokens at the fake price, leaving $37.5 real backing $50 debt. Complements A4-L-10 (the
inverse asymmetry on `deposit`).

**Fix (2026-09-02).** `withdrawCollateral` with `p.debt > 0` now reverts `MintingPaused`
when the mint pause is set — the same operator lever, same scope as `mint`. Not gated on
`enabled`: per the A4-L-10 resolution that switch means "no new exposure" and must keep letting
debtors reduce risk. Pure exits (repay, close, debt-free withdrawal) stay ungated. Together with
the halt and trading-pause gates in `_freshPrice`, every risk-increasing action on the manager
now answers to the same switches. Test: `test_setMintPaused_blocksWithdrawWithDebt_exitsOpen`.

**Detected by** 1 of 12 agents (asymmetry), with a complete numeric trace; gate-checked against
source.

### A4-L-11 (Low) — sEUSD dead-shares seed and `totalSupply > 0` before streaming are unenforced — **Fixed**

**Problem.** The OZ v5 virtual-shares defense does not cover the protocol's own reward stream:
if `transferInRewards` runs while `totalSupply == 0` (stream before the seed deposit, or after
a full exit including the seed), vested rewards make `totalAssets ≫ totalSupply`, and OZ
ERC-4626 `deposit` then mints `floor(a·1/(A+1)) = 0` shares **without reverting** — the deposit
is silently donated (e.g. residual `A = 1000e18`: a 1000e18 deposit mints 0 shares; a 2000e18
deposit mints 1 share and loses ~500e18 on exit). The seed is a deploy *note*, not code, and no
production deploy script exists yet for StakedEUSD/OwnIncentives to enforce it.

**Fix (2026-09-02).** `transferInRewards` reverts `NoSharesOutstanding` when `totalSupply() == 0`
(one line), so rewards can never land in an empty vault and the OZ virtual-share defense is
never asked to cover the protocol's own stream. The dead-shares seed remains a deploy step:
no production deploy script exists yet for StakedEUSD / OwnIncentives — add the seed deposit
and a `totalSupply() > 0` assertion when it is written (checklist §6). Tests:
`test_transferInRewards_emptyVault_reverts` (before any deposit, and again after a full exit).

**Detected by** 5 of 12 agents (math-precision, economic-security, execution-trace,
first-principles, boundary) — all as leads with matching arithmetic.

### A4-L-13 (Low) — Force-execution never checks `order.expiry` (reopens the unimplemented half of external A3-L-03) — **Fixed**

**Problem.** Both fill paths revert on expired orders (`OwnMarket.sol:179`, `:349`), and
`expireOrder` exists to retire them — but neither the `forceExecuteOrder` wrapper (which checks
only `status == Open` via `_openOrder`) nor `ForceExecuteLib._validateForce` reads
`order.expiry`. External audit Report 3's A3-L-03 explicitly noted "no order.expiry check" on
this path and is marked Fixed; git history shows the price-freshness half of that fix landed
(fresh proof + `currentPrice ≥ limitPrice`) but an expiry check never existed on the force path
in any commit — the expiry half was not implemented. Consequences: an expired-but-unretired
redeem order remains a standing, pre-aged force-execution right against the approved vault pool
indefinitely (a fresh order would restart `claimThreshold`); inversely, permissionless
`expireOrder` can front-run the owner's force-execution and restart their window (bounded
grief). Economic damage is capped — payout settles at `limitPrice` and requires a fresh price ≥
limit — so this is a lifecycle/state-machine hole, not a drain.

**Fix (2026-09-02).** As suggested — `_validateForce` reverts `OrderExpiredError` when
`block.timestamp > order.expiry`, matching both fill paths. The pre-existing
`test_forceExecute_expiredOrder_reverts` only covered an order already retired by `expireOrder`
(status check); new `test_forceExecute_expiredUnretiredOrder_reverts` covers the un-retired
case that was the actual hole. Closes A3-L-03's expiry half for good. Ships with the next
OwnMarket / ForceExecuteLib upgrade.

**Detected by** 3 of 12 agents (access-control, periphery as findings; execution-trace as the
expire-frontrun inversion lead). Verified directly against source and full git history.

### A4-L-12 (Low, ops) — Bridge `crosschainBurn` aimed at the sEUSD vault: socialized loss plus vault-wide DoS — **Fixed** (DoS leg)

**Problem.** `EUSD.crosschainBurn` is allowance-free from any `from` — accepted under A4-I-05
as "griefing within one window" against the user who asked to bridge. StakedEUSD invalidates
that bound: the vault concentrates all stakers' eUSD at one address, so a compromised bridge
aiming its per-window `burnMaxLimit` at the vault (a) socializes the loss across every sEUSD
holder, and (b) if the burn pushes `eusd.balanceOf(vault)` below `getUnvestedAmount()`,
`totalAssets()` underflow-reverts and **every** vault entry/exit bricks until vesting decays or
someone tops the balance up — a DoS amplification the A4-I-05 analysis (which predates sEUSD)
did not consider. Latent today (no bridge limits set, `maxNetBridgedIn = 0`).

**Fix (2026-09-02).** DoS leg closed in code: `totalAssets()` is now
`balance − min(balance, unvested)`, so an external burn below the unvested slice reports zero
assets instead of underflow-reverting on every deposit and withdrawal — the vault degrades to a
visible loss and keeps working while value vests back. The loss leg stays bridge-trust
territory, handled operationally: keep every per-bridge `burnMaxLimit` well below the sEUSD
vault's balance and re-run the sizing whenever a transport is authorized (no bridge has limits
today). Test (as of the round-3 re-fix): `test_externalBurnBelowUnvested_blocksEntryKeepsExit` (burn
to 301 with 500 unvested → `totalAssets == 0`, deposit now reverts `ERC4626ExceededMaxDeposit`,
redemption stays open; the earlier DoS-leg-only test that asserted "deposit succeeds" was superseded by
the A4-L-12 entry gate).

**Detected by** 4 of 12 agents (flow-gap, access-control, trust-gap, boundary) — all as leads
(compromised-bridge precondition).

### A4-M-06 (Medium) — Partial liquidation of a position below 1 + bonus seizes the full bonus and manufactures unbacked eUSD — **Fixed**

**Problem.** `_seizure` computes `seized = repaid × (1 + bonus) / price` and caps it at the position's
**whole** collateral; on a partial (`!fullClose`) `refund = 0` and `remaining = debt − repaid` stays
on the books. The A4-M-03 rationale ("no close factor: a fixed 5% bonus under a 130% threshold does not
need one") and the `_validateRatios` guarantee ("a threshold liquidation is always solvent") both
reason about the **full-close** branch only. The liquidator chooses `amount`, so on any position with
ratio `r` in **[100%, 100% + bonus)** — solvent — a partial takes the full bonus out of collateral the
remaining debt needs: the remainder's ratio becomes `(r − f·(1+b)) / (1 − f)` for repaid fraction `f`,
which drops below 100% once `f > (r − 1)/b`, and with `f ≈ 1 − minDebt/D` (the only floor is
`minDebt`) the residual is collateral-exhausted. Below 100% the same sizing *enlarges* bad debt by the
bonus. Because the partial payoff `b·x` strictly exceeds the full-close payoff `(r − 1)·D` on the whole
strip, the partial is the keeper's dominant strategy there, not an edge case. There is no
`owner != msg.sender` check, so the debtor can self-liquidate the same way and pocket the difference
versus `closePosition`. The interface's "if the position is underwater the caller absorbs the
shortfall" is true only for full closes.

**PoC (unit fixture: MCR 150% / threshold 130% / bonus 5% / minDebt 100; reproduced by the
orchestrator).** alice: 2 eSPY, 1,000 eUSD minted at $750; price gaps to **$505** (V = $1,010,
ratio 101% — solvent, liquidatable).
- Full close (`amount = max`): keeper burns 1,000, receives 2 eSPY → **+$10**; position deleted;
  bad debt 0.
- Partial (`amount = 900`): `seized = 900 × 1.05 / 505 = 1.871287 eSPY` ($945) → keeper **+$45**;
  remainder debt 100, collateral 0.128713 eSPY ($65), ratio **65%**, still list head. A follow-on
  `redeem(100)` takes the $65 for 65 eUSD (A4-H-01 cap) and leaves **35 eUSD of debt-only, off-list,
  permanently unbacked** supply (`totalSupply == totalDebt` still holds).
- Underwater variant (price $475, V = $950, 95%): full close = keeper **−$50** (nobody does it;
  redemption would leave $50 bad debt); partial 900 → keeper **+$45**, residual $5 collateral / 100
  debt → bad debt **$95**. The liquidation *increased* unbacked eUSD by the bonus.
- Worst case at `r = 100%`: `x = D/1.05` takes all collateral at full bonus and strands
  `D·(1 − 1/1.05) ≈ 4.76%` of `D`, where a full close strands 0.

Reachability: threshold 130% means the band is reached after a ~23–30% move from the liquidation
line; overnight/earnings gaps of that size are routine for single-stock eTokens, and the anchor is
frozen off-hours so keepers cannot act earlier. Unprivileged, profitable, repeatable.

**Fix options.**
- **A — pro-rata cap on partials (recommended).** Pass `debt` into `_seizure`; when `!fullClose`,
  `seized = min(seized, Math.mulDiv(coll, repaid, debt))`. Never binds when `r ≥ 1 + b` (bonus fully
  paid), so A4-M-03's chunked-liquidation liveness is untouched; in the band the keeper's bonus
  degrades to `r − 1 ≥ 0` and the remainder's ratio can never fall below the pre-liquidation ratio
  (101% stays 101% in the example instead of collapsing to 65%). One parameter, one line.
- **B — force a full close in the band.** Revert partials with `FullLiquidationRequired` when
  `collValue × BPS < debt × (BPS + liquidationBonusBps)`, so the shortfall-absorption rule applies
  whenever it matters.
- Either way: regression tests asserting (i) remainder ratio ≥ pre-liquidation ratio for every
  partial, (ii) an underwater partial leaves no more bad debt than a full close would, and an
  invariant "Σ collateral value ≥ Σ debt across listed positions after liquidations at a fixed price".
  Consider also clamping `0 < remaining < minDebt` to a full close instead of reverting
  `BelowMinimumDebt` (the A4-L-03 round-2 note) — it closes the 1-wei `repay` front-run grief on
  sized partials recorded in §5.

**Detected by** 7 of 12 agents (math-precision, economic-security, first-principles, trust-gap,
numerical-gap as findings; boundary, flow-gap as leads), with three independent forge PoCs agreeing on
the numbers; not covered by A4-M-03 (whose write-up only argues the `r ≥ 1 + b` case) nor A4-H-01
(redemption path).

**Fix (2026-09-02, Option A).** `_seizure` now takes `debt` and, on a partial, caps `seized` at the
pro-rata share `Math.mulDiv(coll, repaid, debt)`. The cap is inert while ratio ≥ 1 + bonus (the bonus
seizure is already below pro-rata there, so A4-M-03's chunked liquidation is unchanged); below it the
liquidator's bonus degrades to the position's cushion and the remainder's ratio can never fall below
the pre-liquidation ratio, so a partial can no longer strand debt that a full close would have covered.
Interface NatSpec updated (the "caller absorbs the shortfall" rule now holds for partials too). Full
suite 1430 passing. **Tests:** `test_liquidate_partial_inBand_proRataCap_keepsRatio` (101% position,
partial 900 → 1.8 eSPY seized instead of 1.871, remainder stays at 101%, follow-on redeem leaves no
debt-only residual) and `test_liquidate_partial_underwater_noExtraBadDebt` (95% position, remainder
ratio unchanged at 9,500 bps, residual shortfall pro-rata) — both fail without the cap; the existing
`test_liquidate_partial_improvesRatioAndRelists` (120%) pins the inert case.

### A4-L-12 (Low) — Re-fixed: the DoS-leg clamp had opened a share-capture leg; entries are now gated while under-collateralised — **Fixed** (2026-09-03)

**Problem.** The 2026-09-02 fix (`totalAssets()` clamped at 0 instead of underflow-reverting) opened
OZ ERC-4626's saturation pricing: `StakedEUSD` keeps `_decimalsOffset() == 0`, so
`_convertToShares = assets × (S + 1) / (TA + 1)`. With `TA == 0` and `S > 0`, **one wei mints `S + 1`
shares** (>50% of supply) and `previewRedeem` returns 0 for every existing holder (OZ `redeem` has no
zero-assets revert, so exits burn shares for nothing). As the unvested slice vests, `TA` climbs back to
the surviving balance and the new depositor redeems it. This is the class A3-M-08 closed in `OwnVault`
with `_requireSolvent`, re-introduced on the other ERC-4626 vault by the A4-L-12 remedy itself: the
"visible, pro-rata loss" the fix intended is instead "first depositor takes the residual".

**PoC (unit fixture; orchestrator-reproduced).** alice deposits 1,000,000 eUSD; `transferInRewards(50,000)`;
bridge burn to 40,000 (< unvested 50,000) → `totalAssets() == 0`. bob `deposit(1 wei)` mints
1,000,001e18 + 1 shares; alice `previewRedeem` = 0. After the vesting window `TA = 40,000`: bob redeems
**20,000 eUSD for 1 wei**; alice keeps 20,000 of the surviving 40,000. Tail (third agent): with `TA`
small but non-zero (`unvested` still > `TA`), bob `deposit(100)` still takes ~397 of 401 and alice ~4.
The then-shipped regression (`test_externalBurnBelowUnvested_vaultStaysLive`, since renamed) asserted
"deposit succeeds" — i.e. it passed on exactly this capture outcome; the round-3 re-fix replaces it
with `test_externalBurnBelowUnvested_blocksEntryKeepsExit`, which asserts entries revert instead.

**Severity.** Precondition unchanged — an authorized bridge burning more than the vault's vested
balance (no bridge has limits today; trusted-bridge model per A4-I-05) — so Low, but the remedy regressed
the failure mode from bounded to winner-take-all and must be revisited before any bridge is armed.

**Fix.** Gate entries during loss recovery, keep exits open: override `maxDeposit`/`maxMint` to 0 (or
revert in `_deposit`) while `getUnvestedAmount() > totalAssets()` — covers both the `== 0` state and
the tiny-positive tail; inert in normal operation because a single reward batch is a small fraction of
TVL (record the ops rule: never `transferInRewards` more than `totalAssets()` in one batch). The
narrower `totalAssets() == 0 && totalSupply() > 0` gate (a literal `_requireSolvent` mirror) closes the
1-wei case only. Update the regression test to assert entries revert in the deficit state and that
alice's post-vest redemption is the pro-rata 40,000.

**Detected by** 3 of 12 agents in round 3 (boundary and periphery as findings, both with forge PoCs;
periphery-2 as lead).

**Fix (2026-09-03).** `StakedEUSD` now overrides `maxDeposit`/`maxMint` to return 0 while
`getUnvestedAmount() > totalAssets()` — the under-collateralised window (an external bridge burn below
the unvested slice) in which ERC-4626 prices new shares against the virtual offset alone. OZ v5
`deposit`/`mint` enforce those caps, so entries revert `ERC4626ExceededMaxDeposit` in that state while
`withdraw`/`redeem` stay open, and the vault still degrades to a visible loss rather than a DoS. The
gate is inert in normal operation (a reward batch is a small fraction of TVL; ops rule: never stream
more than `totalAssets()` in one batch) and re-opens automatically once the balance vests back above
the unvested slice. Regression `test_externalBurnBelowUnvested_blocksEntryKeepsExit` (deposit reverts
in the burned state, redeem still executes, entry re-opens after vesting and the incumbent keeps its
pro-rata claim); replaces the old test that asserted the capture-prone "deposit succeeds". Full suite
1430 passing. `StakedEUSD` is UUPS, so the fix reaches the (not-yet-deployed) proxy.


---

## 2. Open Findings

None — as of 2026-09-03 every round-3 finding is fixed (§1) or accepted with rationale (§3).

---

## 3. By-Design / Withdrawn

### A4-L-19 (Low) — Under in-house signer compromise the PSM ratio's damage bound is ≈ 2 × `bandBps` and the jump guard is walkable — **Acknowledged** (2026-09-03)

**Decision (2026-09-03): acknowledged, no live code change; fix folded into the next oracle/PSM
deploy.** The clean fix — anchor the ratio-jump guard to the Chainlink-implied ratio instead of
`lastUsedRatio` — needs the served Chainlink anchor for each leg, but `ChainlinkOracleVerifier._chainlink`
is `internal` and the verifier is **deployed and non-upgradeable**, and the guard state
(`lastUsedRatio`, `ratioJumpBoundBps`, `notePsmRatio`) lives in `AssetRegistry`, which is a plain
**non-upgradeable** contract; `OwnMarket` (upgradeable) only ever sees the *served* prices, which are
the manipulated legs off-hours, so no reachable market-side change can compute the anchor ratio. (This
corrects the earlier "cheap, market-side" note — it is a next-deploy item.) The actor is the in-house
KMS signing key, an accepted and instantly revocable trust root (CL-I01): a compromised signer can
already misprice within the band, and containment is the same — instant `removeSigner` plus off-hours
feed/ratio monitoring — so this introduces no new trust, only a corrected damage estimate (round-trip
≈ (1+b)/(1−b) − 1, i.e. ≈ 17–38% for b = 5–8%, not the one-band figure the CL-I01 note implies).
**Next-deploy fixes:** (a) expose a Chainlink-anchor getter on the verifier and gate the ratio against
`|ratio − clRatio| ≤ ratioJumpBoundBps × clRatio`; or (b) key the in-house price cache by aggregator so
two tickers sharing one feed cannot carry divergent pushes. Correct the CL-I01 damage-cap wording to
"≈ 2 × band for derived PSM ratios" wherever it is quoted. Original write-up retained below.


**Problem.** CL-I01 accepts that a compromised in-house signer can move a served price up to `bandBps`
off the Chainlink anchor while the feed is quiet ("the band, not a calendar, is the security
boundary"). The PSM ratio is the *quotient* of two independently band-checked in-house legs for one
physical stock: `ChainlinkOracleVerifier._checkAnchorBand` and the `_prices[asset]` cache are per
ticker, and `DeployChainlinkOracleRobinhood.s.sol` registers every underlying/wrapper pair (`TSLA` /
`R.TSLA`, …) against the same aggregator with `bandBps = 800` each (500 for SPY/QQQ). Off-hours (feed
silent > `clSilence` = 15 min — every evening and weekend) the signer can push `R.TSLA = 1.08·A` and
`TSLA = 0.92·A`, both individually valid; `getPrice` prefers the fresher in-house entry on each leg,
so `_psmContext` derives ratio `1.08 / 0.92 = 1.1739` (17.4% off) — and `0.8519` after flipping both
legs. The per-operation `ratioJumpBoundBps` (150 deployed) is anchored to `lastUsedRatio`, which the
same actor advances: one multicall of back-dated attestations (timestamps `t, t+1, … ≤ block.timestamp`,
each newer than the cached entry) interleaved with dust `psmMint`s walks the baseline ≤ 1.5% per step
(`1.015^11 ≥ 1.1739`) in a single block. `psmMint(W)` then issues `1.1739·W` eTokens; flip and walk
down; `psmRedeem` releases `1.378·W` wrapper — **37.8% of the deposited wrapper extracted from the
ReserveVault per cycle** (21.6% at `bandBps = 500`), bounded only by `AmountExceedsReserve` and cap
headroom (util-neutral, since the reserve is marked at the same inflated wrapper price). The redeem
leg has a second entry point: `_psmContext` records `notePsmRatio` on every non-halted `psmRedeem` even
when the in-tx `pullAssetPrice` was caught, so a frozen asset mark plus a live wrapper leg walks the
baseline the same way.

**Severity.** Low — the actor is the in-house KMS signer key, an accepted and instantly revocable
trust root (CL-I01, `removeSigner`) — but the documented damage cap is off by ≈ 2×, and the
ratio-jump guard, the load-bearing mitigation for `psmRedeem`'s accepted stale-mark tolerance, does not
bind against this actor. Recorded as an open decision rather than acknowledged because the fix is
cheap and market-side.

**Fix.** Anchor the ratio-jump guard to the *Chainlink-implied* ratio (both legs' `_chainlink` anchors;
≈ 1e18 on shared-feed deployments) instead of `lastUsedRatio`: revert when
`|ratio − clRatio| > ratioJumpBoundBps × clRatio`, so the in-house legs can move the PSM ratio at most
one bound off the feed and cannot be walked. Alternative (oracle redeploy): key the in-house cache by
aggregator so tickers sharing a feed cannot carry divergent pushes. Regression: two-leg opposite-edge
pushes must revert `RatioJumpExceeded` on the first PSM op.

**Detected by** 1 of 12 agents (trust-gap); mechanism verified against the verifier's per-ticker
cache/band and the deployed oracle and PSM parameters. Corrects the round-3 new-contracts lead that
called guard-walking moot: the Chainlink leg is shared, the in-house cache is not.


### A4-M-08 (Medium → Low) — JIT yield capture when the best-effort claim is blocked at the pool LTV — **Acknowledged** (reassessed 2026-09-03)

**Reassessment (2026-09-03).** Downgraded from Medium to Low and acknowledged. The attack's payoff is
the *unclaimed premium backlog* sitting on the vault when the attacker deposits, and that backlog does
not realistically pile up: every deposit, withdrawal, borrow and repay runs `_syncLending`, and any
one of them that lands while the vault has borrowing headroom realizes the accrued premium to the
existing LPs. On a live vault with ordinary flow the gap is therefore drained continuously in small
increments, so there is rarely a large lump to capture, and an incumbent LP who does notice a stuck
gap can self-defend by depositing dust and calling `syncYield` to realize it to themselves first. The
large $41k PoC figure needs the vault pinned at its debt cap with ~$92k of premium left unclaimed for
60 days and open (permissionless) deposits — a combination the live config does not present: the
wind-down vault is in approval mode (the direct-deposit path is closed) and carries an 8-hour
withdrawal queue (no atomic in-and-out). Accepted as Low, self-limiting and recoverable. The clean
fix (escrow-then-price in `_depositWithMin`/`mint`, so a newcomer's own collateral cannot be what
unblocks the yield they then skim) remains the recommended hardening **if** a vault is ever run with
open deposits at sustained full utilization; the async accept-deposit path is already immune. Original
write-up retained below.


**Problem.** A3-M-01 made every LP entry/exit call `_syncLending()` (accrue → best-effort
`claimEarnedInterest` → `distribute`) before pricing shares, so accrued premium is realized before a
newcomer is priced. The claim draws the premium from the lending pool as new vault debt and is refused
once the vault's pool-side debt sits at the pool LTV (75%) or the `minClaimHealthFactor` floor;
`_claimBestEffort` is all-or-nothing and swallows the revert. Because the hook runs **before** the
depositor's aTokens arrive, in exactly that state it is a no-op: the newcomer is priced pre-yield,
their deposit supplies the headroom, a follow-up `syncYield()` realizes the whole accumulated gap and
distributes it pro-rata, and the newcomer exits with a slice of yield earned entirely before they
arrived. The blocked state is the *documented* steady state at cap — `DeployRobinhood.s.sol` notes
that premium claims drift pool debt from the 70% borrow cap up to the 75% LTV, after which every
claim is refused and the gap grows at up to 80% APR × book. The async path (`requestDeposit` →
`acceptDeposit`) is immune because its escrow already sits in the aToken balance when the claim runs.

**PoC (Robinhood params: pool LTV 7500 / LT 10000, `targetLtv` 7000, curve 600/8000/200/7200,
treasury cut 1000, wait 0; agent PoC re-run by the orchestrator, 3/3 pass).** LP1 deposits 1,000,000
USDG; borrowers draw 700,000 (= cap); 60 days → unrealized premium 92,054.80; `syncYield()` alone
realizes nothing (claim refused). Attacker `LendingRouter.deposit(1,000,000)` → 50% of shares at
price 1.0. Attacker `syncYield()` → 91,134.25 claimed, 82,020.82 pushed to the vault. Attacker
exits with **1,041,420.52 (+41,420.52 for one block of capital)**; LP1 ends with 1,041,420.52
instead of 1,082,020.82 (loses 50.5% of its yield). Control via `requestDeposit`/`acceptDeposit`:
newcomer 999,999.99, incumbent 1,082,020.82. Exit gates pass (HF ≈ 1.32 ≥ 1.1; no exposure).

**Fix.** Escrow-then-price in `_depositWithMin` and `mint`: pull the assets in first, count them in
`_pendingDepositAssets` (so `totalAssets()` still excludes them), `_syncLending()`, `_requireSolvent()`,
compute shares, un-count, mint — the claim then sees the newcomer's aTokens as headroom while pricing
does not. Secondary hardening: `_claimBestEffort` claims `min(claimable, poolHeadroom)` instead of
all-or-nothing so the gap never accumulates. Regression: the PoC's
`test_directDeposit_capturesBlockedPremium` must show the newcomer redeeming ≈ principal;
`test_deposit_cannotFrontRunPendingYield` only covers the unblocked case. Streaming the distribution
(the open §6 yield-manager item) narrows the capture window but does not remove it while the claim is
blocked.

**Detected by** 2 of 12 agents (economic-security, with a three-test forge PoC; invariant traced the
`minClaimHealthFactor`-floor variant of the same blocked-claim state). Sequel to A3-M-01
(remedy holds when the claim succeeds) and A3-L-02 (same claim/exit-floor coupling); not a reopen
because the A3-M-01 mechanism (permissionless distribute of already-held revenue) stays closed.


### A4-M-07 (Medium → Low) — The premium observed at window open is caller-timed — **Acknowledged** (reassessed 2026-09-03)

**Reassessment (2026-09-03).** Downgraded from Medium to Low and acknowledged (moved here). `_accrue`
re-observes `_lastPremiumBps = _currentPremiumBps()` at the true utilization on **every** call with
elapsed time (`dt > 0`), so the mispriced premium survives only until the next touch of the book —
any keeper `accrue()` (permissionless, cranked routinely — the same cadence A3-H-02's own fix and the
A3 M-05 lag bound already rely on), or any borrow / repay / liquidate / LP deposit / withdrawal —
restores the correct rate. Confirmed on the integration fixture: the $53,276 figure below requires the
book to sit **untouched for 30 days**; inserting a single `accrue()` 15 minutes after the attack
yields $1,356,860 versus the honest $1,356,859 (leak ≈ 0). The per-window leak is therefore bounded to
one inter-touch interval, does not compound, is shared pro-rata across the whole book (not captured by
the attacker alone), and must be re-armed with gas every window to persist — dust-level and
self-correcting, below the finding bar and recoverable by any actor calling `accrue()`. No code change;
recorded so a future pass does not re-raise it as a Medium. The observe-before-mutate detail (mechanism
B) is a benign semantic wart with the same self-correcting bound. Original write-up retained below.


**Problem.** A3-H-02's remedy bills each accrual window at `_lastPremiumBps`, the utilization premium
observed when the window *opened*, so a denominator move can no longer reprice elapsed time. The
observation itself is unguarded: `_accrue` re-samples `_lastPremiumBps = _currentPremiumBps()` only
inside `if (dt != 0)`; `accrue()` and `VaultManager.pullCollateralPrice` are permissionless; and every
collateral-out path in `OwnVault` (`fulfillWithdrawal`, `releaseCollateral`,
`releaseCollateralForBadDebt`) calls `_accrueLending()` **before** `onCollateralReleased`, so no code
path ever re-observes at the post-withdrawal (true) mark. Sequence: block N `deposit` (accrues at the
honest mark; a deposit does not move the mark) → block N+1 `pullCollateralPrice` (mark ↑) → `accrue()`
(`dt > 0`: bills the one-second window honestly, then observes the deflated utilization) →
`requestWithdrawal` + `fulfillWithdrawal` in the same block (the nested accrue has `dt == 0` → no
re-observation; mark ↓). `_lastPremiumBps` now holds the deflated premium while the real mark is
restored, and the next window — however long until anyone's next `dt > 0` touch — bills at it.
Capital is held for one block (or `withdrawalWaitPeriod`) and returned in full; the cost is gas; it is
repeatable after every honest touch; the beneficiary is every borrower, so the attacker only needs to
be one of them.

**PoC (integration fixture; orchestrator).** Rate params base 100 / optimal 8000 / slope1 400 /
slope2 7500; vault 1,000 awstETH @ $4k = $4M, `targetLtv` 35% → cap $1.4M; book $1.3M → util 92.85%
→ premium 6,125 bps. Attacker deposits 1,000 awstETH; one second later `pullCollateralPrice` → util
46.42% (premium 332 bps); `accrue()`; `requestWithdrawal` + `fulfillWithdrawal` in the same block →
util back to 92.85%, attacker holds 999.9995 awstETH. Thirty days later: honest branch debt
**$1,356,859** vs attacked **$1,303,583** — **$53,276 of LP premium erased (≈3.9% of the book per
month)**. One-directional: only borrowers gain (deflating the mark to over-bill borrowers would need
the attacker to own the shares being withdrawn and hurts only themselves).

Preconditions: permissionless deposits on the vault (approval mode off) and a short
`withdrawalWaitPeriod` (the A3-M-01 decision moved it to 0 and `LendingRouter.withdrawFromVault`
requires 0; the old deployed vault's 8 h only lengthens the capital hold). Not covered by A3-H-02
(retroactive repricing — fixed and still holding) nor A4-L-18 (admin rate setters).

**Mechanism B — numerator side (trust-gap agent; structurally verified).** Every path that changes
`_totalScaledDebt` (`borrow`, `borrowMore`, `_repayPosition`, `_liquidate`, `absorbBadDebt`,
`settleHaltedPosition`) calls `_accrue` **before** mutating it, and `_accrue`'s zero-debt branch
observes `_lastPremiumBps = _currentPremiumBps()` even when `dt == 0`. The window opened by a borrow is
therefore priced at *pre-borrow* utilization until an unrelated touch: a sole borrower at cap repays
in full (the observation records `premium(100%) = 8000` bps, then `_totalScaledDebt = 0`) and
re-borrows the same amount in the next transaction (`_totalScaledDebt == 0` branch records
`premium(0) = 100` bps) — the book now grows at the base premium instead of 8000 bps until anyone
else touches the manager. `D = $2M`, six touch-free hours → ≈ $1,082 of premium unbilled, repeatable
after every external touch; funded by the borrowed stablecoin itself. Two-borrower variant: a whale
taking 90% of the cap observes `premium(10%) = 150` bps for its first window. No LP capital and no
`pullCollateralPrice` needed — cheaper than mechanism A. Mirror direction (numerical-gap): a whale
repaying $900k of a $1M book at 95% util leaves the remaining $50k of *other* borrowers billed at the
pre-repay 6,125 bps instead of 125 bps until the next touch (≈ $82/day over-billed), so the
observation timing misprices both ways. The NatSpec at the zero-debt branch ("this
observation is what prices that position's first window") describes the behaviour as intended for a
one-off; it is a repeatable lever.

Both mechanisms share one root: the observation is taken at a moment the caller controls and is not
re-taken after the caller's own state change (numerator or denominator).

**Fix options.** (A) Observe *after* the mutation: add an internal `_observePremium()` that sets
`_lastPremiumBps = _currentPremiumBps()` and call it at the **end** of every path that mutates
`_totalScaledDebt` (closes B, Aave semantics — the next window is priced at post-action utilization
while elapsed windows stay non-retroactive), **and** have `OwnVault` call `_accrueLending()` again
after `onCollateralReleased` in all three release paths with the resample moved out of the `dt != 0`
branch so a same-block re-observation takes effect (closes A; both contracts are redeployable).
(B) Bill each window at `max(premium_open, premium_close)`, which removes the incentive on both sides
without touching the vault. `VaultManager.pullCollateralPrice` cannot host a fix (immutable).
Regressions: the mechanism-A PoC sequence must yield identical debt in both branches; a
repay-all-then-re-borrow must bill the following window at post-borrow utilization.

**Detected by** 3 of 12 agents (access-control: mechanism A, orchestrator PoC reproduced the numbers
above; trust-gap and numerical-gap: mechanism B independently, verified against `_accrue` and all six
mutation sites).
Overlap check: sequel to A3-H-02 (different mechanism — prospective observation, not retroactive
repricing); recorded as a new ID rather than a reopen because the A3-H-02 remedy still holds as stated.


**A4-I-11 … A4-I-17 — acknowledged 2026-09-02** (original notes retained below; disposition per item):
I-11 intended, Maker-style (the ceiling gates new minting, not interest) — documented here.
I-12 oracle is deployed and non-upgradeable; consumers backstop with the global `priceMaxAge` —
noted as defense-in-depth for any future oracle redeploy. I-13 `ReserveVault` non-upgradeable —
ops rule: prefer `withdraw`, monitor skims. I-14 aTokens stay 1:1 backed and nothing relies on
supplier identity — accepted. I-15 integrator doc: the canonical ERC-2612 domain is the
constructor-time name — accepted. I-16 cannot occur with the live config (`basePremiumBps =
600` on Robinhood); config rule: keep it non-zero. I-17 oracle is deployed — the one-line
`delete _prices[asset]` mirror is noted for any future redeploy.

- **A4-I-11.** Stability-fee accrual (`_accrue`) increments `totalDebt` past `debtCeiling`
  with no check (ceiling gates only `mint`). Maker-style and probably intended — confirm and
  document.
- **A4-I-12.** `ChainlinkOracleVerifier._verifyInhouseProof` (inline leg) enforces no age
  bound, while `updatePrice` enforces per-asset `inhouseMaxStaleness`; consumers backstop with
  the *global* `registry.priceMaxAge`, and nothing enforces `priceMaxAge ≤ inhouseMaxStaleness`
  per asset. Defense-in-depth: mirror the staleness check inline. (3 agents.)
- **A4-I-13.** `ReserveVault.skimExcess` pays surplus to `msg.sender` (manager or any
  OPERATOR), while the adjacent `withdraw` deliberately pays only the signer's linked
  settlement address. ReserveVault is non-upgradable — ops rule: prefer `withdraw`, monitor
  skims.
- **A4-I-14.** `LendingRouter.deposit` validates an arbitrary `vault` only by
  `vault.asset() == aToken`, so anyone can supply via a shim vault despite the pool's
  `supplierAllowed` gate — the "router-only supply" policy is advisory. aTokens stay 1:1
  backed; confirm nothing relies on supplier identity.
- **A4-I-15.** `EToken.updateName` changes `name()` but not the constructor-cached EIP-712
  domain — after a post-split rename, integrators deriving the permit domain from live
  `name()` produce invalid signatures. Document the canonical domain. (2 agents.)
- **A4-I-16.** `_lastPremiumBps == 0` doubles as the "unobserved" sentinel, but 0 is a
  legitimate observation when `basePremiumBps = 0` and utilization floors to 0 — the window
  then bills at the live closing premium (the retro-repricing the sample exists to prevent).
  Config guard: keep `basePremiumBps > 0`, or use a +1-offset sentinel on redeploy. (2 agents.)
- **A4-I-17.** `setChainlinkConfig` overwrites config but keeps the previously pushed in-house
  price cached (`disableAsset` deletes both) — after a reconfig with new price semantics the
  old-unit price can serve until it ages out. One-line `delete _prices[asset]` mirror.

- **A4-L-18 — Borrow-rate setters reprice the elapsed accrual window.** Mechanism confirmed
  (`setMinAaveBorrowRateBps` / `setRateParams` do not `_accrue()` first; on Robinhood the floor
  is the whole base rate). Decision (2026-09-02): acknowledged, no fix — rate changes are rare,
  timelocked ADMIN actions; ops runs `accrue()` (permissionless) in the same batch before the
  setter, which settles the window exactly. Revisit if rate changes become frequent.
- **A4-L-02 — Sorted-list ordering drifts under lazy fee accrual.** Documented in the
  interface ("bounded by the stability fee rate"); drift ≤ `stabilityFeeBps × elapsed` (≈2%/yr
  at launch params), redemption still pays par, so ordering fairness only. The permissionless
  1-wei-repay grooming variant lives in the same envelope. Decision (2026-09-02): accepted;
  revisit before raising `stabilityFeeBps` materially.
- **A4-L-04 — `maxAnchorAge` vs liquidation bonus.** This is the protocol-wide stale-anchor
  exit rule (exits work off-hours against the last anchor, no age bound) already adjudicated
  for the PSM and BorrowManager (see audit-report-3 / `psm-design.md` §2). A keeper can only
  liquidate a position that is unsafe *at the anchor*; the anchor is the only price the
  protocol has while the market is closed, and the 130%→105% band is the buffer. Accepted;
  total-outage monitoring is an ops item.
- **A4-L-05 — Threshold raise assumes ADMIN behind the timelock.** Verification item, already
  on the launch checklist (ProtocolRegistryAdmin under timelock from launch). Acknowledged.
- **A4-L-06 — Protocol-global ADMIN/OPERATOR namespace.** All 15 role-gated contracts resolve
  the same `keccak256("ADMIN")` / `keccak256("OPERATOR")`; this is the protocol's access-control
  model, not a module deviation. Accepted.
- **A4-L-09 — `setPartner` + permissionless `sweepPartner`.** Requires a malicious or
  compromised ADMIN key, which already controls `recoverReserve` and the controller wiring;
  no new trust is introduced. Decision (2026-09-02): acknowledged, no hardening — partner
  registration is an announced governance action for pooled contracts only.
- **A4-L-16 — `haltAsset` price unbounded, operator-set, permanent.** `VaultManager` is
  immutable; containment is operational (operator-key hygiene, `haltAsset` parameter
  monitoring, fund `haltRedeemAddress` approvals only after halt-price review). Acknowledged.
  **Widened (2026-09-02, round 3; 2 agents).** Since the A4-M-04 fix, `EUSDManager._anchorPrice`
  returns `_effectivePrice(assetHaltPrice)` for a halted collateral with no bound, no feed cross-check
  and no ADMIN override, so the instant-role, irreversible `haltAsset(asset, price)` is now the *sole*
  liquidation/redemption price for every eUSD CDP in that collateral — a path the `haltRedeemAddress`
  containment does not touch. `haltAsset(SPY, 1)` (operator key compromise or a decimals fat-finger)
  → any account `liquidate(eSPY, victim, 96 wei)` (ratio 0) seizes the victim's full collateral, or
  `redeem(eSPY, 1e18)` walks the list taking each position's collateral for ~100 wei; irreversible (no
  un-halt), and the delayed ADMIN has no lever (`setCollateralEnabled` does not gate exits, by
  design). Contrast the market: `redeemHalted` is capped by the halt fund's approval and `psmRedeem`
  reverts `RatioJumpExceeded`. Unlike `VaultManager`, `EUSDManager` is upgradeable, so a manager-side
  containment exists if wanted: store `lastLivePrice[collateral]` on every successful live read and
  revert `HaltPriceOutOfBand` when the halt price falls outside a wide band of it (e.g. 0.5×–2×), with
  a delayed-ADMIN `setHaltPriceOverride` for legitimately out-of-band halts. A second beneficiary
  path (trust-gap): for a halted asset `ReserveVault._releaseCollateral` marks exposure at the halt
  price (`pullAssetPrice` returns early with `mark = haltPrice`) but the reserve at the live wrapper
  price, so a low halt price manufactures `units × (wrapperPrice − haltPrice)` of skimmable "surplus"
  for any allowlisted maker or the operator, while `psmRedeem` pays PSM depositors only
  `haltPrice / wrapperPrice` wrapper per eToken; minimal guard: block `withdraw`/`skimExcess` while
  `isAssetHalted(backed)`. Surfaced once for the decision; status unchanged.
- **A4-I-18 — `OwnIncentives.setDistribution` has no `emissionPerSecond` bound (round 3; 5 agents).**
  §6 recorded the bound as landed under the A4-I-09/I-10 line, but `setDistribution` carries only the
  `NotAttached` gate. An absurd value overflows `emissionPerSecond × Δt` in `_updateGlobal`, reverting
  `claim`, `sweepPartner`, `setDistribution` itself and every sEUSD hook (swallowed by the `try/catch`,
  leaving `_userIndex` unsynced); the controller is not upgradeable, so recovery is detaching via
  `setIncentivesController`. Admin-only misconfiguration → Info; the ledger entry is corrected in §6
  and the one-line `MAX_EMISSION` check stays optional.
- **A4-I-19 — `EUSD.setBridgeLimits` enabling a previously-zero side of a live bridge starts it empty
  (round 3; 5 agents).** `live = mintMaxLimit != 0 || burnMaxLimit != 0` is evaluated per bridge, so
  raising one side from 0 → X while the other side is live routes that side through
  `_available(_, 0, _) == 0` and it refills linearly over `LIMIT_DURATION` instead of starting full —
  contradicting the "fresh authorization starts with a full window" comment for that side. Fail-safe
  (never over-grants); ops nuisance only. Fix if wanted: compute `live` per side.
- **A4-I-20 — `StakedEUSD.setIncentivesController(current)` retires the live controller in place
  (round 3; 6 agents).** `_retiredControllers[current] = true` runs before the `controller == current`
  case is excluded, so an idempotent re-set marks the attached controller retired while it keeps
  accruing; a later detach → re-attach of that same (still funded) controller is then refused,
  forcing a redeploy plus reserve migration. No fund impact; add `if (controller == current) revert`
  (or skip the retire mark when equal).
- **A4-L-17 — Pending-deposit escrow counted by pool health gates.** Duplicate of the tail risk
  adjudicated in the second GPT-5 batch (2026-07-10): the escrow is refund-senior via
  `totalAssets()` saturation, it is only insolvent after a total LP wipeout, and holding the
  escrow outside the vault would *lower* the vault's health factor and worsen the outcome.
  Accepted; cross-ref `audit-report.md` H-07/M-13 note.
- **A4-M-05 — Force-execute on a PSM-backed asset lets the maker collect the freed reserve
  surplus while generic-vault LPs pay.** Mechanism confirmed (2026-09-02): `closeExposure` on a
  force-executed redeem frees a reserve slice into the maker-withdrawable surplus
  (`ReserveVault.withdraw`, guard `rwaCollateralUSD ≥ exposureUSD`) while the payout came from
  an allowlisted generic vault. Live state at review: TSLA has a PSM wrapper, one generic vault
  (`0x2467…57FC`) is allowlisted as its force source, and `claimThreshold == 0` (force disabled
  globally). **Decision: accepted.** Makers are trusted, admin-allowlisted counterparties with
  exclusive per-asset quoting (`setMakerAllowed`); non-performance on redeem orders by a maker
  is a trust-model breach handled by de-allowlisting, not a permissionless exploit, and the
  same trust already underwrites the RFQ channel and reserve custody. No code change; the
  exit-ladder documentation stands. Ops note (not pushed): if force-execution is ever armed
  (`setClaimThreshold > 0`) on an asset that also has a PSM reserve, the allowlisted generic
  vault's LPs are the counterparty to any maker non-performance — keep that pairing deliberate.
  **Widened (2026-09-02, round 3; first-principles).** The trusted-maker boundary is wider than the
  write-up states. An allowlisted maker can sign a Mint quote with `quote.user` = its own linked
  address and call `executeOrder`: `_settleMint` moves the stablecoin maker → maker (zero net cash),
  `openExposure` passes with no generic collateral while `assetExposureUSD ≤ assetRwaCollateralUSD`
  (RWA netting) or within utilization headroom, and the maker receives freshly minted eTokens;
  `psmRedeem` then releases the wrapper reserve to the maker through the market-gated
  `releaseCollateral` (no surplus guard on that path — A3-M-09). Capital-free, needs neither an armed
  `claimThreshold` nor an allowlisted force-source vault, and the one-wrapper-unpaused lever does not
  help because the maker is the minter. Same trust root (admin-allowlisted maker; de-allowlisting is
  the remedy), so the acceptance stands — recorded so the boundary reads accurately: the reserve is
  only as safe as every allowlisted maker's quote-signing key.
- **A4-L-03 — No `minDebt` floor on redemption.** Explicitly documented in `IEUSDManager`
  ("a partial redemption may leave the last position below minDebt"); Liquity-class behavior.
  Impact is dust-position list bloat only. A4-H-01 Option A removes the only harmful instance
  (the zero-collateral case). Decision: accepted. *Round-2 note (one-time, not pushing):* one
  agent observed that clamping `repaid` so the remainder is 0 or ≥ minDebt would not block
  redemption liveness (the bite is merely rounded), so the acceptance carries no
  liveness-tradeoff cost if ever revisited.
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
- **A4-I-06 — Bridge burn+mint pairing evades the `netBridgedIn` global cap.** A compromised
  bridge can burn X from a victim (allowance-free, decrementing `netBridgedIn`) and mint X to
  itself in the same window: net stays flat, `GlobalBridgeCapExceeded` never fires, and total
  supply is unchanged — invisible to supply monitoring. The global ceiling therefore bounds
  *net inflation*, not *cumulative theft*: the paired flow is per-window theft of existing
  holders' funds, and the "griefing within one window" NatSpec is inaccurate for it. Within the
  accepted trusted-bridge model (A4-I-05) — noted so limit sizing and monitoring treat
  per-window `min(mintMaxLimit, burnMaxLimit)` as a theft budget; correct the NatSpec before
  any transport is authorized. **Widened (round-1 re-review, 3-agent convergence):** victim
  burns are not even required — `netBridgedIn` is net across all bridges with no floor, so
  *organic outflows* through any honest bridge (or a burn-only bridge driving net deeply
  negative) permanently grant every other bridge cumulative mint headroom: a compromised
  bridge's total unbacked mint is bounded by total historical outflow + the cap, not by the
  cap. Fix direction if bridging is ever armed: track net per bridge (cap each bridge's
  cumulative net) instead of one global signed accumulator.
- **A4-I-07 — OWN sent directly to OwnIncentives is unrecoverable.** `rewardReserve` is
  credited only by `fund()`, and both `_pay` and `recoverReserve` are capped at
  `rewardReserve`, so a plain transfer/airdrop above the reserve is permanently locked.
  Accepted; a one-line cap-at-balance in `recoverReserve` (or a surplus skim into the reserve)
  removes it.
- **A4-I-08 — `recoverReserve` can pull reserve backing accrued-but-unclaimed OWN.** No
  solvency check against outstanding accrued liability (not cheaply computable on-chain under
  the index model); shortfalls become first-come-first-served, surfaced via `RewardShortfall`.
  Consistent with the documented capped-budget design — noted; recommend a keeper-side
  invariant check (reserve ≥ Σ accrued) before any admin recovery.
- **A4-I-09 — Zero-amount `crosschainMint`/`crosschainBurn` succeed for any caller. — FIXED (2026-09-02: `ZeroAmount` revert on both ERC-7802 entry points; test `test_crosschain_zeroAmount_reverts`).**
  `_consumeLimit(_, 0)` passes even with a zeroed config (`0 > 0` is false), so any EOA can
  emit genuine `CrosschainMint`/`CrosschainBurn` events with itself as the "bridge" — polluting
  exactly the event surface bridge monitoring and indexers watch. No fund impact; fix is a
  one-line `amount == 0` revert on both ERC-7802 entry points.
- **A4-I-10 — `setBridgeLimits` resets `remaining` to the new maxima. — FIXED (2026-09-02: a fresh authorization starts with a full window; an update to a live bridge settles accrued capacity via `_available` and clamps to the new maxima, never refilling; tests `test_setBridgeLimits_lowerMidWindow_clampsNoRefill`, `test_setBridgeLimits_raiseMidWindow_noRefill`, `test_setBridgeLimits_reauthorizeAfterZero_fullWindow`).** Any limit update —
  including a *lowering* — hands the bridge an instant full window on top of what it just
  spent (momentary 2× per-window throughput), worst exactly during an incident when limits are
  being tweaked. Settle-then-clamp the remaining values instead of resetting.

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

**Staking module (2026-09-02 pass)**

- Swallowed-hook fragility: `StakedEUSD._update`'s `try/catch` can silently skip a checkpoint,
  which would reproduce A4-M-02's over-accrual *while attached*. No unprivileged trigger exists
  today — EIP-150 gas-griefing was proven infeasible by five agents independently, and the only
  deterministic revert needs an admin-absurd `emissionPerSecond` (~1e59/s overflow). Becomes
  real if a future controller adds revert paths or &gt;~1M-gas work: emit an event in the catch
  branch, and bound `emissionPerSecond` in `setDistribution`.
- `setVestingPeriod` shrink → near-instant vest of the crystallized remainder, capturable by a
  JIT depositor front-running the admin tx (no cooldown). ADMIN-gated and bounded to pending
  yield; consider a floor or timelock on the period.
- Orphaned mid-vest batch: if all shareholders exit, the still-unvested batch vests to nobody
  and is captured by the next depositor. Mitigated by the seed (dead shares never fully exit);
  operator lever: pause streaming when supply ≈ seed. **Sharpened (round 3, invariant):** with
  `_decimalsOffset() == 0`, if supply reaches exactly 0 while `L` is still unvested, the first
  depositor of `L + 1` receives **1 wei** of shares and every later depositor of `≤ L` receives 0 —
  the offset-0 defence assumes the attacker funds the inflation, but here the protocol's own batch
  does (stream 10,000 mid-vest, all exit, attacker deposits 10,001 → 1 wei share; victim deposits
  5,000 → 0 shares; attacker redeems 12,500.5). **No production deploy script for StakedEUSD exists
  yet** (see the A4-L-11 ledger correction in §6), so the seed is not enforced anywhere. Code
  invariant options: revert a withdrawal that would leave `totalSupply() == 0` while
  `getUnvestedAmount() > 0`, or set `_decimalsOffset()` to 6 before deploy (UUPS cannot change it
  later).
- Direct eUSD transfer to the vault bypasses vesting and jumps the share price — donor-funded,
  but a *predictable* mis-routed inflow (operator using `transfer` instead of
  `transferInRewards`) is sandwichable. Ops discipline; optional `skim()` folding surplus into
  the vesting batch.
- Deploy atomicity: `DeployEusdRobinhood.s.sol` initializes the EUSDManager proxy atomically in
  the `ERC1967Proxy` constructor, but **no production deploy script exists yet for
  StakedEUSD/OwnIncentives** — a two-tx deploy is initializer-front-runnable (attacker-supplied
  `registry` = full takeover). Tracked in §6.

**New-contracts re-audit (2026-09-02, round 3)**

- Residual re-list grief (execution-trace, forge PoC): the owner of a debt-only residual (collateral 0,
  off-list after A4-H-01/A4-M-06 events) can `deposit(1 wei)` — nominal ratio ≈ 0 puts it at the list
  head for ~75k gas — and every redemption then hits it first: bounded walks with a real
  `minCollateralOut` revert `SlippageExceeded` (1 wei out), unbounded walks pay ~+9k gas per hop and
  clear it for ~400 wei, after which it re-lists. Gas grief on the peg anchor only. Fix: require a
  debtor's deposit to leave the position collateral-backed above a dust floor before it (re)enters the
  list, or skip sub-wei heads in `redeem`.
- 1-wei third-party `repay` front-runs a *sized* partial liquidation (trust-gap): a `repay(coll, owner,
  1 wei)` flips the liquidator's `remaining` to `minDebt − 1` and the liquidation reverts
  `BelowMinimumDebt`; `amount = max` is immune. Liveness/MEV grief only; clamping `0 < remaining <
  minDebt` to a full close (see A4-M-06 / A4-L-03 note) removes it.
- `setAssetActive(false)` is honored by `OwnMarket._validateAsset` and `BorrowManager._validateEligibility`
  but not by `EUSDManager.mint`/`_freshPrice`, so the operator's soft-freeze lever leaves the CDP as the
  one new-exposure path still open on a deactivated eToken. Consistent with the recorded "delist via
  `haltAsset`" rule; a one-line `isActiveAsset` gate in `_freshPrice` closes the asymmetry if the lever
  is ever used as a soft freeze.
- PSM ratio-jump baseline re-anchors on a frozen mark (invariant) — **superseded by A4-L-19**: the
  per-operation guard (no 24h window despite psm-design §8.3's Ondo reference) is walkable, and the
  in-house cache is per ticker, so a signer refreshing `R.TSLA` and `TSLA` divergently opens it even
  though both share one Chainlink feed. The frozen-mark redeem variant is folded into that write-up.

**Protocol-wide re-audit (2026-09-02, round 3)**

- `ForceExecuteLib._refundETH` sibling of A3-L-05 (boundary): refunds `address(this).balance` to
  `msg.sender` and reverts `ETHRefundFailed` on failure; 1 wei force-fed to the market (a same-tx
  `selfdestruct` still pushes ETH under EIP-6780) makes `forceExecuteOrder` revert for any order owner
  that is a contract without a payable receive — the last-resort exit, though `cancelOrder` and RFQ
  remain. A3-L-05's acceptance covered `BorrowManager` only; snapshot `balance − msg.value` or make the
  refund best-effort on the next `OwnMarket` upgrade.
- Util-neutral PSM mints consume `assetCapUSD` (economic-security): `openExposure` charges gross
  `newAssetUSD` against the ceiling regardless of RWA netting, so a wrapper holder can fill a
  ticker's cap risk-free (reversible via `psmRedeem`) and block every RFQ/PSM mint for everyone else.
  Consistent with protocol.md's "issuance ceiling caps total eToken supply"; policy note only — if the
  ceiling is meant for LP-backed issuance, cap the netted residual or add a separate PSM ceiling.
- ReserveVault surplus clamp is asset-level, not per-vault (economic-security): `_releaseCollateral`
  compares Σ RWA collateral to Σ exposure across *all* reserve vaults for the ticker, so with two
  wrappers a maker can `withdraw` one vault down while the other covers the aggregate, and holders
  routed to the drained wrapper get `AmountExceedsReserve` on `psmRedeem`. Dormant (one wrapper per
  asset live; psm-design allows several); distinct root from A3-M-09 (oracle) and M-14 (stale mark).
- LP exit floor is 17.5%, not the 25% the deploy comment states (economic-security):
  `DeployRobinhood.s.sol` says pool LTV 75% "guarantees ≥ 25% of LP funds stay as cash", but LP exits
  are gated by `requireVaultHealthy` (HF ≥ 1.1 at LT 100%), so at the designed 75% pool-debt steady
  state only `1 − 1.1 × 0.75 = 17.5%` of LP capital is exitable, and each claim crank tightens it.
  Extends A3-L-02 with the live-parameter number; fix the comment or lower `minClaimHealthFactor`
  toward 1.0 for LT = 100%.
- ERC-4626 preview conformance (economic-security): `_depositWithMin` runs `_syncLending()` after any
  caller-side `previewDeposit`, so `deposit` can mint fewer shares than previewed in the same
  transaction, and `maxDeposit` returns max while `deposit` can revert `VaultInsolvent`. Integrators
  without `minSharesOut` over-estimate; no loss.
- `BorrowManager.setLiquidationConfig` lacks the `threshold ≥ BPS + bonus` guard that
  `EUSDManager._validateRatios` enforces (asymmetry): a bonus above `BPS/threshold − 1` lets a
  threshold liquidation seize 100% of collateral (capped) and return 0 to the borrower. Protocol
  solvency unaffected; borrower-only under admin misconfiguration.
- `OwnLendingPool.borrow` is open to any aToken holder at 0% (access-control): a shim-vault depositor
  (A4-I-14) can lock pool liquidity at 1.25× their own capital with no profit path — extends the
  audit-3 "supplier allowlist constrains nothing about who borrows" note with the griefing angle;
  gate `borrow` to delegated/allowlisted borrowers if the router-only policy is meant to bind.
- `absorbBadDebt` dust-collateral griefing (trust-gap, invariant): it reverts
  `PositionStillCollateralized` unless `eTokenCollateral == 0`, while `addCollateral` has no minimum,
  so a defaulted borrower can re-arm the guard with 1 wei after every dust liquidation. Fully mitigable
  by bundling a dust `liquidate` with `absorbBadDebt` in one operator transaction; optional hardening:
  sweep sub-unit collateral to the treasury instead of reverting.
- Unswept dividends as a second JIT entry point (invariant): `_syncLending` realizes only the yield
  shell's balance; dividends accrued to the BorrowManager's eToken custody are released by the
  permissionless `sweepDividends`, so deposit → `sweepDividends` → exit captures pre-entry dividends.
  Dormant under A3-M-07 (no on-chain cash dividends on Robinhood); recorded so that acceptance's
  precondition list covers the custody sweep as well as `depositRewards`.
- Approval mode has no LP entry path on an OwnLendingPool-backed vault (invariant): `supply` is
  allowlisted to the router and the router only calls `vault.deposit`, which reverts
  `DepositApprovalRequired`; nothing lets an LP mint aTokens to call `requestDeposit`. Functional gap,
  no fund impact — a router `requestDeposit` passthrough is needed before approval mode is used there.
- Collateral double-encumbrance (trust-gap): `_globalCollateralUSD` counts 100% of a generic vault's
  aTokens as eToken backing while up to `targetLtvBps` (70%) of the same aTokens are pledged as pool
  collateral for BorrowManager debt, and `requireVaultHealthy` makes the pool claim senior — at the
  debt cap the collateral a force-execution can actually release is ≤ `C·(1 − 0.77/LT)`. Fails safe
  (HF gate), but the utilization cap overstates the collateral behind the users' last-resort exit
  once lending runs near cap; adjacent to A3-L-02 / H-07. Consider netting the vault's pool debt out
  of its counted collateral.
- `settleHaltedPosition` on legacy dust (numerical-gap): it calls `convertLegacy` unconditionally when
  the position holds a pre-split token, and `convertLegacy` reverts `ZeroAmount` when the converted
  amount floors to 0, while `absorbBadDebt` still requires `eTokenCollateral == 0` — a few wei of
  legacy collateral with live debt would be neither settleable nor absorbable. No realistic path to
  such a residual was constructed (borrow LTV forbids it directly); hardening: skip the convert when
  the result is 0 and settle with `eTokenToCover = 0`.

**Protocol-wide (2026-09-02, round-2 pass)**

- Split-day multi-clock atomicity: `ChainlinkOracleVerifier` divides the feed by the token's
  **live** `uiMultiplier()` (`:325-327`) for `multiplierToken` tickers, so three separate
  actors re-denominate at three separate times on a split — the exchange's feed adjustment,
  the issuer's multiplier flip, and the protocol's `migrateToken`/`applySplit`. Any
  non-atomicity window mis-marks the asset by the split ratio, and `BorrowManager.liquidate`
  is deliberately not gated by trading pause. One agent traced a wrongful-liquidation window;
  the exact direction depends on whether feed and multiplier adjustments cancel by design —
  verify the intended composition, encode the split runbook (pause/disable the asset across
  the flip), and consider caching the multiplier at config time and failing closed on
  deviation.
- `fulfillWithdrawal` is permissionless with no per-request `minAssetsOut` for direct LPs — a
  third party can crystallize a victim's matured exit at a transient low (all drawdown sources
  traced are permanent, so this is timing/optionality grief, adjacent to the acknowledged
  non-FIFO/exit-before-loss decisions). Revisit only if a transient-dip source is ever added.
- `pullAssetPrice` restamps `_assetMarkUpdatedAt = now` while discarding the oracle's own
  timestamp — mark-age gates measure keeper recency, not price recency. Matches the recorded
  "asset-only stale-mark gate" decision; confirm that decision consciously covers the
  restamp-to-now semantics (3 agents flagged it independently as calibration).
- The in-tree `VaultYieldManager` distributes yield as an instant step; the
  `StreamingVaultYieldManager` that fixed the JIT-capture class on Base is **not in `src/`** —
  confirm which yield manager the Robinhood deployment wires before launch.

---

## 6. Migration / ops checklist (open)

- [x] A4-H-01 — implement Option A (or decide Option B accounting), add partial-underwater
      regression test + "no listed node with zero collateral" invariant, re-run full suite.
- [x] A4-H-02 — implement Option A (`_activeUnits` scaling at all valuation/seizure sites) or
      decide Option B (`onSplit` hook / block-migration-with-open-positions); add forward- and
      reverse-split regression tests + a split-invariant-value invariant; re-run full suite.
      **Treat as a launch blocker for using any split-eligible eToken as eUSD collateral.**
- [ ] A4-M-01 — decide accept/skip-hint/backstop for underwater heads; document the decision in
      the interface NatSpec either way.
- [x] A4-L-01 — confirm intended freshness semantics; document effective bound on
      `setMintPriceMaxAge` or add a strict-timestamp oracle read.
- [ ] A4-L-04 — check deployed `maxAnchorAge` vs `liquidationBonusBps` on Robinhood config.
- [ ] A4-L-05 — verify registry ADMIN grant for EUSDManager is timelock-gated before launch.
- [ ] A4-L-06 — confirm global-role scoping is intended for this module.
- [x] A4-L-07 — add deploy-time sole-minter assertion to `DeployEusdRobinhood.s.sol` (landed:
      `MINTER_ROLE` asserts only).
- [ ] A4-L-07 (ledger correction, round 3) — the `TREASURY` non-zero assertion recorded above as
      landed is **not** in `DeployEusdRobinhood.s.sol`. `_accrue` mints the stability fee to
      `registry.treasury()` with no zero check (every other treasury sink in the codebase guards),
      so with the slot unset every debt-bearing path — including `liquidate` and `redeem` — reverts
      `ERC20InvalidReceiver` once any fee > 0 accrues; recoverable only through the timelocked
      `setAddress`. Add the deploy assert and/or an `initialize` check (4 agents).
- [x] A4-L-08 — confirm the eSPY eToken reward model (claimable vs. rebasing); if claimable, add a
      permissioned `claimCollateralRewards` mirroring `OwnMarket.sweepDividends`; if rebasing,
      additionally reconcile `totalCollateral` against real balance.
- [x] A4-M-02 — implement Option A (freeze accrual while detached) and/or Option B (wiring-seam
      guards); add detach/re-attach and distribute-before-attach regression tests plus a
      Σ-claimed ≤ emission×time invariant.
- [ ] A4-L-09 — enforce contract-only partners or settle-first on `setPartner`; confirm the
      partner reward model.
- [x] A4-L-10 — exempt indebted top-ups from the `enabled` gate in `deposit` (or record as
      accepted with a de-listing runbook that repays/closes before disabling).
- [x] A4-L-11 — `totalSupply() > 0` guard on `transferInRewards` (landed).
- [ ] A4-L-11 (ledger correction, round 3) — the production deploy script for
      StakedEUSD/OwnIncentives recorded above as done (atomic proxy init + seed deposit + wiring
      order: attach controller **before** `setDistribution`; decommission order
      `setDistribution(0,·)` → settle → `recoverReserve` → detach) does **not** exist in `script/`
      (only the test helper `DeployEusdModule.sol`). Until it does, the dead-share seed that mitigates
      the orphaned-batch lead (§5) is unenforced and a two-transaction deploy is
      initializer-front-runnable.
- [x] A4-L-12 (DoS clamp landed; burn-limit sizing stays ops) — size every per-bridge `burnMaxLimit` ≪ sEUSD vested TVL before authorizing any
      transport; decide on the `totalAssets` clamp; fold A4-I-06's paired burn+mint budget into
      bridge monitoring.
- [x] A4-M-03 — decide partial liquidation (`liquidate` with an `amount`) vs a per-position
      size cap; add a whale-starvation regression test (ceiling filled, circulating < debt).
- [x] A4-M-04 — add the halt gate to `mint`/`withdrawCollateral` and decide halted-collateral
      valuation on exits (`min(oracle, haltPrice)`); add a halted-asset mint regression test.
- [x] A4-L-13 — add the `order.expiry` check to `ForceExecuteLib._validateForce` (completes the
      A3-L-03 remediation); regression test: expired order unfillable AND unforceable.
- [x] A4-L-14 — gate the `p.debt > 0` branch of `withdrawCollateral` on `mintPaused`; incident
      runbook: throwing the mint pause must actually stop value extraction.
- [x] A4-L-15 — add the `code.length` guard to `setIncentivesController` + extcodesize unit
      test.
- [x] A4-I-09 / A4-I-10 — zero-amount revert on the ERC-7802 pair; settle-then-clamp in
      `setBridgeLimits`.
- [ ] A4-I-18 (ledger correction, round 3) — the `emissionPerSecond` bound in
      `OwnIncentives.setDistribution` previously listed on the line above as landed is **not** in the
      code (an absurd value overflows `emissionPerSecond·Δt` in `_updateGlobal`, bricking `claim`
      and `setDistribution` itself; recovery = detach the controller). Add `MAX_EMISSION` or record
      as accepted admin-config risk.
- [x] A4-M-06 — Option A landed (pro-rata partial seizure cap) with the two regression tests.
      Still open from the same item: the `remaining < minDebt → full close` clamp (see the §5 1-wei
      `repay` grief) and a listed-solvency invariant in the handler.
- [x] A4-L-12 (reopened) — sEUSD entries gated via `maxDeposit`/`maxMint` while
      `getUnvestedAmount() > totalAssets()`; regression updated to assert the revert and the pro-rata
      post-vest payout. (The underlying bridge-burn loss leg remains ops-bounded: keep every
      `burnMaxLimit` well below vested TVL before authorizing a transport.)
- [ ] A4-L-16 (widened) — decide whether `EUSDManager._anchorPrice` should bound the halt price
      against the last live anchor (manager-side, upgradeable) or stay ops-only.
- [ ] A4-I-19 / A4-I-20 — per-side `live` in `setBridgeLimits`; reject `setIncentivesController(current)`.
- [x] A4-M-07 — reassessed to Low and acknowledged (self-corrects on the next `accrue`); no code change. Optional
      hardening only if the keeper cadence is ever relaxed: bill `max(open, close)` per window.
- [x] A4-M-08 — reassessed to Low and accepted (backlog realized continuously by normal LP flow;
      live vault is approval-mode + 8h queue). Optional hardening if an open-deposit vault ever runs
      at sustained full utilization: escrow-then-price in `_depositWithMin`/`mint` and claim
      `min(claimable, headroom)` in `_claimBestEffort`.
- [x] A4-L-19 — acknowledged (no live code change; verifier + AssetRegistry non-upgradeable). Folded
      into the next oracle/PSM deploy: anchor the ratio-jump guard to the Chainlink-implied ratio (or
      key the in-house cache by aggregator; regression: opposite-edge two-leg pushes revert on the
      first PSM op), and correct the CL-I01 damage-cap wording (≈ 2× band for derived PSM ratios).
- [x] A4-M-05 — accepted (trusted, allowlisted maker; see §3). No code guard; keep the
      force-source pairing for PSM-backed assets deliberate when `claimThreshold` is armed.
- [ ] A4-L-16 — operator-key runbook + monitoring on `haltAsset` params (VM immutable, no code
      fix); fund `haltRedeemAddress` approvals only after halt-price review.
- [ ] A4-L-17 — move pending-deposit escrow out of the vault address (or accept with a
      documented approval-mode sizing rule); regression test: padded health gate + frozen
      cancel.
- [x] A4-L-18 (acknowledged — accrue() before rate setters, ops) — `_accrue()` at the top of `setMinAaveBorrowRateBps`/`setRateParams` on the
      next BorrowManager deploy; until then, rate-change runbook: crank `accrue()` in the same
      block before the setter.
- [ ] A4-I-11…I-17 — batch of small guards/doc items (see write-ups): confirm fee-accrual
      ceiling bypass intent, inline staleness check, skim destination, supplier-allowlist
      policy, permit-domain doc, `basePremiumBps > 0` config guard, `delete _prices` on
      reconfig.
- [ ] Split runbook — verify feed/uiMultiplier/migrateToken composition and atomicity
      (see §5 protocol-wide leads); pause or disable the asset across any scheduled
      corporate-action flip.
- [ ] Yield manager — confirm StreamingVaultYieldManager (not the in-tree step-function VYM)
      is what the Robinhood deployment wires; the JIT-capture class returns otherwise.

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

Staking module (2026-09-02 pass), attacked and held:

- **Vesting continuity:** `totalAssets` is provably continuous across `transferInRewards`
  top-ups and `setVestingPeriod` changes (no jump, no sandwich instant); unvested rounds up so
  `totalAssets` floors; `balance ≥ unvested` holds inductively through all vault flows, so
  `totalAssets()` cannot underflow via ERC-4626 paths (external bridge burns are A4-L-12).
- **Incentives index algebra:** the pre-change-balance hook and live-read claim agree
  segment-by-segment under every ordering tried (flash-mint-and-claim accrues 0; zero-supply
  and post-`distributionEnd` gaps are forfeited, never back-paid; `earned` exactly mirrors the
  write path; `_pay` is reserve-capped with shortfall retention; floor rounding favors the
  reserve; `from == to` double-hook excluded).
- **Hook gas-griefing:** forcing the `try/catch` to swallow a checkpoint via OOG is infeasible
  (EIP-150 63/64 arithmetic), independently verified by five agents.
- **UUPS conversion (EUSDManager + StakedEUSD):** `_disableInitializers` on both
  implementations; atomic proxy-constructor init in `DeployEusdRobinhood.s.sol`;
  ERC-7201-namespaced `Initializable`/`ReentrancyGuard` (proxy `_status = 0` is benign under
  OZ v5 `== ENTERED` semantics); EIP-712 domain rebuilds behind the proxy (`_cachedThis`
  mismatch); ERC-4626 `_asset`/decimals are implementation immutables with
  `_authorizeUpgrade` pinning the asset across upgrades; name/symbol pinned as `pure`
  overrides; no storage collisions; bare-implementation and non-admin upgrade paths blocked.
  The EUSD delta is metadata-only on a pre-launch token (no outstanding EIP-712 signatures).
- **Access control (staking):** every state-changer correctly gated; `handleAction` caller-locked
  to the sEUSD proxy; `sweepPartner`'s permissionless trigger cannot steer funds; no storage
  written by both guarded and unguarded paths.

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
- New-contracts addendum (2026-09-02, round 1): a 12-agent pass over the five contracts new on
  the branch vs `main` (EUSDManager, OwnIncentives, ForceExecuteLib, EUSD, StakedEUSD, with
  OwnMarket read as caller context) produced A4-M-03, A4-M-04, A4-L-13…L-15, A4-I-09/I-10, and
  the A4-I-06/A4-L-09 widenings. Heavy re-derivation of known IDs confirmed A4-H-01 (7 agents),
  A4-H-02 (4 agents), A4-M-02 (all agents), A4-L-03/L-08/L-10/L-11 — folded into existing IDs.
  ForceExecuteLib's delegatecall extraction itself verified clean by every agent that attacked
  it (direct-call, cancelled-order replay, ETH-fee, decimal, and RWA-vault-source vectors all
  blocked); its one defect is the pre-existing A4-L-13 expiry gap, which git history shows was
  never implemented despite external A3-L-03 being marked Fixed (the price-freshness half was).
- Protocol-wide addendum (2026-09-02, round 2): a 12-agent pass over all 25 `src/` contracts,
  deduplicated against this document, `audit-report-3.md`, and the three external audit PDFs
  (02-07 / 12-07 / 03-08). Produced A4-M-05, A4-L-16…L-18, A4-I-11…I-17, the A4-H-02/A4-M-04
  addenda, and the §5 protocol-wide leads (split multi-clock, yield-manager confirmation).
  A4-H-02 was re-derived by 8 of 12 agents — treat it as the launch-blocking priority. Core
  conservation invariants (VaultManager global totals, OwnMarket exposure↔supply pairing across
  all seven settle paths, OwnLendingPool solvency, BorrowManager scaled-debt bookkeeping and
  partial-repay floors, EUSD bridge limit buckets, sEUSD vesting continuity) were attacked and
  held across multiple agents; every previously adjudicated design (stale-anchor exits,
  pullAssetPrice restamp, PSM ratio-guard trip, non-FIFO queue, vault-pause semantics) was
  re-recognized and not duplicated. All external-PDF findings were checked against current
  source: the only remediation gap found is A4-L-13 (A3-L-03's expiry half, recorded in round
  1); no other fixed finding has regressed.
- Staking addendum (2026-09-02): a further 12-agent adversarial pass over the staking module
  (StakedEUSD, OwnIncentives) and the EUSDManager/EUSD deltas since commit `c10c9fd` (UUPS
  conversion, token rename) produced A4-M-02, A4-L-09…L-12, and A4-I-06…I-08. A4-M-02 had
  11-agent convergence (4 as findings with matching numeric traces). Known items re-derived in
  this pass — A4-H-01 (2 agents), A4-L-03 (2 agents), and the A4-L-02 grooming variant — were
  folded into their existing IDs, not duplicated. The UUPS deltas themselves cleared every
  proxy-specific trap class checked (see §7).
- Trap for future passes (historical): before the A4-H-01 fix the interface NatSpec documented
  the *short-change* on underwater redemption but not the *persistence* of the drained node. The
  NatSpec now states the collateral-backed cap and the off-list residual explicitly.
- Severity here is impact × likelihood and is stated independently of the report's confidence
  scores; A4-L-04/L-05 escalate to Medium if the respective config checks fail.
- Rate configuration-dependent items against the deployed Robinhood config
  (`broadcast/…/run-latest.json`), not `script/` alone, once the module ships.
- New-contracts re-audit (2026-09-02, round 3): a fresh 12-agent pass over the six contracts
  new or materially changed on the branch vs `main` (EUSDManager, OwnIncentives, ForceExecuteLib,
  EUSD, StakedEUSD, OwnMarket), deduplicated against this document, `audit-report-3.md` and the
  three external PDFs, then gate-checked. Produced **A4-M-06** (7-agent convergence; three agent PoCs
  and an orchestrator PoC agree on the numbers), the **A4-L-12 reopen** (3 agents, two PoCs — the
  remedy regressed the failure mode), the **A4-L-16 widening** (EUSDManager consumes the halt price
  for user collateral), **A4-I-18…I-20**, two §6 ledger corrections (the emission bound and the
  `TREASURY` deploy assert were recorded as landed but are absent from code/script), and four §5
  leads. Known items re-derived and folded, not duplicated: A4-L-02 grooming (3 agents), A4-L-03,
  A4-L-04 stale anchor (3), A4-M-02 detach consequences (3), A4-M-03 over-liquidation above 1 + bonus,
  A4-I-12 proof selection, A4-I-05/I-06 bridge trust, A3-M-06 exit gating, the audit-3 `_pushOrSweep`
  and `_settleRedeem` notes, and the §5 donation-bypass lead. Conservation, sorted-list integrity,
  access control, hook algebra, bridge-limit accounting, proxy safety and every ForceExecuteLib gate
  were re-attacked and held. No production code was changed in this pass.
- Protocol-wide re-audit (2026-09-02, round 3): a fresh 12-agent pass over all 25 `src/`
  contracts, deduplicated against this document, `audit-report-3.md` and the three external PDFs
  (02-07 / 12-07 / 03-08), then gate-checked. Produced **A4-M-07** (3 agents; **reassessed 2026-09-03 to Info** — the mispricing self-corrects on
  the next `accrue`, verified on-fixture: a single keeper crank 15 min after the attack restores the
  honest debt to the wei, so the leak is bounded to one inter-touch window and does not clear the bar)
  and **A4-M-08** (2 agents; three-test PoC re-run by the orchestrator) — both sequels to fixed
  pass-3 items (A3-H-02, A3-M-01) whose remedies hold as stated, **both reassessed 2026-09-03 to Low and
  acknowledged** (M-07 self-corrects on the next `accrue`; M-08's premium backlog is drained continuously
  by ordinary LP flow so no capturable lump accumulates) — **A4-L-19** (1 agent; verified against the verifier's per-ticker cache and the
  deployed oracle/PSM parameters; corrects a round-3 lead; **acknowledged 2026-09-03** — fix needs a
  verifier getter, folded into the next oracle/PSM deploy), the **A4-M-05 / A4-L-16 widenings**, a
  third §6 ledger correction (no StakedEUSD/OwnIncentives deploy script exists), a sharpened staking
  lead, and twelve §5 leads. Re-derived and folded,
  not duplicated: A4-L-17 escrow-in-HF (2 agents, with a concrete lock trace), A4-I-13, A4-I-14,
  A4-I-15, A4-I-16, A4-L-04/I-03 weekend-gap composition, A4-L-18, A3-L-03, A3-L-05, A3-M-06,
  A3-M-07, pass-1 L-16 (absorb over-socialization), CL-I02/CL-L03, the §5 split
  multi-clock and step-function yield-manager items, the audit-3 `_settleRedeem`/`_pushOrSweep`/
  halt-desync notes, the pass-1 L-09 halt-settlement ceil dust (comment inaccuracy only: the
  over-cover repays pooled debt rather than sweeping), and the psm-design first-come maker surplus
  rule. Core invariants (VaultManager netting writers, OwnLendingPool exit liquidity, BorrowManager
  scaled-debt and floor, PSM round-trip rounding, EToken accumulator, sEUSD/OwnIncentives hook
  algebra) were re-attacked and held. No external-PDF fix has regressed; no production code was
  changed in this pass. Coverage note: 11 of the 12 protocol-wide agents completed; the flow-gap
  agent was cut off by a spend limit and its retry was stopped on request, so the cross-flow seam
  lens over the full protocol is the one gap in this round.
