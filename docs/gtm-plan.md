# Own Protocol — GTM Plan: $0 → $1M TVL, 70% Lending Utilization

*Drafted June 12, 2026. All market data points verified online as of this date; sources in the research appendix at the bottom.*

---

## 0. First, the honest math (what the contracts allow, and the chosen configuration)

"70% of TVL borrowed" is **not achievable safely** under any parameterization — the lending book is collateralized by outstanding eTokens, so it is capped at (issuance × 70% borrower LTV), and pushing issuance utilization to 90–95% thins on-chain backing to 1.05–1.11x, where a routine 5–11% stock-basket rally makes the protocol under-collateralized (full sensitivity analysis in **Appendix A**). The chosen configuration is **aUSDC-led at 65/55** — all parameter changes, no redeploy:

| Parameter | Setting | Where |
|---|---|---|
| `globalMaxUtilizationBps` | 6500 (was 5000) → 1.54x backing | `VaultManager.setGlobalMaxUtilizationBps` |
| `targetLtvBps` | 5500 (was 3500) | `BorrowManager.setTargetLtvBps` |
| Rate curve | `basePremiumBps=100, slope1Bps=200, optimal=8000, slope2=7500` | `BorrowManager.setRateParams` |
| Operating point | ~50% utilization via per-asset `assetCapUSD`; 65% is the hard cap, not the target | `VaultManager` |

The chain at $1M:

```
$1,000,000 LP collateral (aUSDC vault TVL)
  → eToken issuance cap (65% global max utilization)   → $650,000 eTokens
  → borrowers post eTokens at 70% LTV                  → $455,000 max lending book (binds)
  → BorrowManager cap (55% targetLtv = $550k)          → does not bind; 20pt buffer to Aave's 75% LTV
  → realistic posting (~85% of eTokens)                → ~$390,000 borrowed = 39% of TVL
```

**Income at that state** (Aave Base USDC borrow = 4.16% today):

| Stream | Math | $/year |
|---|---|---|
| Lending premium (swept to VM) | ~$390k × ~3% premium (at/near the 80% kink) | ~$12–14k |
| RFQ maker spread | ~20bps on est. $3–5M annual mint/redeem flow | ~$6–10k (to the maker) |
| Dividend sweep (eTLT-type assets) | negligible at this scale | ~$0 |

Borrowers pay ~**7.2%** all-in — under Kamino's ~7–8%, above IBKR's 5.1% (but IBKR has no US-blocked, 24/7, composable equivalent), and far under hot-name perp funding (NVDA ~13%/yr). LPs earn aUSDC base (3.12%) + ~1.2–1.4% premium share = **~4.4–4.5% organic** — already "Aave + 1.4%" with zero subsidy; the incentive budget tops it to ~6.5% ("Aave + 3%") during bootstrap.

**$1M TVL is a proof-of-concept milestone, not a business.** The business case starts at $20–50M TVL (~$300k–800k/yr). Everything below is designed so that the $1M milestone produces the *artifacts that unlock the next tier*: a public yield track record, a working maker, and a live looping product — the things CEXs, curators, and HNIs actually diligence.

### 0.1 LP yield breakdown — both vaults (reference)

LPs earn three stacked streams: the collateral's **base yield** (Aave supply for aUSDC, Lido staking for wstETH), a **lending-premium share** routed from borrowers via `shareYield`, and an optional **RFQ-spread share** the maker kicks back to the VM. The two protocol-derived streams are computed as:

```
premium-share APY  =  (lending book USD  ×  realized premium  ×  VM passthrough)  /  vault TVL
spread-share  APY  =  (annual mint/redeem volume  ×  maker spread bps  ×  LP kickback)  /  vault TVL
```

**Assumptions** (each vault at $1M TVL, operating ~50% issuance utilization, book filled to ~the 80% rate-curve kink):

