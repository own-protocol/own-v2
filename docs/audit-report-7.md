# Own Protocol v2 — Audit Report & Remediation Status (Pass 7)

**Branch:** `deploy-contracts` (audited at `main` `c5d94b1`) · **Last updated:** 2026-11-01 ·
**PDF:** `audits/01-11-2026_Own_V2.pdf` (`A7-` prefix dropped)

Pre-deploy audit of the eUSD-only contract set: three **independent** solidity-auditor runs
(12-agent pipeline each — 9 specialty attackers + 3 gap-hunters, one pass), one per model, merged
here. Every reported item was deduplicated across the three runs and against Reports 3–5 and
Report 4 (`audits/09-09-2026_Own_V2.pdf`, eUSD-only edition; Report 4 IDs below use its numbering),
then re-verified against source before booking. `A7-` items are
new in this pass; items that restate an earlier, already-decided ID are listed under
**Duplicates dropped** rather than re-booked.

| Run      | Agents finished | Models                                              |
| -------- | --------------- | --------------------------------------------------- |
| Opus 5.5 | 12 / 12         | 10 Opus 5.5, 1 Sonnet 5.5, 1 Opus 4.8 (fallbacks)   |
| Fable    | 12 / 12         | 12 Fable 5.1                                        |
| Opus 4.8 | 12 / 12         | 12 Opus 4.8                                         |

The only item all three runs raised as a finding is A7-M-01 (redemption at an unbounded-age price
with no redemption fee). No unprivileged fund-theft path survived verification.

**Remediation (2026-11-01):** M-01, L-01, L-02 and L-05 are fixed on this branch; L-03, L-04,
I-01 and I-02 are acknowledged with the operating rules below; L-06 and I-03 are by design.

