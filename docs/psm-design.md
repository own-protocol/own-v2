# PSM & RWA Reserve Vaults — Design

Status: **draft — pre-implementation design**
Scope: PSM (peg-stability-module) mint/redeem, RWA reserve vaults, per-asset delta netting,
per-asset forceExecute designation, per-asset lending-vault allowlist.

---

## 1. Motivation

Two problems with the current model:

1. **Capital efficiency.** Issuing $1 of eTSLA today requires ~3x capital: ~2x LP collateral in
   vaults (overcollateralization behind the global utilization cap) plus ~1x maker capital for the
   off-chain hedge.
2. **LP bootstrapping.** New assets need LP collateral committed before any volume exists.

The fix: for each listed asset, hold the **wrapper token itself** (e.g. Ondo's tokenized TSLA,
`ondoTSLA`) in an on-chain reserve. Wrapper collateral is delta-1 with the eToken exposure it
backs — its price moves with the liability — so it can back issuance **1:1** with no
overcollateralization. The crypto-collateral pool (USDC/aUSDC/ETH vaults) shrinks to a **buffer**
covering only the residual: exposure minted via RFQ that the maker has not yet backfilled with
wrapper tokens.

Steady-state capital ≈ 1x wrapper reserve + a small crypto buffer sized to in-flight volume.

## 2. Core economics — reserves are protocol-owned, not LP equity

**The PSM reserve must never be LP equity.** If LPs deposited `ondoTSLA` into an ERC-4626 vault
and PSM redemptions pulled from it, every redeem would transfer LP assets out while retiring a
*protocol* liability — a direct wealth transfer from LPs to redeemers. (MakerDAO's PSM avoids this
the same way: PSM reserves back DAI directly and carry no LP claim.)

Therefore the RWA vault is a **share-less reserve pool**:

- No ERC-4626 shares, no deposit queue, no withdrawal queue, no LP accounting.
- Reserve enters via `psmMint` (mints matching eTokens) or `psmBackfill` (no mint — hedge
  delivery, see §4.2).
- Reserve exits only via `psmRedeem` (burns matching eTokens 1:1).
- Every unit of reserve is matched by a unit of eToken liability; vault equity is ~0 by
  construction (plus any fee/skim surplus).

LP deposits on RWA vaults (sharing lending yield) are explicitly **out of scope for v1** — they
require reserve/equity separation inside the vault and change the share-price definition.

### Maker flow (bootstrapping without LP capital)

1. Buyer pays 1x USDC via RFQ (`executeOrder` / `fillOrder`) → eTSLA minted instantly, backed
   temporarily by the crypto buffer (existing path, `openExposure`).
2. The maker received the buyer's USDC, buys `ondoTSLA` with it, and **backfills** it into the
   TSLA reserve vault (`psmBackfill`). The maker keeps the spread and ends flat — no LP shares,
   no residual delta.
3. Netting (§5) recognizes the reserve against TSLA exposure; the buffer frees for the next order.

The maker's incentive to backfill is structural: un-backfilled exposure keeps effective global
utilization elevated, which gates the maker's ability to open new exposure, and the maker remains
on the hook for redeems against the buffer.

## 3. PSM vs forceExecute — coexistence rules

The two paths do not conflict; they cover different failure modes and are segregated by vault
class:

| | PSM redeem | forceExecute |
| --- | --- | --- |
| Purpose | Peg-arb / instant exit | Backstop when maker is unresponsive |
| Timing | Instant | After `claimThreshold` on a resting redeem order |
| Pricing | Fixed conversion ratio, in-kind, **no oracle** | Oracle `limitPrice`, USD-valued |
| Source | RWA reserve vault only | Crypto-native vault only (per-asset designation) |
| Bound | Reserve balance | Designated vault's collateral |

**Rules:**

- PSM exists only on RWA reserve vaults. forceExecute may only be sourced from generic
  (crypto-native) vaults — enforced in `setForceExecuteVault` (designated vault must have
  `backedAsset == 0`).
- Rationale for the exclusion: forceExecute releases collateral at a USD conversion floored at
  the order's `limitPrice`, which can diverge from the fixed 1:1 conversion. Sourcing it from the
  reserve could release **more wrapper units than the burn retires**, breaking the 1:1 matching
  that backs all remaining holders. PSM redemption from the same reserve is always unit-matched.