| Input | Value | Note |
|---|---|---|
| VM passthrough to LPs | 90% | VM keeps ~10% for ops; rest distributed via `shareYield` |
| Realized premium | ~3.0% | two-slope curve at/near the 80% kink |
| Lending book | aUSDC ~$360k · wstETH ~$200k | loopers + basis trade concentrate on the deeper USDC borrow; the ETH vault runs lighter |
| Annual mint/redeem volume | ~6× issuance (~$6M / $1M vault) | conservative 1× monthly turnover; RFQ design taxes both buys and sells |
| Maker spread / LP kickback | 25 bps / 50% | kickback applies above a monthly-volume threshold in the maker term sheet |
| Bootstrap incentives | aUSDC ~2.5% · wstETH ~2.0% | Merkl, ~6 months only — not part of organic yield |

**aUSDC vault** (USD-denominated; benchmark = Aave Base USDC supply 3.12%):

| Stream | APY | Derivation |
|---|---|---|
| aUSDC base (Aave supply) | 3.10% | live, June 2026 |
| + premium share | +1.0% | $360k × 3.0% × 0.90 / $1M |
| **= organic (premium only)** | **~4.1%** | **"Aave + ~1.0%"** |
| + spread share (50% kickback) | +0.6–0.75% | $6M × 25bps × 50% / $1M |
| **= organic (premium + spread)** | **~4.7–4.9%** | **"Aave + ~1.7%" (≈ +55%)** |
| + bootstrap incentives | **~7% headline** | Merkl, launch window only |

**wstETH vault** (ETH-denominated; benchmark = Lido stETH 2.55%, and Aave Base wstETH supply ≈ 0.0%):

| Stream | APY | Derivation |
|---|---|---|
| Lido staking (in wstETH appreciation) | 2.55% | live, June 2026 |
| Aave wstETH supply | ~0.0% | no wstETH borrow demand on Base |
| + premium share | +0.6% | $200k × 3.0% × 0.90 / $1M |
| **= organic (premium only)** | **~3.15%** | **"stETH + ~0.6%" (≈ +24%)** |
| + spread share (50% kickback) | +0.6% | volume tracks total issuance, not collateral type |
| **= organic (premium + spread)** | **~3.75%** | **"stETH + ~1.2%" (≈ +47%)** |
| + bootstrap incentives | **~5.5% headline** | Merkl, launch window only |

Read each vault against *its own* benchmark, never side by side: the wstETH vault's ~3.15% organic looks lower than the aUSDC vault's ~4.1%, but a wstETH holder's only alternative on Base is 2.55% (Aave pays them 0.0%), so it's a ~24–47% uplift on an asset they already hold, paid in kind. The aUSDC vault competes against Morpho's 4–5% USDC vaults, which is why it leans harder on the spread share and the incentive top-up.

**Two caveats.** (1) These are *ramped* figures — both vaults pay only base + incentives on day one and climb to the organic numbers over ~2–3 months as the borrow book fills; quote *realized trailing* APY on the dashboard, not the projection. (2) At the $1M single-vault launch only the aUSDC column is live; the wstETH column is the **phase-2** state, and adding it forces the shared `globalMaxUtilizationBps` down toward ~55 (Appendix A, "structural caveat").

---

## 1. What we learned from the market (June 2026 snapshot)

**The category is real and growing fast.** Tokenized stocks: $0.9–2.65B market cap depending on methodology (rwa.xyz: $2.65B, +81%/30d; 357k holders). Q1 2026 spot volume $15.1B. SEC approved Nasdaq/NYSE tokenized trading in March–April 2026; a tokenized-stock framework proposal is circulating.

**Who won and how:**
- **Ondo GM**: $1B TVL in 8 months, >70% issuer share — won via a **30-partner "Global Markets Alliance"** (wallets, exchanges, DeFi), not via paying for listings.
- **xStocks/Backed**: $225M AUM, $25B volume — won via **CEX distribution (Kraken, Bybit, Gate)** then got **acquired by Kraken**. Distribution owned the value, not issuance.
- **Dinari**: first SEC broker-dealer license… and **$10.8M TVL**. License without distribution = nothing. (Cautionary.)
- **Demand proof is on the perp side**: Hyperliquid stock perps >$390M OI; NVDA funding averages **+13%/yr**, MSFT +30% (snapshot), GOLD +5.4%, TSLA currently *negative*. Ostium $95M OI, 91% RWA pairs. People pay double-digit rates for leveraged stock exposure onchain.
- **The exact looping product exists on Solana**: Kamino Multiply loops xStocks at 50–60% LTV, ~$15M xStocks collateral deposited. **Nothing equivalent exists on Base.** Our 70% LTV and built-in LoopRouter is a genuinely better loop (3.3x max vs their ~2–2.5x).

