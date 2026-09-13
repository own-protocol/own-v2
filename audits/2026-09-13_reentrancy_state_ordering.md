# Own Protocol V2 — Reentrancy & State-Consistency Audit

- **Date:** 2026-09-13
- **Auditor:** llen
- **Scope:** `EUSDManager`, `BorrowManager`, `EToken`, `VaultYieldManager`, `OwnVault` — reentrancy / CEI / state-ordering surface only (Slither-filtered)
- **Method:** Slither static analysis → manual code review → Foundry PoC validation (`test/unit/ReentrancyPoC.t.sol`)
- **Result:** 0 HIGH/CRITICAL exploitable · 2 MEDIUM (guard parity) · 1 LOW (state ordering) · 1 INFO

---

## Executive Summary

Slither flagged 90 issues across the repo. After manual filtering, the attackable
surface is narrow. **No exploitable reentrancy was confirmed.** Two medium-severity
guard-absence violations (`VaultYieldManager.syncYield()`, `EToken.claimRewards()`)
and one low-severity transient state-inconsistency (`EUSDManager._accrue()`)
remain as defense-in-depth gaps. `BorrowManager` is fully protected.

| ID | Severity | Location | Issue |
|----|----------|----------|-------|
| M-01 | MEDIUM | `src/periphery/VaultYieldManager.sol` | `syncYield()` external override lacks `nonReentrant` |
| M-02 | MEDIUM | `src/tokens/EToken.sol` | `claimRewards()` lacks `nonReentrant` (mitigated by CEI zeroing) |
| L-01 | LOW | `src/core/EUSDManager.sol:460-473` | `_accrue()`: `feeIndexSnapshot` updated *after* treasury mint |
| I-01 | INFO | `src/core/BorrowManager.sol` | All state-changing functions guarded — no action |

---

## M-01 — `VaultYieldManager.syncYield()` missing `nonReentrant`

**Root cause.** `syncYield()` is an `external override` that performs external
calls to lending markets via `_claimBestEffort()`. The parent implementation's
reentrancy expectations no longer hold for the override, and no `nonReentrant`
modifier is applied.

**Impact.** The code comment asserts idempotency (rewards accrue into internal
accounting first), which limits — but does not eliminate — impact if a yield
source has transfer callbacks (ERC777 / fee-on-transfer hooks during claim).
Current state is likely safe by argument; the gap is the *absence* of the guard
that every other state-changing function in the protocol carries.

**Recommendation.** Add `nonReentrant` to `syncYield()`.

---

## M-02 — `EToken.claimRewards()` missing `nonReentrant`

**Root cause.** `claimRewards()` transfers accrued rewards without a reentrancy
guard.

**Mitigation present (why MEDIUM, not HIGH).** `_accruedRewards[msg.sender]`
is zeroed **before** `IERC20(rewardToken).safeTransfer(...)` — correct
checks-effects-interactions order, so re-draining the same balance is prevented.

**Residual risk.** If the reward token implements transfer callbacks (ERC777,
ERC1363), a malicious receiver can re-enter `claimRewards()` mid-accrual-update.
Reward tokens are admin-set, so this requires a compromised/misconfigured
reward token — not directly attacker-controlled today.

**Recommendation.** Add `nonReentrant` to `claimRewards()`.

---

## L-01 — `EUSDManager._accrue()` state ordering

**Root cause.** In `_accrue()` (lines 460-473):

```solidity
p.debt += fee;                    // effect 1
totalDebt += fee;                 // effect 2
_eusd.mint(treasury, fee);        // external interaction
p.feeIndexSnapshot = _feeIndex;   // effect 3 — LAST
```

**Why this is NOT exploitable reentrancy.** `EUSD.mint()` is OpenZeppelin
`ERC20._mint()` — no token callback. Slither's reentrancy-eth detector fires on
the mint call, but no attacker-controlled path can execute inside the window.

**Real issue.** Transient inconsistency: any reader traversing `_accrue()`
mid-transaction (internal collateral/liquidation checks in the same tx path)
observes debt updated against a **stale** `feeIndexSnapshot`. PoC
`test_EUSDManager_accrue_stateOrdering()` documents the ordering; it is a
consistency hazard, not a drain vector.

**Recommendation.** Move `p.feeIndexSnapshot = _feeIndex;` to immediately after
`_feeIndex` computation, before the mint call.

---

## I-01 — `BorrowManager` fully guarded (no action)

`borrow()`, `borrowMore()`, `repay()`, `clearDebt()`, `liquidate()` all carry
`nonReentrant`. `_repayAaveAndSweep()` and `acceptDeposit()` external calls run
inside guarded contexts. Verified by code inspection; 1410 pre-existing tests
pass.

---

## Deliberately not tested

- **Full mainnet-fork exploitation** — no exploitable path found at code level;
  forking Base mainnet adds no information for CEI/guard findings.
- **ERC777 reward-token simulation for M-02** — reward tokens are admin-set
  whitelisted ERC20s today; the finding is guard-parity, not a live vector.

---

## PoC validation

```text
$ forge test --match-path test/unit/ReentrancyPoC.t.sol
Suite result: ok. 7 passed; 0 failed; 0 skipped

$ forge test
Suite result: ok. 1417 passed; 0 failed; 0 skipped
```

Files: `test/unit/ReentrancyPoC.t.sol` (7 tests), `slither-output.txt` (raw audit trail).

## Remediation priority

1. `nonReentrant` → `VaultYieldManager.syncYield()`
2. `nonReentrant` → `EToken.claimRewards()`
3. Reorder `_accrue()`: snapshot before mint
