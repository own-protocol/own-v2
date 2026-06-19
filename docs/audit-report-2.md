# 🔐 Audit Doc 2 — Multi-Agent Security Review (Pass 2)

> Second-pass security review of Own Protocol v2, produced by a 12-agent parallel
> audit (9 specialty attackers + 3 gap-hunters, Opus). This is a **standalone**
> document; it does not replace `docs/audit-report.md`. Where a finding overlaps an
> item already tracked there, the existing ID is cross-referenced.

| | |
| --- | --- |
| **Date** | 2026-06-19 |
| **Commit** | `a56beb4` (HEAD / `main`) |
| **Mode** | Default — all `src/` contracts |
| **Reviewer** | Claude Code — `solidity-auditor` skill, 12-agent parallel pass |
| **Confidence threshold** | 80 (findings ≥80 include fixes; below get description + suggested fix) |
| **Severity model** | Impact × Likelihood → Critical / High / Medium / Low / Informational |

### Scope (15 files, ~4,540 LOC)

```
core/AssetRegistry.sol      core/BorrowManager.sol      core/OracleVerifier.sol
core/OwnMarket.sol          core/OwnVault.sol           core/ProtocolRegistry.sol
core/PythOracleVerifier.sol core/VaultManager.sol       libraries/InterestRateModel.sol
libraries/LendingMath.sol   periphery/AaveRouter.sol    periphery/WETHRouter.sol
periphery/WstETHRouter.sol  tokens/EToken.sol           tokens/ETokenFactory.sol
```

Excluded as non-source: `out/`, `cache/`, `broadcast/` (Foundry artifacts), `script/`
(deployment), `interfaces/`, `lib/`, `mocks/`, `test/`.

---

## Severity Summary

| Severity | Count | IDs |
| --- | --- | --- |
| 🔴 Critical | 0 | — |
| 🟠 High | 2 | `A2-H-01` ✅ fixed, `A2-H-02` ✅ fixed |
| 🟡 Medium | 2 | `A2-M-01`, `A2-M-02` |
| 🔵 Low | 1 finding + 8 leads | `A2-L-01` + leads |
| ⚪ Informational | 5 leads | leads |

**Headline:** the protocol's *internal* accounting (debt-index floor, exposure/collateral
conservation, mint↔burn pairing, split invariance, reward accumulator, router balance-diff
handling) is tight. The entire High tier sits at the **lending ↔ vault-collateral boundary** —
the Aave lending layer that prior audit rounds predate or only partially cover. The two Highs
**compound**: `A2-H-01` is a trigger that can realize `A2-H-02`.

---

## 🟠 High

### A2-H-01 — `forceExecuteOrder` lets a redeemer drain any chosen vault's collateral

> **Status: ✅ Fixed (2026-06-19)** — force-execute collateral is now sourced only from a protocol-designated vault (`VaultManager.setForceExecuteVault`, operator-set and rotated to the healthiest vault); the redeemer must pass that exact vault. No designation / `address(0)` reverts `ForceExecuteVaultNotSet` (fail-safe, consistent with `claimThreshold==0`). The `A2-H-02` Aave-HF gate additionally caps any single release.

| | |
| --- | --- |
| **Severity** | High (Impact: High · Likelihood: High) |
| **Location** | `core/OwnMarket.sol:193` (`forceExecuteOrder`) → `core/OwnVault.sol:548` (`releaseCollateral`) |
| **Detected by** | 6 of 12 agents (economic, math, periphery, boundary, numerical-gap, flow-gap) |
| **Overlaps** | Tracked **H-06** ("bind the redeem Order to a vault") — defense-in-depth, still open |

**Plain terms.** The protocol holds collateral in several separate pools (vaults), each owned by
a different set of LPs. When a user force-redeems, they get to **pick which vault pays out the
collateral** — there's no rule tying the payout to a vault actually related to their position. A
malicious actor (e.g. a competing vault operator) can repeatedly aim their redemptions at a
*rival* vault, draining its collateral to zero and harming that vault's LPs, even though the
risk-reduction benefit is shared by everyone. The redeemer isn't paid extra — they just choose
*whose* collateral funds the redemption.

