# 🔐 Security Review — Own Protocol v2 (`lending` branch)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL (`src/` production contracts)                      |
| **Files reviewed**               | `OwnMarket.sol` · `OwnVault.sol` · `BorrowManager.sol`<br>`VaultManager.sol` · `AssetRegistry.sol` · `ProtocolRegistry.sol`<br>`OracleVerifier.sol` · `PythOracleVerifier.sol` · `InterestRateModel.sol`<br>`LendingMath.sol` · `AaveRouter.sol` · `WETHRouter.sol`<br>`WstETHRouter.sol` · `EToken.sol` · `ETokenFactory.sol` |
| **Method**                       | 12-lens pashov attack pipeline + 3 plamen depth agents + ToB entry-point/token-integration pass (16 agents), deduped, gate-validated, source-verified |
| **Confidence threshold (1-100)** | 75                                                     |

Prior audit `docs/audit-2026-06-09.md` (C-01, H-01..H-04, M-05) and its remediation log `docs/audit-fixes-2026-06-10.md` were treated as out of scope **except** to verify the fixes. Verified correct: the M-05 Aave-debt floor (`85192ed`), the H-04 decimal fix (`207415c`), the EToken dividend rewrite (`f24eee9`), and the `BorrowManager._verifyPrice` staleness bound. **F-1 below is an incomplete C-01 remediation** — the asset-side of `forceExecuteOrder` was not covered.

---

## Findings

[90] **1. `forceExecuteOrder` never bounds the asset price proof freshness (incomplete C-01 fix), and prices the payout at `limitPrice` while skipping the utilization gate — LP collateral over-extraction**

`OwnMarket.forceExecuteOrder` · Confidence: 90

**Description**
The C-01 remediation added a `priceMaxAge` staleness bound to the **collateral** price (`_convertToCollateral`, OwnMarket.sol:463) and to `BorrowManager._verifyPrice` (BorrowManager.sol:799-801), but the **asset** price proof in `forceExecuteOrder` is still gated only by `assetTs ∈ [order.createdAt, block.timestamp]` (OwnMarket.sol:29) with no recency bound, and `OracleVerifier.verifyPrice` (OracleVerifier.sol:122-135) performs no staleness/replay check — so a redeem-order owner can replay any signed price that ever touched `limitPrice` during the order's life, long after the asset has crashed; compounding this, the payout is `grossUsd = remaining × order.limitPrice` (line 32) valued at the historical limit while exposure is retired at the current mark, and `releaseCollateral` runs no `withdrawalBreachesUtil` check, so the redeemer drains more vault collateral than the risk retired and can push the pool past `globalMaxUtilizationBps`.

**Proof:** Order for 100 eTSLA at `limitPrice=$300` placed at a transient spike; asset later trades $100. After `claimThreshold`, owner force-executes with the old signed $300 proof (passes `assetTs ≥ createdAt`, `reachedPrice ≥ limitPrice`). Vault releases `$30,000` of collateral while `closeExposure` retires only `100 × $100 = $10,000` — `$20,000` LP loss, no stablecoin inflow. Flagged independently by 6 agents.

**Fix**

```diff
  (uint256 reachedPrice, uint256 assetTs) = _verifyAssetPrice(order.asset, assetPriceData);
  if (assetTs < order.createdAt || assetTs > block.timestamp) revert AssetPriceProofOutsideWindow();
+ if (block.timestamp - assetTs > registry.priceMaxAge()) revert StaleAssetPrice();
  if (reachedPrice < order.limitPrice) revert PriceBelowMinimum();
- uint256 grossUsd = Math.mulDiv(remaining, order.limitPrice, PRECISION);
+ // Pay out at the lesser of the limit price and the current verified price so the
+ // redeemer never extracts more collateral than the exposure being retired.
+ uint256 grossUsd = Math.mulDiv(remaining, Math.min(order.limitPrice, reachedPrice), PRECISION);
```
(and add a `withdrawalBreachesUtil`-equivalent check on the release path). A staleness bound belongs in `OracleVerifier.verifyPrice` itself so no caller can rely on an unbounded proof.
---

[88] **2. `OwnVault.fulfillWithdrawal` removes collateral without syncing the VaultManager mark — global utilization cap bypass**

