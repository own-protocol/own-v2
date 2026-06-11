# Own Protocol v2 — Audit Remediation Log

**Started:** 2026-06-10
**Branch:** `lending`
**Source audit:** [`docs/audit-2026-06-09.md`](./audit-2026-06-09.md)

This document tracks the fixes applied for findings in the 2026-06-09 audit. Each entry records the
root cause, the fix, the files touched, and the regression tests that lock the behavior in. It is
updated as findings are remediated.

## Status

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| C-01 | Critical | `verifyPrice` has no staleness check; stale signed prices drain collateral | **Fixed** (force-execute **asset leg** uses an in-window price by design — see design note below / `audit-2026-06-09.md` §2B C-01\*) |
| H-01 | High | `forceExecuteOrder` accepts a halted (wind-down) vault as collateral source | **Fixed** |
| H-02 | High | Resting redeem escrow stranded after `migrateToken` (stock split) | **Fixed** |
| H-03 | High | Withdrawal util gate combines a stale cached mark with live `totalAssets` | **Fixed** |
| H-04 | High | `absorbBadDebt` releases collateral in 18-dec units, not the vault's native decimals | **Fixed** |
| M-05 | Medium | Interest-model divergence: book debt can lag the real (compounding) Aave debt → LP shortfall | **Fixed** |

---

## C-01 — `verifyPrice` staleness / price-manipulation (Critical) — **Fixed**

### Root cause

The inline proof path `OracleVerifier.verifyPrice` (and the Pyth equivalent) verified only the
signature and `price != 0` — it never bounded the proof's `timestamp`. The signed digest carries no
nonce, so **every price the signer ever produced is a valid proof forever.** Because all consumers
pass caller-supplied `priceData`, an attacker could replay the most favorable historical price:

- **Force-redeem** settled at the *submitted* asset price (only required `price >= limitPrice`) and
  converted to collateral at a *submitted* collateral price — pick the highest asset price + lowest
  collateral price to over-release vault collateral.
- **Borrow / liquidate / absorbBadDebt** valued collateral / health at a submitted price — pick a
  stale high price to over-borrow, or a stale low price to force a liquidation.

This was pre-existing on `main` as well (the force-redeem collateral-over-release vector); the
`lending` branch widened it to borrowing and liquidation.

### Fix

The freshness rule is context-specific, so it lives in the **consumers**, not in `verifyPrice`
(which stays a pure signature primitive returning `(price, timestamp)` — it must still accept old
prices for the force-redeem *asset* leg).

1. **Force-redeem asset leg — settle at the limit, prove reachability in-window.**
   `OwnMarket.forceExecuteOrder` now requires the asset proof's timestamp to fall in the order's live
   window `[createdAt, now]` and to reach the limit, then values the payout at the user's own
   `limitPrice` — *not* the submitted price. A replayed/cherry-picked asset proof can no longer
   inflate settlement. (Mirrors the pre-refactor `main` semantics: the user is owed a fill at their
   limit, not the best price in the window.)

2. **Force-redeem collateral leg — must be current.**
   `OwnMarket._convertToCollateral` rejects a collateral proof whose timestamp is in the future or
   older than `registry.priceMaxAge()`.

3. **Borrow / liquidate / absorbBadDebt — must be current.**
   `BorrowManager._verifyPrice` rejects a price proof that is future-dated or older than
   `registry.priceMaxAge()`.

4. **Governance-tunable freshness.**
   `ProtocolRegistry` gained `priceMaxAge` — set explicitly in the constructor (reverts on zero) and
   updatable by governance via `setPriceMaxAge` (immediate, `onlyOwner`). Both consumers read it, so
   there is a single tunable source of truth. Deployment value: `2 minutes`.

### Files