- Exit ladder for a redeemer: (1) RFQ redeem (maker quote, USDC out); (2) PSM redeem (instant,
  wrapper out, while reserve lasts); (3) forceExecute (delayed, crypto collateral out, guaranteed).

Peg dynamics: eTSLA below NAV → arber buys eTSLA, PSM-redeems for `ondoTSLA`, sells → reserve
shrinks. Above NAV → arber buys `ondoTSLA`, PSM-mints, sells → reserve grows. Reserves
self-balance with flow direction.

## 4. Architecture

### 4.1 Design principle: PSM routes through OwnMarket

`psmMint` / `psmRedeem` / `psmBackfill` are **OwnMarket external functions**, not a standalone
contract. This keeps every existing authority boundary intact:

- `EToken.mint/burn` stays market-only — unchanged.
- `VaultManager.openExposure/closeExposure` stays `onlyMarket` — unchanged.
- `ReserveVault.releaseCollateral` is `onlyMarket`, mirroring `OwnVault.releaseCollateral`
  (including the `onCollateralReleased` mark sync).
- Every PSM mint/burn flows through open/closeExposure, so the protocol keeps **one set of
  books**: `Σ eToken supply == globalAssetUnits` holds across all four mint/burn paths
  (RFQ settle, forceExecute, redeemHalted, PSM). No dual-ledger fungibility problem.

### 4.2 New contract: `ReserveVault`

A lean custody contract (`src/core/ReserveVault.sol`), deliberately **not** an OwnVault fork:

- Holds one wrapper token (`asset()`), exposes `totalAssets()` — just enough surface for
  VaultManager's duck-typed `IERC4626(vault).totalAssets()` / `.asset()` marking to work.
- `releaseCollateral(address to, uint256 amount)` — `onlyMarket`, syncs the collateral mark via
  `VaultManager.onCollateralReleased` before transfer (same ordering as OwnVault).
- No shares, no queues, no pause state of its own (asset-level pause/halt on VaultManager
  governs the PSM paths), no Aave, no BorrowManager, no credit delegation (see §8.6 for the
  future-lending path).
- `skimExcess(uint256 amount)` (operator) — moves reserve **in excess of the asset's outstanding
  exposure** to the treasury (fee surplus / donations). On-chain guard: the skim must not
  increase the asset's `netExposure` (§5), i.e. it can only spend the clamped surplus where
  `R_a > E_a`. Required in v1.

One ReserveVault per (asset, wrapper) pair. Multiple wrappers per asset (e.g. `ondoTSLA` and
`xTSLA`) are separate ReserveVaults, all netting against the same asset (§5).

### 4.3 AssetRegistry — per-asset routing config

New per-asset state (AssetRegistry is the natural home; it already resolves per-asset config and
talks to VaultManager):

```solidity
struct PsmConfig {
    address reserveVault;  // ReserveVault holding this wrapper
    uint256 lastUsedRatio; // last conversion ratio used, for the ratio-jump guard (§8.3)
    bool paused;           // per-wrapper PSM pause
}
// ticker → wrapper token → config
mapping(bytes32 => mapping(address => PsmConfig)) psmConfigs;
// ticker → wrapper token list (enumeration for ops/indexing)
mapping(bytes32 => address[]) psmWrappers;

// ticker → vaults whose BorrowManager may lend against this eToken
mapping(bytes32 => mapping(address => bool)) allowedLendingVault;
```

- `setPsmConfig(ticker, wrapper, config)` — admin. Registering requires the ReserveVault to be a
  registered RWA vault on VaultManager (`backedAsset == ticker`).
- `setLendingVaultAllowed(ticker, vault, allowed)` — admin.
- **The conversion ratio is derived, not stored** (§8.3): wrapper issuers (Ondo) are total-return
  trackers whose share multiplier (`sValue`) drifts with dividend reinvestment and jumps at
  splits. A static ratio would systematically misprice the PSM. Instead:

  ```
  conversionRatio (eTokens per wrapper unit, 1e18)
      = assetMark(WRAPPER_TICKER) / assetMark(ASSET_TICKER)   // ≡ Ondo's sValue
  ```

  computed from the keeper-cached VaultManager marks at PSM-execution time. During a halt no
  special casing is needed: the asset mark is frozen at the halt price, so the derived ratio
  pays redeemers exactly haltPrice-worth of wrapper at its live mark — USD-fair, and it keeps
  `E_a`/`R_a` netting in lockstep (a fixed ratio snapshot would desync both as the wrapper price
  moved).