**Final pass (2026-11-01):** one more Opus 5.5 run on the fixed code (`67bff71`) booked L-07 to
L-09 and I-04 (see [Final pass](#final-pass-opus-55-2026-11-01)). L-09 and I-04 are fixed; L-07 and
L-08 are acknowledged.

### Scope

```
src/eusd/EUSD.sol                     src/eusd/EUSDManager.sol
src/staking/StakingVault.sol          src/oracle/ChainlinkOracleVerifier.sol
src/registry/ProtocolRegistry.sol     misc/MoneyFeeCollector.sol
+ interfaces; the Fable run also read script/robinhood/*.s.sol
```

`EUSD` is already deployed and non-upgradeable; its items are recorded for completeness only.

---

## Status at a Glance

| Severity | Total | Fixed | Open | By design |
| -------- | ----- | ----- | ---- | --------- |
| Critical | 0     | 0     | 0    | —         |
| High     | 0     | 0     | 0    | —         |
| Medium   | 1     | 1     | 0    | —         |
| Low      | 9     | 4     | 0    | 5         |
| Info     | 4     | 1     | 0    | 3         |

| ID      | Severity | Finding                                                                         | Status    |
| ------- | -------- | ------------------------------------------------------------------------------- | --------- |
| A7-M-01 | Medium   | `redeem` prices at an unbounded-age oracle price with no redemption fee         | Fixed     |
| A7-L-01 | Low      | Permissionless `accrue` compounds the stability fee                             | Fixed     |
| A7-L-02 | Low      | `closePositionPrincipalOnly` settles the fee at an unbounded-age price          | Fixed     |
| A7-L-03 | Low      | In-house price cache survives reconfig / signer removal; replay after re-enable | Acknowledged |
| A7-L-04 | Low      | Full liquidation pushes the refund to the owner inline (blocked owner reverts)  | Acknowledged |
| A7-L-05 | Low      | Manager deploy script truncates risk params with `uint16(...)`                  | Fixed     |
| A7-L-06 | Low      | One OPERATOR role covers the oracle kill-switch, mint pause and reward top-ups  | By design |
| A7-I-01 | Info     | Principal-only close and `pullFromTreasury` draw on the same treasury eUSD      | Acknowledged |
| A7-I-02 | Info     | `setChainlinkConfig` does not bound `bandBps` to `BPS`                          | Acknowledged |
| A7-I-03 | Info     | `buyBack` forwards the full held $MONEY, not just the swap output               | By design |
| A7-L-07 | Low      | Off-hours redemption can use an in-house price up to `mintPriceMaxAge` old      | Acknowledged |
| A7-L-08 | Low      | `StakingVault` rewards compound on every touch, above `aprBps`                  | Acknowledged |
| A7-L-09 | Low      | Repayments retired principal before fees, shrinking the fee base                | Fixed     |
| A7-I-04 | Info     | Deploy scripts lack unit and chain guards (vault script, manager amounts/age)   | Fixed     |

---

## A7-M-01 — `redeem` prices at an unbounded-age oracle price with no redemption fee (Medium, Fixed 2026-11-01)

Raised by all three runs (Opus 5.5: 6 agents, Fable: 5, Opus 4.8: 7 incl. the liquidation side).

`redeem` (`EUSDManager.sol:353`) reads `(price,) = _oracle().getPrice(ticker)` and discards the
timestamp; `mint`/`withdrawCollateral` use `_freshPrice`. The verifier serves a Chainlink answer
up to `maxAnchorAge` old (`ChainlinkOracleVerifier.sol:236`), and an in-house quote may only sit
within `bandBps` of that anchor (`_checkAnchorBand`), so even an honest, always-on signer cannot
follow an off-hours move larger than the band. Stock tokens keep trading on-chain while their
feeds are silent, and there is no redemption fee.

When the token trades above the stale anchor by more than the band, a redeemer buys eUSD at or
below $1, redeems against the head positions at the stale price and sells the collateral at market.
Example: anchor $600, in-house capped at $618 (3% band), token trades $650 on a weekend gap —
redeeming 100,000 eUSD seizes 161.8 tokens worth $105,178, a ~$5,000 transfer from head debtors,
who cannot defend off-hours (mint and withdraw need a fresh price; only `closePosition` with the
full debt in eUSD is open). In-session, a watcher can take up to the feed's ~0.5% deviation per
redemption, repeatedly. With several managers the redeemer picks the most-lagged collateral.

**Relation to earlier reports:** Report 4 L-04 acknowledged the stale-anchor exit family against
the *liquidation bonus*, and the interface documents redemption as "no freshness bound, never
pausable". That decision predates higher-volatility collateral and was sized for liquidation; the
redemption-side transfer from head debtors, its dependence on `bandBps`, and the missing fee are
not covered by it, so it is booked here.

**Fix:** `redeem` now prices through `_freshPrice` (no older than `mintPriceMaxAge`, the same
bound as mint), so collateral is never redeemed at a stale price; with no fresh price the call
reverts `StaleMintPrice` and waits. Off-hours redemption follows the in-house signer, whose
anchor band is an admin config sized so it can track off-hours moves; a move beyond the band
pauses redemption until prices catch up. A redemption fee was considered and not added: it only
deters gaps smaller than the fee and loosens the peg floor by the same amount. The residual
in-session gap (Chainlink deviation threshold, ~0.5% measured on-chain) is accepted; the manager is
upgradeable if a fee is ever needed. Liquidation stays on the Report 4 L-04 decision. Tests:
`test_redeem_stalePrice_reverts_thenFreshPriceWorks`; invariant handler re-posts the price.

## A7-L-01 — Permissionless `accrue` compounds the stability fee (Low, Fixed 2026-11-01)

Raised by Opus 5.5 (5 agents, as High) and Fable (2 agents). Verified.

`_accrue` (`EUSDManager.sol:488-490`) charges `fee = p.debt × Δindex / (BPS·YEAR)` and folds it
into `p.debt`, so the next fee is charged on principal plus earlier fees. `accrue(collateral,
owner, hint)` is callable by anyone on any position. Untouched for a year, 1,000,000 debt at 8%
owes 80,000; touched daily by a third party it owes 83,277 (+0.33% of debt per year); hourly,
83,287 (the e^r − 1 limit). Cost to the caller is gas only. The extra is minted to the treasury, so
there is no attacker profit — it is borrower griefing — but it contradicts the interface
("simple interest", and `accrue` "never changes what a position owes", `IEUSDManager.sol:27,329`).
Distinct from A5-L-04 (ordering only).

**Fix:** `_accrue` and `currentDebt` charge the fee on principal only — `p.debt - p.feesAccrued`
— so the fee is simple interest however often a position is touched. Debt that is only unpaid fees
accrues no further fee. Test: `test_fee_frequentAccrue_doesNotCompound` (365 daily third-party
touches match an untouched position to within rounding dust).

## A7-L-02 — `closePositionPrincipalOnly` settles the fee at an unbounded-age price (Low, Fixed 2026-11-01)

Raised by all three runs (Opus 5.5: 3 findings + 6 leads; Fable: 6 agents; Opus 4.8: lead).

`_close(…, feesFromCollateral = true)` (`EUSDManager.sol:266`) prices the fee collateral with raw
`getPrice` and burns the full fee from the treasury. The debtor picks `closePosition` (fee in eUSD,
no price) or `closePositionPrincipalOnly` (fee in collateral at the oracle price) after seeing the
price, so the treasury is always on the losing side of any staleness: fees 80 eUSD, stale price
$600, market $540 → the treasury retires 80 eUSD for $72 of collateral. Bounded by
`feesAccrued × gap` per position; contradicts "value-neutral for the treasury".

**Fix:** the `feesFromCollateral` branch prices through `_freshPrice`. `closePosition` stays the
price-free exit that always works off-hours, and a principal-only close with no fees to settle
still needs no price. Test: `test_closePrincipalOnly_stalePrice_reverts_closePositionStillWorks`.

## A7-L-03 — In-house price cache survives reconfig / signer removal; replay after re-enable (Low, Acknowledged)

Raised by Opus 5.5 (4 agents) and Fable (4 + 3 agents). Verified.

Only `disableAsset` deletes `_prices[asset]`. After `setChainlinkConfig` re-points a ticker (new
aggregator or `multiplierToken`), `getPrice` keeps serving the last in-house price — in the old
units, never re-band-checked — while it is newer than the Chainlink answer and within
`inhouseMaxStaleness`; the same holds for a price signed by a signer that `removeSigner` just
revoked. Conversely, because `disableAsset` zeroes the stored timestamp, the replay floor
(`timestamp <= existing.timestamp`) is lost: after a disable + re-config, anyone can resubmit an
earlier public attestation that is still within staleness and band. All paths need an admin
sequence and are bounded by `inhouseMaxStaleness` and the band, but liquidation reads the price
with no age bound (Report 4 L-04).

**Acknowledged (2026-11-01):** handled operationally, so the verifier code is unchanged. Replay only
accepts signatures from signers that are still authorized and prices within `inhouseMaxStaleness`,
and any newer attestation overwrites the cache and raises the replay floor. Rules: push a fresh
price right after every `setChainlinkConfig` or re-enable; on a signer compromise run
`removeSigner(old)`, `addSigner(new)` and push fresh prices for every ticker.

## A7-L-04 — Full liquidation pushes the refund to the owner inline (Low, Acknowledged)

Raised by Fable (6 agents) and Opus 5.5 (4 agents). Verified on-chain: Robinhood stock tokens
(`Stock` implementation behind the BeaconProxy) gate `transfer` with `onlyNotBlocked(to)`.

On a full close, `liquidate` sends `refund` to the owner in the liquidator's call
(`EUSDManager.sol:338`). If the token issuer blocks the owner, every full liquidation with
`refund > 0` reverts. Partial liquidations still work but must leave at least `minDebt`, so the
last `minDebt` of a blocked owner's position cannot be cleared by liquidation (redemption can still
reach it). Impact is capped at about `minDebt` of debt per blocked position.

**Acknowledged (2026-11-01):** rare (issuer blocklist), capped at about `minDebt` per position and
still reachable by redemption; a pull-pattern refund would add a claim step for every liquidated
owner. Revisit by upgrade if a blocked owner ever holds a position.

## A7-L-05 — Manager deploy script truncates risk params with `uint16(...)` (Low, Fixed 2026-11-01)

Raised by Fable (7 agents). Verified.

`DeployEusdManagerRobinhood.s.sol:31-34` casts `vm.envUint(...)` to `uint16` without a bound:
`MCR_BPS=150000` (a typo for 15000) deploys as 18928, and `_validateRatios` only checks ordering.
The script also lacks the `block.chainid` guard that `DeployCoreRobinhood` has.

**Fix:** each value goes through `SafeCast.toUint16` (out-of-range reverts), plus typo guards on
ratio, bonus and fee ranges and the same `block.chainid` check as `DeployCoreRobinhood`. Script
only; no contract change.

## A7-L-06 — One OPERATOR role covers the oracle kill-switch, mint pause and reward top-ups (Low, By design)

Raised by all three runs. `disableAsset` / `removeSigner` (verifier), `setMintPaused` (managers)
and `pullFromTreasury` (vaults) share the registry OPERATOR role, and it is granted to the keeper
so it can top up the vaults. A compromised keeper could
`disableAsset` (every `getPrice` reverts, freezing liquidation, redemption and principal-only
close until ADMIN re-configures) or pause mints; it cannot move funds anywhere but treasury →
vault reserve, capped by the treasury's allowance.

**Accepted (2026-10-31):** the keeper key is held in a KMS; the realistic compromise is the server,
which would expose a separate rewards key too, so a dedicated role adds little.
Containment: ADMIN re-configures, `withdrawReserve` returns over-pulled rewards.

## A7-I-01 — Principal-only close and `pullFromTreasury` draw on the same treasury eUSD (Info, Acknowledged)

`closePositionPrincipalOnly` burns the settled fee from `registry.treasury()`
(`EUSDManager.sol:283`), and `StakingVault.pullFromTreasury` pulls eUSD from the same address.
If top-ups take the treasury's eUSD below outstanding `feesAccrued`, principal-only closes revert
(documented; `closePosition` still works). Ops rule: keep the treasury's eUSD at or above the sum
of open `feesAccrued`, or fund the seUSD vault from other eUSD. **Acknowledged** as that ops rule.

## A7-I-02 — `setChainlinkConfig` does not bound `bandBps` to `BPS` (Info, Acknowledged)

`bandBps` is a `uint16` up to 65,535; at 10,000 or more any lower in-house price passes
`_checkAnchorBand`. Admin typo plus signer compromise only. **Acknowledged:** the band is set in
the reviewed go-live Safe batch; the verifier code stays unchanged.

## A7-I-03 — `buyBack` forwards the full held $MONEY, not just the swap output (Info, By design)

For a non-$MONEY input, `buyBack` forwards `money_.balanceOf(this)` (`MoneyFeeCollector.sol:231`),
so pre-existing $MONEY moves to `reserve` in one call regardless of `burnSpendBps`. The destination
is the owner-set reserve (the treasury Safe), so this is a sweep of donations and swap dust, as
the inline comment says — not a bypass of the keeper cap on the input token. Related keeper-trust
note (Fable, 6 agents): a compromised keeper can route the per-interval input slice to itself
through permissive `swapData` with `minMoneyOut = 1`; the header documents that slice as the
keeper's damage cap, which compounds to most of the held input over a day. Keep `burnInterval`
and `burnSpendBps` conservative.

## Final pass (Opus 5.5, 2026-11-01)

One more solidity-auditor run (Opus 5.5 only, one pass, skill unchanged) on `deploy-contracts`
`67bff71`, after the fixes above. Scope: `src/` with interfaces, `misc/MoneyFeeCollector.sol`,
`script/robinhood/*.s.sol`. 12/12 agents returned; two (economic-security, trust-gap) finished
partially after model safeguard stops, and their files were covered by other agents. Every other
item restated an ID already booked here or in Reports 4–5.

### A7-L-07 — Off-hours redemption can use an in-house price up to `mintPriceMaxAge` old (Low, Acknowledged)

Raised by 3 agents as the selective-push variant, plus 4 agents on the redeem side. After A7-M-01,
`redeem` accepts any price no older than `mintPriceMaxAge`. Off-hours the stored price is the last
in-house push, so a redeemer can redeem against it after the market has moved. `updatePrice` is
permissionless and accepts any valid signature newer than the stored one (never an older one), and
the oracle service publishes each signed price, so a caller can also push a signed price from
between two keeper pushes and redeem in the same transaction. Either way the transfer from head
debtors is capped by the token's price move inside one push interval, and by the anchor band.

**Acknowledged (2026-11-01):** the go-live batch sets the anchor band on every ticker, and large
off-hours moves within one push interval are rare for the listed collateral. If they become
material, the keeper pushes more often; no contract change. Same class as the in-session residual
accepted under A7-M-01.

### A7-L-08 — `StakingVault` rewards compound on every touch (Low, Acknowledged)

Raised by 7 agents. `_accrue` adds `earned` to `_staked`, and `_pending` charges
`aprBps × min(_staked, cap)`, so below the cap rewards earn rewards. `deposit(0)`, `fund(1)` and
every deposit or withdraw are touches, so the effective rate trends to `e^apr − 1` (10% APR touched
every block pays about 10.52%). The reserve pays the difference; no user loses funds. Above the cap
the drip is fixed and nothing compounds.

**Acknowledged (2026-11-01):** the extra comes out of the admin-funded reserve, not from users, and
is a few percent of the reward budget; size the reserve and APR with the compounded rate in mind.

### A7-L-09 — Repayments retired principal before fees, shrinking the fee base (Low, Fixed 2026-11-01)

Raised by 4 agents; a side effect of the A7-L-01 fix. The fee is charged on `debt - feesAccrued`,
but `repay`, `liquidate` and `_redeemFrom` only clamped `feesAccrued` down to the new debt, so a
repayment reduced principal first. Example at 8%: 1,000 debt grows to 1,080 (80 fee); the borrower
repays 80 and still owes 1,000, but year 2 charges 8% on 920 (73.6, not 80). The treasury lost 8% a
year of every fee a borrower had already repaid while the position stayed open.

**Fix:** every debt reduction retires fees first — `p.feesAccrued -= Math.min(repaid,
p.feesAccrued)` in `repay`, `liquidate` and `_redeemFrom`. `feesAccrued <= debt` still holds. Test:
`test_repay_retiresFeesFirst` (replaces `test_closePrincipalOnly_repayClampsFeesAccrued`).

### A7-I-04 — Deploy scripts lack unit and chain guards (Info, Fixed 2026-11-01)

Raised by 6 agents per script. `DeployStakingVaultRobinhood` had no `block.chainid` check and no range
check on the APR or the 18-decimal cap; `DeployEusdManagerRobinhood` did not bound `MIN_DEBT`,
`DEBT_CEILING` or `MINT_PRICE_MAX_AGE`, so a unit typo (milliseconds for seconds) would silently
turn off the A7-M-01 / A7-L-02 fresh-price gate. Admin setters could correct each value later.

**Fix:** the vault script requires chain 4663 and range-checks APR and cap; the manager script
range-checks `minDebt`, `debtCeiling` and `mintPriceMaxAge`. Scripts only.

### Leads from the final pass

- `ChainlinkOracleVerifier._chainlink` only divides by `uiMultiplier()`; a ticker priced by a
  share-price feed (not a token feed) would be valued at the share price. Check per ticker.
- `CheckChainlinkFeedsRobinhood` checks a fixed feed list; run it against every configured ticker.
- `MoneyFeeCollector.collectFees` is permissionless and splits pending fees at the
  `burnShareBps` in force at collect time, so a caller can order it around `setBurnShareBps`.
  Protocol-only impact.
- `StakingVault.rewardRate` / `currentAprBps` read stored `_staked` without pending rewards (UI only).

---

## Duplicates dropped (→ existing decisions)

- **Underwater head redemption leaves an unbacked residual that liquidation never clears**
  (Fable F1, Opus 4.8, Opus 5.5 lead) → **Report 4 H-01 / M-01**, the deliberate fix: an
  underwater head is redeemed value-for-value and the residual stays on the owner's books off-list.
  The owner self-redeeming gains nothing over walking away from the position. Fee accrual on such
  residuals → Report 5 lead ("fee accrual on unbacked residuals").
- **Liquidation at an unbounded-age price** (Opus 4.8 F-1) → **Report 4 L-04**, acknowledged; the
  redemption side is booked as A7-M-01.
- **`getPrice` reports `block.timestamp` inside `clFreshWindow`, so `mintPriceMaxAge` can't bind
  tighter** (Opus 4.8 F-2, Fable) → **Report 4 L-01**, resolved as documented semantics.
- **Sorted list ordered by stale stored debt** → **A5-L-04 / Report 4 L-02**, acknowledged.
- **Head at exactly `minDebt` stops sub-`minDebt` redemptions** → **A5-M-04** designed semantics
  and Report 5's `setMinDebt` lead.
- **`withdrawCollateral` ignores `cfg.enabled`** → **A5-L-05 / Report 4 L-10**, deliberate.
- **`EUSD.crosschainBurn` is allowance-free** → **Report 4 I-05 / I-06**, acknowledged; bridging
  stays disabled. **`_available` `maxLimit × elapsed` overflow** → Report 5 third-scan lead. EUSD
  is deployed and unchanged by this release.
- **Initializer front-run** → not reachable: deploy scripts initialize in the `ERC1967Proxy`
  constructor.
- **In-house signer may quote in quiet market hours after `clSilence`** → the documented hybrid
  oracle design (silence gate + band; `docs/chainlink-feeds-robinhood.md`).

## Leads (not scored — trails for manual review)

- **Chainlink leg not wrapped in try/catch** (all runs): a reverting aggregator or
  `ZeroMultiplier` stops `getPrice` even when a valid in-house price exists. `multiplierToken` is
  unset on every planned ticker, so `ZeroMultiplier` is unreachable today; revisit if a multiplier
  token is ever configured.
- **Registry treasury unset at deploy**: `_accrue` mints to `registry.treasury()`; the go-live
  batch sets it before any manager can mint (minting needs `MINTER_ROLE`, granted later in the
  same batch).
- **StakingVault has no sweep for plain transfers**: direct transfers are locked (by design, they
  never move the share price). Never set the fee collector's `reserve` to a vault.
- **`collectFees` reverts if one payee rejects native coin**: the payee is the treasury Safe.
- **`buyBack` native path** reads `amountIn` from the live balance at execution: fees accrue in
  SPY, so the native path is unused.
- **Wrong-hint `_insertNode` walk gas** on long lists: self-limiting (those positions are redeemed
  first).
- **`setBridgeLimits` enabling one side of a live bridge starts it at zero capacity** (EUSD,
  deployed): availability only.
- **StakingVault 1-wei `_staked` dust at zero supply** and unchecked pre-multiplication in
  `_seizure` / `_pending` at extreme admin params: dust / admin-bounded.

## Attacked and held

StakingVault: no share-price inflation (donations ignored, `_staked` tracked), no back-pay after an
empty reserve or zero supply, `setApr`/`setCap` accrue at the old rate first, payouts bounded by
stake plus reserve. EUSDManager: `eUSD supply == Σ totalDebt` across mint, repay, every `_close`
branch, liquidation and redemption; `totalCollateral` matches token flows; listed ⇔ debt > 0 ∧
collateral > 0; partial liquidation and redemption never lower the survivor's ratio; rounding
protocol-favoring; UUPS initializers locked. Verifier: EIP-712 domain bound to the verifier address
(no replay from the legacy verifier), future-timestamp and zero-price rejection, `clDecimals <= 18`.
Registry: two-step delayed admin transfer. MoneyFeeCollector: storage append-only (`reserve` in
slot 11, namespaced ReentrancyGuard), allowance reset after swaps, balance-delta claim accounting.