**Description.** The `vault` parameter of `forceExecuteOrder` is fully caller-supplied and is
**not bound to `order.asset`**. The only gates are `isRegisteredVault`, `!isVaultExcluded`,
`!isTradingPaused`, `!isAssetHalted`, and the elapsed claim threshold. `releaseCollateral` then
drains *that* vault (bounded only by its own `totalAssets()`), while `closeExposure` reduces
**global** exposure shared across all vaults — so one vault's LPs absorb the full collateral cost
of a redemption whose benefit is socialized.

**Impact.** Cross-vault value transfer and a targeted-drain / griefing primitive: a vault can be
emptied of collateral, and — combined with `A2-H-02` — pushed into Aave liquidation.

**Likelihood.** High — unprivileged (`order.user` only), always available, repeatable through the
normal place-redeem → wait-threshold → force-execute flow.

**Note on rating.** The redeemer earns *no direct profit* (they receive the same fair `grossUsd`
from any vault). Under a strict profit-only lens this is **Medium**; it earns High because it
inflicts real, repeatable loss on an identifiable victim vault's LPs and is the trigger that
compounds with `A2-H-02`.

**Trace.**
```
forceExecuteOrder(orderId, vault /* attacker-chosen */, ...)
  ├─ isRegisteredVault(vault) ✓   isVaultExcluded(vault) == false ✓   (no asset↔vault link)
  ├─ grossUsd        = remaining × order.limitPrice / 1e18
  ├─ grossCollateral = _convertToCollateral(vault, grossUsd, ...)   // fresh collat price
  ├─ IOwnVault(vault).releaseCollateral(order.user, grossCollateral) // drains CHOSEN vault
  └─ vmgr.closeExposure(order.asset, remaining)                      // reduces GLOBAL exposure
```

**Fix (Option A — bind the source to a protocol-determined vault):**
```diff
- function forceExecuteOrder(uint256 orderId, address vault, bytes calldata assetPriceData, bytes calldata collateralPriceData) external payable {
+ function forceExecuteOrder(uint256 orderId, bytes calldata assetPriceData, bytes calldata collateralPriceData) external payable {
+     // Source from the vault the redeemed asset is registered against — never caller-chosen.
+     address vault = vmgr.vaultForAsset(order.asset);
```

**Fix (Option B — pro-rata across all non-excluded vaults):**
```diff
- IOwnVault(vault).releaseCollateral(order.user, grossCollateral);
+ // Spread grossCollateral across every non-excluded vault in proportion to its counted
+ // collateral, so no single vault's LPs absorb the whole redemption.
+ _releaseProRata(order.user, grossCollateral);
```

---

### A2-H-02 — LP withdrawals are not gated on the vault's Aave health factor

> **Status: ✅ Fixed (2026-06-19)** — `OwnVault.fulfillWithdrawal` (active vaults) and `releaseCollateral` now call `BorrowManager.requireVaultHealthy()` after the aTokens leave, reverting `VaultUnsafeHealthFactor` if the vault's Aave HF would drop below `minClaimHealthFactor` (1.1e18). Lending-disabled vaults and halted-vault emergency exits are exempt.

| | |
| --- | --- |
| **Severity** | High when lending is live (Impact: High · Likelihood: Medium). Latent/Informational if `setBorrowManager` is never called. |
| **Location** | `core/OwnVault.sol:348` (`fulfillWithdrawal`), `:595` (`totalAssets`), `:548` (`releaseCollateral`); `core/VaultManager.sol:576` (`withdrawalBreachesUtil`); `core/BorrowManager.sol:246` (`borrow`) |
| **Detected by** | 2 of 12 agents (invariant = finding, flow-gap = lead) |
| **Overlaps** | Net-new. `docs/leverage-design.md` describes the intended loan-recall-on-withdrawal flow, which is **unimplemented** |

**Plain terms.** The vault's collateral does two jobs at once: it backs the LP investors' shares,
**and** it is the collateral the protocol uses to borrow USDC from Aave (which it lends to users) —
like using your house as both your home and as loan collateral. When an LP withdraws, the protocol
hands back collateral **without checking whether that leaves the Aave loan dangerously
under-collateralized**. If enough LPs withdraw (or someone force-drains via `A2-H-01`), the vault's
Aave loan goes unsafe and **Aave liquidates it at a penalty** — and that loss lands on whoever is
still in the pool. There's also a bank-run dynamic: the first to leave get out clean, the last ones
eat the loss.