`OwnVault.fulfillWithdrawal` · Confidence: 88

**Description**
`fulfillWithdrawal` transfers vault collateral out (OwnVault.sol:369) but never calls `IVaultManager.onCollateralReleased`, whereas both sibling collateral-exit paths `releaseCollateral` (line 541) and `releaseCollateralForBadDebt` (line 557) do — and document why ("Sync the cached mark before assets leave, so the withdrawal gate never reads stale-high") — so `_globalCollateralUSD`/`_collateralMark` stay overstated until a permissionless keeper `pullCollateralPrice`, letting subsequent `openExposure` (mint) and `maxDebtUSD` (borrow) reads issue exposure/debt against collateral that has already left.

**Proof:** mark=1,000,000 USD, exposure=800,000, cap 80%. Five LPs each `fulfillWithdrawal` of 100k-worth collateral; each `withdrawalBreachesUtil` reads the un-decremented 1,000,000 and passes. Real collateral ends at 500,000 vs reported 1,000,000 → true utilization 140% while VM believes 70%. `rejectDeposit`/`cancelDeposit` (lines 258/275) correctly skip the sync because they return untracked pending-deposit assets — isolating `fulfillWithdrawal` as the unique offender. Flagged independently by 2 agents.

**Fix**

```diff
  WithdrawalRequest storage req = _withdrawalRequests[requestId];
  uint256 assets = convertToAssets(req.shares);
+ if (_vaultStatus != VaultStatus.Halted) {
+     IVaultManager(registry.vaultManager()).onCollateralReleased(assets);
+ }
  // ... burn shares ...
  IERC20(asset()).safeTransfer(req.owner, assets);
```
---

[80] **3. `WstETHRouter` wraps the requested stETH amount instead of the received balance — stETH deposits revert on Lido rounding**

`WstETHRouter._depositStETHInternal` · Confidence: 80

**Description**
The router does `stETH.safeTransferFrom(msg.sender, this, stETHAmount)` (line 99) then `wstETH.wrap(stETHAmount)` (line 102) using the *requested* figure; because stETH's share→amount integer math delivers `stETHAmount − 1..2 wei`, the router holds less than `stETHAmount` and `wrap` (which pulls the full amount) reverts — breaking the primary stETH deposit path. The sibling `AaveRouter.deposit` uses the correct balance-diff pattern (`aTokenReceived = balanceAfter − balanceBefore`, AaveRouter.sol:101-107). Flagged independently by 4 agents.

**Fix**

```diff
- stETH.safeTransferFrom(msg.sender, address(this), stETHAmount);
- uint256 wstETHAmount = wstETH.wrap(stETHAmount);
+ uint256 balBefore = stETH.balanceOf(address(this));
+ stETH.safeTransferFrom(msg.sender, address(this), stETHAmount);
+ uint256 received = stETH.balanceOf(address(this)) - balBefore;
+ uint256 wstETHAmount = wstETH.wrap(received);
```
---

[80] **4. `BorrowManager.borrow` checks the protocol debt cap before accruing interest — cap bypass widened by the M-05 floor**

`BorrowManager.borrow` · Confidence: 80

**Description**
The hard-cap check `totalDebtUSD() + borrowValueUSD > maxDebtUSD()` (BorrowManager.sol:25-27) runs *before* `_accrue()` (line 31), and `totalDebtUSD()` reads the stored (pre-accrual, pre-floor) `_index`, so pending interest and the M-05 Aave-debt floor are excluded from the comparison — a borrow that should breach `targetLtvBps × collateral` can pass. The M-05 floor (which raises the index toward real Aave debt on a rate spike) widened this from "sub-block dust" to potentially the full spike delta over an idle period. Flagged independently by 6 agents; both prior-fix-verifying depth agents confirmed the widening.

**Fix**

```diff
- {
-     uint256 cap = maxDebtUSD();
-     uint256 projected = totalDebtUSD() + borrowValueUSD;
-     if (projected > cap) revert BorrowExceedsCap(projected, cap);
- }
- _accrue();
+ _accrue();
+ {
+     uint256 cap = maxDebtUSD();
+     uint256 projected = totalDebtUSD() + borrowValueUSD;
+     if (projected > cap) revert BorrowExceedsCap(projected, cap);
+ }
```
---

