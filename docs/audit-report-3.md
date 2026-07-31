# Own Protocol v2 — Audit Report & Remediation Status (Pass 3)

**Branch:** `upgrade-borrow-manager` · **Last updated:** 2026-07-31 · **Test suite:** 1,197 passing

Consolidated from the 2026-07-19 `ChainlinkOracleVerifier` implementation review and the 2026-07-31
full multi-agent re-audit (solidity-auditor, 12-agent pipeline — 9 specialty attackers + 3
gap-hunters). This single document replaces `docs/chainlink-audit-report.md`. IDs are stable across
passes: `CL-` items retain their original numbering from the Chainlink review, `A3-` items are new in
this pass.

Findings from earlier passes (`C-`, `H-`, `M-`, `L-`, `PA-`, `A2-`) are referenced where a new
finding extends or overlaps them, but are not restated — those passes' documents are not in-tree.

The 2026-07-31 pass surfaced **3 High, 9 Medium, 5 Low**. Two Highs (**A3-H-01**, **A3-H-02**) were
fixed during the pass, each with a regression test verified to fail against the pre-fix code. The internal accounting was attacked directly across multiple agents
and held (§7); the findings cluster instead in three shapes: **guard ordering** (a check evaluated
against a value the same call then changes), **asymmetric guards** (a floor enforced on one side of a
paired operation but not the other), and **permissionless cranks** whose timing an attacker chooses.
Two findings — **A3-H-01** and **A3-M-03** — are direct sequels to earlier fixes that closed one half
of a symmetry.

**Scope change made during this pass.** `OracleVerifier.sol` and `PythOracleVerifier.sol` were retired
from use and moved from `src/core/` to `archive/` (sources preserved, imports rebased, suite green).
Two findings existing only in those contracts were withdrawn and two others downgraded; see §3.

### Scope (20 files, ~6,523 LOC)

```
core/AssetRegistry.sol          core/BorrowManager.sol       core/ChainlinkOracleVerifier.sol
core/OwnLendingPool.sol         core/OwnMarket.sol           core/OwnVault.sol
core/ProtocolRegistry.sol       core/ReserveVault.sol        core/VaultManager.sol
libraries/InterestRateModel.sol libraries/LendingMath.sol    periphery/LendingRouter.sol
periphery/VaultYieldManager.sol periphery/WETHRouter.sol     periphery/WstETHRouter.sol
tokens/EToken.sol               tokens/ETokenFactory.sol     tokens/OwnAToken.sol
tokens/OwnDebtToken.sol         tokens/OwnershipNFT.sol
```

Excluded as non-source: `out/`, `cache/`, `broadcast/` (Foundry artifacts), `script/` (deployment),
`interfaces/`, `lib/`, `mocks/`, `test/`, `archive/` (retired contracts).

---

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 0     | 0     | 0    | —         |
| High     | 3     | 2     | 1    | —         |
| Medium   | 9     | 1     | 8    | —         |
| Low      | 8     | 0     | 5    | 3         |
| Info     | 4     | 0     | 0    | 4         |

| ID        | Severity | Finding                                                                                                          | Status                                    |
| --------- | -------- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| A3-H-01   | High     | `psmFillOrder` validates the settle band against a mark it then refreshes → filler edge = band + intra-`maxMarkAge` drift | **Fixed** (2026-07-31)              |
| A3-H-02   | High     | `_accrue` billed the whole elapsed window at an attacker-timed rate; no denominator change accrued first          | **Fixed** (2026-07-31)                    |
| A3-H-03   | High     | `fulfillWithdrawal` is permissionless with no zero-check and no `minAssetsOut` → LP shares settled at a chosen trough | **Open** (extends tracked lead, §5)   |
| A3-M-01   | Medium   | JIT capture of accrued LP yield via permissionless `distribute` / `claimEarnedInterest`                          | **Fixed** (2026-07-31)                    |
| A3-M-02   | Medium   | Concentration cap derived only from *other* vaults collapses a capped vault's counted collateral to zero          | **Open**                                  |
| A3-M-03   | Medium   | Borrower `_drawFromAave` skips the Aave health floor that every collateral-decreasing path enforces               | **Open** (sequel to H-07)                 |
| A3-M-04   | Medium   | `migrateToken` desyncs every PSM wrapper's ratio-jump baseline → all PSM paths brick on a split                   | **Open**                                  |
| A3-M-05   | Medium   | `releaseCollateral` ignores `Paused` → paused vault pays redeemers while its LPs are frozen                       | **Open**                                  |
| A3-M-06   | Medium   | `placeOrder`/`executeOrder` gate redeem on `isActiveAsset` → deactivated asset traps holders                      | **Open** (sequel to L-17)                 |
| A3-M-07   | Medium   | `depositRewards` has no ex-dividend snapshot; fee-free PSM round-trip front-runs it                               | **Open** (reachability unconfirmed)       |
| A3-M-08   | Medium   | Saturated `totalAssets()` makes `previewDeposit` mint a near-unbounded share count                               | **Open** (venue-dependent)                |
| A3-M-09   | Medium   | `ReserveVault._releaseCollateral` omits the PSM ratio-jump guard it shares a ratio with                           | **Open**                                  |
| A3-L-01   | Low      | `utilizationBps` returns 0 for a zero cap with live debt → premium collapses to floor during a halt               | **Open**                                  |
| A3-L-02   | Low      | `claimEarnedInterest` and `requireVaultHealthy` share one threshold → revenue crank consumes the exit floor       | **Open** (more reachable after A3-M-01)   |
| A3-L-03   | Low      | `forceExecuteOrder` is the only settle path with no price band                                                    | **Open** (downgraded, §3)                 |
| A3-L-04   | Low      | `BorrowManager._convertToCollateral` divides by an unbanded signed price                                          | **Open** (downgraded, §3)                 |
| A3-L-05   | Low      | ETH refund helpers pay out `address(this).balance`, not this call's surplus                                       | **Open**                                  |
| CL-L01    | Low      | Reverting aggregator bricks both legs, including a fresh in-house price                                           | **By design** — fail-closed accepted      |
| CL-L02    | Low      | Cached `clDecimals` can rot on an aggregator upgrade                                                              | **By design** — ops mitigation (§6)       |
| CL-L03    | Low      | A feed that dies mid-session reads as current for up to `clFreshWindow`                                           | **By design** — ops mitigation (§6)       |
| CL-I01    | Info     | Compromised-signer damage cap = `bandBps` during any quiet stretch                                                | **By design**                             |
| CL-I02    | Info     | Timestamp-ignoring consumers accept prices up to `maxAnchorAge` old                                               | **By design** — but see A3-L-03 note      |
| CL-I03    | Info     | `verifyPriceForSession` self-call drops `msg.value`                                                               | **By design** — `verifyFee` is always 0   |
| CL-I04    | Info     | Multicall + payable `verifyPrice`                                                                                 | **By design** — no function reads `msg.value` |

---

## 1. Fixed Findings

### A3-H-01 (High) — `psmFillOrder` validated the settle band against a mark it then refreshed