**Description.** `BorrowManager.borrow` draws USDC `onBehalf=vault`, so the vault carries the Aave
debt (`debtToken.balanceOf(vault)`) and its aTokens are the Aave collateral. But `totalAssets()`
returns `super.totalAssets() − _pendingDepositAssets` — it **never nets the Aave debt** — and **no
withdrawal/release path checks the vault's Aave health factor**. The only withdrawal gate,
`withdrawalBreachesUtil`, looks solely at synthetic exposure ÷ *global* collateral; because draining
one vault barely moves the global total in a multi-vault pool, the gate passes while a single vault
is emptied.

**Impact.** Aave liquidation of LP collateral (penalty loss) + socialized bad debt to remaining LPs;
first-mover advantage to early exiters. (The `totalAssets` mis-valuation *alone* is largely offset
by the floor-protected book receivable — the **material** harm is the missing solvency gate.)

**Likelihood.** Medium — requires lending enabled (`setBorrowManager`) with outstanding Aave debt and
synthetic-exposure headroom for the util gate. Once lending is live this is reachable through normal
usage.

**Trace.**
```
borrow(...)  ─ pool.borrow(stablecoin, amt, ..., onBehalf=vault)   // vault now owes Aave
fulfillWithdrawal(reqId)
  ├─ assets = convertToAssets(shares)                              // priced off aToken balance only
  ├─ withdrawalBreachesUtil(vault, assets)  → checks SYNTHETIC exposure only (Aave debt invisible)
  ├─ onCollateralReleased(assets)                                  // syncs VM mark, NOT Aave HF
  └─ safeTransfer(req.owner, assets)                               // aTokens (Aave collateral) leave
        →  vault Aave LTV rises → Aave liquidation → penalty socialized to remaining LPs
```

**Fix (Option A — health-factor gate, mirrors the `claimEarnedInterest` guard):**
```diff
  if (IVaultManager(registry.vaultManager()).withdrawalBreachesUtil(address(this), assets)) revert MaxUtilizationExceeded();
+ // Block any release that would push the vault's Aave position below the configured HF floor.
+ if (_borrowManager != address(0)) {
+     (,,,,, uint256 hf) = IAaveV3Pool(aavePool).getUserAccountData(address(this));
+     require(hf >= minWithdrawHealthFactor, "AaveHealthFactorTooLow");
+ }
```

**Fix (Option B — net the Aave debt from the withdrawable base):**
```diff
- function totalAssets() public view override returns (uint256) {
-     return super.totalAssets() - _pendingDepositAssets;
+ function totalAssets() public view override returns (uint256) {
+     // Subtract the vault's outstanding Aave debt (in collateral units) so share value reflects
+     // the lending liability, not just gross aToken balance.
+     return super.totalAssets() - _pendingDepositAssets - _aaveDebtInCollateralUnits();
  }
```

> The robust fix is the design's own (unimplemented) **loan recall**: repay/withdraw from Aave to
> restore the HF *before* returning collateral to the exiting LP.

---

## 🟡 Medium

### A2-M-01 — Redeem settle band trusts a stale mark; mint settle does not

| | |
| --- | --- |
| **Severity** | Medium (Impact: High · Likelihood: Low — requires signer-key compromise) |
| **Location** | `core/OwnMarket.sol:424` (`_checkSettleBand`), `:470` (`_settleRedeem`); `core/VaultManager.sol:143` (`openExposure` freshness) vs `:165` (`closeExposure`, exempt) |
| **Detected by** | 2 of 12 agents (trust-gap = finding, asymmetry = lead) |
| **Overlaps** | Tracked **PA-01** (settle-band per-unit cap) — this is its asymmetric extension |

**Description.** `_checkSettleBand` bounds the settle price to ±`settleBandBps` of
`VaultManager.assetMark` with **no age check**. The mint leg's subsequent `openExposure` enforces
`maxMarkAge` (so a stale mark blocks mints), but the redeem leg's `closeExposure` is
freshness-exempt — so with a stale-high mark a **compromised signer key** can settle a redeem far
above true value, draining the maker's linked wallet. This defeats the band's stated purpose
(capping leaked-key damage) on the redeem side only.