[80] **5. `BorrowManager.borrow` ignores the bound vault's Paused/Halted status — borrowing continues against a paused vault**

`BorrowManager.borrow` / `_validateEligibility` · Confidence: 80

**Description**
`_validateEligibility` checks only the *asset's* state (`isActiveAsset`, `_assetBorrowDisabled`, `isAssetHalted`, `isTradingPaused`) and never the *vault's* `vaultStatus()` — so when an admin calls `OwnVault.pause()` (or the vault is otherwise non-Active) to stop fund flow during an incident, the BorrowManager bound to that vault keeps drawing on its Aave credit delegation. The kill-switch has a hole on the lending path.

**Fix**

```diff
  if (vmgr.isAssetHalted(asset) || vmgr.isTradingPaused(asset)) {
      revert VaultEffectivelyHalted();
  }
+ if (IOwnVault(vault).vaultStatus() != VaultStatus.Active) revert VaultNotActive();
```
---

[78] **6. `BorrowManager` payable functions strand caller ETH — no refund of the oracle-fee surplus**

`BorrowManager.borrow` / `liquidate` / `absorbBadDebt` (via `_verifyPrice`) · Confidence: 78

**Description**
`_verifyPrice` forwards `{value: msg.value}` to `IOracleVerifier.verifyPrice` (BorrowManager.sol:797); the Pyth path consumes only `pyth.getUpdateFee(...)` and the in-house `OracleVerifier.verifyPrice` ignores `msg.value` entirely, so any `msg.value − fee` (or 100% for in-house assets) is permanently stranded — `BorrowManager` has no refund tail and `OracleVerifier`/`PythOracleVerifier` have no `receive`/sweep/withdraw. `OwnMarket._refundETH` exists precisely for this and has no equivalent here.

**Fix**

```diff
  uint256 oraclePrice = _verifyPrice(asset, priceData);
+ if (address(this).balance > 0) Address.sendValue(payable(msg.sender), address(this).balance);
```
or compute and forward only the exact `verifyFee(priceData)` like `OwnMarket` does.
---

[76] **7. Sub-unit `repayAmount` in `_liquidate` (and `stablecoinAmount` in `borrow`) records zero scaled debt while moving real value**

`BorrowManager._liquidate` / `borrow` · Confidence: 76

**Description**
`scaledRepay = actualToScaled(repayAmount, idx)` (and `scaledDebt = actualToScaled(stablecoinAmount, idx)` in `borrow`, line 44) floor to **0** once `_index > PRECISION` and the amount is small (`amount × 1e18 < idx`), with no `> 0` guard — so in `_liquidate` a liquidator can pay a dust `repayAmount` (swept to the VM / repaid to Aave), seize a non-zero `seize` of the borrower's collateral, yet reduce `p.principal` by 0 (collateral leaves the borrower while debt persists); symmetrically `borrow` can hand out stablecoin and pull collateral while recording `principal = 0` (an unrepayable no-debt position). Reachable once the index has grown or been inflated (see Finding 8).

**Fix**

```diff
+ if (scaledRepay == 0 || seize == 0) revert DustAmount();   // _liquidate
...
+ if (scaledDebt == 0) revert DustAmount();                  // borrow
```
---

[75] **8. `_flooredIndex` divides vault-wide Aave debt by this manager's scaled-debt base — index inflation on dust and corruption under the documented multi-manager design**

`BorrowManager._flooredIndex` · Confidence: 75

**Description**
`minIndex = IERC20(debtToken).balanceOf(vault).mulDiv(PRECISION, _totalScaledDebt)` (BorrowManager.sol:~903) assumes this BorrowManager is the **sole** originator of the vault's Aave variable debt. Two ways this breaks: (a) when `_totalScaledDebt` shrinks to dust (residual after floored partial repays/liquidations) while `realAaveDebt` does not, `minIndex` explodes — e.g. `realAaveDebt=50e6`, `_totalScaledDebt=1` → index jumps ~5e7×, ballooning every remaining position; (b) the protocol docs anticipate "a future Morpho or in-house manager implementing `{IBorrowManager}` … reusing the same vault" — a second delegated borrow on the same reserve makes each manager's floor read the *combined* `balanceOf(vault)`, instantly multiplying its borrowers' debt. Flagged across 6 agents.