**Problem.** `psmFillOrder` called `_checkSettleBand` (`OwnMarket.sol:375`) immediately before
`_psmContext` (`:376`). `_psmContext` calls `pullAssetPrice` at `:718`, re-reads the mark at `:720`,
and derives the conversion `ratio` from the refreshed value — which `_psmFillMint`/`_psmFillRedeem`
and `_psmSpreadFee` all price off. The band therefore bounded the *pre-refresh* mark while the fill
settled against the *post-refresh* one, so a filler's real edge was `settleBandBps` **plus** whatever
the price drifted within `maxMarkAge`, not `settleBandBps` alone. The **M-11** fix had already made
the band reference fresh-within-`maxMarkAge`; this was the ordering half of the same guarantee, and
it defeated **PA-01**'s stated per-unit damage cap on the PSM fill path.

With Robinhood params (`settleBandBps` 500, `maxMarkAge` 1h): mark $400 written 55 min ago, market at
$368 (−8%), resting Mint order with `limitPrice` $420 (exactly the +5% edge at placement). The band
passes at the edge against $400; `_psmContext` refreshes to $368; the filler delivers 100 wrapper
units worth $36,800 and collects the full $42,000 escrow — 12.4% against a 5% cap, borne by the order
owner. `psmFillSpreadShareBps` defaults to 0, so no fee offsets it. The redeem leg is symmetric after
a rise at ~13.7%. Swapping the calls makes the counterfactual revert `PriceOutOfBand`
(diff 52e18; `52e18·10000 > 368e18·500`).

**Fix.** `_checkSettleBand` now runs *after* `_psmContext`, so the band bounds the same mark the fill
settles against. `_checkSettleBand` is `view`, and `_psmContext`'s `notePsmRatio` write rolls back if
the band then reverts, so the only behavioural change is revert ordering. Localised: `psmMint`
(`:309`) and `psmRedeem` (`:338`) call `_psmContext` but never `_checkSettleBand` (they price off the
oracle ratio directly), and the `_settleMint`/`_settleRedeem` call sites (`:547`, `:579`) are
quote-driven and do not refresh the mark mid-call.

**Tests.** `PsmFlow.t.sol::test_psmFillOrder_bandChecksRefreshedMark_reverts` pins the ordering: a
limit sitting exactly on the +5% edge of the $250 mark clears the band pre-refresh, the oracle then
drops 8% to $230, and the fill must revert `PriceOutOfBand(TSLA, 262.5e18, 230e18, 500)` because
`_psmContext` refreshed the mark first. Verified to **fail** against the pre-fix ordering. Existing
coverage retained: `::test_psmFillOrder_limitOutsideBand_reverts`, `::test_psmFillOrder_staleWrapper_reverts`.
Full suite green (1,195 passing / 0 failed).

**Detected by** 1 of 12 agents (execution-trace).


### A3-H-02 (High) — `_accrue` billed the whole elapsed window at an attacker-timed rate

**Problem.** `_accrue` computes `accrueIndex(_index, _currentRateBps(), dt)` — the instantaneous rate
sampled at call time, applied retroactively across the whole elapsed interval — and both inputs were
attacker-controlled. `accrue()` (`BorrowManager.sol:513`) has no modifier, and the rate's denominator
`maxDebtUSD()` derives from `collateralMark`, which tracks the vault's `totalAssets()`.
`OwnVault.fulfillWithdrawal` has **no caller check**, so anyone can settle any matured request and
move it.

Stated as an invariant: every path changing the *numerator* already accrued first (all seven internal
`_accrue()` sites — borrow / repay / liquidate / absorb / settle), but **no path changing the
denominator did**, leaving a window whose rate was decided after the fact.

With `rateParams` (base 100, optimal 8000, slope1 400, slope2 7500), mark $20M, `targetLtvBps` 5000 →
cap $10M, book debt $5M → utilisation 5000 bps → premium 350 bps. Settling a matured $12M request
drops the mark to $8M → cap $4M → utilisation clamps to 10000 bps → premium 8000 bps. Calling
`accrue()` in the same transaction with `dt` = 7 days grew the index **+1.534%** instead of +0.067% —
~$73.4k of debt on a $5M book in one block, making every position in HF ∈ [1.0, 1.0147) liquidatable
at `liquidationBonusBps`. `withdrawalBreachesUtil` gates a different ratio and `requireVaultHealthy`
passed at HF 1.28. The mirror direction pinned the premium at its 100 bps floor and starved LPs.

**Fix.** A private `_accrueLending()` in `OwnVault` books interest at every point that moves
`totalAssets()`: both `deposit` overloads (via `_depositWithMin`), `mint`, `acceptDeposit`,
`fulfillWithdrawal`, `releaseCollateral`, and `shareYield`. It no-ops when lending is disabled
(`_borrowManager == address(0)`) and needs no new imports — the vault already calls
`IBorrowManager.requireVaultHealthy()`.

**Why `OwnVault` alone is sufficient.** `VaultManager.pullCollateralPrice` recomputes the mark as
`totalAssets() × price`; it cannot move the mark independently, only *reflect* `totalAssets()`. Since
`totalAssets()` moves only through the six vault entry points above, timestamping accrual at each one
bounds any subsequent `pullCollateralPrice` + `accrue()` bundle to `dt ≈ 0`. Both directions close:
the withdrawal path books the window before the mark drops, and the deposit path books it before the
mark can rise.

**Deployment constraint.** `VaultManager` is **not redeployable** in the live system; `OwnVault`,
`BorrowManager` and `VaultYieldManager` are. An earlier attempt placed the hook inside
`VaultManager.pullCollateralPrice` / `onCollateralReleased` — cleaner as an invariant, but
unshippable, and it additionally broke `pullCollateralPrice` for every reserve vault
(`ReserveVault` does not implement `borrowManager()`). Any future fix must respect this boundary.

**Not done: distribution on the LP path.** Realizing yield on every deposit and withdrawal — so the
withdrawal delay could be dropped — is blocked by the reentrancy guard, not by preference.
`OwnVault is ERC4626, IOwnVault, ReentrancyGuard` shares one `_status`, and `deposit`,
`fulfillWithdrawal` and `shareYield` are all `nonReentrant`, so `vault → manager.distribute() →
vault.shareYield()` reverts. Separately, `claimEarnedInterest` performs a real Aave draw and reverts
below `minClaimHealthFactor`, so routing it through the LP path would make deposits and withdrawals
fail exactly when the vault is near its health floor (the band **A3-M-03** lets a borrower create),
both are resolved under **A3-M-01**, which also records the decisions to set `interestBufferBps` to
1% and to move to instant withdrawal.

**Residual.** A direct aToken transfer to the vault also raises `totalAssets()` and cannot be
intercepted, but it is an unrecoverable gift to LPs that only pushes the rate *down* — the attacker
funds the subsidy. An external Aave liquidation reducing the balance is likewise outside the vault's
control. The Aave base-rate component of `_currentRateBps()` still drifts within a window and applies
over the whole `dt`; that is inherent and matches Aave's own model. The manipulable component is the
utilisation-driven premium, which the fix covers.

**Tests.** `BorrowAndLiquidateFlow.t.sol::test_deposit_accruesBeforeTotalAssetsMoves` opens a
position, warps 180 days, asserts `totalDebtUSD()` (which reads the *stored* index, not the projected
one) is unchanged, then asserts an LP deposit moves it — proving accrual is booked before
`totalAssets()` does. Verified to **fail** with the hook removed. Full suite green (1,196 passing /
0 failed). `MockHealthBorrowManager` (`test/unit/OwnVault.t.sol`) gained an `accrue()` no-op; it was
the only test double affected.