**Impact.** Drains the maker (signer's linked settlement wallet) — a distinct, identifiable victim
(not self-harm, contrary to the note appended to `audit-report.md` §5).

**Likelihood.** Low — only bites after a signer key is compromised (a trusted-role precondition).

**Suggested fix.** Add a `maxMarkAge` freshness check inside `_checkSettleBand` so both legs use a
fresh band reference:
```diff
  uint256 mark = vmgr.assetMark(asset);
  if (mark == 0) return;
+ if (block.timestamp - vmgr.assetMarkUpdatedAt(asset) > vmgr.maxMarkAge()) revert StaleSettleMark(asset);
```

---

### A2-M-02 — `migrateToken` on a halted asset desyncs the fixed halt price

| | |
| --- | --- |
| **Severity** | Medium (Impact: High · Likelihood: Low — requires migrating an already-halted asset) |
| **Location** | `core/AssetRegistry.sol:100` (`migrateToken`) → `core/VaultManager.sol:357` (`applySplit`); consumed at `core/OwnMarket.sol:260` (`redeemHalted`), `core/VaultManager.sol:191` (`pullAssetPrice` halt branch) |
| **Detected by** | 2 of 12 agents (flow-gap = finding, boundary = related lead) |
| **Overlaps** | Net-new |

**Description.** Neither `migrateToken` nor `applySplit` guards against a halted asset or rescales
`_assetHaltPrice`, while `applySplit` scales `_globalAssetUnits` by `ratio`. After e.g. a 2:1 split
of a halted asset, holders convert to 2× tokens (`convertLegacy`) but `redeemHalted` still pays the
**un-rescaled** halt price (`payout = eTokenAmount × haltPrice`), so it pays 2× fair value — draining
the finite halt-redeem fund — and the next `pullAssetPrice` double-counts global exposure
(`haltedUSD = rescaled units × un-rescaled haltPrice`).

**Impact.** Drains the halt-redeem fund (early redeemers over-paid, late redeemers can't redeem) +
corrupted global utilization accounting.

**Likelihood.** Low — requires the admin-error sequence of calling `migrateToken` on an asset already
(permanently) halted via `haltAsset`. (Splitting first, then halting, is safe: `haltAsset` snapshots
the post-split mark.)

**Suggested fix.** Block migration of a halted asset:
```diff
  function migrateToken(bytes32 ticker, address newToken, uint256 ratio) external onlyAdmin {
      if (!_registered[ticker]) revert AssetNotFound(ticker);
+     if (IVaultManager(registry.vaultManager()).isAssetHalted(ticker)) revert AssetHalted();
```

---

## 🔵 Low

### A2-L-01 — `maxDeposit` / `maxMint` violate the ERC-4626 max invariant

| | |
| --- | --- |
| **Severity** | Low (Impact: Low — no fund loss · Likelihood: High — deterministic) |
| **Location** | `core/OwnVault.sol:606` (`maxDeposit`), `:613` (`maxMint`) |
| **Detected by** | 1 of 12 agents (economic) |

**Description.** Both return `type(uint256).max` whenever the vault is Active, but `deposit` reverts
`DepositApprovalRequired` under the approval gate and `mint` is unconditionally `onlyManager` —
violating EIP-4626's requirement that `max*` return the maximum that would not revert. Breaks
aggregator/zapper integrations; no direct fund loss.

**Suggested fix.** Return `0` from `maxDeposit` when `_requireDepositApproval && receiver != manager`,
and from `maxMint` for any non-manager caller.

---

## Leads (severity *if confirmed*)

High-signal trails where the full unprivileged-profit exploit could not be completed in one pass.
Not part of the scored findings; severity is conditional on confirmation.

| Lead | Location | If-confirmed | Why not higher / overlap |
| --- | --- | --- | --- |
| Inline `verifyPrice` has no deviation bound | `OracleVerifier.verifyPrice` | Medium | Signer-trust assumption; signature-gated, bites only in volatility |
| `_flooredIndex` dust/unit guard | `BorrowManager._flooredIndex:1030` | Low | Agents argue harmful state (`book ≪ aaveDebt`) is **unreachable**; documented dust carve-out (4 agents flagged) |
| `claimEarnedInterest` carry attribution | `BorrowManager.claimEarnedInterest` | Low | Protocol-favorable, manager-gated; 10% buffer not breachable (3 agents) |
| `maxDebtUSD` stale collateral mark | `BorrowManager.maxDebtUSD`/`borrow` | Low | Aggregate-cap softness only; per-position fresh LTV + Aave HF backstop. Overlaps **PA-03** |
| `utilizationBps` premium floor at `cap==0` | `BorrowManager.utilizationBps` | Low | Bounded revenue leak; principal floor-protected |
| Redeem settles in current payment token | `OwnMarket._settleRedeem:480` | Low | Needs an admin payment-token flip mid-flight; stablecoins ~1:1 |
| `_cappedContribution` bricks single-vault minting | `VaultManager._cappedContribution` | Low | Liveness/bootstrapping footgun; self-heals with a 2nd vault |
| Permissionless `fulfillWithdrawal` | `OwnVault.fulfillWithdrawal` | Low | Fulfiller gains nothing; `cancelWithdrawal` is the opt-out |
| `applySplit` deferred exposure recompute | `VaultManager.applySplit` | Informational | Drift is protocol-conservative; can't underflow. Overlaps tracked "split-ratio rounding drift" |
| aToken rebase on pending deposits | `OwnVault.totalAssets`/`requestDeposit` | Informational | Dust-bounded by the pending window |
| Pyth `updatePriceFeeds` strands overpaid ETH | `PythOracleVerifier.updatePriceFeeds` | Informational | Self-harm to a direct caller only |
| `onCollateralReleased` over-removes (capped vault) | `VaultManager.onCollateralReleased` | Informational | Conservative direction; self-heals on next pull |
| `_pushOrSweep` transfer-then-false double-spend | `OwnMarket._pushOrSweep` | Informational | Not reachable with the trusted eToken/USDC set |

---

## Verified sound (no finding)

Traced adversarially and cleared, recorded so the absence is calibrated, not skipped:

- **Mint/burn ↔ open/close exposure** pairing is unit-matched on every path; `convertLegacy` is
  exposure-neutral (split-invariant).
- **Four debt-reduction paths** (`repay`, `_liquidate`, `settleHaltedPosition`, `absorbBadDebt`) each
  reduce `_totalScaledDebt` and `principal` by identical scaled amounts; every one is preceded by a
  matching `_repayAaveAndSweep`, so book and Aave debt move in lockstep.
- **`claimEarnedInterest` self-accounting** closes: the non-zero `interestBufferBps` keeps
  `claimable < earnedInterest`, so `book > aaveDebt` after every Aave draw.
- **Decimal scaling**: collateral `>18` rejected in the `OwnVault` constructor; payment token `>18`
  rejected in `setPaymentToken`; every `10**(18-decimals)` is underflow-safe.
- **Rounding** is consistently protocol-favorable; **virtual-shares offset** (`_decimalsOffset = 6`)
  neutralises the first-depositor/inflation attack.
- **EIP-712**: `OracleVerifier` and `OwnMarket` share name/version but differ by `verifyingContract`
  + typehash — no cross-contract signature replay; quote digests bind `orderId` + `user`.
- **Reentrancy**: `nonReentrant` + effects-before-interactions throughout; ETH refunds are state-last.
- **Periphery routers** use balance-diff accounting (fee-on-transfer / rebasing safe) and are
  stateless (no capturable standing approvals or balances).

---

## Methodology

Twelve attacker agents ran in parallel on Opus, each given the full in-scope source plus a senior-
auditor SOP, a specialty playbook, and shared output rules:

| # | Specialty | # | Specialty |
| --- | --- | --- | --- |
| 1 | Math precision | 7 | First principles |
| 2 | Access control | 8 | Asymmetry |
| 3 | Economic security | 9 | Boundary |
| 4 | Execution trace | 10 | Numerical gap-hunter |
| 5 | Invariant | 11 | Trust gap-hunter |
| 6 | Periphery | 12 | Flow gap-hunter |

Raw findings were deduplicated by (contract, function, bug-class) with function isolation, then each
candidate was run through four sequential validation gates (attack execution → reachability → trigger
→ impact). The two highest-severity claims (`A2-H-01`, `A2-H-02`) and the contested settle-band /
halt-price items were re-verified against source by tracing the actual guards on each attack path.
Coverage: 21 unique (contract, function) tuples surfaced across the panel; all 21 are represented in
the findings/leads above.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence
> of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs,
> and on-chain monitoring are strongly recommended.