### 4.4 VaultManager — vault classes and per-asset forceExecute

- `registerVault(address vault, bytes32 collateralAsset, bytes32 backedAsset)`:
  - `backedAsset == 0` → **generic vault** (all existing vaults; behavior unchanged).
  - `backedAsset != 0` → **RWA vault**: its mark accrues to `_assetRwaCollateralUSD[backedAsset]`
    instead of `_globalCollateralUSD` (§5).
- `_forceExecuteVault` becomes `mapping(bytes32 => address)`. `setForceExecuteVault(asset, vault)`
  keeps the operator role, the zero-default = disabled fail-safe, and adds the guard
  `backedAsset(vault) == 0`.

### 4.5 OwnMarket — PSM entrypoints

```
psmMint(bytes32 asset, address wrapper, uint256 wrapperAmount)
```
1. Gates: asset active (`_validateAsset`), not trading-paused, not halted, PSM config exists and
   not paused, **both marks fresh** (asset mark via openExposure's gate; wrapper mark checked
   explicitly against `maxMarkAge` since it prices the conversion).
2. `eTokenAmount = wrapperAmount · conversionRatio · decimalScale` (ratio derived per §4.3;
   floor — protocol-favorable).
3. Pull wrapper from user directly into the ReserveVault (`safeTransferFrom`, with the
   fee-on-transfer balance check used by `placeOrder`).
4. `VaultManager.pullCollateralPrice(reserveVault)` — already permissionless; syncs the reserve
   mark so netting sees the new reserve **before** the exposure check.
5. `openExposure(asset, eTokenAmount)` — inherits the fresh-mark gate (`maxMarkAge`) and asset
   cap. Under netting the matched mint is ~util-neutral, so the global cap does not block it.
6. Mint eToken to user.

```
psmRedeem(bytes32 asset, address wrapper, uint256 eTokenAmount)
```
1. Gates: PSM config exists and not paused; not trading-paused. **Allowed while the asset is
   halted** (policy decision, §8.4) — the frozen halt mark makes the derived ratio settle at
   haltPrice-worth of wrapper (§4.3). Halted redeems gate on **wrapper-mark freshness** only
   (the wrapper still trades and prices the payout).
2. `wrapperAmount = eTokenAmount / conversionRatio` (ratio derived per §4.3; floor —
   protocol-favorable). Off-hours (non-halted) both marks are frozen at the same session close,
   so their **ratio** (= sValue) stays valid even when the prices themselves are stale — redeem
   works off-hours without a freshness gate.
3. Burn eToken from user; `closeExposure(asset, eTokenAmount)` (stale-mark-tolerant, so PSM
   redeem works off-hours).
4. `reserveVault.releaseCollateral(user, wrapperAmount)` — bounded by reserve balance
   automatically (revert on insufficient reserve).

```
psmBackfill(bytes32 asset, address wrapper, uint256 wrapperAmount)
```
1. Gates: PSM config exists and not paused.
2. Transfer wrapper user → ReserveVault; `pullCollateralPrice(reserveVault)`.
3. No mint, no exposure change — the donated reserve nets against existing exposure (§5),
   freeing the crypto buffer. This is the maker's hedge-delivery door.

No quote, no signature, no settle band on any PSM path — there is no price input from the caller.
Fees (`tin`/`tout` bps) are deferred; if added later they accrue to the reserve as surplus and
exit via `skim`.

### 4.6 BorrowManager — per-asset lending allowlist

`_validateEligibility(asset)` additionally requires
`assetRegistry.allowedLendingVault(asset, vault)` where `vault` is the manager's bound vault.
Complements the existing per-asset borrow blocklist. The one-borrow-manager-per-vault invariant is
untouched; ReserveVaults never bind a BorrowManager and never appear in any allowlist.

## 5. Risk accounting — per-asset delta netting

### Problem

Matched 1:1 issuance breaks the current global cap: a PSM mint adds equal USD to exposure and
collateral, dragging `util = E/C` toward 100% and past any cap below it — even though the matched
book adds **zero** net risk (collateral price moves with the liability).

### Model

Let, per asset `a`:

- `E_a` = `_assetExposureUSD[a]` (unchanged: units × mark)
- `R_a` = `_assetRwaCollateralUSD[a]` = Σ collateral marks of RWA vaults with `backedAsset == a`

Then:

```
netExposure_a       = max(0, E_a − R_a)
_globalExposureUSD  = Σ_a netExposure_a            (running total)
_globalCollateralUSD = Σ marks of GENERIC vaults only
utilization         = _globalExposureUSD / _globalCollateralUSD
```

Semantics: wrapper collateral perfectly hedges its own asset's exposure and nets to zero; the
crypto pool backs only the **unhedged residual** and keeps its overcollateralization haircut.
Excess reserve above exposure is clamped out by the `max(0, ·)` — wrong-delta collateral must not
back other assets (conservative by construction). Multiple RWA vaults per asset sum into `R_a`.

### Update sites (all O(1), all existing code paths)

Every site already recomputes a single asset's or vault's delta; netting adds a re-derivation of
that one asset's `netExposure` contribution:

| Site | Change |
| --- | --- |
| `openExposure` / `closeExposure` | update `E_a`, then re-net `a` into `_globalExposureUSD` |
| `pullAssetPrice` / `haltAsset` | re-mark `E_a`, re-net `a` |
| `pullCollateralPrice` | RWA vault: update `R_a`, re-net `a`. Generic vault: unchanged |
| `onCollateralReleased` | branch by class: RWA → `R_a` + re-net; generic → `_globalCollateralUSD` |
| `onVaultHalted` / `onVaultUnhalted` | same branch |
| `deregisterVault` | same branch + existing util guard on the netted figures |

`withdrawalBreachesUtil` (generic LP withdrawals) keeps its form — it already projects the global
figures, which are now the netted ones. `collateralCapBps` (concentration cap) applies to generic
vaults; RWA vaults don't need it (their contribution is bounded by their own asset's exposure via
the clamp).

**Freshness note:** `openExposure` requires a keeper-fresh **asset** mark (unchanged). Reserve
marks (`R_a`) refresh on every PSM operation via the inline `pullCollateralPrice` and on
permissionless keeper pulls, same as vault collateral today. A stale-high `R_a` between pulls
under-states net exposure; mitigations are the existing keeper cadence plus the inline sync on
every PSM touch. Same trust profile as today's collateral marks.

## 6. Oracle configuration

**Asset and wrapper-collateral tickers are separate from day one**, and the wrapper ticker's
semantics are the **wrapper token price** (total-return), not the underlying share price. Per
Ondo's design (verified against Ondo/Chainlink docs, §8.3):

```
wrapper token price = underlying equity price × sValue
sValue (SyntheticSharesOracle) = cumulative dividend-reinvestment & corporate-action multiplier
```

Example for TSLA:

| Ticker | Semantics | Used for | Feed (launch) |
| --- | --- | --- | --- |
| `TSLA` | underlying share price | eTSLA exposure marks, settle band, forceExecute pricing | TSLA feed |
| `ONDO.TSLA` | **wrapper token price** (share price × sValue) | ReserveVault marks, PSM conversion ratio (§4.3) | numerically = TSLA feed while sValue = 1 |

TSLA pays no dividends, so at launch sValue = 1 and the two feeds coincide numerically — but the
`ONDO.TSLA` ticker carries token-price semantics from day one. It diverges permanently on the
first dividend reinvestment (for dividend payers like TLT, from the first month) or split. The
in-house oracle publishes it directly; Chainlink also publishes Ondo GM token-price feeds
(Ethereum mainnet today) as a future source.

This ticker is also where **wrapper depeg risk** (issuer insolvency, secondary-market discount,
issuer redemption halt) surfaces: mark the reserve at the wrapper's real price and any basis
shows up as `R_a < E_a`, correctly re-loading the residual onto the crypto buffer.

The derived conversion ratio (§4.3) and the reserve valuation both key off the same
`ONDO.TSLA` mark, so unit conversion and USD netting can never disagree about what a wrapper
token is worth.

## 7. Flows (reference)

```
Mint via RFQ (instant, buffer-backed)          Mint via PSM (1:1, reserve-backed)
────────────────────────────────────           ───────────────────────────────────
buyer USDC → maker (quote)                     user ondoTSLA → ReserveVault
openExposure(TSLA, x)                          pullCollateralPrice(reserve)
eTSLA → buyer                                  openExposure(TSLA, x)
[maker later: buy ondoTSLA → psmBackfill]      eTSLA → user

Redeem via RFQ                                 Redeem via PSM (instant, in-kind)
────────────────────────────────────           ───────────────────────────────────
maker USDC → user (quote)                      burn eTSLA
burn eTSLA, closeExposure                      closeExposure(TSLA, x)
[maker may psmRedeem + sell to recover]        ReserveVault → ondoTSLA → user

forceExecute (backstop, unchanged semantics)
────────────────────────────────────
resting redeem order + claimThreshold elapsed + fresh oracle price ≥ limitPrice
→ releaseCollateral from the PER-ASSET designated GENERIC vault, USD-valued
```

