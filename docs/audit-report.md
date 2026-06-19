# Own Protocol v2 — Audit Report & Remediation Status

**Branch:** `main` (pre-audit hardening on `pre-audit-fixes-1`) · **Last updated:** 2026-06-19 · **Test suite:** 721 passing

Consolidated from the 2026-06-09 full manual audit, the 2026-06-10/11 focused re-audits
(BorrowManager, AaveRouter, H-02 migration changes), and the 2026-06-11 multi-agent re-audit
(16-agent pipeline). This single document replaces `audit-2026-06-09.md`,
`audit-fixes-2026-06-10.md`, and the raw re-audit report. IDs are stable across all passes.

The 2026-06-19 multi-agent re-audit (solidity-auditor, 12-agent pipeline) surfaced one new High
(**H-06**) and one new Low (**L-14**), and reopened **L-07** for an on-chain fix. All three were fixed
with regression tests on 2026-06-19 — H-06 in §1, L-14 and L-07 in §4; no open items remain.

A **second 2026-06-19 pass ("round 2", same 12-agent pipeline)** drilled into the lending ↔
vault-collateral boundary. It implemented the H-06 "bind the redeem to a vault" defense-in-depth (a
protocol-designated force-execute vault, removing the arbitrary-vault amplifier and the cross-vault
value-transfer vector), and surfaced one new High (**H-07** — no Aave health-factor gate on LP
withdrawals/releases), two new Mediums (**M-11** — the redeem settle band trusted a stale mark;
**M-12** — `migrateToken` desynced a halted asset's frozen price), and one new Low (**L-15** —
`maxDeposit`/`maxMint` misreported capacity). All are fixed with regression tests; see §1/§4 for
per-finding coverage (H-07 via a live-Aave fork test). Suite: 721 passing.

A **2026-06-19 follow-up** reviewed the withdrawal loss-ordering surface left by H-07 and identified
**M-13** (Medium) — the *user-bad-debt* sibling of H-07's *Aave-HF* gate: `fulfillWithdrawal` can
settle before a borrower's unrecognized bad debt is absorbed, letting an early LP socialize the loss
onto the remainder, and H-07's `requireVaultHealthy` gate does not catch it. There is no O(1) signal
for unrecognized bad debt (the loss window opens at "position underwater," before liquidation), so it
is **accepted by design** with a proactive pause-on-volatility mitigation rather than a code fix; see
§3 for the decision and the operational controls the acceptance depends on.

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 1     | 1     | 0    | —         |
| High     | 7     | 7     | 0    | —         |
| Medium   | 13    | 11    | 0    | 2         |
| Low      | 15    | 12    | 0    | 3         |

**No findings are open. The 2026-06-19 re-audits' findings are all fixed — round 1: H-06 (High), L-14 (Low), L-07 (Low, reopened then fixed); round 2: H-07 (High), M-11 + M-12 (Medium), L-15 (Low), plus the H-06 amplifier removed. All carry regression tests (H-07 via a live-Aave fork test). All earlier findings remain closed (fixed, mitigated, documented, or by-design). A 2026-06-19 withdrawal loss-ordering follow-up added **M-13** (Medium) — the user-bad-debt sibling of H-07 — accepted by design with an operational pause-on-volatility mitigation (no code change; see §3). The §5 leads are triaged.**

| ID        | Severity | Finding                                                                                                              | Status                                                                                           |
| --------- | -------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| C-01      | Critical | `verifyPrice` accepted any ever-signed price (no staleness) → collateral theft via force-redeem / borrow / liquidate | **Fixed**                                                                                        |
| H-01      | High     | `forceExecuteOrder` could drain a halted (wind-down) vault                                                           | **Fixed**                                                                                        |
| H-02      | High     | Resting redeem escrow stranded after `migrateToken` (stock split)                                                    | **Fixed**                                                                                        |
| H-03      | High     | Withdrawal gate read a stale collateral mark after bad-debt release                                                  | **Fixed**                                                                                        |
| H-04      | High     | `absorbBadDebt` released collateral in 18-dec units, not native decimals                                             | **Fixed**                                                                                        |
| H-05      | High     | `fulfillWithdrawal` didn't sync the VaultManager mark → utilization cap bypass                                       | **Fixed**                                                                                        |
| H-06      | High     | Unbounded `releaseCollateral` drains pending-deposit escrow & bricks the vault (`totalAssets` underflow) | **Fixed** (2026-06-19) |
| H-07      | High     | No Aave health-factor gate on LP withdrawals/releases → collateral backing the vault's Aave debt can be drained into liquidation | **Fixed** (2026-06-19, round 2) |
| M-01      | Medium   | Pyth confidence interval ignored                                                                                     | **Fixed**                                                                                        |
| M-02      | Medium   | In-house push path unbounded when an asset's oracle config is unset                                                  | **Fixed**                                                                                        |
| M-03      | Medium   | `setRateParams` unvalidated → accrual DoS bricks repay/liquidate                                                     | **Fixed**                                                                                        |
| M-04      | Medium   | Withdrawal queue is not FIFO                                                                                         | **By design** — spec updated 2026-06-12 to drop the FIFO claim                                   |
| M-05      | Medium   | Book debt could lag real compounding Aave debt → LP shortfall                                                        | **Fixed**                                                                                        |
| M-06      | Medium   | `borrow` checks the debt cap before `_accrue()` → cap bypass                                                         | **Fixed**                                                                                        |
| M-07      | Medium   | `borrow` ignores the bound vault's Paused/Halted status                                                              | **Fixed**                                                                                        |
| M-08      | Medium   | `_flooredIndex` inflates on a dust scaled-debt base; breaks under multi-manager                                      | **Fixed**                                                                                        |
| M-09      | Medium   | Sub-unit amounts record zero scaled debt while moving real value                                                     | **Fixed**                                                                                        |
| M-10      | Medium   | `WstETHRouter` wraps requested (not received) stETH → deposit path DoS                                               | **Fixed**                                                                                        |
| M-11      | Medium   | Redeem settle band bounded against a stale mark (mint leg gated by `maxMarkAge`, redeem leg not)                     | **Fixed** (2026-06-19, round 2)                                                                  |
| M-12      | Medium   | `migrateToken` on a halted asset desyncs its frozen halt price → `redeemHalted` over-pays                           | **Fixed** (2026-06-19, round 2)                                                                  |
| M-13      | Medium   | `fulfillWithdrawal` can settle before a borrower's bad debt is absorbed → loss socialized to remaining LPs (user-bad-debt sibling of H-07; the Aave-HF gate doesn't catch it) | **By design** — accepted with pause-on-volatility mitigation (see §3) |
| L-01–L-13 | Low      | See §4                                                                                                               | 10 closed (9 fixed + L-02 mitigated) · 3 by design/accepted (L-04, L-09, L-11) |
| L-14      | Low      | In-house `getPrice` has no read-time staleness bound; `pullAssetPrice` re-stamps `block.timestamp` | **Fixed** (2026-06-19) |
| L-15      | Low      | `maxDeposit`/`maxMint` report unlimited while `deposit`/`mint` revert (approval gate / `onlyManager`) → ERC-4626 integrators revert | **Fixed** (2026-06-19, round 2) |
| C-01\*    | Info     | Force-execute asset proof was window-scoped, not fresh                                                               | **Fixed** (2026-06-18 — fresh price now required; see Pre-audit hardening)                       |

