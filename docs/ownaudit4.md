# Own Protocol v2 — Audit Report & Remediation Status (Pass 4 — eUSD CDP Module)

**Branch:** `stablecoin` · **Last updated:** 2026-09-02 · **Test suite:** 1400 passing excl. fork suites (+14 for the A4-H-01 / A4-H-02 fixes)

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
| Medium   | 5     | 0     | 5    | 0         |
| Low      | 18    | 0     | 17   | 1         |
| Info     | 17    | 0     | 9    | 8 (noted) |

| ID      | Severity | Finding                                                                  | Status                       |
| ------- | -------- | ------------------------------------------------------------------------ | ---------------------------- |
| A4-H-01 | High     | Partial redemption of underwater position strands unbacked debt at head  | **Fixed** (2026-09-02)       |
| A4-H-02 | High     | Stock split re-denomination silently mis-values all eUSD collateral      | **Fixed** (2026-09-02)       |
| A4-M-01 | Medium   | Redemption cannot skip an underwater head — peg anchor stalls            | **Open**                     |
| A4-M-02 | Medium   | OwnIncentives pays retroactive OWN on balances from unhooked windows     | **Open**                     |
| A4-M-03 | Medium   | Full-debt-only liquidation can be starved of eUSD liquidity (no partial) | **Open**                     |
| A4-M-04 | Medium   | Halted collateral valued at live feed — unbacked mint above halt price   | **Open**                     |
| A4-M-05 | Medium   | Force-execute on PSM-backed asset: vault LPs pay, maker collects surplus | **Open** (ops-gated)         |
| A4-L-01 | Low      | `mintPriceMaxAge` is a no-op inside the oracle's `clFreshWindow`         | **Open**                     |
| A4-L-02 | Low      | Sorted-list ordering drifts under lazy stability-fee accrual             | **Open**                     |
| A4-L-03 | Low      | No `minDebt` floor on the redemption path                                | **By design** — documented   |
| A4-L-04 | Low      | Oracle `maxAnchorAge` width vs liquidation bonus unverified              | **Open** (ops check)         |
| A4-L-05 | Low      | `setRiskParams` threshold raise assumes ADMIN sits behind the timelock   | **Open** (ops check)         |
| A4-L-06 | Low      | ADMIN/OPERATOR role namespace is protocol-global, not per-contract       | **Open** (confirm intent)    |
| A4-L-07 | Low      | `MINTER_ROLE` exclusivity not structurally enforced on EUSD              | **Open** (deploy-time assert)|
| A4-L-08 | Low      | eToken collateral dividends stranded in the manager (no claim path)      | **Open** (confirm reward model)|
| A4-L-09 | Low      | `setPartner` + permissionless sweep can redirect any holder's accrued OWN| **Open** (hardening)         |
| A4-L-10 | Low      | Disabled collateral blocks defensive top-ups while liquidation stays live| **Open**                     |
| A4-L-11 | Low      | sEUSD seed / `totalSupply > 0` before streaming unenforced — 0-share trap| **Open** (deploy-time guard) |
| A4-L-12 | Low      | Bridge `crosschainBurn` vs sEUSD vault: socialized loss + vault DoS      | **Open** (ops check)         |
| A4-L-13 | Low      | Force-execution ignores `order.expiry` (reopens A3-L-03's expiry half)   | **Open**                     |
| A4-L-14 | Low      | `withdrawCollateral` with debt escapes `mintPaused`/`enabled` levers     | **Open**                     |
| A4-L-15 | Low      | Code-less incentivesController bricks sEUSD (try/catch ≠ extcodesize)    | **Open** (guard + unit test) |
| A4-L-16 | Low      | `haltAsset` price is operator-set, unbounded, and permanent              | **Open** (ops; VM immutable) |
| A4-L-17 | Low      | Pending-deposit escrow counted as vault collateral by pool health gates  | **Open**                     |
| A4-L-18 | Low      | Rate setters reprice the elapsed accrual window (no accrue-first)        | **Open**                     |
| A4-I-01 | Info     | `_freshPrice` tolerates future-dated timestamps                          | **By design** — noted        |
| A4-I-02 | Info     | Fee rounds to zero but `feeIndexSnapshot` still advances                 | **By design** — noted        |
| A4-I-03 | Info     | Zero-fee redemption (no Liquity-style base rate)                         | **By design** — noted        |
| A4-I-04 | Info     | `debt * (BPS + bonus)` computed outside `mulDiv`'s 512-bit space         | **By design** — noted        |
| A4-I-05 | Info     | `EUSD.crosschainBurn` burns from an arbitrary `from` (trusted-bridge)    | **By design** — noted        |
| A4-I-06 | Info     | Bridge burn+mint pairing evades the `netBridgedIn` global cap            | **By design** — noted        |
| A4-I-07 | Info     | OWN sent directly to OwnIncentives (not via `fund`) is unrecoverable     | **By design** — noted        |
| A4-I-08 | Info     | `recoverReserve` can pull reserve backing accrued-but-unclaimed OWN      | **By design** — noted        |
| A4-I-09 | Info     | Zero-amount `crosschainMint/Burn` lets any EOA emit spoofed bridge events| **Open** (one-line guard)    |
| A4-I-10 | Info     | `setBridgeLimits` resets remaining to max — instant window refill        | **Open** (settle-then-clamp) |
| A4-I-11 | Info     | Stability-fee accrual bypasses `debtCeiling`                             | **Open** (confirm intent)    |
| A4-I-12 | Info     | `_verifyInhouseProof` lacks the per-asset staleness bound of `updatePrice`| **Open** (defense-in-depth)  |
| A4-I-13 | Info     | `ReserveVault.skimExcess` pays surplus to `msg.sender` (hot key)         | **Open** (ops)               |
| A4-I-14 | Info     | `LendingRouter.deposit` bypasses the pool supplier allowlist (shim vault)| **Open** (confirm policy)    |
| A4-I-15 | Info     | `EToken.updateName` breaks the cached ERC-2612 permit domain             | **Open** (docs/integrators)  |
| A4-I-16 | Info     | `_lastPremiumBps` zero-sentinel collides with a real 0 observation       | **Open** (config guard)      |
| A4-I-17 | Info     | `setChainlinkConfig` keeps the old in-house `_prices` cache              | **Open** (one-line delete)   |

---

## 1. Fixed Findings

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

---

## 2. Open Findings

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

**Overlaps.** Worst case (CR = 0) was A4-H-01. *Post-fix note (2026-09-02):* the A4-H-01 fix
makes the walk continue past a drained head at fair value, so the "accurate `minCollateralOut`
always reverts" stall described above no longer reproduces — re-validate this finding against
the fixed code before choosing an option.

**Detected by** 4 of 12 agents (economic-security, execution-trace, periphery, trust-gap).

### A4-M-02 (Medium) — OwnIncentives pays retroactive OWN on sEUSD balances acquired while the hook is detached

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

**Tests.** None currently exercise a detach/re-attach or distribute-before-attach sequence; add
both, plus an invariant that Σ claimed ≤ emission × campaign time.

**Detected by** 11 of 12 agents (economic-security, execution-trace, trust-gap, flow-gap as
findings with matching traces; math-precision, access-control, invariant, first-principles,
asymmetry, boundary, numerical-gap as leads).

### A4-M-03 (Medium) — Full-debt-only liquidation can be starved of eUSD liquidity

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

**Suggested fix.** Support partial liquidation — `liquidate(collateral, owner, amount)` with the
same bonus math pro-rata, remainder re-listed (subject to the `minDebt` floor). Alternatively
document a hard cap on any single position relative to expected circulating liquidity.

**Detected by** 1 of 12 agents (economic-security); mechanics verified directly against source
(full-debt burn in `liquidate`, ceiling check in `mint`).

### A4-M-04 (Medium) — Halted collateral is valued at the live feed, enabling unbacked minting above the halt price

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

**Suggested fix.** In `mint`/`withdrawCollateral`, revert when
`IVaultManager(registry.vaultManager()).isAssetHalted(cfg.ticker)`; value
liquidations/redemptions of halted collateral at `min(oraclePrice, assetHaltPrice)`.

**Detected by** 2 of 12 agents (economic-security as finding; execution-trace tied the variant
to the A4-H-02 root cause). **Round-2 addendum:** the seam has a second wing — once a
halted/delisted asset's feeds die past `maxAnchorAge`, `_anchorPrice` reverts and `liquidate`/
`redeem`/`withdrawCollateral`-with-debt all brick for that collateral while debt remains
outstanding (only `closePosition` works), so undercollateralized positions become permanently
unliquidatable. The halt gate fix should pair with a wind-down path for existing positions.

### A4-M-05 (Medium, ops-gated) — Force-executing a PSM-backed asset makes generic-vault LPs pay while the maker collects the freed reserve surplus

**Problem.** In the normal redeem flow the party that funds the user's payout (the maker) is
also the party entitled to withdraw the RWA reserve surplus freed when exposure closes
(`ReserveVault.withdraw`, guard `rwaCollateralUSD ≥ exposureUSD`). Force-execution breaks that
pairing: the payout comes from an admin-allowlisted **generic** vault's LP collateral, but
`closeExposure` still frees the matching reserve slice into the maker-withdrawable surplus.
A maker can therefore monetize its own non-performance: ignore redeem orders on a PSM-backed
asset, let users force-execute against the allowlisted generic vault (LPs pay ~$100k per $100k
forced), then withdraw the freed $100k surplus — repeatable until the vault's util/HF gates
bind. Preconditions: the asset has a funded PSM reserve AND the admin has allowlisted ≥1
generic vault for force-execution on it (the pool is empty by default, which disables force).

**Suggested fix.** Don't allowlist generic force-execution vaults for assets with a configured
PSM reserve (ops rule, effective immediately), and/or in `ForceExecuteLib._validateForce`
revert when the asset carries RWA reserve backing — or route the freed reserve slice to the
paying vault instead of the maker surplus (larger change).

**Detected by** 1 of 12 agents (asymmetry), with a complete numeric trace across
ForceExecuteLib → VaultManager → ReserveVault.

### A4-L-16 (Low, ops) — `haltAsset` accepts an arbitrary, permanent, operator-set settlement price

**Problem.** `haltAsset` is gated by the instant OPERATOR role, checks only `haltPrice != 0`
(no band against the live mark, unlike every other price ingress), and halting is one-way —
no un-halt exists. The price is immediately monetizable by permissionless paths: `haltPrice = 1
wei` lets anyone `settleHaltedPosition` every borrower (all collateral seized for ~0 proceeds,
debt residual kept — irreversible); an inflated price drains the halt fund via `redeemHalted`
up to its allowance. This contradicts the leaked-key damage-cap philosophy applied everywhere
else (settle band, price band, ratio-jump guard). **VaultManager is immutable, so there is no
code fix** — containment is operational: operator-key hygiene, monitoring on `haltAsset`
params, and funding `haltRedeemAddress`/approvals only after halt-price review.

**Detected by** 2 of 12 agents (trust-gap as finding, access-control as lead).

### A4-L-17 (Low) — Pending-deposit escrow is counted as vault collateral by every pool health gate

**Problem.** In approval mode, `requestDeposit` pulls aTokens to the vault address
(`OwnVault.sol:231`) and `totalAssets()` excludes them (`:680`) — but
`OwnLendingPool._requireHealthy` (`OwnLendingPool.sol:344`) and the vault-health gates read raw
`aToken.balanceOf(vault)`, which includes the escrow. A large pending deposit therefore pads
every health check: LP exits via `fulfillWithdrawal` can drain real backing below the intended
floor while the gates pass; once drained, `cancelDeposit`/`rejectDeposit` revert in the aToken
transfer health hook (`validateTransfer`), freezing every pending depositor's escrow until debt
is repaid or deposits are accepted. On the Robinhood venue (OwnLendingPool: no liquidations)
the harm is floor dilution + escrow freeze; on any real-Aave venue the unpadded vault can end
below HF 1.0 and be externally liquidated.

**Suggested fix.** Hold pending-deposit escrow outside the vault address (dedicated escrow
holder, or pull assets only on `acceptDeposit`) so venue-side balance equals real backing.

**Detected by** 1 of 12 agents (numerical-gap); escrow pull and raw-balance health read
verified directly against source.

### A4-L-18 (Low) — Rate setters reprice the elapsed accrual window instead of applying prospectively

**Problem.** `EUSDManager.setStabilityFee` settles the fee index before changing the rate ("so
the new rate applies only prospectively") — but `BorrowManager.setMinAaveBorrowRateBps` and
`setRateParams` mutate rate inputs without calling `_accrue()` first, and `_windowRateBps`
reads the floored base leg live at the next accrual. A floor change therefore re-bills the
entire elapsed window at the new rate (both directions: raise → borrowers retro-charged, lower
→ LP-side under-billing). On Robinhood the pool's variable rate is hard-zero, so the floor IS
the whole base rate — fully retroactive. Worked case: $1M debt, 10 quiet days, floor raised
0→2000 bps → next `accrue()` charges ~$5,480 for a window advertised at 0%. Violates the
stored-`_lastPremiumBps` design's own stated invariant (no repricing of elapsed time).

**Suggested fix.** Call `_accrue()` at the top of `setMinAaveBorrowRateBps` and
`setRateParams`, mirroring `setStabilityFee`.

**Detected by** 1 of 12 agents (asymmetry), via the protocol-internal setter-pair contrast.

### A4-I-11 … A4-I-17 (Info, round-2 protocol-wide pass)

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
interface NatSpec ("bounded by the stability fee rate"). Grooming variant (2026-09-02 pass):
`repay` is permissionless, so a third party can force-crystallize a victim's pending fees with a
1-wei repay, deliberately re-sorting near-tied positions toward the redemption head — same drift
envelope, same accept/fix decision.

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

### A4-L-09 (Low) — `setPartner` plus permissionless `sweepPartner` can redirect any holder's accrued OWN

**Problem.** `setPartner(account, destination)` accepts **any** account (EOAs included) with no
consent step and no contract-only check, and does not settle the account's accrued rewards to
the account first; `sweepPartner(account)` is then permissionless and pays the account's entire
accrued OWN to the admin-fixed destination. The interface documents partners as pool contracts
that cannot claim for themselves, but the code does not enforce it — a compromised or malicious
ADMIN key gets a one-transaction confiscation lever over any holder's earned-but-unclaimed OWN
(retroactive-sweep amplifier), on-chain indistinguishable from the intended partner flow.
ADMIN-trust item, hence Low.

**Suggested fix.** Require `account.code.length > 0`, and/or settle-and-pay the account's
already-accrued OWN to the account itself at the moment its partner destination is first set
(or require an opt-in from the account). Also note (round-1 re-review): the destination pinning
is advisory in the other direction too — a partner contract able to make arbitrary calls can
`claim(to)` around its pinned destination; if pinning is meant as a guarantee, `claim` should
revert for accounts with a partner destination set.

**Detected by** 2 of 12 agents (trust-gap as finding, boundary as lead).

### A4-L-10 (Low) — Disabled collateral blocks defensive top-ups while liquidation stays live

**Problem.** `deposit` applies the `cfg.enabled` gate unconditionally, but `liquidate` has no
enabled gate. After `setCollateralEnabled(c, false)` (a legitimate de-listing/migration lever),
an indebted borrower cannot top up collateral — their only risk-*decreasing* lever other than
sourcing eUSD to repay — while keepers can still liquidate at the bonus. In a drawdown during a
de-listing window, a borrower holding spare eTokens is forced into an avoidable liquidation and
pays `liquidationBonusBps` to the keeper (the unprivileged amplifier). Pre-existing pass-4-scope
code; surfaced by the staking-pass re-review.

**Suggested fix.**

```diff
-        if (!cfg.enabled) revert CollateralDisabled(collateral);
+        if (!cfg.enabled && _positions[collateral][msg.sender].debt == 0) {
+            revert CollateralDisabled(collateral);
+        }
```

(top-up-only exemption: `enabled` keeps gating new exposure — first deposits and all minting —
while existing debtors may always defend.)

**Detected by** 2 of 12 agents (trust-gap as finding, asymmetry as lead).

### A4-L-11 (Low) — sEUSD dead-shares seed and `totalSupply > 0` before streaming are unenforced

**Problem.** The OZ v5 virtual-shares defense does not cover the protocol's own reward stream:
if `transferInRewards` runs while `totalSupply == 0` (stream before the seed deposit, or after
a full exit including the seed), vested rewards make `totalAssets ≫ totalSupply`, and OZ
ERC-4626 `deposit` then mints `floor(a·1/(A+1)) = 0` shares **without reverting** — the deposit
is silently donated (e.g. residual `A = 1000e18`: a 1000e18 deposit mints 0 shares; a 2000e18
deposit mints 1 share and loses ~500e18 on exit). The seed is a deploy *note*, not code, and no
production deploy script exists yet for StakedEUSD/OwnIncentives to enforce it.

**Suggested fix.** `require(totalSupply() > 0)` in `transferInRewards` (one line), and/or
revert on zero-share deposits; alternatively mint the dead-shares seed inside `initialize`.
Add the assertion to the production deploy script when it is written.

**Detected by** 5 of 12 agents (math-precision, economic-security, execution-trace,
first-principles, boundary) — all as leads with matching arithmetic.

### A4-L-12 (Low, ops) — Bridge `crosschainBurn` aimed at the sEUSD vault: socialized loss plus vault-wide DoS

**Problem.** `EUSD.crosschainBurn` is allowance-free from any `from` — accepted under A4-I-05
as "griefing within one window" against the user who asked to bridge. StakedEUSD invalidates
that bound: the vault concentrates all stakers' eUSD at one address, so a compromised bridge
aiming its per-window `burnMaxLimit` at the vault (a) socializes the loss across every sEUSD
holder, and (b) if the burn pushes `eusd.balanceOf(vault)` below `getUnvestedAmount()`,
`totalAssets()` underflow-reverts and **every** vault entry/exit bricks until vesting decays or
someone tops the balance up — a DoS amplification the A4-I-05 analysis (which predates sEUSD)
did not consider. Latent today (no bridge limits set, `maxNetBridgedIn = 0`).

**Suggested fix (ops).** Keep every per-bridge `burnMaxLimit` well below the sEUSD vault's
vested TVL (or exempt/monitor the vault address), and re-run this sizing whenever a transport
is authorized. Optionally clamp the DoS leg in code: `totalAssets = balance −
min(balance, getUnvestedAmount())` (the loss leg remains bridge-trust territory).

**Detected by** 4 of 12 agents (flow-gap, access-control, trust-gap, boundary) — all as leads
(compromised-bridge precondition).

### A4-L-13 (Low) — Force-execution never checks `order.expiry` (reopens the unimplemented half of external A3-L-03)

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

**Suggested fix.** In `_validateForce`:
`if (block.timestamp > order.expiry) revert IOwnMarket.OrderExpiredError(orderId);`

**Detected by** 3 of 12 agents (access-control, periphery as findings; execution-trace as the
expire-frontrun inversion lead). Verified directly against source and full git history.

### A4-L-14 (Low) — `withdrawCollateral` with debt outstanding escapes both emergency levers

**Problem.** For an indebted position, withdrawing collateral is risk-increasing with exactly a
mint's shape (same `_freshPrice` + MCR gate), yet it checks neither `mintPaused` nor
`cfg.enabled`. During a bad-oracle-price incident (leaked signer / erroneous print — the threat
the protocol's settle bands exist for), ops can throw `setMintPaused(true)` and
`setCollateralEnabled(false)` and debtors can still extract collateral against the inflated
price down to MCR, leaving undercollateralized debt behind; the identical extraction via `mint`
is blocked. Worked case: price pushed 2×, position 100 eTokens/$50 debt at MCR 150% withdraws
62.5 tokens at the fake price, leaving $37.5 real backing $50 debt. Complements A4-L-10 (the
inverse asymmetry on `deposit`).

**Suggested fix.** In `withdrawCollateral`, when `p.debt > 0`, also revert if `mintPaused`
(pure exits — full close, repay, zero-debt withdrawal — stay ungated).

**Detected by** 1 of 12 agents (asymmetry), with a complete numeric trace; gate-checked against
source.

### A4-L-15 (Low) — A code-less incentives controller bricks every sEUSD transfer despite the try/catch

**Problem.** `StakedEUSD._update` wraps `handleAction` in `try/catch` precisely so "a controller
fault can never block sEUSD transfers" — but for a high-level call to an address with no code,
solc's extcodesize check reverts in the **caller's** frame, outside what `try/catch` can catch.
`setIncentivesController` accepts any address, so an EOA / typo / not-yet-deployed CREATE
address bricks every transfer, mint, and burn (deposits, withdrawals, money-market liquidations
of sEUSD) until admin resets it. Admin-misconfig trigger, admin-recoverable — hardening grade,
but it directly falsifies the wrapper's stated guarantee.

**Suggested fix.** `require(controller == address(0) || controller.code.length > 0)` in
`setIncentivesController`, plus one unit test pinning the extcodesize-revert semantics on
solc 0.8.28.

**Detected by** 1 of 12 agents (boundary).

---

## 3. By-Design / Withdrawn

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
- **A4-I-09 — Zero-amount `crosschainMint`/`crosschainBurn` succeed for any caller.**
  `_consumeLimit(_, 0)` passes even with a zeroed config (`0 > 0` is false), so any EOA can
  emit genuine `CrosschainMint`/`CrosschainBurn` events with itself as the "bridge" — polluting
  exactly the event surface bridge monitoring and indexers watch. No fund impact; fix is a
  one-line `amount == 0` revert on both ERC-7802 entry points.
- **A4-I-10 — `setBridgeLimits` resets `remaining` to the new maxima.** Any limit update —
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
  operator lever: pause streaming when supply ≈ seed.
- Direct eUSD transfer to the vault bypasses vesting and jumps the share price — donor-funded,
  but a *predictable* mis-routed inflow (operator using `transfer` instead of
  `transferInRewards`) is sandwichable. Ops discipline; optional `skim()` folding surplus into
  the vesting batch.
- Deploy atomicity: `DeployEusdRobinhood.s.sol` initializes the EUSDManager proxy atomically in
  the `ERC1967Proxy` constructor, but **no production deploy script exists yet for
  StakedEUSD/OwnIncentives** — a two-tx deploy is initializer-front-runnable (attacker-supplied
  `registry` = full takeover). Tracked in §6.

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
- [ ] A4-M-02 — implement Option A (freeze accrual while detached) and/or Option B (wiring-seam
      guards); add detach/re-attach and distribute-before-attach regression tests plus a
      Σ-claimed ≤ emission×time invariant.
- [ ] A4-L-09 — enforce contract-only partners or settle-first on `setPartner`; confirm the
      partner reward model.
- [ ] A4-L-10 — exempt indebted top-ups from the `enabled` gate in `deposit` (or record as
      accepted with a de-listing runbook that repays/closes before disabling).
- [ ] A4-L-11 — add the `totalSupply() > 0` guard to `transferInRewards` (or seed in
      `initialize`); write the production deploy script for StakedEUSD/OwnIncentives with
      atomic proxy init + seed deposit + wiring order (attach controller **before**
      `setDistribution`; decommission order `setDistribution(0,·)` → settle → `recoverReserve`
      → detach).
- [ ] A4-L-12 — size every per-bridge `burnMaxLimit` ≪ sEUSD vested TVL before authorizing any
      transport; decide on the `totalAssets` clamp; fold A4-I-06's paired burn+mint budget into
      bridge monitoring.
- [ ] A4-M-03 — decide partial liquidation (`liquidate` with an `amount`) vs a per-position
      size cap; add a whale-starvation regression test (ceiling filled, circulating < debt).
- [ ] A4-M-04 — add the halt gate to `mint`/`withdrawCollateral` and decide halted-collateral
      valuation on exits (`min(oracle, haltPrice)`); add a halted-asset mint regression test.
- [ ] A4-L-13 — add the `order.expiry` check to `ForceExecuteLib._validateForce` (completes the
      A3-L-03 remediation); regression test: expired order unfillable AND unforceable.
- [ ] A4-L-14 — gate the `p.debt > 0` branch of `withdrawCollateral` on `mintPaused`; incident
      runbook: throwing the mint pause must actually stop value extraction.
- [ ] A4-L-15 — add the `code.length` guard to `setIncentivesController` + extcodesize unit
      test.
- [ ] A4-I-09 / A4-I-10 — zero-amount revert on the ERC-7802 pair; settle-then-clamp in
      `setBridgeLimits`. Bound `emissionPerSecond` in `OwnIncentives.setDistribution` (an
      absurd value overflows `emissionPerSecond·Δt` in `_updateGlobal`, bricking `claim` AND
      `setDistribution` itself — unrecoverable without an upgrade).
- [ ] A4-M-05 — ops rule NOW: no generic force-execution vaults allowlisted for PSM-backed
      assets; decide the code-side guard (`_validateForce` RWA-reserve check vs reserve-slice
      routing) for the next OwnMarket/ForceExecuteLib relink.
- [ ] A4-L-16 — operator-key runbook + monitoring on `haltAsset` params (VM immutable, no code
      fix); fund `haltRedeemAddress` approvals only after halt-price review.
- [ ] A4-L-17 — move pending-deposit escrow out of the vault address (or accept with a
      documented approval-mode sizing rule); regression test: padded health gate + frozen
      cancel.
- [ ] A4-L-18 — `_accrue()` at the top of `setMinAaveBorrowRateBps`/`setRateParams` on the
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