- `src/core/OracleVerifier.sol` — unchanged primitive (documented: no max-age here, by design).
- `src/core/OwnMarket.sol` — asset-leg window check + settle-at-limit; collateral-leg staleness check.
- `src/core/BorrowManager.sol` — `_verifyPrice` freshness check.
- `src/core/ProtocolRegistry.sol` (+ `IProtocolRegistry`) — `priceMaxAge` param (constructor + setter).
- `src/interfaces/IOwnMarket.sol` — `AssetPriceProofOutsideWindow`, `StaleCollateralPrice` errors.
- `src/interfaces/IBorrowManager.sol` — `StalePrice(timestamp, maxAge)` error.

### Tests

- `test/unit/OwnMarket.t.sol`:
  - `test_forceExecuteOrder_settlesAtLimitNotProof` — payout valued at limit even with a 2× proof.
  - `test_forceExecuteOrder_assetProofWithinWindow_succeeds` — old-but-in-window proof accepted.
  - `test_forceExecuteOrder_assetProofBeforeWindow_reverts` — proof predating the order rejected.
  - `test_forceExecuteOrder_staleCollateralPrice_reverts` — stale collateral proof rejected.
- `test/unit/BorrowManager.t.sol`: `test_borrow_stalePrice_reverts`.
- `test/unit/ProtocolRegistry.t.sol`: `test_constructor_setsPriceMaxAge`,
  `test_constructor_zeroPriceMaxAge_reverts`, `test_setPriceMaxAge_updatesAndEmits`,
  `test_setPriceMaxAge_onlyOwner_reverts`, `test_setPriceMaxAge_zero_reverts`.
- Updated `test/integration/OrderLifecycle.t.sol` force-exec tests to the settle-at-limit semantics.

Full suite: **616 passing**.

### Residual / follow-ups

- **Intra-window replay (bounded, by design):** the collateral / borrow legs accept any
  validly-signed price within `priceMaxAge`. Impact is bounded to intra-window price drift. Full
  closure would require a monotonic sequence number in the signed digest — tracked as hardening, not
  a blocker.
- **`main` carries the same root flaw.** This fix is on `lending`; if `main` is the deployed
  testnet code, the equivalent fix must land there too.

### Design note (2026-06-11 re-audit) — C-01\* asset leg is intentionally window-scoped

The 2026-06-11 re-audit flagged that the force-execute **asset** leg has no `priceMaxAge` bound
(unlike the collateral leg and `BorrowManager._verifyPrice`) and proposed requiring a fresh asset
price. After review with the team this is **by design and not adopted** — requiring freshness would
break the intended VM-failure recourse.

Force-execute exists precisely because a VM *should have* executed the user's redeem order when the
asset reached the user's `limitPrice`; if no VM did so within `claimThreshold`, the user proves the
asset reached that price *at some point in the order's `[createdAt, now]` window* and is filled at
their **own, immutable, placement-time `limitPrice`**. Fix-step 1 above is therefore correct as
written: the only thing C-01 needed to remove was settling at an *attacker-submitted* price (done —
it now settles at the committed limit, claimable only by `order.user`, only if the asset actually
reached it). There is no unbounded extraction and no third-party theft, so C-01 is **Fixed**.

**Acknowledged, by-design risk:** LP collateral backstops the redeem at the committed `limitPrice`
whenever the asset reached it during the window, so a wick a VM fails to execute against can cost LPs
up to `(limitPrice − currentPrice) × remaining`. This is the intended LP trust model, bounded by the
user's own pre-committed limit. (Cross-ref: `audit-2026-06-09.md` §2B C-01\*.)

---

## H-01 — Force-execution can drain a halted (excluded) vault (High) — **Fixed**

### Root cause

`forceExecuteOrder` let the caller name *any registered* vault as the collateral source. A halted
vault has had its collateral excluded from the global risk pool (`onVaultHalted`) and is winding down
to its LPs via instant withdrawals — it no longer backs any exposure. But `releaseCollateral` is
`onlyMarket` with no status check, so a redeemer could name the halted vault, drain its collateral,
while `closeExposure` reduced the *global* book that other vaults were backing. The halted vault's
LPs (who were mid-exit) absorbed the loss.