---

## Pre-audit hardening (2026-06-18)

A focused hardening pass on `pre-audit-fixes-1`, ahead of external audit. Four issues, all **fixed**
with tests. Every new risk parameter is **fail-safe on zero** — its setter rejects `0`, so the only
zero state is the pre-deploy default, which blocks the guarded action — and is set by the deploy /
config scripts.

| ID    | Severity | Issue                                                                                                                                                                                | Fix                                                                                                                                                                                                                                   |
| ----- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PA-01 | Critical | A leaked quote-signer key could settle `executeOrder` / `fillOrder` at an arbitrary price, draining the maker's full payment-token allowance in one tx.                              | `OwnMarket._settleMint` / `_settleRedeem` bound the settle price to **±`settleBandBps`** of the `VaultManager` asset mark (`PriceOutOfBand`); default **500 bps**. Force-execute / `redeemHalted` exempt.                             |
| PA-02 | Critical | `claimThreshold` defaulted to `0`, making `forceExecuteOrder` exercisable the instant an order was placed; no script set it.                                                         | `forceExecuteOrder` reverts `ForceNotEnabled` when the threshold is `0`; the setter rejects `0`; `Deploy` + `ConfigureVault` set **6 h**.                                                                                             |
| PA-03 | High     | `openExposure` valued new exposure at `assetMark` with no freshness check — the solvency cap ran against arbitrarily stale marks.                                                    | `openExposure` reverts `StaleAssetMark` if the asset mark is older than **`maxMarkAge`** (default **15 min**); `closeExposure` (risk-reducing) exempt. Collateral-aggregate freshness intentionally not gated (O(1) + DoS avoidance). |
| PA-04 | High     | `forceExecuteOrder` accepted any asset proof within the order's `[createdAt, now]` window, so a stale favorable print could be exercised after the market moved (supersedes C-01\*). | The asset leg now requires a **fresh** price (≤ `priceMaxAge`) that currently satisfies the limit (`StaleAssetPrice`), matching the collateral leg.                                                                                   |

Deployment defaults (`Deploy.s.sol`): `settleBandBps = 500`, `claimThreshold = 6 hours`,
`maxMarkAge = 15 minutes` (`priceMaxAge = 2 minutes`, unchanged).

---

## 1. Fixed Findings

### C-01 (Critical) — `verifyPrice` had no staleness check; stale signed prices could drain collateral

**Problem.** The inline proof path `OracleVerifier.verifyPrice` (and the Pyth equivalent) checked
only the signature and `price != 0` — never the timestamp, and the digest carries no nonce. Every
price the signer ever produced was a valid proof forever. All consumers pass caller-supplied
`priceData`, so an attacker could replay the most favorable historical price: over-release
collateral in force-redeem (high asset + low collateral price), over-borrow against a stale high
collateral price, or force-liquidate a healthy position with a stale low price.

**Fix.** Freshness is enforced in the consumers (`verifyPrice` stays a pure signature primitive):

- `OwnMarket.forceExecuteOrder` settles at the user's own immutable `limitPrice` (never the
  submitted price) and requires the asset proof to be **fresh** (≤ `registry.priceMaxAge()`, not
  future-dated) and to currently satisfy the limit — the same freshness rule as the collateral leg
  below. (The original window-scoped acceptance was reversed 2026-06-18; see C-01\* in §3.)
- `OwnMarket._convertToCollateral` (collateral leg) and `BorrowManager._verifyPrice`
  (borrow/liquidate/absorbBadDebt) reject proofs that are future-dated or older than
  `registry.priceMaxAge()`.
- `ProtocolRegistry.priceMaxAge` is governance-tunable (`setPriceMaxAge`, non-zero enforced).
  Deployment value: 2 minutes.

**Tests.** `OwnMarket.t.sol` (settle-at-limit, fresh price accepted at the `priceMaxAge` boundary,
stale favorable print rejected, stale collateral rejected), `BorrowManager.t.sol::test_borrow_stalePrice_reverts`,
`ProtocolRegistry.t.sol` (priceMaxAge constructor/setter suite).

**Residual (accepted).** Intra-window replay within `priceMaxAge` is bounded to 2-minute drift;
a signed-digest nonce is tracked as hardening, not a blocker. `main` carries the same root flaw —
the fix must be ported if `main` is ever deployed.

### H-01 (High) — Force-execution could drain a halted vault

**Problem.** `forceExecuteOrder` accepted any registered vault as the collateral source. A halted
vault's collateral is excluded from the global pool and reserved for its exiting LPs, but
`releaseCollateral` had no status check — a redeemer could cherry-pick the halted vault and drain it.

**Fix.** `forceExecuteOrder` reverts `VaultExcludedFromPool(vault)` when
`vmgr.isVaultExcluded(vault)`.
**Test.** `OwnMarket.t.sol::test_forceExecuteOrder_excludedVault_reverts`.

### H-02 (High) — Redeem escrow stranded after `migrateToken` (stock split)