## 8. Decisions & open items

### 8.1 Ondo transfer restrictions — resolved (monitor)

Verified: Ondo wrapper tokens currently have **no transfer restrictions** on Base. Monitored
assumption — if allowlisting is ever introduced, the ReserveVault/OwnMarket addresses and PSM
redeemers would need permitting, and `psmRedeem` may need an address gate. Revisit before each new
wrapper listing (xStocks etc. may differ).

### 8.2 Oracle tickers — resolved

Separate tickers per §6; same feed initially.

### 8.3 Corporate actions — resolved (verified against Ondo & Chainlink docs)

How Ondo actually handles corporate actions (sources: Ondo GM docs overview; Chainlink tokenized
equity feeds for Ondo GM):

- Wrapper tokens are **total-return trackers**. Token balances never rebase and the token is
  never migrated. `token price = underlying price × sValue`, where `sValue` (from Ondo's
  `SyntheticSharesOracle`) accumulates dividend reinvestment and corporate actions.
- **Dividends**: reinvested (net of withholding) via small automated sValue increases
  (≤1% per 24h). One wrapper token therefore represents a growing number of shares over time.
- **Splits**: large sValue jump (e.g. 1.0 → 10.0 for 10:1) behind a **scheduled pause ≥24h in
  advance** — the token price freezes at the last good value, the new sValue is staged, and Ondo
  manually unpauses after verifying price and sValue re-sync. The wrapper token price is
  **continuous through the split**.

Consequences for this design:

1. **The conversion ratio ≡ sValue and is dynamic** — it drifts continuously for dividend-paying
   assets and jumps at splits. A stored admin-set ratio would misprice the PSM by the accumulated
   drift, an exploitable one-directional arb against the reserve. Hence the ratio is **derived**
   from the two cached marks (§4.3): `ratio = mark(ONDO.X) / mark(X) = sValue` by construction.
2. **Splits need no on-chain ratio maintenance.** When the protocol runs `migrateToken`/
   `applySplit` for the eToken (units ×N, asset mark ÷N) and the underlying feed moves to the
   post-split price, the derived ratio scales by N automatically. There is nothing to rescale in
   AssetRegistry.
3. **PSM must be paused around desync windows** (per-wrapper `psmPaused`): (a) Ondo's scheduled
   corporate-action pause — the wrapper feed freezes while the underlying feed moves, corrupting
   the derived ratio; Ondo gives ≥24h notice; (b) the protocol's own `migrateToken` event window
   until both feeds reflect post-split values. Runbook items, mirroring the trading pause the
   protocol would apply around a split anyway.
4. **Ratio-jump guard (hardening):** store the last-used ratio per wrapper; if a PSM operation
   sees the derived ratio move more than a configured bps bound since last use (mirroring Ondo's
   own 1%/24h small-update rule), revert and require operator acknowledgment. Protects against a
   bad feed print or a missed pause window. Recommended for v1, cheap to implement.