### Fix

`forceExecuteOrder` now rejects an excluded vault: after the `isRegisteredVault` check it calls
`vmgr.isVaultExcluded(vault)` and reverts `VaultExcludedFromPool(vault)`.

### Files

- `src/core/OwnMarket.sol` — `isVaultExcluded` guard in `forceExecuteOrder`.
- `src/interfaces/IOwnMarket.sol` — `VaultExcludedFromPool(address vault)` error.

### Tests

- `test/unit/OwnMarket.t.sol`: `test_forceExecuteOrder_excludedVault_reverts` (+ default
  `isVaultExcluded → false` mock in `setUp`).

Full suite: **617 passing**.

---

## H-02 — Resting redeem escrow stranded after `migrateToken` (High) — **Fixed**

### Root cause

A resting redeem order escrowed the eToken resolved at placement, but every later path re-resolved
`getActiveToken`. After a stock-split `migrateToken`, the market held the *old* token while
cancel/expire/fill/force all targeted the *new* one — so escrow recovery reverted and the user's
legacy eTokens were locked permanently. The same staleness affected borrow positions (collateral
held in the old token; all paths resolved the new one) and left legacy holders with no redemption
path at all.

### Fix

Token migration is now a first-class, end-to-end flow built on a **convert-first** model (full design
in `docs/protocol.md` §13):

- **`Order.escrowToken`** snapshots the escrowed token at `placeOrder`; `_returnEscrow` returns it, so
  cancel/expire always recover the original token. `fillOrder`/`forceExecuteOrder` on a migrated
  redeem order revert `OrderTokenMigrated` (recover via cancel/convert).
- **`OwnMarket.convertLegacy`** burns a legacy token and mints the active token at the migration
  ratio. Pause/halt-exempt so legacy holders can always reach redemption.
- **`AssetRegistry.migrateToken(ticker, newToken, ratio)`** records a per-legacy-token ratio,
  re-based on each split so any legacy token converts directly to the live active token.
- **`VaultManager.applySplit(asset, ratio)`** re-denominates exposure (`units *= ratio`,
  `mark /= ratio`), USD-invariant.
- **`Position.collateralToken`** snapshots borrow collateral; repay/liquidate act on the stored
  token, valued at `activePrice × legacyRatio`. A split never moves a position's health factor;
  `settleHaltedPosition` converts legacy collateral to active internally before halt settlement.

### Files

- `src/core/AssetRegistry.sol` (+`IAssetRegistry`) — ratio storage, `migrateToken(ratio)`, getter.
- `src/core/VaultManager.sol` (+`IVaultManager`) — `applySplit`.
- `src/core/OwnMarket.sol` (+`IOwnMarket`, `Types.Order`) — `convertLegacy`, `escrowToken`, migrated-order guards.
- `src/core/BorrowManager.sol` (+`IBorrowManager`) — `Position.collateralToken`, `_effectivePrice`, legacy-aware repay/liquidate/settle.

### Tests

- `test/unit/AssetRegistry.t.sol` — ratio set + compounding across splits, zero-ratio revert.
- `test/unit/VaultManager.t.sol` — `applySplit` USD invariance, access/zero-ratio reverts.
- `test/unit/OwnMarket.t.sol` — `convertLegacy` (forward, active-token revert, halted-exempt);
  cancel returns original token; fill/force revert after migration.
- `test/integration/BorrowAndLiquidateFlow.t.sol` — HF preserved across split; repay returns legacy;
  liquidation at effective price.
- `test/integration/RFQAusdcFlows.t.sol` — convert-then-redeem; `settleHaltedPosition` with legacy
  collateral.

### Post-fix hardening (re-audit)

A re-audit of the H-02 changes surfaced one consistency gap, now fixed: `_settleMint` settled escrow
fills using the *current* payment token rather than the token escrowed at placement, so a mint order
filled after a global payment-token change could mismatch its escrow. `_settleMint` now takes the
settlement token explicitly — `order.escrowToken` for fills, the current payment token for market
orders. Test: `test_fillMint_afterPaymentTokenChange_settlesInEscrowToken`.