**Problem.** A resting redeem order escrowed the eToken resolved at placement, but every later path
re-resolved the _current_ active token. After a split migration, the market held the old token while
cancel/expire/fill/force targeted the new one — escrow recovery reverted, locking user funds. Borrow
positions had the same staleness on their collateral token.

**Fix.** Migration is now a first-class convert-first flow (`docs/protocol.md` §13):
`Order.escrowToken` and `Position.collateralToken` snapshot the held token; cancel/expire return the
snapshot; fill/force on a migrated order revert `OrderTokenMigrated`; `OwnMarket.convertLegacy`
(pause/halt-exempt) converts legacy → active at the recorded ratio; `AssetRegistry.migrateToken`
stores per-legacy-token ratios; `VaultManager.applySplit` re-denominates exposure USD-invariantly;
legacy collateral is valued at `activePrice × legacyRatio` so splits never move a position's health.
Post-fix hardening: `_settleMint` settles fills in `order.escrowToken`, not the current payment
token.

**Tests.** Unit + integration coverage across `AssetRegistry`, `VaultManager`, `OwnMarket`,
`BorrowAndLiquidateFlow`, `RFQAusdcFlows` (ratio compounding, USD invariance, cancel-returns-original,
fill-after-migration revert, HF preserved across split, settle-in-escrow-token).

### H-03 (High) — Withdrawal gate read a stale mark after a bad-debt release

**Problem.** `withdrawalBreachesUtil` nets against `_globalCollateralUSD` (keeper-cached marks).
`releaseCollateralForBadDebt` shrank real `totalAssets` without refreshing the mark, so in the window
before the next keeper pull the gate under-reported utilization — informed LPs could exit ahead of a
socialized loss.

**Fix.** Mark updates are atomic with the release: `VaultManager.onCollateralReleased(amount)`
(`onlyRegisteredVault`) decrements the mark proportionally and is called before the transfer in
**both** collateral-out paths (`releaseCollateralForBadDebt`, `releaseCollateral`).
**Tests.** `VaultManager.t.sol` (proportional reduction, access control, gate tightens post-release),
`OrderLifecycle.t.sol` (mark syncs on force-execute release).

### H-04 (High) — `absorbBadDebt` released collateral in 18-dec units

**Problem.** The LP-socialized collateral slice was computed 18-dec-normalized and passed straight
to `releaseCollateralForBadDebt`, which transfers in native decimals. For 6-dec collateral
(aUSDC/USDC) the amount was 10¹² too large — bad-debt absorption reverted (bricked), or would
over-release given sufficient balance. 18-dec vaults were accidentally correct, which is why
existing tests passed.