**Overlaps.** Net-new. Adjacent to **M-06** (debt cap checked before `_accrue`), which fixed ordering
within `borrow` but not the rate-sampling semantics.
**Detected by** 1 of 12 agents (economic-security).

### A3-M-01 (Medium) — JIT capture of accrued LP yield

> **Status: ✅ Fixed (2026-07-31)** — the vault now realizes yield before it prices any LP entry or
> exit, so a newcomer buys in at the post-yield share price. Residuals below.

**Problem.** `VaultYieldManager.distribute` was permissionless and pushed the entire held balance
through `OwnVault.shareYield` in one step, raising the share price instantly with no vesting.
`claimEarnedInterest` was likewise permissionless, letting a caller first force-realize borrowers'
accrued premium into the shell and then pay it to themselves. Whoever held shares at that instant
took a pro-rata slice of everything accrued since the last distribution, regardless of how long they
had been invested.

**Rating correction (kept for the record).** Initially rated High on the assumption that
`OwnVault._withdrawalWaitPeriod` sat at its `0` default, making the attack atomic and flash-loanable.
That assumption was wrong: `broadcast/SetWithdrawalDelayRobinhood.s.sol/4663/run-latest.json` records
`setWithdrawalWaitPeriod(28800)` — 8 hours — succeeding against the oUSDG OwnVault
`0x246705F13bF56e3A572ae1407c065126230557FC` on 2026-07-20. See §8.

**Fix, part 1 — remove the reentrant callback.** `distribute` no longer calls
`IOwnVault.shareYield`; it transfers the converted aTokens straight to the vault. `totalAssets()` is
`balanceOf(vault) − _pendingDepositAssets`, so a plain transfer lifts the share price identically,
and the manager already performed `shareYield`'s only other check (`totalSupply() != 0`) itself. This
matters because `OwnVault is ERC4626, IOwnVault, ReentrancyGuard` shares one `_status` across
`deposit`, `fulfillWithdrawal` and `shareYield` — with the callback in place, a vault-side hook was
impossible.

**Fix, part 2 — sync before pricing.** `VaultYieldManager.syncYield()` performs a best-effort claim
then a non-reverting distribute, and `OwnVault._syncLending()` calls it (after `accrue()`) on the
four paths that price LP shares: both `deposit` overloads, `mint`, `acceptDeposit` and
`fulfillWithdrawal`. `releaseCollateral` and `shareYield` keep accrue-only — they are not LP pricing
points, and hooking `shareYield` would re-enter the manager that called it.

`syncYield` deliberately carries **no reentrancy guard**: the vault calls it from inside its own
guarded paths, the body is idempotent (it drains the held balance, so a nested call is a no-op), and
nothing in it calls back into the vault. The claim leg is `try`/`catch` — a draw that would breach the
vault's Aave health floor, or a paused or borrow-capped venue, must never block LP flow; the yield
simply stays unrealized, which is the pre-fix behaviour. The vault-side call is guarded by
`manager.code.length != 0` plus `try`/`catch`, since an EOA manager is a documented supported state.

**Residual.** `interestBufferBps` rate-limits each claim to `(BPS − buffer)/BPS` of the *current*
gap. It is a per-claim limiter, not a cumulative reserve — each claim draws from Aave and shrinks the
gap, so successive claims extract ~all premium, and anything still unclaimed is not forfeited: it
reaches the shell as `_repayAaveAndSweep` surplus at repayment and pays out to LPs on the next sync.
The buffer therefore affects *when* premium lands, not how much LPs receive. (The only genuine
reduction to LPs is `treasuryCutBps` — 1000 bps on Robinhood — the protocol fee, by design.)

**Decision (2026-07-31): `interestBufferBps` → 1% (100 bps)**, down from 10%. Applied as the
`BorrowManager` constructor default, so redeployed managers ship with it and no setter call is needed;
existing deployments still need `setInterestBufferBps(100)`. Shrinks the repay-time
lump roughly 10× while keeping about an 8× margin over the worst-case divergence between Aave's
continuous compounding and the sampled simple-interest book — the divergence `_flooredIndex` exists to
absorb. Admin setter, no redeploy. A direct aToken transfer into the vault remains uncapturable by the
hook, but it is a gift to LPs.

**Interaction with A3-L-02 — watch this.** The claim now fires on every LP entry and exit rather than
on an occasional crank, so the shared-threshold issue in **A3-L-02** becomes materially more
reachable: repeated claims can walk the vault's Aave HF down toward `minClaimHealthFactor`, which is
the same value `requireVaultHealthy` gates exits on. The `try`/`catch` means a breaching claim is
skipped rather than reverting the LP's transaction, and `claimEarnedInterest` still refuses to cross
the floor, so exits remain possible at equality — but the recommended follow-up in **A3-L-02** (gate
the claim on `minClaimHealthFactor + buffer`) is now the natural next change rather than an optional
hardening.

**Decision (2026-07-31): instant withdrawal.** `withdrawalWaitPeriod` goes to `0`, with no further
code changes. The delay is no longer load-bearing for this finding, and at a 1% buffer the residual
repay-time lump is small enough to accept. Two risks are knowingly accepted alongside it, recorded
here rather than re-argued: **M-13**'s exit-before-bad-debt-is-absorbed window loses the queue half of
its pause-plus-queue mitigation, so a proactive pause must now beat an exiting LP in the same block;
and **A3-L-02** stays open while claims fire on every LP action.

**Tests.** `VaultYieldManager.t.sol::test_deposit_cannotFrontRunPendingYield` sweeps 10,000e6 of
revenue into the shell, has an attacker deposit 9× the incumbent's stake, and asserts the attacker
redeems only their principal while the incumbent keeps the full 8,000e6 LP share — verified to
**fail** with the `_syncLending` hook removed. Existing coverage retained, including
`::test_distribute_splitsAndLiftsSharePrice`, which pins that the direct aToken transfer lifts the
share price exactly as `shareYield` did. Full suite green (1,197 passing / 0 failed).

**Detected by** 2 of 12 agents (periphery = finding; economic-security, first-principles = leads).

---

## 2. Open Findings

### A3-H-03 (High) — `fulfillWithdrawal` settles another LP's shares at a caller-chosen price

**Problem.** `fulfillWithdrawal` checks only that the request exists and is `Pending`. There is no
caller gate, no `assets == 0` revert, and no `minAssetsOut` — unlike `deposit(assets, receiver,
minSharesOut)` and `requestDeposit(..., minSharesOut)`, which both carry slippage floors.
`SafeERC20.safeTransfer(owner, 0)` does not revert, so a zero settlement succeeds silently. A rival LP
can therefore burn a victim's escrowed shares at a chosen trough; the difference accrues pro-rata to
remaining LPs, so an attacker holding 50% of shares who burns a victim's 10% moves to 55.6% of the
restored pool — quantified profit, not merely griefing.

The zero-price variant needs `totalAssets()` to saturate (see **A3-M-08**) plus a halted vault, since
halting skips both the wait period and the util gate. The depressed-price variant needs no special
state at all.