**Fix**

```diff
- uint256 realAaveDebt = IERC20(debtToken).balanceOf(vault);
+ uint256 realAaveDebt = _originatedAaveDebt; // tracked: += on borrow, -= actualRepaid in _repayAaveAndSweep
```
or enforce and document a one-manager-per-vault invariant (reject a second `grantCreditDelegation`) and skip the floor when `_totalScaledDebt` is below a dust threshold (clear residuals via `absorbBadDebt`).
---

[72] **9. `settleHaltedPosition` / halt-settlement assume `paymentToken == stablecoin` with no on-chain check**

`BorrowManager.settleHaltedPosition` · Confidence: 72

**Description**
`redeemHalted` returns `proceeds` in the global **payment token's** decimals while `_repayAaveAndSweep` and `actualToScaled` treat it as this manager's **borrow stablecoin** — correct only if the two tokens (and decimals) are identical, an assumption the code comments acknowledge ("both USDC in the MVP") but never enforce; `VaultManager.setPaymentToken` accepts any ≤18-dec token (USDS is 18-dec, USDC/USDT are 6-dec), so a governance change silently mis-scales halt-settlement repayment. Flagged across 5 agents.

---

[70] **10. `sweepDividends` forwards dividends to the admin-mutable `vault.manager()` rather than treasury/VaultManager**

`BorrowManager.sweepDividends` · Confidence: 70

**Description**
The permissionless `sweepDividends` sends realized reward-token value to `IOwnVault(vault).manager()` (a plain admin-set address via `setManager`), a weaker trust boundary than the bad-debt path which hard-codes `registry.treasury()` and documents bounding the blast radius — route it to `registry.treasury()` / `registry.vaultManager()` or enforce that `vault.manager()` equals the VaultManager.

---

[68] **11. `OwnMarket` escrow accounting trusts sent-equals-received — fee-on-transfer payment token desyncs escrow**

`OwnMarket.placeOrder` / `_settleMint` / `_returnEscrow` · Confidence: 68

**Description**
`placeOrder` stores `order.amount = amount` and later settles/returns from that stored figure (OwnMarket.sol:22,32) without measuring the balance actually received, so a fee-on-transfer/deflationary payment token (USDT has a dormant fee switch) leaves the market short by the cumulative fee — the last orders to settle/cancel revert (funds locked) or draw down another user's escrow. AGENTS.md says fee-on-transfer is unsupported but there is no asserting check anywhere.

---

[66] **12. Blocklist-freeze (USDC/USDT) bricks escrow returns and, for `haltRedeemAddress`, all halt redemptions**

`OwnMarket._returnEscrow` / `redeemHalted` · Confidence: 66

**Description**
Escrow returns and halt-redeem proceeds are pushed synchronously to a single party; if USDC/USDT freezes that recipient, `cancelOrder`/`expireOrder` revert permanently (escrow locked), and a frozen `haltRedeemAddress` bricks `redeemHalted`/`settleHaltedPosition` for *every* user of that asset — consider a pull-payment fallback for escrow returns and a non-freezable, monitored halt address.

---

[65] **13. `settleHaltedPosition` ceil-cover over-seizes borrower collateral and sweeps the surplus to the VM**

`BorrowManager.settleHaltedPosition` · Confidence: 65