**Fix.** `BorrowManager._convertToCollateral` helper (mirrors `OwnMarket`'s) verifies the fresh
collateral price and floors to native decimals; `absorbBadDebt` routes through it.
**Test.** `BorrowManager.t.sol::test_absorbBadDebt_sixDecimalCollateral_releasesNativeAmount`
(asserts `2000e6`, not `2000e18`; fails without the fix).

### H-05 (High) — `fulfillWithdrawal` didn't sync the collateral mark

**Problem.** The third collateral-exit path missed the H-03 treatment: `fulfillWithdrawal`
transferred collateral out without calling `onCollateralReleased`, leaving the cached mark
stale-high. Serial withdrawals each cleared the gate against the un-decremented mark, and
mints/borrows immediately after a withdrawal issued exposure/debt against collateral that had
already left — bypassing the global utilization cap within a block.

**Fix.** `fulfillWithdrawal` (non-halted branch) calls `onCollateralReleased(assets)` after the
gate check and before the transfer. Halted vaults skip it (already excluded from the pool).
**Test.** `OwnVault.t.sol::test_fulfillWithdrawal_syncsCollateralMark` (fails without the fix).

### H-06 (High) — Unbounded `releaseCollateral` drained pending-deposit escrow and bricked the vault

**Problem.** `releaseCollateral` (and `releaseCollateralForBadDebt`) transferred `amount` of `asset()`
from the vault's *raw* balance with no `amount <= totalAssets()` bound. Since
`totalAssets() = super.totalAssets() - _pendingDepositAssets` excludes the async approval-queue
escrow, the raw balance exceeds `totalAssets()` whenever a deposit is pending. `forceExecuteOrder`
lets a redeemer pick any non-excluded vault and size `grossCollateral` with no per-vault
free-collateral check, so a redeemer could force-execute against an approval-mode vault holding a
pending deposit, pay out escrowed funds, then brick the vault — the next `totalAssets()` read
underflow-reverts (Solidity 0.8), freezing deposits, withdrawals, accept/reject/cancel, and keeper
price pulls. Distinct from H-01 (halted-vault exclusion) and H-03/H-05 (mark sync): neither bounded
the physical transfer.

**Fix (2026-06-19).** Both release paths revert `AmountExceedsBackedCollateral` when
`amount > totalAssets()`, so a release can only spend share-backing collateral, never pending-deposit
escrow — which also makes the `totalAssets()` underflow unreachable. **Round 2 (2026-06-19): the
amplifier is now removed** — `forceExecuteOrder` sources collateral only from a protocol-designated
vault (`VaultManager.setForceExecuteVault`, operator-set and rotated to the healthiest vault; unset /
`address(0)` reverts `ForceExecuteVaultNotSet`, fail-safe like `claimThreshold == 0`). This also closes
a related cross-vault value-transfer vector (a redeemer could otherwise concentrate a redemption's
collateral cost on any chosen vault's LPs while the exposure reduction socialized globally). Round-2
tests: `OwnMarket.t.sol` (no-designation and wrong-vault reverts), `VaultManager.t.sol`
(`setForceExecuteVault` success / onlyOperator / unregistered / clear-to-zero).

**Tests.** `OwnVault.t.sol::test_releaseCollateral_exceedingBackedCollateral_reverts` (verified to
fail — vault bricks via `Panic(0x11)` in `totalAssets()` — without the guard),
`test_releaseCollateralForBadDebt_exceedingBackedCollateral_reverts`,
`test_releaseCollateral_atBackedCollateral_succeeds` (boundary: full-backing release still allowed).
Full suite green (703 passing).

### H-07 (High) — No Aave health-factor gate on LP withdrawals or collateral release

**Problem.** `BorrowManager.borrow` draws stablecoin from Aave `onBehalf=vault`, so the vault carries
the Aave debt (`debtToken.balanceOf(vault)`) and its aTokens double as the Aave collateral backing it.
But `totalAssets()` never nets that debt, and **no withdrawal/release path checked the vault's Aave
health factor** — the only HF check in the repo was `claimEarnedInterest`. The sole withdrawal gate,
`withdrawalBreachesUtil`, sees only synthetic exposure ÷ *global* collateral; since draining one vault
barely moves the global total in a multi-vault pool, the gate passes while a single vault's aTokens are
pulled out from under its Aave borrow — tipping its Aave position into liquidation and socializing the
penalty onto remaining LPs (first-mover advantage to early exiters). The intended
loan-recall-on-withdrawal flow (`leverage-design.md`) was never implemented. Reachable once lending is
enabled with outstanding Aave debt; compounds with the H-06 force-execute path.

**Fix (2026-06-19, round 2).** `BorrowManager.requireVaultHealthy()` (the same
`getUserAccountData(vault)` check `claimEarnedInterest` uses, against `minClaimHealthFactor` = 1.1e18)
is called by `OwnVault.fulfillWithdrawal` (active vaults) and `releaseCollateral` *after* the aTokens
leave, reverting `VaultUnsafeHealthFactor` if the release dropped the vault below the floor.
Lending-disabled vaults (`_borrowManager == 0`) and halted-vault emergency exits are exempt. Composes
with the H-06 designated-vault fix: a force-execute can neither pick a victim vault nor push it to
liquidation.

**Tests.** `AaveBaseFork.t.sol::test_fork_releaseCollateral_unsafeHealthFactor_reverts` — against live
Aave V3 on Base, the vault borrows real USDC against its awstETH, then a collateral release sized to
land the Aave HF in the (1.0, 1.1) gap reverts `VaultUnsafeHealthFactor` (selector-matched). Verified
to **fail without the guard** (the release succeeds, no revert); a smaller release that keeps the HF
healthy still succeeds. Skips gracefully when `BASE_RPC` is unset. Full suite green (721 passing).

### M-11 (Medium) — Redeem settle band bounded against a stale mark (PA-01 / PA-03 asymmetry)

**Problem.** `_checkSettleBand` bounds the settle price to ±`settleBandBps` of the `VaultManager` mark
(the PA-01 leaked-key damage cap) but never checked the mark's *age*. The mint leg's following
`openExposure` enforces `maxMarkAge` (PA-03), so a stale mark blocks mints; the redeem leg's
`closeExposure` is freshness-exempt (risk-reducing), so a leaked signer key — the exact threat the band
exists for — could settle a redeem within ±band of a *stale* mark, draining the maker. The cap was
asymmetrically weaker on the redeem side.

**Fix (2026-06-19, round 2).** `_checkSettleBand` now reverts `StaleSettleMark` when
`block.timestamp − assetMarkUpdatedAt > maxMarkAge`, so both settle legs bound against a keeper-fresh
mark. `closeExposure` stays intentionally stale-tolerant — it also serves `forceExecuteOrder` and
`redeemHalted`, which must work when the mark is frozen/stale — so the freshness lives on the band
itself, not on `closeExposure`.
**Test.** `OwnMarket.t.sol::test_executeOrder_redeem_staleMark_reverts`.

### M-12 (Medium) — `migrateToken` on a halted asset desynced its frozen halt price

**Problem.** Neither `AssetRegistry.migrateToken` nor `VaultManager.applySplit` guarded against a
halted asset or rescaled `_assetHaltPrice`, while `applySplit` scales `_globalAssetUnits` by `ratio`.
Splitting an already-halted asset doubles holders' token counts but leaves the halt price un-halved, so
`redeemHalted` pays out at the un-rescaled price (2× at a 2:1 split), draining the finite halt-redeem
fund, and the next `pullAssetPrice` double-counts the asset's global exposure. (Related to L-07's
migration atomicity and the §5 split-ratio-drift lead, but a distinct halt-price seam.)

**Fix (2026-06-19, round 2).** `migrateToken` reverts `AssetHalted(ticker)` when
`VaultManager.isAssetHalted(ticker)` — a halted asset is in permanent wind-down and must never be
re-denominated. The safe ordering (split first, then halt) is unaffected: `haltAsset` snapshots the
post-split mark.
**Test.** `AssetRegistry.t.sol::test_migrateToken_haltedAsset_reverts`.

### M-05 (Medium) — Book debt could lag real compounding Aave debt

**Problem.** `_accrue` sampled Aave's variable rate at sparse touch points and applied simple
interest; Aave compounds continuously. During rate spikes book debt fell below the vault's real Aave
debt, so borrower repayments under-covered the loan and LPs ate the shortfall.

**Fix.** The interest index is floored so book debt never sits below the vault's real Aave debt,
read live from `debtToken.balanceOf(vault)` (`_flooredIndex`). Worst case the protocol premium
shrinks toward zero during a spike, but borrowers always cover the Aave loan. A permissionless
`accrue()` keeper entry point bounds the lag window. (The floor introduced the M-08 edge — open,
see §2.)
**Tests.** `BorrowManager.t.sol::test_accrue_floorsBookDebtToRealAaveDebt` (reproduces the exact
$500 shortfall without the floor), `test_accrue_keeperCanSyncIndependently`.

### M-03 (Medium) — Rate params unvalidated → accrual DoS

**Problem.** `InterestRateModel.premium` reverts when `optimalUtilBps == 0 || >= BPS`. Neither
`setRateParams` nor the constructor validated the params, so a bad value made `_accrue` revert —
bricking repay and liquidate, which must always stay open.

**Fix (2026-06-12).** Both write sites reject `optimalUtilBps == 0 || >= BPS` with
`InvalidRateParams()`. Only `optimalUtilBps` is validated — it's the only value that can revert the
curve; the slope/base values can only misprice, not brick, and stay admin-tunable.
**Tests.** `BorrowManager.t.sol::test_constructor_invalidRateParams_revert`,
`test_setRateParams_invalidOptimalUtil_reverts`.

### M-06 (Medium) — Debt cap checked before `_accrue()`

**Problem.** `borrow` ran the hard cap against `totalDebtUSD()` _before_ calling `_accrue()`, so the
cap excluded interest accrued since the last touch and the M-05 Aave-debt floor — a borrow that
should breach the cap could pass.

**Fix (2026-06-12).** `_accrue()` moved above the cap block in `borrow` (pure reordering; it was
already called in the function, just too late), so the cap sees the accrued + floored debt.
**Test.** `BorrowManager.t.sol::test_borrow_capChecksAccruedDebt` — an Aave spike to just under the
cap, then a small borrow that passes on the stale index, must revert `BorrowExceedsCap` (fails
without the fix).

### M-07 (Medium) — `borrow` ignored the bound vault's Paused/Halted status

**Problem.** `_validateEligibility` checked the asset only, never `vaultStatus()` — a vault
paused or halted during an incident kept being borrowed against via its Aave credit delegation
(sibling of H-01, which fixed only the force-execute path).

**Fix (2026-06-12).** `_validateEligibility` reverts `VaultNotActive()` unless
`IOwnVault(vault).vaultStatus() == VaultStatus.Active`. Only `borrow` calls it, so repay /
liquidate / halt settlement stay open on a non-Active vault (exits must always work). A distinct
error (vs the asset-level `VaultEffectivelyHalted`) keeps vault- and asset-level blocks
distinguishable for monitoring.
**Tests.** `BorrowManager.t.sol::test_borrow_pausedVault_reverts` (also asserts repay still works
while paused), `test_borrow_haltedVault_reverts`.

### M-10 (Medium) — `WstETHRouter` wrapped requested, not received, stETH

**Problem.** Lido's share math delivers 1–2 wei less than the `transferFrom` amount, so the router
held less than `stETHAmount` and `wstETH.wrap(stETHAmount)` reverted on insufficient balance —
breaking every stETH deposit.

**Fix (2026-06-12).** `_depositStETHInternal` measures the received balance-diff and wraps that
(the same pattern `AaveRouter.deposit` uses). The existing `minSharesOut` check covers the
wei-level shortfall.
**Test.** `WstETHRouter.t.sol::test_depositStETH_lidoRounding_succeeds` — a rounding stETH mock
that delivers 2 wei short; reproduces the exact `ERC20InsufficientBalance` revert without the fix.

### M-01 (Medium) — Pyth confidence interval ignored

**Problem.** `PythOracleVerifier._normalizePythPrice` read only `price`/`expo`, never `conf` —
Pyth's own ±uncertainty band. Wide-uncertainty prices (thin market, degraded publishers) were
consumed as exact by both the cached reads (marks) and inline proofs (force-exec, borrow, liquidate).

**Fix (2026-06-12).** A `maxConfBps` bound (constructor param + admin `setMaxConfBps`, non-zero
enforced) checked in `_normalizePythPrice` — the chokepoint both read paths flow through:
reject when `conf · BPS > price · maxConfBps` (`ConfidenceTooWide`; conf and price share the
exponent, so no rescaling). Deploy default: 100 bps (1%). Liveness trade-off is intentional:
while Pyth reports wider uncertainty than the bound, pricing for that asset pauses.
**Tests.** `PythOracleVerifier.t.sol::test_getPrice_wideConfidence_reverts`,
`test_verifyPrice_wideConfidence_reverts`, `test_getPrice_confidenceAtBound_succeeds`, plus
constructor/setter validation. All verified to fail without the check.

### M-02 (Medium) — Unset oracle config accepted unbounded prices

**Problem.** `OracleVerifier.updatePrice` applied staleness/deviation bounds only when the
per-asset config values were `> 0` — an asset never configured via `setAssetOracleConfig` accepted
any validly-signed push with no bounds. Exploitable without signer compromise: signed price blobs
handed out for inline proofs share `updatePrice`'s digest format, so anyone could backfill a stale
cache with the most favorable price ever signed. Configuration relied on an off-chain ops step
(`launch-assets.ts`) with silent-off as the default.

**Fix (2026-06-12).** Fail closed: `updatePrice` reverts `OracleConfigNotSet(asset)` unless both
bounds are configured, then applies them unconditionally; `setAssetOracleConfig` rejects zero
values (`InvalidOracleConfig`) and now emits `AssetOracleConfigSet`. First-push semantics
unchanged (deviation skipped, staleness applies). Ops flow unaffected — the contract now enforces
what `launch-assets.ts` already did by convention.
**Tests.** `OracleVerifier.t.sol::test_updatePrice_unsetConfig_reverts` (verified to fail without
the fix), `test_setAssetOracleConfig_zeroValues_revert`.

### M-09 (Medium) — Sub-unit amounts recorded zero scaled debt while moving real value

**Problem.** Debt is stored as scaled units (`actual × PRECISION / index`, floor division). Once the
index exceeds 1.0, amounts below `index / 1e18` base units floor to **zero scaled units** with no
guard, so real value moved while the ledger recorded nothing: a dust liquidation seized non-zero
collateral (plus the 5% bonus) while reducing the borrower's debt by zero (repeatable griefing — the
position gets strictly less healthy each call); a dust borrow recorded `principal = 0`, which is also
the "no position" sentinel — unrepayable, unliquidatable, collateral stranded, and a second borrow
silently overwrites the struct, orphaning the first collateral; a dust repay took the borrower's
stablecoin and reduced nothing.