Two items were left as documented recommendations (Low / operational): keep `migrateToken` +
`applySplit` in one multisig transaction (skipping `applySplit` makes converted tokens temporarily
unredeemable — liveness only), and an optional `migrateToken` `newToken == oldToken` guard.

Full suite: **634 passing**.

---

## H-03 — Withdrawal gate reads a stale collateral mark after a bad-debt release (High) — **Fixed**

### Root cause

`VaultManager.withdrawalBreachesUtil` decides LP exits by netting against `_globalCollateralUSD`, a
sum of keeper-cached marks. `OwnVault.releaseCollateralForBadDebt` transferred vault collateral to the
treasury and shrank real `totalAssets` immediately, but did **not** update the cached mark ("catches
up on the next keeper pull"). In the window between the write-off and the next `pullCollateralPrice`,
`_globalCollateralUSD` overstated real collateral, so the gate under-reported utilization and allowed
withdrawals it should have blocked — letting fast LPs exit ahead of the socialized loss. The window is
front-runnable by transaction ordering, so controlling the keepers does not close it unless the
refresh is atomic with the release.

### Fix

Make the mark update atomic with the release. `OwnVault.releaseCollateralForBadDebt` now calls
`VaultManager.onCollateralReleased(amount)` **before** transferring, and the manager decrements
`_collateralMark[vault]` and `_globalCollateralUSD` proportionally (`mark × assets / totalAssets`,
the same basis the gate uses). No stale window remains, and no operational dependency on a timely
keeper pull. (Price drift between pulls is still handled by the keeper model, as designed — only the
protocol-caused step reduction is now synchronous.)

### Files

- `src/core/VaultManager.sol` (+`IVaultManager`) — `onCollateralReleased` (`onlyRegisteredVault`) +
  `CollateralMarkReduced` event.
- `src/core/OwnVault.sol` — call `onCollateralReleased` before transferring in **both** collateral-out
  paths: `releaseCollateralForBadDebt` and `releaseCollateral` (force execution). Both leave the
  cached mark honest; the same root cause is closed in both places rather than only the bad-debt one.

### Tests

- `test/unit/VaultManager.t.sol`: `test_onCollateralReleased_reducesMarkProportionally`,
  `test_onCollateralReleased_onlyRegisteredVault_reverts`,
  `test_badDebtRelease_tightensWithdrawalGate` (gate blocks post-release where it was stale-allowed).
- `test/integration/OrderLifecycle.t.sol`: `test_forceExecute_redeem_releasesCollateral` asserts the
  mark syncs down on force-execution release.

Full suite: **637 passing**.

---

## H-04 — `absorbBadDebt` releases collateral in 18-dec units, not native decimals (High) — **Fixed**

*(Found in a focused re-audit of `BorrowManager` + `AaveRouter`, not in the 2026-06-09 report.)*

### Root cause

`absorbBadDebt` computed the LP-socialized collateral slice as
`collateralReleased = lpLossUSD.mulDiv(PRECISION, collateralPrice)` — an **18-decimal-normalized**
amount — then passed it straight to `OwnVault.releaseCollateralForBadDebt`, which does a raw
`safeTransfer` in the asset's **native** decimals. The native-decimal scale-down (present in the
analogous `OwnMarket._convertToCollateral`) was missing.

- 18-dec collateral (awstETH): `10**(18-18)=1`, accidentally correct — which is why all existing
  `absorbBadDebt` tests (awstETH-only) passed.
- 6-dec collateral (**aUSDC / USDC**, a primary collateral type with lending wired in): the amount is
  **10¹² too large**, so the transfer reverts on insufficient balance — bad-debt absorption is bricked
  for those vaults (and would catastrophically over-release if a vault ever held enough).