**Description**
`eTokenToCover` is ceil-rounded so `proceeds` can exceed `currentDebt`; the surplus (funded by the borrower's seized collateral) is swept to the VM as "lending fee" via `_repayAaveAndSweep` rather than returned to the borrower — dust per call but a systematic wrong-recipient on every non-exact halt settlement. Flagged across 5 agents.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | `forceExecuteOrder` asset-price staleness (incomplete C-01) + `limitPrice` payout / util-gate bypass → LP over-extraction |
| 2 | [88] | `fulfillWithdrawal` missing `onCollateralReleased` → global utilization cap bypass |
| 3 | [80] | `WstETHRouter` wraps requested not received stETH → deposit DoS |
| 4 | [80] | `borrow` cap checked before `_accrue` → cap bypass (widened by M-05 floor) |
| 5 | [80] | `borrow` ignores vault Paused/Halted status → borrowing against paused vault |
| 6 | [78] | `BorrowManager` payable funcs strand oracle-fee ETH (no refund) |
| 7 | [76] | Sub-unit `repayAmount`/`stablecoinAmount` → zero scaled debt while moving value |
| 8 | [75] | `_flooredIndex` dust-base index inflation + multi-manager debt corruption |
| 9 | [72] | `settleHaltedPosition` unenforced `paymentToken == stablecoin` assumption |
| 10 | [70] | `sweepDividends` → admin-mutable `vault.manager()` |
| 11 | [68] | Fee-on-transfer payment token desyncs `OwnMarket` escrow |
| 12 | [66] | Blocklist-freeze bricks escrow returns / halt redemptions |
| 13 | [65] | `settleHaltedPosition` ceil over-seize surplus → VM |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **`fulfillWithdrawal` has no `minAssetsOut` slippage floor** — `OwnVault.fulfillWithdrawal` — Code smells: asymmetric vs `deposit`/`requestDeposit` (`minSharesOut`); `convertToAssets` evaluated at fulfillment time. A bad-debt socialization landing between request and fulfillment dilutes a queued LP with no opt-out.
- **`shareYield` between `requestDeposit` and `acceptDeposit` dilutes a pending LP** — `OwnVault.shareYield`/`acceptDeposit` — Code smells: optional `minSharesOut` (can be 0); virtual-offset defense doesn't cover manager donation in the async window. Trust-model adjacent (manager semi-trusted).
- **`_convertToCollateral` floor-div releases 0 collateral for sub-`1e12`-USD bad-debt slices** — `BorrowManager.absorbBadDebt` — Code smells: `collateral18 / 10**(18-collatDecimals)` floors to 0 for a 6-dec vault on dust loss → LP loss under-socialized; admin-gated, dust per call.
- **eTokens escrowed for resting redeem orders accrue unclaimable dividends to `OwnMarket`** — `OwnMarket.placeOrder` — Code smells: market has no `claimRewards`/sweep path (unlike `BorrowManager.sweepDividends`); dividends distributed while orders rest are permanently stranded.
- **`EToken.depositRewards` per-share truncation** — `EToken.depositRewards` — Code smells: `amount.mulDiv(PRECISION, supply)` floors to 0 when `amount × 1e18 < supply` (large 18-dec supply, low-dec reward token) → reward tokens become stuck dust; can quietly zero the lending-revenue sweep.
- **`absorbBadDebt` NatSpec vs code mismatch** — `BorrowManager.absorbBadDebt` — Code smells: doc says LP-loss collateral slice "reimburses the caller," code releases it to `registry.treasury()`; admin-only, doc/intent clarity.
- **`absorbBadDebt` surplus sweep to manager** — `BorrowManager.absorbBadDebt`/`_repayAaveAndSweep` — Code smells: treasury fronts `residual`, but if `actualRepaid < residual` the surplus sweeps to `vault.manager()` as fee; reachability tied to Finding 8 index inflation.
- **Split-ratio rounding drift across `migrateToken`/`convertLegacy`/`applySplit`** — `OwnMarket.convertLegacy` — Code smells: separately-floored compounded ratio vs once-floored `_globalAssetUnits`; observed drift protocol-favorable, needs a multi-split trace to confirm a holder-blocking or over-mint direction.
- **`setRateParams` performs no bounds validation** — `BorrowManager.setRateParams`/`InterestRateModel.premium` — Code smells: `basePremiumBps`/`slope1Bps`/`slope2Bps` unbounded; admin-trusted, but the floor only raises the index and cannot offset a punitive rate.
- **`registerVault`/`forceExecuteOrder` don't reject a zero `collateralAsset`** — `VaultManager.registerVault` — Code smells: zero ticker resolves a missing oracle feed → revert; liveness only, admin-induced.
- **PythOracleVerifier ETH surplus stranded** — `PythOracleVerifier.updatePriceFeeds`/`_verifyPriceWithFeed` — Code smells: pays exact Pyth fee, no refund/sweep/`receive`; same class as Finding 6, separate contract.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