**Fix (2026-06-12).** Revert `AmountTooSmall()` whenever a non-zero input converts to zero scaled
units: `borrow` (`scaledDebt == 0`), `repay` and `_liquidate`'s partial branch (`scaledRepay == 0`) —
the same guards Aave V3 carries. `settleHaltedPosition` is deliberately left ungated: it's a
wind-down path that must stay live, and a zero there only under-reduces book debt
(protocol-favorable).
**Tests.** `BorrowManager.t.sol::test_liquidate_dustRepay_reverts`,
`test_borrow_dustAmount_reverts`, `test_repay_dustAmount_reverts` — all verified to fail without
the guards (index lifted to 1.05 via the Aave-debt floor).

### M-08 (Medium) — `_flooredIndex` exploded on a dust scaled-debt base; broke under multi-manager

**Problem.** The M-05 floor computed `minIndex = debtToken.balanceOf(vault) × 1e18 / _totalScaledDebt`
— the vault's **entire** real Aave debt spread over **this manager's** recorded units. The two sides
can diverge: (1) when repays wind the book down to a dust base while residual Aave debt (rounding
crumbs, model lag) remains, the division explodes — e.g. 50 USDC residual over 0.5 USDC of scaled
units lifts the index ×101, multiplying every remaining position's debt, **permanently** (the index
is monotonic, nothing can lower it); (2) a second borrow manager on the same vault would make
`balanceOf(vault)` the combined debt, double-charging both books.

