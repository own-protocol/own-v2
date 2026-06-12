# Own Protocol v2 — Audit Report & Remediation Status

**Branch:** `lending` · **Last updated:** 2026-06-12 · **Test suite:** 666 passing

Consolidated from the 2026-06-09 full manual audit, the 2026-06-10/11 focused re-audits
(BorrowManager, AaveRouter, H-02 migration changes), and the 2026-06-11 multi-agent re-audit
(16-agent pipeline). This single document replaces `audit-2026-06-09.md`,
`audit-fixes-2026-06-10.md`, and the raw re-audit report. IDs are stable across all passes.

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 1     | 1     | 0    | —         |
| High     | 5     | 5     | 0    | —         |
| Medium   | 10    | 9     | 0    | 1         |
| Low      | 13    | 10    | 0    | 3         |

**Every finding in the report is closed: fixed, mitigated, documented, or by-design — none open. Remaining future work: the unconfirmed leads in §5.**

| ID        | Severity | Finding                                                                                                              | Status                                                         |
| --------- | -------- | -------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| C-01      | Critical | `verifyPrice` accepted any ever-signed price (no staleness) → collateral theft via force-redeem / borrow / liquidate | **Fixed**                                                      |
| H-01      | High     | `forceExecuteOrder` could drain a halted (wind-down) vault                                                           | **Fixed**                                                      |
| H-02      | High     | Resting redeem escrow stranded after `migrateToken` (stock split)                                                    | **Fixed**                                                      |
| H-03      | High     | Withdrawal gate read a stale collateral mark after bad-debt release                                                  | **Fixed**                                                      |
| H-04      | High     | `absorbBadDebt` released collateral in 18-dec units, not native decimals                                             | **Fixed**                                                      |
| H-05      | High     | `fulfillWithdrawal` didn't sync the VaultManager mark → utilization cap bypass                                       | **Fixed**                                                      |
| M-01      | Medium   | Pyth confidence interval ignored                                                                                     | **Fixed**                                                      |
| M-02      | Medium   | In-house push path unbounded when an asset's oracle config is unset                                                  | **Fixed**                                                      |
| M-03      | Medium   | `setRateParams` unvalidated → accrual DoS bricks repay/liquidate                                                     | **Fixed**                                                      |
| M-04      | Medium   | Withdrawal queue is not FIFO                                                                                         | **By design** — spec updated 2026-06-12 to drop the FIFO claim |
| M-05      | Medium   | Book debt could lag real compounding Aave debt → LP shortfall                                                        | **Fixed**                                                      |
| M-06      | Medium   | `borrow` checks the debt cap before `_accrue()` → cap bypass                                                         | **Fixed**                                                      |
| M-07      | Medium   | `borrow` ignores the bound vault's Paused/Halted status                                                              | **Fixed**                                                      |
| M-08      | Medium   | `_flooredIndex` inflates on a dust scaled-debt base; breaks under multi-manager                                      | **Fixed**                                                      |
| M-09      | Medium   | Sub-unit amounts record zero scaled debt while moving real value                                                     | **Fixed**                                                      |
| M-10      | Medium   | `WstETHRouter` wraps requested (not received) stETH → deposit path DoS                                               | **Fixed**                                                      |
| L-01–L-13 | Low      | See §4                                                                                                               | 10 closed (8 fixed + L-02 mitigated + L-07 documented) · 3 by design/accepted (L-04, L-09, L-11) |
| C-01\*    | Info     | Force-execute asset proof is window-scoped, not fresh                                                                | **By design** (team-confirmed 2026-06-11)                      |

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
  submitted price) and requires the asset proof's timestamp to fall inside the order's
  `[createdAt, now]` window. The window scoping is intentional — see C-01\* in §3.
- `OwnMarket._convertToCollateral` (collateral leg) and `BorrowManager._verifyPrice`
  (borrow/liquidate/absorbBadDebt) reject proofs that are future-dated or older than
  `registry.priceMaxAge()`.
- `ProtocolRegistry.priceMaxAge` is governance-tunable (`setPriceMaxAge`, non-zero enforced).
  Deployment value: 2 minutes.

**Tests.** `OwnMarket.t.sol` (settle-at-limit, in-window accepted, pre-window rejected, stale
collateral rejected), `BorrowManager.t.sol::test_borrow_stalePrice_reverts`,
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