**What's closed to us:**
- **CEX token listing**: MEXC ~$90k all-in, Bitget $175k+, Gate/KuCoin $150–250k — out of budget, and no CEX has ever listed a *synthetic* stock token from a small team. Every listed tokenized equity has a prospectus (Backed/FMA Liechtenstein) or a broker-dealer (Dinari). Synthetic + small team = unlistable today. **Stop thinking "list eTSLA on a CEX." The sellable thing is the yield and the lending infrastructure, not the token.**
- **EU retail**: synthetic stock tokens are MiFID II derivatives, not MiCA assets — no light-touch path. Geo-block EU retail (professional investors only), plus US/UK/Canada.
- **HNI fiat-brain yield**: the institutional bar is Maple at 9–14% / stables at 4–5%. Our base LP yield can't clear that *in USD terms* — but it doesn't have to (see §2).

**Regulatory posture (fits in $8k):** Panama foundation or BVI BC ($3–6k) + ToS geo-block (US, UK, CA, EU-retail, sanctioned) + front-end IP blocking + risk disclosures. This matches what Ostium/Avantis/HIP-3 deployers actually run. Note: the Mirror/Terraform ruling (SDNY, Dec 2023) found overcollateralized synthetic mAssets were **not** security-based swaps — helpful precedent — but our RFQ-with-registered-makers model looks more dealer-like, so no US-person marketing, ever, and put the maker entity offshore too.

---

## 2. The three products we're actually selling (and to whom)

The contracts give us three distinct sellable products. Each has a different buyer:

### Product A — "Aave + 3%, honestly funded" aUSDC vault → sells to **USDC whales & curators** (this is the TVL)
Lead with the aUSDC vault. The USDC LP market is 10–100x deeper than Base wstETH whales, and the collateral story is the strongest in the protocol: **same-asset borrowing (USDC against aUSDC) means essentially zero Aave liquidation risk** — the only bad state is a stock melt-up, and the 65% cap requires a +54% basket rally to breach (Appendix A). The pitch: aUSDC base (3.12%) + ~1.4% lending-premium share organic, topped to **~6.5% with incentives** during bootstrap. That beats Morpho's curated 4–5% USDC vaults by enough to move money, and unlike most new-protocol APYs, ~4.5% of it is organic and verifiable on the Dune dashboard (`LendingFeeAccrued` / `shareYield` events). The quotable risk statement: a −30% *overnight simultaneous* gap across every posted eToken produces bounded LP loss of ~2.5–3.5% of TVL — under one year of yield (Appendix A).

**wstETH vault = phase 2** (post-$1M). The research finding stands — wstETH earns ~0.0% on Aave Base ($27M idle) and there's no competing wstETH venue, so it's an easy second vault and it's what makes the **Lido LEGO grant** application credible. But the utilization cap is *global* across all vaults (pooled risk), so adding volatile collateral later means revisiting the 65% cap (blended ~55–60%) — sequencing USD-first keeps the launch parameters clean.