**Suggested fix.**
```diff
+ if (msg.sender != req.owner && msg.sender != manager) revert NotAuthorized();
  uint256 assets = convertToAssets(req.shares);
+ if (assets == 0) revert ZeroAmount();
+ if (assets < req.minAssetsOut) revert SlippageExceeded();
```
The `minAssetsOut` leg changes the `requestWithdrawal` external API and should be decided alongside a
frontend update.

**Overlaps.** **Reopens and extends the tracked lead "No `minAssetsOut` on withdrawals"** (§5, open
for future review), which identified the permissionless-fulfilment dilution but not the missing caller
check or the silent zero settlement. Distinct from **M-13** (loss *ordering* vs unabsorbed bad debt,
accepted by design) and **M-04** (capacity ordering).
**Detected by** 1 of 12 agents (numerical-gap); the missing caller check independently corroborated
via A3-H-02.

### A3-M-02 (Medium) — Concentration cap collapses a capped vault's counted collateral to zero

**Problem.** `VaultManager._cappedContribution` computes `maxCounted = others·cap/(BPS−cap)`, deriving
a capped vault's allowance purely from *other* vaults' counted collateral. It floors to zero when the
capped vault is the only counted vault, and collapses super-linearly — a `cap/(BPS−cap)` multiplier on
someone else's balance change — as the rest of the pool shrinks. The permissionless
`pullCollateralPrice` then zeroes `_globalCollateralUSD`, reverting all `openExposure` with
`CollateralNotInitialized` and all `fulfillWithdrawal` with `MaxUtilizationExceeded`.
`onVaultUnhalted` has the identical defect (it passes `_globalCollateralUSD` as `others`).

Worked case at cap 3000 bps: vault A raw $9,000,000, vault B uncapped $1,000,000 → A counts $428,571
(30%, as intended). B is then drained to $1,000; the next routine keeper `pullCollateralPrice(A)` sees
`others` = $1,000 → A counts **$428**. $9,001,000 of real collateral counts as $1,428.

**Suggested fix (Option A — handle the degenerate case):**
```diff
+ if (others == 0) return rawMark;
```
**Suggested fix (Option B — make the cap self-referential):**
```diff
- uint256 maxCounted = others.mulDiv(cap, BPS - cap);
+ uint256 maxCounted = Math.max(others.mulDiv(cap, BPS - cap), rawMark.mulDiv(cap, BPS));
```
Option B also fixes the gradual-shrinkage case, not just `others == 0`.

**Residual.** Availability only — no fund loss, and admin-recoverable via
`setCollateralCapBps(vault, 0)`. Chains into **A3-L-01**.
**Open question:** does any vault carry a non-zero concentration cap in the deployed config? Must be
checked against `broadcast/`, not `script/` — see §8.
**Detected by** 3 of 12 agents (math-precision, numerical-gap = findings; flow-gap = lead).

### A3-M-03 (Medium) — Borrower draws skip the Aave health floor every exit path enforces

**Problem.** `_drawFromAave` has two call sites. `claimEarnedInterest` draws then reverts below
`minClaimHealthFactor`; `_executeBorrow` draws with no such check. Nothing ties `targetLtvBps` to the
venue's liquidation threshold — `initialize` and `setTargetLtvBps` validate only `0 < ltvBps < BPS` —
so any `targetLtvBps > LT/1.1` reaches HF ∈ [1.0, `minClaimHealthFactor`) at the protocol's own debt
cap. In that band every `fulfillWithdrawal` and every `releaseCollateral` reverts on
`requireVaultHealthy()` while `borrow` keeps succeeding. With `OwnLendingPool` at ltv 7500 / LT 8000,
the cap itself yields HF = 8000/7500 = 1.0667, below the 1.1 default.

The cap is checked only at borrow time, so **ordinary Aave interest accrual walks the vault into the
band even from a conservative config** — this is the one finding in the report that fires without an
attacker.

**Suggested fix.**
```diff
  _drawFromAave(stablecoinAmount);
+ requireVaultHealthy();
```

**Overlaps.** **Direct sequel to H-07** (round 2), which added `requireVaultHealthy()` to the
collateral-*decreasing* paths; the debt-*increasing* path never got it. Consider additionally
validating `targetLtvBps` against the venue's liquidation threshold at set time.
**Open question:** deployed `targetLtvBps` (7000) vs the pool's `liquidationThresholdBps` — confirm
against `broadcast/`.
**Detected by** 1 of 12 agents (trust-gap).

### A3-M-04 (Medium) — `migrateToken` desyncs every PSM wrapper's ratio-jump baseline

**Problem.** `AssetRegistry.migrateToken` rescales `_legacyRatio` for every legacy token
(`:143-148`) but leaves `_psmConfigs[ticker][*].lastUsedRatio` untouched, while the atomically-called
`VaultManager.applySplit` divides `_assetMark` by `ratio`. The derived PSM ratio
(`wrapperPrice·PRECISION/mark`) therefore shifts by exactly `ratio` — a 2-for-1 split doubles it — and
`_psmContext`'s jump guard sees `diff == last`, so `last·BPS > last·bound` holds for every bound below
`BPS`. Every PSM path for that ticker (`psmMint`, `psmRedeem` including the halted in-kind exit,
`psmFillOrder`) reverts `RatioJumpExceeded` until an operator calls `resetRatioGuard` for each entry
of `_psmWrappers[ticker]` — and that reset sets `lastUsedRatio = 0` (`:240`), disarming the jump guard
entirely for the following operation. Splits are routine for equities, so likelihood is high.

A second mechanism at the same function: the `_legacyRatio` rebase floors with no zero-guard, so ~19
successive 1-for-10 reverse splits drive the oldest ratio to 0, bricking `convertLegacy` (the holder's
last exit) and defeating the `_legacyRatio[newToken] != 0` address-reuse guard.

**Suggested fix.**
```diff
+ address[] memory ws = _psmWrappers[ticker];
+ for (uint256 i; i < ws.length; ++i) {
+     PsmConfig storage c = _psmConfigs[ticker][ws[i]];
+     if (c.lastUsedRatio != 0) c.lastUsedRatio = Math.mulDiv(c.lastUsedRatio, ratio, PRECISION);
+ }
```
Add a zero-guard on the `_legacyRatio` rebase separately.

**Overlaps.** Same function and same class as **M-12** (`migrateToken` desynced a halted asset's
frozen price) and **L-07** (atomic `applySplit`) — a third value that a split invalidates.
**Detected by** 4 of 12 agents (execution-trace = finding; math-precision, invariant, numerical-gap =
leads).

### A3-M-05 (Medium) — Paused vaults keep paying redeemers while their LPs are frozen

**Problem.** Every LP-facing entry point reads `_vaultStatus`, but `releaseCollateral` and
`releaseCollateralForBadDebt` never do, and `OwnMarket.forceExecuteOrder` filters only on
`isVaultExcluded` — set by `haltVault`, never by `pause`. A vault in `Paused` is not excluded, is
registered, and passes every force-execute check, so collateral keeps leaving while every queued LP's
`fulfillWithdrawal` reverts `VaultIsPaused`. The loss the pause exists to contain lands entirely on
the LPs the pause froze.