**Fix (2026-06-12, team decision: one manager per vault).** Constrain the world to match the
assumption rather than rebuild the accounting:

- **One borrow manager per vault is now a documented protocol invariant** — it was already enforced
  on-chain (`OwnVault.setBorrowManager` is one-shot, no rotation); the contracts' NatSpec
  (`BorrowManager`, `IBorrowManager`) and docs (protocol.md, AGENTS.md) no longer suggest a second
  manager can share a vault.
- **The floor is skipped when `_totalScaledDebt < 10^stableDecimals`** (one whole stablecoin unit):
  at dust scale there is no meaningful book left for the floor to protect, and residual Aave debt is
  crumb-scale by construction. The M-05 guarantee is unchanged for real positions.
  **Tests.** `BorrowManager.t.sol::test_accrue_dustScaledDebt_skipsFloor` — reproduces the exact ×101
  explosion ($0.50 → $50.50) without the guard; `test_accrue_floorsBookDebtToRealAaveDebt` still
  passes, confirming the floor works above the threshold.

### Fixed Info item — EToken pass-through dividends

The EToken dividend accumulator was rewritten (pass-through holder redirect) and re-verified correct
in the 2026-06-11 re-audit.

---

## 2. Open Findings

No open findings at any severity. The three findings surfaced by the 2026-06-19 re-audit are all
fixed with regression tests — **H-06** (High, §1), and **L-07** + **L-14** (Low, §4). Remaining
future work: the unconfirmed leads in §5.

---

## 3. By-Design / Withdrawn

- **L-04 — Borrow manager is one-shot with no rotation (reclassified by design 2026-06-12).**
  One borrow manager per vault, for the vault's lifetime, is the documented protocol invariant the
  M-08 fix relies on — rotation would break the interest-index floor's debt attribution. The
  incident path for a compromised manager is `haltVault` (instant LP withdrawals, collateral
  excluded from the pool), as the original finding noted.
- **L-09 — Halt-settlement ceil rounding sweeps the surplus to the VM (accepted 2026-06-12).**
  `settleHaltedPosition` ceil-rounds `eTokenToCover`, so redeem proceeds can exceed the book debt
  by a rounding sliver, which sweeps to the VM with the premium instead of refunding the borrower.
  The surplus is bounded by one rounding step (sub-cent) per settlement. A refund was considered
  and rejected: pushing a dust stablecoin transfer to the borrower costs more in gas and adds a
  freeze-revert surface (L-13 class) for negligible value; flooring the cover instead would leave
  zombie dust positions in the wind-down flow. The behavior is documented in code
  ("surplus (over-cover from ceil rounding) sweeps to the manager"). No code change.
- **L-11 — `sweepDividends` pays `vault.manager()` (reclassified by design 2026-06-12).**
  The revenue model routes collateral dividends to the VM (`protocol.md` §7.3), the same
  destination as the lending-premium sweep in `_repayAaveAndSweep`. The admin-mutable `setManager`
  is the same trust boundary that governs all other VM-directed flows. The token argument is
  validated since the L-06 fix.
- **C-01\* — Force-execute asset proof window-scoping (originally by-design 2026-06-11, now FIXED
  2026-06-18; see Pre-audit hardening / PA-04).** The original recourse accepted any asset proof
  timestamped within the order's `[createdAt, now]` window and filled at the pre-committed
  `limitPrice`. The acknowledged risk — that a favorable wick a VM failed to execute against could be
  exercised long after the market moved, costing LPs up to `(limitPrice − currentPrice) × remaining`
  — was judged unacceptable on review. The deferred lever was adopted: force-execute now requires a
  **fresh** asset price (≤ `priceMaxAge`) that **currently** satisfies the limit, matching the
  collateral leg.
- **M-04 — Withdrawal queue is not FIFO (reclassified 2026-06-12).** `fulfillWithdrawal` enforces
  only the wait period + utilization gate; near the cap, capacity is allocated by gas-race/caller
  choice. The queue was never required to be FIFO — the FIFO claim was dropped from the spec
  (protocol.md, AGENTS.md, Types.sol). No code change.