### Product B — "Loop NVDA at 7% when perps charge 13–30%" → sells to **crypto-native leverage traders** (this is the 70% utilization)
Borrowing USDC at ~6.9% against eNVDA to loop to 3x compares against: NVDA perp funding +13%/yr average (spikes to 25%+), IBKR margin 5.1% (but no US users, no 24/7, no composability), Kamino ~7–8% at lower LTV. **List assets by perp funding rate, not by brand**: launch with eNVDA, eMSFT, eGOOG, eGOLD, eSPY — names where funding is persistently positive, so spot-loop-vs-perp is a clean arbitrage pitch. Do not lead with TSLA (funding currently negative — perp longs get *paid*, our loop can't compete on TSLA right now).

### Product C — "The tokenized-stock basis trade" → sells to **crypto funds / HNIs** (this is the borrowing income at size)
The structured product for sophisticated money: **long looped eNVDA on Own + short NVDA perp on Hyperliquid = delta-neutral, captures the funding spread.** At 13% average NVDA funding minus our ~7% borrow on the looped legs, a 2–3x looped position nets a low-teens delta-neutral USD yield — which *does* clear the HNI bar (12–15% for new-protocol risk). This is a pitch deck you can put in front of any crypto fund's Telegram. One $250k basis-trade allocation fills the entire $245k lending book. **This is the highest-leverage single sales motion in the whole plan.**

---

## 3. The 90-day execution plan

### Phase 0 — Weeks 1–2: Foundation (~$10k)
| Action | Detail | Cost |
|---|---|---|
| Legal entity + geo-block | Panama foundation or BVI BC via Legal Nodes/equivalent; ToS blocking US/UK/CA/EU-retail; IP-block on frontend | $8k |
| Parameters | Set the 65/55 config from §0: `setGlobalMaxUtilizationBps(6500)`, `setTargetLtvBps(5500)`, `setRateParams(100, 8000, 200, 7500)` → ~7.2% borrow at full book; hold operating utilization ~50% via `assetCapUSD` | $0 |
| Asset lineup v1 | eNVDA, eMSFT, eGOOG, eSPY, eGOLD (+ keep eTSLA live but unpromoted). Set `assetCapUSD` per asset | $0 |
| Visibility plumbing | DeFiLlama adapter (TVL page), CoinGecko, rwa.xyz listing, public Dune dashboard showing: TVL, issuance, lending util, realized LP APY, every `LendingFeeAccrued`/`shareYield` event | $1k |
| Grants pipeline (extends the $30k) | **Lido LEGO** application — pitch the phase-2 wstETH vault ("first wstETH yield venue on Base," $25–100k historical tiers); Base Builder Grant nomination (1–5 ETH); watch Base Batches next cohort; OP Retro after shipping | $0 |

*Already done, use it in marketing: audit (docs/audit-report.md), contracts deployed, Pyth oracle integration.*

### Phase 1 — Weeks 2–5: Recruit the maker/VM (the critical path, ~$0 cash)
$30k cannot hedge $500k of minted exposure (even at 5x on Hyperliquid that's ~$100k margin). **An external maker is mandatory above ~$100–200k issuance.**

- **Targets, in order**: Kairon Labs (explicitly low/mid-cap focused, 400+ projects), Keyrock, Flowdesk, Empirica, plus 2–3 small Base-native prop desks found via Aerodrome/Avantis ecosystems.
- **The offer**: exclusive maker/VM seat on a live, audited RFQ market — they keep **100% of the RFQ spread** (10–30bps on all flow), **100% of the lending premium** (~$11k/yr at target, scaling linearly with TVL), and dividend sweeps. Zero listing fee, zero retainer from us — they earn from flow. Their hedge: long the real stock at IBKR or the perp on HL.
- **Fallback if no desk bites in 3 weeks**: self-MM at reduced scale — team runs the signer (AWS KMS, already planned), hedges with HL perps, caps issuance at ~$150k until a desk joins. Ship anyway; a live book is the best recruiting tool.
- In parallel: **Pyth co-marketing** (we run PythOracleVerifier — oracle co-announcements are free distribution; every xStocks/Ondo integration was amplified by their oracle partner).

### Phase 2 — Weeks 4–9: Fill the vault (~$17k)
- **Capped pre-deposit campaign**: $1.5M hard cap on the aUSDC vault ("capped + explicit terms" is the documented pattern that retains; uncapped points farms churn 60–80%). Terms: ~2–3% incentive APR paid via **Merkl** on top of the ~4.5% organic + points with a stated future-token claim → **~6.5% headline ("Aave + 3%")**. Budget: **$12k** covers ~3% on $800k average balance for 6 months.
- **DeBank Official Account broadcast**: targeted paid DMs to every Base wallet holding >$25k aUSDC/USDC in passive venues (Aave, idle wallets — the people earning 3.1% who can move to 6.5%), plus top wstETH holders for the phase-2 waitlist (~$1/recipient, refunded if unread). The only documented direct-to-whale paid channel. Budget: **$3k** → ~2,500 top wallets.
- **Curator outreach** (warm path to $250k–$1M single tickets): **K3 Capital** first (explicitly markets "bootstrapping TVL for new primitives", 10 bespoke pools in H1 2025), then Clearstar, Re7 (10–15% perf fee). Offer: co-incentives from the Merkl budget + the audit + the Dune dashboard. Also open the **Turtle Club** conversation (free to users; BD-negotiated).
- **Content** (founder-led, $0): one thread per week, alternating the two wedges — "Your USDC earns 3.1% on Aave; here's 6.5%, and here's the on-chain event log proving where it comes from" and "NVDA perp funding cost you 13% last year; loop spot at 7%." Budget **$2k** for design/dashboard polish.

### Phase 3 — Weeks 8–13: Fill the lending book (~$3k + BD)
- **Ship LoopRouter UX** (one-click "3x eNVDA"; contracts support it, this is frontend work). Mirror Kamino Multiply's page structure — it's the proven UX for this exact product.
- **Publish the basis-trade playbook**: a public, numbers-complete doc — "Long looped eNVDA / short HL perp: the tokenized-stock carry trade." Include live funding feeds, our borrow rate, net-carry calculator. This document IS the HNI/fund pitch.
- **Direct fund outreach** (20 names): crypto funds running HL basis books — source from HL leaderboards, Ethena/Maple allocator ecosystems, structured-product Telegram desks. One $250k allocation = full book. Offer the first allocator a "founding borrower" rate lock (premium floor waived → ~5.5%) — costs us ~$3k/yr of income, fills 70% utilization on day one.
- **Borrow-side incentive**: rebate 50% of paid premium in points for the first 90 days (paid from the points program, $0 cash).
- HNI wrapper channels to open now for the *next* tier (don't expect closes at $1M): Abra Private, L1 Advisors.

### Day-90 scoreboard
| Metric | Target |
|---|---|
| TVL (aUSDC vault) | $1.0M+ |
| eToken issuance | $450–550k (operating ~50% util; 65% is the hard cap) |
| Lending book | $320–390k borrowed (~32–39% of TVL) |
| External maker live | 1 desk |
| Realized LP APY (on dashboard) | ≥6% headline |
| Grants landed | ≥$25k (LEGO most likely) |

### Budget recap ($30k)
| Item | $ |
|---|---|
| Legal entity + ToS/geo-block | 8,000 |
| LP incentives (Merkl, 6 mo) | 12,000 |
| DeBank whale broadcast | 3,000 |
| Dashboards/listings/design | 3,000 |
| Ops (KMS, keepers, RPC, oracle) | 2,000 |
| BD buffer (curator co-incentives, calls, travel) | 2,000 |
| **Total** | **30,000** |
| Grants offset (LEGO + Base, probable) | +25–50k |

---

## 4. The CEX/HNI endgame (what $1M unlocks)

The research is unambiguous: CEXs integrate **issuers with track records** (Kraken→Backed acquisition; MEXC listing Ondo pairs; Gate's xStocks section), and they integrate via BD, not listing forms. The realistic ladder:

1. **Now ($0–1M)**: wallets + aggregators + DeFiLlama/rwa.xyz presence. Free, BD-driven (Trust Wallet, OKX Wallet fast-listing precedents exist for tokenized equities).
2. **$5–10M TVL + 6-month dashboard**: pitch mid-tier CEX **earn desks** (not listing desks) — "white-label 5–8% wstETH/USDC yield for your earn page, we're the venue." This is a rev-share conversation, not a fee conversation. Same moment: Morpho/Moonwell curator listings of eTokens as collateral become possible, which is what made xStocks investable on Solana (Kamino).
3. **$25M+**: institutional wrappers (Abra, L1 Advisors, Maple-style fixed-term notes on the lending book), regional exchanges in permissive jurisdictions, and — the proven exit in this category — **acquisition by an exchange that wants the issuance stack** (Kraken/Backed precedent).

Every step of the 90-day plan exists to produce the three artifacts step 2 and 3 diligence: a live audited book, a realized-yield dashboard, and a professional maker.

---

## 5. Top risks (ranked)

1. **No maker signs** → issuance capped at self-MM scale (~$150k). Mitigation: ship anyway, ramp via HL-perp self-hedging, keep recruiting with live numbers.
2. **TSLA-style negative funding regimes spread to all names** → looping demand dries up. Mitigation: multi-asset lineup (GOLD funding +5.4% is steady; SPY/index names are structurally long-biased), and the borrow book also serves non-arb leverage demand.
3. **Stock melt-up pushes utilization toward the 65% cap** → mints and LP withdrawals gate. Mitigation: operate at ~50% via `assetCapUSD` (a +30% basket rally only takes you to the cap), keeper marks pulled frequently, and a written runbook: pause new-asset promotion, recruit LP top-ups, let redemptions bleed exposure down. A crash is the *healthy* direction for a USD-collateral vault — only rallies stress it.
4. **Regulatory** — synthetic equities drew SEC action even offshore (Mirror). Mitigation: strict geo-block, no US marketing, professional-investor framing in EU, offshore maker entity, and the favorable SDNY precedent on overcollateralized synthetics.
5. **Points-mercenary churn at incentive end** → cap the campaign, publish the sustainable-yield math from day one, convert top LPs to the curator/fixed-deal track before incentives lapse.
6. **Smart-contract risk** — an audit is signaling, not safety (Cork was hacked post-audit). Keep `assetCapUSD` and the $1.5M deposit cap tight; raise caps monthly, not at launch.

---

## Appendix A — Parameter configuration & sensitivity (why 65/55)

*For when an LP, curator, or auditor asks why the caps are where they are. Notation: `issuance utilization cap / targetLtvBps`. All configurations assume $1M aUSDC TVL, 70% borrower LTV, Aave Base USDC borrow 4.16%.*

### Sensitivity table

| Config | On-chain backing | Basket rally to insolvency | Max lending book | Premium income/yr | LP exits | Verdict |
|---|---|---|---|---|---|---|
| 50 / 35 (as deployed) | 2.00x | +100% | $245k | ~$11k | always open | safe but starves the book |
| **65 / 55 (chosen)** | **1.54x** | **+54%** | **$455k** | **~$12–14k** | ~23% of TVL instantly withdrawable at operating point | **chosen** |
| 90 / 90 | 1.11x | +11% (weekly event for NVDA) | $630k | ~$30k | effectively gated | rejected |
| 95 / 75 | 1.05x | +5.3% (routine) | $665k | ~$33k | frozen; trap-then-bleed under force-redeems | rejected |

The marginal income from 65→95 is ~$20k/yr; the cost is the solvency story that *is* the product. The same income arrives at ~$2.5–3M TVL with safe parameters — a GTM problem, not a parameters problem.

### Why 65% issuance is defensible for USD collateral (when 50% is the floor for wstETH)

The protocol is structurally **short the stocks** — liabilities grow when the basket rallies. The cap sizes the buffer against everything that can hurt the collateral-to-exposure ratio:

- **wstETH collateral has two risk legs**: stocks rally (liabilities up) and ETH can fall (collateral down). ETH's positive correlation with stocks partially hedges rallies, but ETH carries fat idiosyncratic risk — ETH −50% with stocks flat takes 2x backing to 1x on its own. Hence 50%/2x there.
- **aUSDC collateral has one risk leg**: only a stock melt-up hurts. The collateral cannot draw down, and a crash *improves* utilization. 1.54x backing requires a +54% basket rally to breach — comparable in probability to the joint scenarios that breach 2x ETH backing. Rising utilization also blocks new mints automatically on the way up, so the book cannot grow into a rally.
- **Same-asset Aave position**: borrowing USDC against aUSDC has no collateral/debt price gap → essentially zero Aave liquidation risk (vs the 79.5% wstETH threshold cliff). Only interest drift (~1%/yr negative carry) moves the position, and borrower repayments cover it.

### Why 55% targetLtv specifically

- The issuance side binds first: 65% × 70% borrower LTV = $455k max book. `targetLtvBps` above ~46% adds **zero capacity** — it only spends the buffer to Aave's own ~75% stablecoin LTV ceiling. 55% leaves a 20-point cushion and needs no e-mode change.
- Deliberate rate-curve interaction: lending utilization = `totalDebtUSD / maxDebtUSD`, so with a $550k cap the full book sits at ~83% utilization — just past the 80% kink, where slope2 begins applying structural deleveraging pressure exactly when the book is full. To park the full book *below* the kink instead, use `targetLtvBps = 5700` (455/570 = 80%). Either is defensible.
- E-mode (~93% stablecoin LTV on Aave) is future headroom, not a target: `OwnVault` has no `setUserEMode` hook today; consider adding it at $10M+ TVL for capital efficiency.

### Operating discipline: cap ≠ operating point

Launch with per-asset `assetCapUSD` ceilings holding the operating point near **~50%** utilization. The 15-point gap to the 65% hard cap does three jobs:

1. **Rally absorption** — +30% basket move before anything gates; time to respond instead of insta-freezing.
2. **Keeper-mark staleness** — utilization uses cached marks; the docs assign staleness absorption to exactly this buffer.
3. **LP exit liquidity** — at $500k exposure, the withdrawal gate allows exits down to $769k collateral: ~$230k (23% of TVL) instantly withdrawable at any time. A number you can show a curator.

### The LP worst-case statement (for the pitch)

A −30% overnight, *simultaneous* gap across every posted eToken (harsher than any historical single-day equity event, no intervening liquidations): posted collateral $650k → $455k against a $455k debt book; liquidations with the 5% bonus recover most; residual bad debt ≈ **$25–35k ≈ 2.5–3.5% of TVL — under one year of LP yield**. Bounded and quotable. The same event at 95/75 is protocol-ending.

### Structural caveat: the cap is global

`globalMaxUtilizationBps` is one number across **all** vaults (pooled-risk model — no per-vault cap exists). "65% for the USD vault, 50% for wstETH" is not expressible on-chain. Hence the sequencing: launch USD-collateral-only at 6500; when the phase-2 wstETH vault ships, either accept 65% for the blended pool (fine while USD collateral dominates) or step the global cap down to ~55–60%.

---

## Research appendix (key sources)

- Market size/growth: rwa.xyz/stocks; CoinGecko RWA Report 2026; Kraken xStocks $25B volume (blog.kraken.com); Ondo $1B TVL (PRNewswire).
- Rates (live, June 12, 2026): Aave Base USDC borrow 4.16% / wstETH supply ~0% (aavescan.com); Lido 2.55% (Lido API); Hyperliquid xyz funding — NVDA +13.3% 7d-avg, GOLD +5.4%, TSLA −2.6% (api.hyperliquid.xyz); IBKR ~5.1%, Robinhood 5.0% margin; Maple syrupUSDC 4.76%, sUSDe 3.57% (DeFiLlama).
- Distribution playbooks: Ostium points 10x ($5.5M→$53.6M, Blockworks); Kamino xStocks collateral + Multiply looping (The Block, Kamino gov); Euler v2 incentive efficiency (OAK Research); Merkl, Turtle Club, Royco docs; K3 Capital H1-2025 recap (blog.k3.capital); DeBank Official Accounts (docs.cloud.debank.com).
- CEX listing costs: MEXC ~$90k, Bitget ~$175k+, Gate/KuCoin $150–250k (listing.help — broker estimates, not rate cards).
- Legal/structuring: xStocks Jersey/FMA prospectus (docs.xstocks.fi); Dinari broker-dealer (SEC CTF memo); ESMA MiFID-vs-MiCA guidelines; SDNY Terraform opinion (Dec 28, 2023) on mAssets/SBS; CFTC Opyn/ZeroEx/Deridex orders; Panama/BVI costs (Legal Nodes, Carey Olsen); VARA fee schedule (rulebooks.vara.ae).
- Grants: Lido LEGO (lido.fi/lego; 2026 EGG $16.2M cap); Base get-funded (docs.base.org); Base Batches; OP Retro. Note: Aave Grants DAO wound down — do not budget for it.