### Fix

Extracted a `BorrowManager._convertToCollateral(usdValue, collateralPriceData)` helper (mirrors
`OwnMarket`'s) that verifies the fresh collateral price and **floors to the asset's native decimals**,
and routed `absorbBadDebt` through it. The decimal-sensitive conversion now lives behind one named
helper instead of being open-coded.

### Files

- `src/core/BorrowManager.sol` — new `_convertToCollateral`; `absorbBadDebt` uses it.

### Tests

- `test/unit/BorrowManager.t.sol`: new `BorrowManagerBadDebt6DecTest` with a 6-decimal aUSDC
  collateral vault — `test_absorbBadDebt_sixDecimalCollateral_releasesNativeAmount` asserts the
  treasury receives `2000e6` (native), not `2000e18`. Verified to revert without the fix.
- `AaveRouter` was audited in the same pass — no Critical/High found.

Full suite: **633 passing**.

---

## M-05 — Interest-model divergence vs. real Aave debt (Medium) — **Fixed**

*(Found in the focused `BorrowManager` re-audit.)*

### Root cause

`BorrowManager` modelled the Aave-side interest itself: `_accrue` sampled Aave's *current* variable
borrow rate (`getReserveData().currentVariableBorrowRate`) at sparse touch points and applied it as
**simple** interest over the elapsed time. Aave's actual debt **compounds continuously** and the rate
moves between touches, so during a rate spike the book debt could fall **below** the vault's real
Aave debt. The borrowers' repayments would then under-cover the Aave loan, and the shortfall would
land on LPs. The variable debt token (`debtToken`) was stored but never read — Aave's ground-truth
debt was ignored.

### Fix

Anchor to Aave's ground truth instead of modelling it. `_accrue` / `_projectedIndex` now **floor** the
interest index so total book debt (`_totalScaledDebt × index`) can never sit below the vault's real
Aave debt, read live from `IERC20(debtToken).balanceOf(vault)` (a real Aave variable debt token's
`balanceOf` is the current compounded debt). The index is monotonic, so the floor only ever raises it.

Effect: the protocol's *premium* (the markup above Aave) is whatever the book debt exceeds the real
Aave debt by. If our simple-interest model lags Aave, the floor lifts the book debt to exactly the
Aave debt and the premium shrinks toward zero for that window — but borrowers always cover the Aave
loan, so **LPs never absorb the shortfall**. The risk converts from LP principal loss to (at worst)
foregone protocol premium during rare spikes.

A full per-position decomposition (Aave-scaled debt + a separate premium index) would also preserve
premium precisely during spikes, but is a large, higher-risk rewrite of the core accounting for a
revenue-only refinement; the index floor delivers the safety guarantee in ~12 lines.

A permissionless `accrue()` entry point was also added so a keeper can advance + floor the stored
index between organic borrow/repay/liquidate touches — bounding the window where the model can lag
and keeping the stored-index reads (`totalDebtUSD` / `utilizationBps`) current.

### Files

- `src/core/BorrowManager.sol` (+`IBorrowManager`) — `_flooredIndex` helper; `_accrue` +
  `_projectedIndex` apply it; permissionless `accrue()` keeper entry point.
- `test/helpers/MockAaveV3Pool.sol` — `MockAaveDebtToken.balanceOf` now mirrors `pool.debtOf`
  (matches real Aave's debt-token semantics) so the read is exercised in tests.

### Tests

- `test/unit/BorrowManager.t.sol`:
  - `test_accrue_floorsBookDebtToRealAaveDebt` — an Aave spike (`accrueDebt`) lifts the real debt
    above the model; the floor raises the book debt to match, and a full repay clears the Aave loan
    with no LP shortfall. Verified to fail (the exact $500 shortfall) without the floor.
  - `test_accrue_keeperCanSyncIndependently` — any address can call `accrue()` to floor the stored
    index to the real Aave debt with no borrower interaction.

Full suite: **635 passing**.