- **M-13 — `fulfillWithdrawal` lets an LP exit before a borrower's bad debt is absorbed (accepted with
  a pause-on-volatility mitigation, 2026-06-19).** While a position is underwater but its loss is not
  yet booked into `totalAssets()` (via `absorbBadDebt`), an LP with a matured request exits at the
  pre-loss share price, socializing the loss onto the remaining LPs. Sibling of H-07 (whose Aave-HF gate
  is blind to it — a user default doesn't move the vault's own Aave HF) and distinct from M-04 (loss,
  not capacity, ordering). No clean code fix: the window opens at "underwater" (before liquidation) and
  there is no O(1) signal for unrecognized bad debt (netting Aave debt is wrong — it is offset by
  borrowers' book-debt receivable). Mitigated by **proactive pause**: `OwnVault.pause()` freezes
  deposits and withdrawals when a backing asset turns volatile, before the window opens — assuming an
  automated, over-biased trigger that never unpauses into a stale/underwater state. Residual: a clean
  flash gap can still beat the pause; revisit with a price-aware withdrawal gate if it becomes material.

---

## 4. Low Findings

### Fixed (2026-06-19)

- **L-07 — Fixed.** `AssetRegistry.migrateToken` now calls `VaultManager.applySplit` atomically in
  the same tx (one `ratio`, so there is no window where the new legacy ratio is live but exposure is
  un-rescaled), and `applySplit` is locked to the AssetRegistry (`OnlyAssetRegistry`) so it can be
  neither called nor skipped independently. Supersedes the 2026-06-12 ops-only mitigation. Tests:
  `AssetRegistry.t.sol::test_migrateToken_appliesSplitAtomically` (verified to fail without the
  atomic call), `VaultManager.t.sol::test_applySplit_onlyAssetRegistry_reverts`.
- **L-14 — Fixed.** In-house `OracleVerifier.getPrice` now reverts `StalePrice` when the cached price
  is older than the asset's configured `maxStaleness` (mirroring `PythOracleVerifier`), so a keeper
  can no longer re-stamp a stale in-house price as fresh via `pullAssetPrice`. Tests:
  `OracleVerifier.t.sol::test_getPrice_stalePrice_reverts` (verified to fail without the check),
  `test_getPrice_atStalenessLimit_succeeds`.
- **L-15 — Fixed (round 2).** `maxDeposit` / `maxMint` returned `type(uint256).max` while the vault
  was Active even though `deposit` reverts for non-managers under the approval gate and `mint` is
  `onlyManager` in every mode — so ERC-4626 aggregators read unlimited capacity and revert. Both now
  return 0 for callers who cannot actually deposit/mint, keyed on the **caller** (`msg.sender`), not
  the `receiver` (a receiver-based check would break the manager depositing/minting on behalf of an
  LP, since OZ's `deposit`/`mint` internally check `amount > max*(receiver)`). Supersedes the §6
  hygiene note. Tests: `OwnVault.t.sol` (`maxMint` zero-for-non-manager / max-for-manager; `maxDeposit`
  open-mode vs approval-mode × manager-vs-non-manager).

### Fixed (2026-06-12)

- **L-01 — Fixed (the other way).** All protocol signatures migrated from EIP-191 personal-sign to
  **EIP-712** typed data, matching what the docs always claimed: quotes sign a
  `Quote(uint256 orderId,address user,bytes32 asset,uint8 orderType,uint256 amount,uint256 price,uint256 quoteId,uint256 expiry)`
  struct and price attestations a `PriceAttestation(bytes32 asset,uint256 price,uint256 timestamp)`
  struct, both under domain `("Own Protocol", "1", chainId, verifyingContract)` (OZ `EIP712`;
  chainId/contract binding moved from manual digest fields into the domain separator).
  `OracleVerifier.priceDigest` is exposed for off-chain/KMS signers. **Off-repo signer services
  (quote signer, oracle price signer) must switch to typed-data signing before deployment.** Tests
  re-sign via reference EIP-712 encodings implemented independently in the test files;
  `test_priceDigest_matchesLocalEip712Encoding` locks the encoding, and new foreign-domain replay
  tests (wrong chainId, wrong verifying contract) replace the old manual-digest ones.
- **L-03 — Fixed.** `closeExposure` now reverts `PriceUnavailable` on a zero mark, mirroring `openExposure` (reachable via an extreme `applySplit` ratio flooring the mark). Test: `test_closeExposure_zeroMark_reverts`.
- **L-05 — Fixed.** `migrateToken` rejects migrating to the current active token or an existing legacy token (`InvalidNewToken`). The `updateAssetConfig` half was already fixed in code (it explicitly preserves `activeToken`/`legacyTokens`/`active`). Test: `test_migrateToken_toActiveOrLegacyToken_reverts`.
- **L-06 — Fixed.** `sweepDividends` validates the token via `AssetRegistry.isValidToken(ticker, token)` (`InvalidEToken`); legacy tokens stay sweepable. Test: `test_sweepDividends_invalidToken_reverts`.
- **L-08 — Fixed.** `_verifyPrice` forwards exactly `verifyFee(priceData)` instead of all of `msg.value`, and `borrow`/`liquidate`/`absorbBadDebt` refund the surplus to the caller as their last step (`_refundExcessEth`, `EthRefundFailed`). Also fixes the latent double-forward in `absorbBadDebt` (two price proofs, each previously sent `{value: msg.value}`). Test: `test_borrow_refundsExcessEth`.
- **L-10 — Fixed.** `settleHaltedPosition` requires `vaultManager.paymentToken() == stablecoin` (`PaymentTokenMismatch`) — proceeds are accounted in stablecoin units, so a diverged payment token now fails loud and recoverable instead of mis-accounting. Test: `test_settleHaltedPosition_paymentTokenMismatch_reverts`.
- **L-12 — Fixed.** `placeOrder` measures the escrow balance-diff and reverts `FeeOnTransferNotSupported` when received ≠ sent. Direct party-to-party legs (`executeOrder`, fill payouts) are intentionally not gated — a FoT token there shorts the counterparty, not the escrow pool. This also closes L-02's fee-on-transfer half. Test: `test_placeOrder_feeOnTransferToken_reverts`.
- **L-13 — Fixed (escrow half) + documented (halt half).** A USDC/USDT blocklist freeze of a
  recipient could permanently brick `cancelOrder`/`expireOrder` (escrow locked), and a frozen
  `haltRedeemAddress` blocks halt redemptions. Fix (team decision): `_returnEscrow` routes through
  `_pushOrSweep` — if the push to the user fails, the escrow sweeps to `registry.treasury()`
  (governance multisig, the protocol's existing custodial sink) and emits
  `EscrowSweptToTreasury(user, token, amount)`; resolution is off-chain (genuine cases refunded by
  governance, illicit funds held/forwarded to authorities). The treasury was chosen over a VM
  destination: orders aren't vault-bound so there is no canonical VM, and a profit-motivated
  counterparty must not custody user escrow — governance custody is neutral and timelocked. The
  halt half is operational by nature (the frozen party is the funding _source_):
  `setHaltRedeemAddress` is rotatable, and protocol.md §10 now mandates monitoring + immediate
  rotation on freeze. A frozen _caller_ of `redeemHalted` blocks only themselves (untouched by
  design). Test: `test_cancelOrder_frozenUser_sweepsEscrowToTreasury` (cancel bricked without the
  fix).

### Closed without code change (2026-06-12)

- **L-02 — Mitigated.** Both halves are covered by existing code: `setPaymentToken` enforces
  `decimals() <= 18`, and the fee-on-transfer half is closed by the L-12 escrow balance-diff check.

---

## 5. Leads (from the 2026-06-11 re-audit — triaged 2026-06-12)

### Confirmed and fixed (2026-06-12)

- **Escrowed eToken dividends stranded — Fixed.** `OwnMarket` had no claim path for dividends
  accruing on eTokens escrowed in resting redeem orders (permanently burned). Added permissionless
  `OwnMarket.sweepDividends(eToken)` → treasury (no canonical VM exists for market escrow;
  per-order attribution is infeasible with the global accumulator), token validated against the
  registry. Test: `test_sweepDividends_escrowedETokens_toTreasury`.
- **`EToken.depositRewards` truncation — Fixed.** For large supply + low-dec reward tokens the
  per-share delta floored to 0 while the full amount was still pulled in (stuck — the old
  "dust stays for the next deposit" comment was wrong: deltas don't accumulate across deposits).
  Now reverts `RewardTooSmall` when the delta is 0 (M-09 pattern).
  Test: `test_depositRewards_tooSmall_reverts`.
- **`absorbBadDebt` NatSpec mismatch — Fixed.** Interface + inline comments said the LP-loss
  collateral "reimburses the caller"; corrected to match the code (released to the treasury).
- **Zero `collateralAsset` accepted — Fixed.** `registerVault` now reverts
  `InvalidCollateralAsset` on a zero ticker. Test: `test_registerVault_zeroCollateralAsset_reverts`.

### Resolved by earlier fixes

- **`PythOracleVerifier` strands surplus ETH** — both consumers now forward the exact fee and
  refund the remainder (`OwnMarket._refundETH`, pre-existing; `BorrowManager._refundExcessEth`,
  L-08 fix). Only a third party calling `verifyPrice` directly with excess ETH can strand it —
  their own overpayment.
- **`absorbBadDebt` surplus sweep to `vault.manager()`** — reachability was tied to M-08's index
  inflation, which is closed (dust-base floor skip + one-manager invariant).

### Noted, no action

- **`shareYield` dilution in the async deposit window** — `requestDeposit` already takes
  `minSharesOut`; the lead only bites when the user passes 0. Frontend should default it sensibly.
- **`_convertToCollateral` floor-div on sub-`1e12`-USD bad-debt slices** — admin-gated path,
  dust-bounded under-socialization per call.

### Open for future review

- **No `minAssetsOut` on withdrawals** — `convertToAssets` is evaluated at (permissionless)
  fulfillment, so value socialized between request and fulfill dilutes a queued LP with no
  automatic opt-out (mitigation today: `cancelWithdrawal`). Candidate fix: `minAssetsOut` stored
  on the request — changes the `requestWithdrawal` external API; decide alongside a frontend
  update.
- **Split-ratio rounding drift** across `migrateToken`/`convertLegacy`/`applySplit` — observed
  drift was protocol-favorable; confirming needs a dedicated multi-split fuzz/trace pass.

### Round-2 re-audit leads (2026-06-19)

New high-signal trails from the round-2 pass. The rest of the round-2 lead set overlaps existing items
(`_flooredIndex` dust base → M-08; collateral-aggregate mark freshness → PA-03; split-ratio drift →
above; Pyth surplus ETH → "Resolved by earlier fixes"; no-`minAssetsOut` withdrawals → "Open for
future review"; `_pushOrSweep` weird-token → L-13).

- **Inline `verifyPrice` has no deviation bound.** The cached push path (`updatePrice`) enforces
  per-asset max-deviation + only-newer-timestamp (M-01/M-02); the inline proof path used by
  `borrow`/`liquidate`/`forceExecuteOrder` checks only signature + staleness, so within `priceMaxAge` a
  signer could attest a wide-deviation print the cached path would reject. Partial-signer-trust
  assumption; defense-in-depth candidate (mirror the deviation bound on the inline path).
- **`utilizationBps` collapses to the floor when `maxDebtUSD() == 0`.** A halted/excluded vault (zero
  collateral mark) makes `utilizationBps()` return 0, so existing borrowers accrue at the *minimum*
  premium during the halt regardless of true utilization. Bounded revenue leak; principal stays
  floor-protected (`_flooredIndex`).
- **`_cappedContribution` bricks single-vault minting.** With a concentration cap set and only one
  contributing vault (`others == 0`), the cap formula yields `maxCounted = 0`, so global collateral
  stays 0 and every `openExposure` reverts `CollateralNotInitialized`. Bootstrapping footgun;
  self-heals once a second vault contributes.
- **aToken rebase on pending deposits.** While a deposit sits in the approval queue,
  `_pendingDepositAssets` is fixed but the aToken rebases, so yield on the pending principal accrues to
  existing LPs and isn't refunded on cancel/reject. Dust-bounded by the pending window.
- **Redeem settles in the _current_ payment token.** `_settleRedeem` resolves `_paymentToken()` live,
  while mint settles in the snapshotted `order.escrowToken` (the H-02 hardening); an admin
  payment-token change mid-flight would settle a resting redeem in the new token.
  Stablecoin-to-stablecoin, admin-action-gated.

---

## 6. Info / Hygiene Notes

- Lending premium sweeps 100% to the VM — matches the current spec (the planned 3-way fee split was dropped from the roadmap 2026-06-12).
- `borrow`/`repay` rely on `nonReentrant` rather than strict CEI ordering — tighten to true CEI.
- `deposit()`/`mint()` access asymmetry (ERC-4626 `max*` misreporting) — **promoted to L-15 and fixed in round 2.**
- `verifyPriceForSession` uses an external self-call, dropping `msg.value` and wasting gas — refactor to internal.
- Apply or suppress the `asm-keccak256` lint notes.
- Gas (minor): cache `registry.vaultManager()` and payment-token decimals per settlement.

---

_Original findings cite code at review time (2026-06-09 review at commit `fa9cf33`; re-audits on `lending` through 2026-06-11, and the two 2026-06-19 multi-agent passes). Every Critical/High was verified directly against source, and every fix carries a regression test that fails without it (H-07 via a live-Aave fork test). Suite: 721 passing._