**Suggested fix.**
```diff
+ if (_vaultStatus == VaultStatus.Paused) revert VaultIsPaused();
```
Decide explicitly whether `releaseCollateralForBadDebt` should stay exempt, and document the exemption
if so.

**Overlaps.** Complements **H-01** (which excluded *halted* vaults from force-execution) — the
`Paused` state was never given the same treatment. Note **M-13**'s acceptance depends on proactive
pause being effective; this finding weakens that mitigation and should be reviewed alongside it.
**Detected by** 2 of 12 agents (asymmetry = finding, economic-security = lead).

### A3-M-06 (Medium) — Deactivating an asset traps holders with no redemption route

**Problem.** `fillOrder` (`:169`) and `psmFillOrder` (`:364`) apply `_validateAsset` only on the Mint
branch; `placeOrder` (`:114`) and `executeOrder` (`:84`) apply it unconditionally. After
`setAssetActive(ticker, false)` a holder with no pre-existing resting order cannot create one, and
every exempted redeem path requires an order id that can no longer be minted. `redeemHalted` reverts
`AssetNotHalted` (deactivated ≠ halted), and `psmRedeem` works only for tickers with a configured,
unpaused wrapper and a funded reserve. `setAssetActive` is `onlyOperator` with no timelock, so one key
freezes redemption for every holder of that ticker.

**Suggested fix.**
```diff
- _validateAsset(asset);
+ if (orderType == OrderType.Mint) _validateAsset(asset);
```

**Overlaps.** **Direct sequel to L-17**, which fixed `fillOrder` to gate Mint-only precisely so
"existing positions wind down" — the same reasoning was never applied to the order-*entry* functions,
leaving the wind-down path reachable only for holders who already had a resting order.
**Detected by** 1 of 12 agents (asymmetry).

### A3-M-07 (Medium) — Dividends are front-runnable through a fee-free PSM round-trip

**Problem.** `EToken.depositRewards` raises `_rewardsPerShare` by `amount·PRECISION/supply` with no
ex-dividend snapshot and no holding period, and `_settleRewards` on mint stamps the new holder at the
pre-drop accumulator, so freshly minted units earn the full drop. `psmMint`/`psmRedeem` reverse at the
identical `lastUsedRatio` in the same block with no fee (`psmFillSpreadShareBps` applies only to
`psmFillOrder`) and both legs floor, so the round trip costs ≤1 wrapper unit. A market maker holding
900,000 wrapper units against a 100,000 eToken float takes 90% of a $50,000 distribution and redeems
out; honest holders who held all quarter receive $5,000.

**Suggested fix.** Pay against a balance snapshot taken strictly before `depositRewards` executes, or
make freshly minted units ineligible until the next distribution.

**Residual / open question.** Reachability is unconfirmed: `depositRewards` appears only in
`test/unit/EToken.t.sol` and in no deploy or ops script. **Confirm whether the dividend channel is
live before rating** — this is Medium only because it may be dormant; it is High if live.
**Overlaps.** Same JIT family as **A3-M-01**. The **M-09**-pattern `RewardTooSmall` guard (from the
round-1 leads) addresses truncation, not snapshot timing.
**Detected by** 2 of 12 agents (economic-security = finding, first-principles = lead).

### A3-M-08 (Medium) — Saturated `totalAssets()` mints a near-unbounded share count