5. **Dividend payers close the loop via `skimExcess`.** For assets like TLT the reserve
   appreciates with reinvested dividends (`R_a` grows; `E_a` doesn't), while eToken holders are
   owed dividends via the eToken reward accumulator. The reserve surplus **is** that dividend
   pool: the operator skims it and funds the accumulator. No extra mechanism needed.

Blocked-while-halted rules from `migrateToken` apply unchanged.

### 8.4 PSM redeem during halt — resolved: allowed

PSM redeem stays live for a **halted** asset: in-kind and price-free, strictly better than the
halt-fund path while reserve lasts; `closeExposure` at the frozen halt price keeps books
consistent. Trading **pause** (global or per-asset) blocks **all** PSM paths — mint, redeem, and
backfill.

### 8.5 Out of scope for v1

- LP deposits on RWA vaults (requires reserve/equity separation).
- PSM fees (`tin`/`tout`) — stubs acceptable, not required. (`skimExcess` **is** in scope, §4.2.)
- Any borrow/lending logic in ReserveVault (§8.6).

### 8.6 Future: Aave listing of wrapper assets — keep borrow logic OUT of ReserveVault

If Aave later lists a wrapper (e.g. ondoTSLA), do **not** retrofit borrow logic into
ReserveVault. The reserve is the 1:1 backing for outstanding eTokens; encumbering it with Aave
debt puts liquidation risk on exactly the collateral that guarantees PSM redemption — an Aave
liquidation of the reserve would break the 1:1 match for every remaining holder. PSM redemption
must stay senior to everything, and the only way to guarantee that is for the reserve to carry no
debt.

The upgrade path that captures Aave **yield** without that risk mirrors the existing aUSDC
pattern: deploy a new ReserveVault whose `asset()` is the **aToken** (aOndoTSLA), register it,
and migrate the reserve operationally. `totalAssets()` then appreciates as Aave interest accrues;
the marking machinery works unchanged (wrapper-price ticker × growing aToken balance), and the
growing surplus above matched exposure exits via `skimExcess`. Since the wrapper token address is
an immutable constructor param, this is a config/migration exercise, not a contract change.

If drawing **liquidity against** the reserve is ever genuinely needed, that is a separate design
with strict LTV where PSM redemptions remain senior — not the existing OwnVault/BorrowManager
credit-delegation pattern, and not v1.

### 8.7 Wrapper availability on Base — resolved: accept bridge risk (option 3)

**Decision (2026-07-08): proceed with bridged Ondo tokens.** The bridged representation is a
distinct, riskier wrapper: it carries bridge trust in addition to issuer trust, gets its own
ticker/feed, and its ReserveVault should launch with conservative sizing. Revisit if Ondo ships
native Base support (option 1 below then supersedes). Original analysis kept for reference:

As of July 2026, Ondo GM tokens live on **Ethereum, BNB Chain, and Solana** (bridgeable to
HyperEVM). **Base is not supported**, and Chainlink's Ondo GM feeds are Ethereum-mainnet only.
Options, in preference order:

1. **Ondo launches natively on Base** — cleanest; track their expansion roadmap.
2. **Start with a Base-native issuer** (e.g. Dinari dShares) — the design is issuer-agnostic
   (per-wrapper PsmConfig + per-wrapper ticker); note other issuers' corporate-action mechanics
   differ from Ondo's sValue model and need the same §8.3-style verification per issuer.
3. **Bridged Ondo tokens** — adds bridge trust to the reserve's backing; treat as a distinct,
   riskier wrapper with its own ticker if ever considered.

None of this blocks implementation (contracts are wrapper-agnostic); it gates which wrapper is
configured first at deployment.

## 9. Implementation phases

| Phase | Scope | Contracts touched |
| --- | --- | --- |
| 1 | Per-asset forceExecute designation (independently shippable) | VaultManager, OwnMarket |
| 2 | Vault classes (`backedAsset`) + delta netting | VaultManager |
| 3 | ReserveVault + `psmMint`/`psmRedeem`/`psmBackfill` + PSM config | ReserveVault (new), OwnMarket, AssetRegistry |
| 4 | Per-asset lending-vault allowlist | AssetRegistry, BorrowManager |
| 5 | Tests, invariants, docs, deployment scripts | test/, script/, docs/ |

Interfaces first, then tests, then implementation (per AGENTS.md). This is a **redeploy** of
VaultManager, OwnMarket, and AssetRegistry (non-upgradeable) — bundle as a v2.1 deployment.

## 10. Invariants (additions)

- **Supply == units (preserved):** `Σ eToken supply == globalAssetUnits[a]` across all mint/burn
  paths — RFQ settle, forceExecute, redeemHalted, psmMint, psmRedeem.
- **Netting consistency:** `_globalExposureUSD == Σ_a max(0, E_a − R_a)` and
  `_globalCollateralUSD == Σ generic-vault marks` after any operation sequence.
- **Reserve bound:** `psmRedeem` never releases more than the ReserveVault balance; reserve
  releases only via `psmRedeem` (+ `skim` of surplus above `E_a`, if implemented).
- **Class segregation:** forceExecute never sources a vault with `backedAsset != 0`; ReserveVault
  never binds a BorrowManager; RWA marks never enter `_globalCollateralUSD`.
- **Matched-mint neutrality:** a `psmMint` at fresh equal marks does not increase
  `_globalExposureUSD` (mint is util-neutral up to mark drift within `maxMarkAge`).
- **Conversion rounding:** both PSM directions round in the protocol's favor (mint floors eTokens
  out; redeem floors wrapper out).