No open findings at any severity. Remaining future work: the unconfirmed leads in §5.

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
- **C-01\* — Force-execute asset proof is window-scoped, not fresh (team-confirmed 2026-06-11).**
  Force-execute is the user's VM-failure recourse: if no VM filled the redeem within
  `claimThreshold`, the user proves the asset reached their `limitPrice` _at some point in the
  order's `[createdAt, now]` window_ and is filled at that pre-committed limit — claimable only by
  `order.user`. Requiring a fresh price would break the recourse (a wick that recovered could never
  be forced). The collateral leg stays fresh-checked. **Acknowledged risk:** LP collateral backstops
  the redeem at the committed limit whenever the asset touched it in-window, so a wick a VM fails to
  execute against can cost LPs up to `(limitPrice − currentPrice) × remaining` — the intended LP
  trust model, bounded by the user's own limit. Possible future levers (not adopted): a force-window
  shorter than the order lifetime, or settling at `min(limitPrice, fresh price)`.
- **M-04 — Withdrawal queue is not FIFO (reclassified 2026-06-12).** `fulfillWithdrawal` enforces
  only the wait period + utilization gate; near the cap, capacity is allocated by gas-race/caller
  choice. The queue was never required to be FIFO — the FIFO claim was dropped from the spec
  (protocol.md, AGENTS.md, Types.sol). No code change.

---

## 4. Low Findings (all open)

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
  halt half is operational by nature (the frozen party is the funding *source*):
  `setHaltRedeemAddress` is rotatable, and protocol.md §10 now mandates monitoring + immediate
  rotation on freeze. A frozen *caller* of `redeemHalted` blocks only themselves (untouched by
  design). Test: `test_cancelOrder_frozenUser_sweepsEscrowToTreasury` (cancel bricked without the
  fix).

### Closed without code change (2026-06-12)

- **L-02 — Mitigated.** Both halves are covered by existing code: `setPaymentToken` enforces
  `decimals() <= 18`, and the fee-on-transfer half is closed by the L-12 escrow balance-diff check.
- **L-07 — Documented.** `migrateToken` + `applySplit` atomicity is now an explicit ops requirement
  in `protocol.md` §13 (single multisig batch; liveness-only, admin-recoverable if violated).

---

## 5. Leads (unconfirmed, for future review)

High-signal trails from the 2026-06-11 re-audit, not yet verified:

- No `minAssetsOut` on `fulfillWithdrawal` — bad-debt socialization between request and fulfill dilutes a queued LP with no opt-out.
- `shareYield` between `requestDeposit`/`acceptDeposit` dilutes a pending LP when `minSharesOut == 0`.
- `_convertToCollateral` floor-div releases 0 collateral for sub-`1e12`-USD bad-debt slices on 6-dec vaults.
- eTokens escrowed in `OwnMarket` for resting redeem orders accrue dividends with no claim/sweep path — stranded.
- `EToken.depositRewards` per-share truncation floors to 0 for large supply + low-dec reward tokens.
- `absorbBadDebt` NatSpec says collateral "reimburses the caller"; code releases to `registry.treasury()`.
- `absorbBadDebt` surplus (when `actualRepaid < residual`) sweeps to `vault.manager()`; reachability tied to M-08.
- Split-ratio rounding drift across `migrateToken`/`convertLegacy`/`applySplit` — needs a multi-split trace.
- `registerVault`/`forceExecuteOrder` accept a zero `collateralAsset` → missing-feed revert (liveness, admin-induced).
- `PythOracleVerifier` strands surplus ETH (same class as L-08).

---

## 6. Info / Hygiene Notes

- Lending premium sweeps 100% to the VM — matches the current spec (the planned 3-way fee split was dropped from the roadmap 2026-06-12).
- `borrow`/`repay` rely on `nonReentrant` rather than strict CEI ordering — tighten to true CEI.
- `deposit()`/`mint()` access asymmetry: `mint` is always `onlyManager` while `deposit` can be open — standard ERC-4626 `mint` integrators revert. Align or document.
- `verifyPriceForSession` uses an external self-call, dropping `msg.value` and wasting gas — refactor to internal.
- Apply or suppress the `asm-keccak256` lint notes.
- Gas (minor): cache `registry.vaultManager()` and payment-token decimals per settlement.

---

_Original findings cite code at review time (2026-06-09 review at commit `fa9cf33`; re-audits on `lending` through 2026-06-11). Every Critical/High was verified directly against source, and every fix has a regression test that fails without it. Suite: 665 passing._