**Problem.** `totalAssets()` returns `raw > _pendingDepositAssets ? raw - _pendingDepositAssets : 0` —
a saturating subtraction whose own comment names the trigger ("an external Aave liquidation can pull
the aToken balance below pending deposits"). The consequence of returning `0` was not followed
through: OZ's `previewDeposit` computes `assets · (totalSupply + 10**6) / (totalAssets + 1)`, so with
shares outstanding and `totalAssets()` at 0 the denominator becomes the virtual `+1`. A 500,000-unit
`acceptDeposit` against a 1e18 share supply mints ~5e29 shares, leaving prior LPs with ~2e-12 of the
vault. The `_decimalsOffset() = 6` defence protects the *empty*-vault case, not the
zero-assets-with-live-supply case.

A second mechanism at the same function: `acceptDeposit` is the only share-minting path that never
reads `_vaultStatus`, so it mints into a `Paused` vault whose `requestWithdrawal` reverts — while
`maxDeposit`/`maxMint` already report 0 for a non-Active vault.

A third, structural: un-accepted deposit escrow sits in the same aToken balance the venue uses as
collateral for the vault's debt, so a liquidation consumes depositors' escrow even though
`totalAssets()` excludes it from share math.

**Suggested fix.**
```diff
+ if (totalAssets() == 0 && totalSupply() > 0) revert VaultInsolvent();
+ if (_vaultStatus != VaultStatus.Active) revert DepositsNotAllowed();
  uint256 shares = previewDeposit(req.assets);
```

**Residual.** Impact is Critical but reachability is venue-dependent: inert against `OwnLendingPool`
(no external liquidation path can reduce the raw balance), live against canonical Aave V3. Worth
fixing while inert, since the precondition is a deployment choice someone could make without recalling
this constraint.
**Overlaps.** Root cause shared with **A3-H-03**. **H-06** previously fixed a `totalAssets` *underflow*
by introducing this saturation; this finding is the saturation's own downstream consequence.
**Detected by** 2 of 12 agents (flow-gap = finding, math-precision = lead).

### A3-M-09 (Medium) — Reserve surplus release omits the PSM ratio-jump guard

**Problem.** `ReserveVault._releaseCollateral`'s surplus clamp
(`assetRwaCollateralUSD(backed) >= assetExposureUSD(backed)`) rearranges to
`x <= bal − units/ratio`, where `ratio = wrapperPrice·PRECISION/mark` is byte-for-byte the quantity
`OwnMarket._psmContext` bounds with `ratioJumpBoundBps`. `_releaseCollateral` never reads that bound
and never touches `lastUsedRatio` (`notePsmRatio` is `onlyMarket`). A reserve holding 1,000 wrapper
units backing 1,000 eTokens has zero skimmable surplus at a true ratio of 1.0; a wrapper feed printing
10% high makes 90.9 units skimmable — $36,364 of real backing — leaving 1,000 eTokens against 909
units. The identical ratio move reverts `RatioJumpExceeded` on every `OwnMarket` PSM path.

**Suggested fix.** Derive the same ratio in `_releaseCollateral` and apply
`IAssetRegistry.ratioJumpBoundBps()` against the wrapper's `lastUsedRatio`, failing closed when the
bound is unset — mirroring `_psmContext`.

**Residual.** Trigger is an allowlisted maker (`withdraw`) or the manager/operator (`skimExcess`), so
this is a guard-parity gap on a semi-trusted path rather than an open drain.
**Detected by** 2 of 12 agents (trust-gap = finding, economic-security = lead).

---

## 3. By-Design / Withdrawn

- **CL-L01 — Reverting aggregator bricks both legs (acknowledged, won't fix, 2026-07-19).**
  `_chainlink()` lets `latestRoundData()` reverts bubble up. A *stale* feed correctly fails over to
  the in-house leg, but a *reverting* one (unset/bricked proxy) DoSes `getPrice` and blocks
  `updatePrice`. Availability-only; funds safe; recoverable via `setChainlinkConfig` / `disableAsset`.
  A `try/catch` fallback was considered and declined — with no anchor the in-house leg is unusable by
  design anyway. **Note:** the related `ZeroMultiplier` hard-revert in the `multiplierToken` branch is
  a *different* path and remains an open lead (§5) — it is not covered by this acceptance.
- **CL-L02 — Cached `clDecimals` can rot on an aggregator upgrade (acknowledged, 2026-07-19).**
  `setChainlinkConfig` caches `decimals()` once; an aggregator upgrade behind the proxy that changes
  decimals would silently mis-scale by 10^n. Very low probability (all current Robinhood feeds are
  8-dec); severe if it occurs. Ops mitigation in §6.
- **CL-L03 — A dead feed reads as current for up to `clFreshWindow` (acknowledged, 2026-07-19).**
  The timestamp clamp assumes "no update ⇒ price within the 0.5% deviation band," which fails if feed
  infrastructure dies silently. `clFreshWindow` was reduced 24.5h → 12h → **4h** precisely to shrink
  this window. A 15-min-quiet feed is indistinguishable on-chain from a dead one, so this is inherent
  to the freshness semantics. Ops mitigation in §6.
- **CL-I01 — Compromised-signer damage cap is `bandBps` during any quiet stretch (by design).** The
  silence gate opens routinely mid-session, so a compromised signer can move the served price up to
  `bandBps` off the anchor whenever the feed is quieter than `clSilence` — not only on weekends.
  Explicit decision: the band, not a market-hours calendar, is the security boundary. Second belt:
  BorrowManager/OwnMarket band checks vs VM marks; instant `removeSigner`.
- **CL-I02 — Timestamp-ignoring consumers accept prices up to `maxAnchorAge` old (by design).**
  `VaultManager._resolvePrice` discards the returned timestamp. Intended: weekend marks track Friday's
  close, optionally refined by band-limited in-house quotes. **Scope note:** what this acceptance
  covers is *mark pulls*. It does not address `OwnMarket.forceExecuteOrder`'s collateral leg, whose own
  comment asserts the price "must be current" — tracked as a lead in §5.
- **CL-I03 — `verifyPriceForSession` self-call drops `msg.value` (by design).** `this.verifyPrice(...)`
  forwards no ETH; harmless because `verifyFee` is always 0 for this verifier.
- **CL-I04 — Multicall + payable `verifyPrice` (verified non-issue).** OZ Multicall's known
  `msg.value`-reuse hazard does not apply: no function in the contract reads `msg.value`.
- **Withdrawn — `PythOracleVerifier` strands surplus `msg.value` (2026-07-31).** The contract forwards
  only `pyth.getUpdateFee(...)` and has no `receive`, withdraw, sweep or rescue, so keeper over-sends
  were permanently stranded. Withdrawn on scope change: `PythOracleVerifier` moved to `archive/`.
  Consistent with the earlier disposition of the same issue, which noted only a third party calling
  `verifyPrice` directly with excess ETH can strand it — their own overpayment.
- **Withdrawn — `OracleVerifier.verifyPrice` signed-price replay cherry-picking (2026-07-31).** Bare
  ECDSA with no staleness, deviation, or newest-wins check, allowing a force-executor to replay the
  most favourable already-signed price within `priceMaxAge`. Withdrawn on scope change: `OracleVerifier`
  moved to `archive/`.
- **Downgraded — A3-L-03 and A3-L-04, Medium → Low (2026-07-31).** Both rated on the deployed in-house
  oracle being pure ECDSA, the basis for calling a leaked signer key an unbounded loss. With
  `OracleVerifier` retired, `ChainlinkOracleVerifier._verifyInhouseProof` anchors every proof to the
  live feed within `bandBps` and reverts when the feed is dead rather than accepting an unanchored
  price (`test_updatePrice_clDead_revertsNoAnchor`), capping damage at the anchor band. **Containment
  holds only for assets with a Chainlink feed configured**, and it makes `ChainlinkOracleVerifier` a
  single point of failure for the whole price surface — see the §5 leads against it.
- **Already accepted — collateral-aggregate freshness (PA-03).** Several agents flagged that
  `VaultManager.openExposure` gates the asset mark on `maxMarkAge` but not the `_globalCollateralUSD`
  denominator, and that `BorrowManager.maxDebtUSD` reads `collateralMark` with no age bound. **PA-03**
  already records this as intentionally not gated (O(1) cost + DoS avoidance). Not reopened; noted here
  so future passes stop re-surfacing it. Adding a `_collateralMarkUpdatedAt` companion would be a
  prerequisite for ever revisiting it.

---

## 4. Low Findings

### Open (2026-07-31)

- **A3-L-01 — Zero debt cap reported as zero utilisation.** `BorrowManager.utilizationBps`'s
  `if (cap == 0) return 0` assumes `cap == 0 ⟹ debt == 0`, but `onVaultHalted` zeroes
  `_collateralMark` while `_totalScaledDebt` is untouched. Halting a fully-drawn vault cuts the premium
  from 6125 bps to the 100 bps floor at the exact moment LPs are exiting unconditionally, and hands
  borrowers an incentive not to repay during a halt. Also reachable at genesis (before the first
  `pullCollateralPrice`), whenever `onCollateralReleased` drives the mark to 0, and permissionlessly by
  chaining **A3-M-02**. Loss is forgone premium only — `_flooredIndex` still pins book debt ≥ pool
  debt, so LPs carry no shortfall risk. Fix: `if (cap == 0) return _totalScaledDebt == 0 ? 0 : BPS;`
  Detected by 2 of 12 agents.
- **A3-L-02 — Revenue claim and LP exit share one threshold.** `BorrowManager.claimEarnedInterest`
  gates on `hf >= minClaimHealthFactor` and `requireVaultHealthy()` reads the identical storage
  variable, so a junior claim — crankable by anyone via the unauthenticated
  `VaultYieldManager.claimEarnedInterest` — can consume 100% of the margin senior claims (LP principal
  exit, force-redemption) depend on, converging precisely on the floor since the HF is re-read *after*
  the draw. Self-limiting: convergence is geometric and `distribute()` returns most of the drawn amount
  as collateral. Fix: gate the claim on `minClaimHealthFactor + buffer`. Detected by 2 of 12 agents.
  **Raised priority:** since **A3-M-01** the claim fires on every LP entry and exit rather than on an
  occasional crank, and instant withdrawal removes the queue that previously absorbed a temporarily
  blocked exit. Accepted open for now.
- **A3-L-03 — Force-execution is the only settle path with no price band.** `forceExecuteOrder` applies
  neither `_checkSettleBand` nor `_checkPriceBand`, though both exist expressly to cap leaked-signer
  damage; `placeOrder` bounds `limitPrice` only as non-zero. Under an honest oracle the
  `currentPrice >= limitPrice` gate keeps the payout at or below market, so this is
  damage-amplification, not a live drain — and it is now anchor-band contained (§3). Third mechanism at
  this function: it is the only fill path with no `order.expiry` check (benign today, since the price
  gate means an expired order can only execute at or below market, but it diverges from the documented
  good-til-date lifecycle). Overlaps **H-01**, **H-06**, **PA-04** and **A2-H-01**, whose
  caller-chosen-vault and stale-proof halves are already fixed. Detected by 3 of 12 agents.
- **A3-L-04 — Bad-debt collateral conversion uses an unbanded signed price.**
  `BorrowManager._convertToCollateral` verifies the collateral price for staleness only and uses it
  directly as a divisor, skipping the `_checkPriceBand` that guards `_executeBorrow` and `liquidate`;
  `absorbBadDebt`'s `absorbAmount` is operator-chosen, so the release is an operator input times an
  unbanded price, bounded only by `totalAssets()`. The band may be *structurally* unavailable here —
  `_checkPriceBand` reads `vmgr.assetMark(collatAsset)` and a collateral-only ticker may legitimately
  carry no mark — so a clamp against the cached collateral mark is the practical form. Destination is
  the fixed registry treasury, which bounds where value can land. Related to **L-16** (accepted
  over-socialization via the same function's `absorbAmount`). Detected by 2 of 12 agents.
- **A3-L-05 — ETH refund helpers pay out the whole contract balance.**
  `BorrowManager._refundExcessEth` and `OwnMarket._refundETH` forward `address(this).balance` on the
  stated premise that "the contract has no `receive`, so its balance can only be the current call's
  surplus" — false, since SELFDESTRUCT and coinbase payments bypass `receive`. Force-fed ETH is swept
  by whichever unrelated caller next hits a payable entry point. Second mechanism: the helper reverts
  the whole call on a failed send, so 1 wei force-sent bricks `liquidate` for any contract caller
  lacking a payable `receive`, including flash-loan liquidator bots. Fix: snapshot
  `address(this).balance - msg.value` at entry and refund only the delta; do not revert on a failed
  send. At minimum correct the comment, so a future refactor does not build on a false invariant.
  Detected by 3 of 12 agents.

---

## 5. Leads

Concrete code smells with incomplete exploit paths. Not scored.

### Open for review — oracle surface

Now more load-bearing, since retiring `OracleVerifier` makes `ChainlinkOracleVerifier` the sole price
authority (§3).

- **`_verifyInhouseProof` omits the `inhouseMaxStaleness` bound its `updatePrice` twin enforces.**
  `updatePrice` reverts `StalePrice` past `cfg.inhouseMaxStaleness`; the inline-proof twin validates
  zero-price, future-timestamp, signer, `bandBps != 0` and the anchor band, but never age. Consumers
  re-check only against the *global* `registry.priceMaxAge()`, so the per-asset knob an admin would
  tune for a thinly-quoted ticker is inert on exactly the paths that move money. **Five of 12 agents**
  converged on this — the highest convergence in the pass. Value is anchor-band bounded, which is why
  it is a lead.
- **`verifyPrice` returns `block.timestamp`, not `clUpdated`.** Both the primary
  (`clAge <= clSilence`) and empty-proof (`clAge <= clFreshWindow`) branches substitute a synthetic
  timestamp, so `BorrowManager._verifyPrice` and `OwnMarket._isStale` can never fail for a
  Chainlink-backed asset and the effective bound silently becomes `clFreshWindow` (4h) regardless of
  `priceMaxAge` (2 min). **CL-I02** accepts this for mark pulls; it does *not* cover
  `forceExecuteOrder`'s collateral leg, whose comment asserts the price "must be current". A redeemer
  could force-execute against a collateral price up to 4h old.
- **`_chainlink`'s `multiplierToken` branch hard-reverts where its siblings fail soft.** The two
  preceding branches return `(0, updated, false)` per the function's documented contract; this one
  reverts `ZeroMultiplier` and makes an unguarded external call to a third-party ERC-8056 token.
  Because `_checkAnchorBand` calls the same helper, a zero or reverting `uiMultiplier()` kills
  `getPrice`, `verifyPrice`, `updatePrice` **and** the in-house fallback simultaneously — no price path
  survives, and `disableAsset` disables the same paths. Distinct from **CL-L01** (reverting
  *aggregator*), which is accepted. `setChainlinkConfig` validates `uiMultiplier() != 0` once, at
  config time.
- **`uiMultiplier` scale is assumed 1e18 with no assertion.** `price · PRECISION / mult` hardcodes the
  numerator while `setChainlinkConfig` validates only non-zero. A 1e27-scaled multiplier divides every
  price by 1e9, and because every downstream band check compares values derived from the same feed, the
  mis-scaling is self-consistent and silent. Needs confirmation of the Gen-2 Robinhood token scale.

### Open for review — other

- **`LendingRouter.registerReserve` never cross-checks the `(underlying, aToken)` pair** against
  `pool.getReserveData(underlying).aTokenAddress`, unlike `OwnVault.enableAaveCollateral` which does
  exactly that. A mismatch makes the balance-diff `aTokenReceived == 0`, `vault.deposit(0)` mint zero
  shares, and the default `minSharesOut == 0` let the call **succeed** — silently converting every user
  deposit into an unrecoverable loss, in a router with no rescue function. Highest-severity lead here.
- **`AssetRegistry.addAsset` never binds an EToken to its ticker.** `EToken` carries an immutable
  `ticker` the registry never reads, and `migrateToken` does not reject a token that is the *active*
  token of a different ticker. Binding one EToken to two tickers lets `psmMint(B)` mint units that
  `psmRedeem(A)` burns against A's reserve. The one-line invariant is already available on-chain.
- **Two halt-state desyncs between `OwnVault` and `VaultManager`,** both collateral-inflating.
  `deregisterVault` clears `_excluded` without touching `OwnVault._vaultStatus`; and `_excluded` can
  only be set by `onVaultHalted`, which requires `Active`, so a vault registered while already halted
  is permanently non-excluded. In both cases `fulfillWithdrawal`'s halted branch skips
  `onCollateralReleased`, so LPs drain while `_globalCollateralUSD` still counts the departed
  collateral. `onVaultUnhalted` early-returns on `!_excluded` and repairs neither.
- **`OwnVault.haltVault` is `onlyAdmin` but requires `Active`,** while `pause`/`unpause` are
  `onlyManagerOrOperator` — so the weaker instant role can park the vault in `Paused` where the
  stronger role's emergency lever reverts `InvalidStatusTransition`. Recoverable via a batched
  `setManager(self)` → `unpause()` → `haltVault()`. Separately, `haltVault` unconditionally calls the
  `onlyRegisteredVault` hook `onVaultHalted`, so an unregistered or deregistered vault cannot be halted
  at all and its LP withdrawals revert.
- **`OwnMarket._convertToCollateral`** — the permissionless twin of **A3-L-04**, payout to `msg.sender`.
- **`VaultYieldManager` uninstall strands in-flight revenue.** `rescueToken` hard-blocks the stablecoin
  on the premise that "revenue exits only through `distribute()`", but `distribute` calls the
  `onlyManager` `shareYield` — so `setManager` away (documented as a reversible operation) leaves
  `pendingYield()` with no exit. `setSupplierAllowed(false)` bricks it by a second route.
- **`Position.interestIndex` is write-only state** — five writers, zero readers, and `addCollateral`
  and `absorbBadDebt` leave it unsynced. Harmless today, but it is part of the public `positionOf` ABI
  on a now-upgradeable contract, so a future implementation that starts reading it inherits values that
  were never a reliable snapshot.
- **`_settleRedeem` lacks the zero-payout guard `_psmFillRedeem` has.** A maker quote with
  `amount·price < 1e30` (USDC) burns the user's escrowed eTokens while `safeTransferFrom(maker, user, 0)`
  succeeds. Capped at ~1e-6 USD per fill; recorded for the asymmetry.

### Noted, no action

- **`OwnMarket._pushOrSweep` raw `.call`** skips the extcodesize guard, and a 1–31 byte return makes
  `abi.decode` revert *before* the treasury-sweep fallback. Unreachable today: `escrowToken` is
  snapshotted from registry-controlled contracts with standard returns.
- **`OwnLendingPool` supplier allowlist constrains nothing about who borrows** — `LendingRouter.deposit`
  is permissionless and `borrow` is open to any aToken holder. Verified not to break solvency
  (`balance' = aTokenSupply − totalDebt` stays positive); a policy gap, not a drain.
- **`WstETHRouter.depositStETHWithPermit`** calls `permit` unconditionally with no try/catch — standard
  front-running griefing, no fund loss, user can retry via `depositStETH`.
- **`BorrowManager.initialize` caches `_stableDecimals` with no upper bound,** unlike every sibling. The
  `>18` branch of `LendingMath.stableToUSD` truncates a non-zero debt to zero, panicking `healthFactor`
  — but no realistic `>18`-decimal stablecoin is in scope.
- **`_liquidate` close factor floors to zero** for `currentDebt < 2` at the 5000 bps default, leaving a
  1-unit position unliquidatable and un-absorbable. Self-heals once `hf ≤ 0.95` lifts the cap; stranded
  value ≤1e-6 USDC.
- **`AssetRegistry.migrateToken` legacy-ratio decay** — ~19 successive 1-for-10 reverse splits floor a
  ratio to zero. Folded into **A3-M-04** as a second mechanism; not credible standalone.

---

## 6. Migration / ops checklist (open)

- [ ] Verify on-chain `registry.priceMaxAge` and `VaultManager.maxMarkAge` on Robinhood are consistent
      with `clFreshWindow = 4h` and the intended in-house cadence.
- [ ] Signer service: 24/7 operation, band pre-check before signing, feed-age alerting (<4h),
      aggregator-upgrade monitoring on all feed proxies (**CL-L02**).
- [ ] `BorrowManager.setInterestBufferBps(100)` on any **already-deployed** manager — 1%, down from
      10% (**A3-M-01** decision). Redeployed managers pick it up from the constructor default.
- [ ] `OwnVault.setWithdrawalWaitPeriod(0)` — instant withdrawal (**A3-M-01** decision); confirm the
      M-13 pause trigger is automated and fast enough to act without the queue behind it.
- [ ] Confirm deployed `targetLtvBps` against the pool's `liquidationThresholdBps` (**A3-M-03**).
- [ ] Confirm whether any vault carries a non-zero concentration cap (**A3-M-02**).
- [ ] Confirm whether the `EToken.depositRewards` dividend channel is live (**A3-M-07**).
- [ ] Increase `distribute()` crank frequency as the interim **A3-M-01** mitigation.
- [ ] Remove the dead `PYTH_ORACLE` constant and `pythOracle()` getter from `ProtocolRegistry`
      (`src/core/ProtocolRegistry.sol:70`) now that `PythOracleVerifier` has left `src/`.

---

## 7. Verified sound (no finding)

Attacked directly across multiple agents and held:

- `_totalScaledDebt = Σ p.principal` across all eight mutation sites; eToken custody conservation in
  the borrow manager; `debtClearingPermission` cannot outlive its position into a new one.
- The RWA netting identity `_globalNetExposureUSD = Σ_a max(0, E_a − R_a)`, and PSM
  exposure-neutrality at *any* mark (so a stale mark cannot skew netting).
- `_projectedIndex` vs `_accrue` equivalence; `absorbBadDebt`'s health impact (proved strictly
  improving whenever `C > D`); the `interestBufferBps` guarantee that iterative `claimEarnedInterest`
  can never activate the `_flooredIndex` over-charge (`gap' = gap · buffer/BPS > 0`).
- `OwnLendingPool`'s exit-liquidity claim: `balance' ≥ aTokenSupply·(1 − ltv/BPS) ≥ 0`, holding even at
  the loosest LT `_validateLtvConfig` permits — the missing liquidity check is genuinely redundant.
- PSM mint/redeem round-trip rounding: floors protocol-favorable on all four pairings; `_psmFillMint`
  double-ceils the wrapper the filler delivers.
- `EToken`'s reward accumulator against supply collapse, tiny-supply inflation, mint-after-deposit
  dilution, and claim-vs-`claimableRewards` divergence in both `sweepDividends` implementations.
- `OwnAToken._update` health hook across every mint/burn/transfer branch; `OwnershipNFT` soulbound
  gates across `_update`/`_approve`/`_setApprovalForAll`.
- Reentrancy on the ETH-refund callbacks: the arbitrary-code call to `msg.sender` is the last statement
  after all state writes in every payable entry point.
- **Dropped on verification:** a claimed UUPS slot-0 collision from a non-upgradeable `ReentrancyGuard`
  in `BorrowManager`, raised by two agents and disproved by a third reading the vendored library — this
  repo's OpenZeppelin `ReentrancyGuard` uses ERC-7201 namespaced storage, so no collision exists.

Carried forward from the Chainlink review (2026-07-19):

- Reentrancy: all external calls in `ChainlinkOracleVerifier` are staticcalls.
- Signature replay: EIP-712 domain binds chainId + verifying contract; the monotonic-timestamp guard
  prevents overwrite replays; the per-asset digest prevents cross-asset replay.
- Circuit-breaker pinning: the live TSLA aggregator has `minAnswer = 1`, `maxAnswer = int192.max`, so
  LUNA-style pinned-price scenarios are not possible on these feeds (checked on-chain 2026-07-19).
- No spot/AMM prices anywhere; flash-loan surface absent.
- Fixed during the Chainlink review: unused `NonPositiveAnswer` error removed (dead code); test gaps
  closed across multiplier×band interaction, non-8-dec normalization, `verifyPriceForSession` proof
  leg, multicall batch push, equal-timestamp replay skip, garbage-proof revert, fuzz, integration and
  live-fork tests against RHTSLA / USDG on chain 4663.

---

## 8. Verification notes

**Deleted deploy scripts are a blind spot.** **A3-M-01** was initially rated High because deployed
configuration was inferred from `script/`, and the script setting the withdrawal delay had been
executed and then deleted. `broadcast/<Script>.s.sol/<chainId>/run-latest.json` records what actually
ran — decoded function name, arguments, target and receipt status — and is the authoritative in-repo
source for deployed configuration. **Any finding whose severity depends on "no script sets X" must be
checked against `broadcast/` before rating**, and confirmed on-chain before relying on it, since
`broadcast/` records what was executed, not what is currently set.

**Not re-reported.** `VaultManager._resolvePrice` discarding the oracle timestamp was independently
rediscovered but is already tracked as **CL-I02**; only its uncovered effect on `forceExecuteOrder`'s
collateral leg is carried as a new lead (§5).
