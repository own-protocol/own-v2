# eUSD — Protocol Mechanics Q&A

**Date:** 2026-09-02 · **Branch:** `stablecoin` · Params referenced from
`script/robinhood/DeployEusdRobinhood.s.sol` (MCR 150%, liq. threshold 130%, liq. bonus 5%,
stability fee 2%/yr, minDebt 100 eUSD, debt ceiling 250k eUSD, mint price max age 15 min).

The eUSD CDP engine (`EUSDManager`) is built on **Liquity v1's** battle-tested design — the
sorted-list riskiest-first redemption (`SortedTroves` pattern), hint-based O(1) insertion,
keeper liquidation with direct burn, and value-neutral redemption as the peg anchor (mainnet
since 2021). It is a fresh implementation of those mechanisms adapted to Own's oracle/registry
stack and market-hours price-freshness rules, not a copy of the Liquity codebase.

---

**Q: Deposit $150 eSPY — can I mint only $70?**
Max = collateral / MCR = $100. But `minDebt` = 100 eUSD means a $150 deposit can mint *exactly*
$100 — and sits at MCR instantly (liquidatable after ~13% drop). $150 is the effective floor
deposit; realistic users deposit more or mint less.

**Q: Deposit $1,500 eSPY, mint $700 — possible?**
Yes (verified against `mint`, EUSDManager.sol:163): $700 ≥ minDebt, ≤ ceiling, ratio 214% ≥ 150%
MCR. Any amount $100 → ~$1,000 is the user's choice. Requires fresh in-session price (≤ 15 min);
two txs (`deposit`, then `mint`).

**Q: Can I mint more later while I have buffer?**
Yes — `mint` is repeatable; each call re-checks MCR at a fresh price, ceiling, pause.

**Q: Can I repay partially and keep collateral, improving health?**
Yes — `repay` burns eUSD, collateral untouched, ratio strictly improves. Remaining debt must be
0 or ≥ minDebt. Works off-hours (no oracle); anyone may repay on your behalf.

**Q: How does redemption work for a depositor?**
Two senses: (a) getting collateral back — `repay` then `withdrawCollateral`, or `closePosition`
(burns full debt incl. fees, returns all collateral, works off-hours, no oracle);
(b) being redeemed against — any eUSD holder burns X eUSD and takes exactly $X of eSPY at the
oracle anchor, from the riskiest positions first (lowest collateral/debt ratio, tracked in a
sorted list; head = riskiest). Value-neutral to the redeemed owner; they lose upside exposure on
the seized portion only.

**Q: eSPY at $150 → $200 in a year: mint more? full value back on close?**
Yes and yes. Ratio uses the live price, so capacity grows (e.g. $100 debt → ~$133 cap; ~$31 more
after the 2%/yr fee grows debt to ~$102). Debt is in eUSD, collateral in eSPY units: on close you
repay ~$102 and receive the entire 1 eSPY at $200 — all appreciation is the owner's.

**Q: Does liquidation surplus go back to the user automatically?**
Yes, same transaction (`liquidate`): seized = repaid × 1.05 capped at the position's
collateral; on a full close the remainder transfers straight to the owner. E.g. $150 coll / $100
debt, ratio hits 128% → liquidator burns 100 eUSD, takes $105 of eSPY, owner gets $23 back
instantly. Underwater positions: no refund; liquidator absorbs the shortfall.

**Q: Must a liquidator repay the whole debt at once?**
No. `liquidate(collateral, owner, amount, hint)` repays up to `amount` (`type(uint256).max` =
full). A partial takes collateral worth repaid × 1.05, leaves the rest of the position in place
re-sorted, and may not drop the debt below `minDebt` (else it reverts, like `repay`). Surplus is
refunded to the owner only on a full close. Why it matters: a whale who mints most of the supply
and moves it out of reach can no longer make themselves unliquidatable — any keeper with any
eUSD can clear the position in chunks.

**Q: Is minDebt configurable?**
Yes — `setMinDebt` (ADMIN via ProtocolRegistry). Gates new state changes only; existing smaller
positions unaffected (full close always works). Keep it high enough that liquidating a minimum
position clears keeper gas + bonus.

**Q: My minted eUSD after someone redeems my position — what happens on close?**
The redeemer burned *their* eUSD to retire your debt; yours is untouched and fully fungible.
E.g. $1,500 coll / 700 debt, $400 redeemed → close burns your remaining 300 debt, returns $1,100
of eSPY, and 400 eUSD stays yours free and clear — exact compensation for the seized collateral.
Fully-redeemed positions keep residual collateral; all minted eUSD remains valid
(`totalSupply == Σ debt` holds at every step).

**Q: How does the protocol know which position is "riskiest" for redemptions?**
Each collateral keeps an on-chain doubly-linked list of all positions with debt and collateral, sorted
ascending by **nominal ratio** = collateral units × 1e18 / debt (`_insertNode`,
EUSDManager.sol:460). Head = lowest ratio = riskiest; redemptions consume from the head and walk
toward safer positions. Because every position in one collateral shares the same oracle price,
the price cancels out of the comparison — the ordering stays valid at any price with no
re-sorting on price moves. Every `deposit` / `withdrawCollateral` / `mint` / `repay` re-inserts
the touched position at its correct slot; a partially-redeemed position (only ever the last one
touched) is re-sorted with its now-improved ratio. Ordering uses stored (last-accrued) debt, so
long-untouched positions drift marginally riskier than their slot implies — bounded by the
stability fee rate. Same pattern as Liquity's `SortedTroves` (mainnet since 2021).

**Q: What is the `hint` parameter on deposit/mint/repay/withdraw/redeem?**
The expected list predecessor of your position after the update — it lets insertion be O(1)
instead of walking the list. Front-ends compute it off-chain for free via the `findInsertHint`
view (or an indexer at scale) and pass it through; a stale hint (someone's tx landed first) only
walks the few displaced nodes; a wrong/zero hint falls back to a full walk from the head — which
the caller alone pays for, and which can exceed block gas on a very long list. Rule for
integrators: always supply a computed hint. Users going through the front-end never see this
parameter.

**Q: Can my entire collateral be consumed by redemption? Does it worsen my ratio?**
No and no. Seizure is bounded by your **debt** (at most $1 of collateral per 1 eUSD of debt
retired) — equity above debt is untouchable. And removing equal dollar amounts of debt and
collateral from an overcollateralized position strictly *raises* its ratio:
$1,400/$1,000 = 140% → after $500 redeemed → $900/$500 = 180% → full redemption → $400
collateral, zero debt. Redemption is forced fair-price deleveraging; it can never push a healthy
position toward liquidation. Only an already-underwater head position behaves differently — the
redeemer takes all of its collateral but burns only that collateral's value in eUSD; the unbacked
debt residual stays on the owner's books off the sorted list (clearable by repay, close,
liquidation, or a collateral top-up, which re-lists it) and the redemption walks on to the next
position. A redeemer is therefore never charged for collateral they do not receive.

**Q: With two collaterals (say eSPY and eQQQ), does a redeemer receive both tokens?**
No. Redemption is per collateral: the caller passes the collateral address, each collateral keeps
its own sorted list, and the redeemer receives only that token. "Riskiest-first" is ordered
within one collateral, never across collaterals — redeeming against both takes two calls.
Consequences: an underwater eSPY list never blocks eQQQ redemptions (or the reverse); peg
arbitrageurs gravitate to whichever collateral they can sell most easily, so the more liquid
collateral absorbs most redemption pressure. Same branch model as Liquity v2.

---

## How this differs from Liquity

Same skeleton — overcollateralized CDPs, sorted-list riskiest-first redemption as the peg floor,
hint-based insertion, value-neutral redemption math, keeper liquidations with surplus refund,
min-debt dust guard. Five real divergences (vs Liquity v1 unless noted):

1. **Market-hours price asymmetry** (our biggest structural addition). Liquity prices ETH 24/7;
   our collateral stops trading nights/weekends. Every action splits by risk direction:
   risk-increasing (mint, withdraw-against-debt) needs a fresh in-session price (≤ 15 min);
   exits (repay, close, redeem, liquidate) work off-hours against the last anchor with **no age
   bound** — the unblockable-exit rule. No Liquity equivalent; designed from scratch.
2. **No Stability Pool — direct keeper liquidation.** Liquity v1 liquidations are absorbed by
   the Stability Pool (with trove redistribution as fallback). Ours: keeper burns the full debt
   from their own eUSD and takes collateral worth debt × 1.05. Far less code (the SP is where
   Liquity v2's critical bug lived), but liquidations depend on keepers holding eUSD inventory
   at crisis moments — no pre-funded pool, no redistribution fallback.
3. **Interest model.** Liquity v1: no recurring interest — one-time borrow fee + redemption fee,
   both floating with an algorithmic `baseRate`. Ours: zero mint fee, zero redemption fee, fixed
   2%/yr stability fee accrued lazily into debt and minted to the treasury. Consequences: our
   redemption pays exactly $1.00 of collateral per eUSD (no redemption-fee damper against
   redemption cascades), and fee revenue goes to the treasury, not token stakers. (Liquity v2's
   user-set rates + rate-ordered redemption deliberately not adopted — we keep v1's simpler
   ratio ordering.)
4. **Governance & parameters.** Liquity is fully immutable, no admin. Ours is admin-configured
   via ProtocolRegistry roles (risk params, ceiling, minDebt, price max-age, collateral
   add/enable, operator mint-pause) — adaptable for equity collateral and multi-collateral, but
   a different trust model. No Recovery Mode; the levers are debt ceiling, mint pause, and
   per-collateral disable.
5. **Softer peg ceiling.** Liquity's $1.10 hard ceiling comes from mint-to-sell arb at 110% MCR;
   at 150% MCR our theoretical ceiling is ~$1.50, dampened in practice only by capital-heavy
   minting arb. Below-peg is equally hard-floored in both (redemption). A future USDG PSM closes
   the gap from both sides.

Smaller deltas: multi-collateral by design (per-collateral lists/configs; Liquity v1 is
ETH-only forever); eUSD carries ERC-7802 bridge rails with per-bridge rate limits and a global
net-bridged-in cap (LUSD is a plain ERC-20); liquidation threshold/MCR at 130/150 vs Liquity's
110; minDebt 100 eUSD vs ~2,000 LUSD; no separate gas-compensation reserve (liquidation bonus +
minDebt cover it).
