# Chainlink Feeds on Robinhood Chain — Discovery (2026-07-19)

Groundwork for the oracle migration (Chainlink primary + in-house signer off-hours).
Verify live state any time with `script/robinhood/CheckChainlinkFeedsRobinhood.s.sol`.

Source of truth for the full list (55 feeds): Chainlink reference data directory,
`feeds-robinhood-mainnet`. All prices below are USD, 8 decimals, 0.5% deviation trigger,
24h heartbeat.

## Feeds we use

| Asset | Description            | Proxy                                        |
| ----- | ---------------------- | -------------------------------------------- |
| MU    | RHMU / USD             | `0x425EEFdCf05ed6526C3cE61Af99429A228a6d596` |
| SPCX  | Robinhood SPCX / USD   | `0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb` |
| MSFT  | RHMSFT / USD           | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` |
| GOOGL | Robinhood GOOGL / USD  | `0xF6f373a037c30F0e5010d854385cA89185AE638b` |
| TSLA  | RHTSLA / USD           | `0x4A1166a659A55625345e9515b32adECea5547C38` |
| SPY   | RHSPY / USD            | `0x319724394D3A0e3669269846abE664Cd621f9f6A` |
| QQQ   | Robinhood QQQ / USD    | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` |
| USDG  | USDG / USD             | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` |

Descriptions are not uniform (`RH<SYM>` vs `Robinhood <SYM>`) — pin the exact string when
asserting. No L2 sequencer uptime feed exists on this chain as of 2026-07-19.

## Price semantics: token price, multiplier included

Stock feeds return the **token** price = underlying share price x the ERC-8056
`uiMultiplier()` (per docs.robinhood.com/chain/oracles-and-price-feeds). The multiplier is
readable on each Gen-2 token contract (1e18 fixed point; 1.0 for all assets so far). So both
quantities are derivable on-chain:

- wrapper (r.TSLA) price = feed answer, as-is
- underlying (TSLA) price = feed answer x 1e18 / `token.uiMultiplier()`

During a corporate action the feed **pauses** and resumes after the multiplier updates —
fail-safe for consumers with staleness checks, but expect multi-hour gaps around splits and
special dividends.

## Measured update cadence (round history Jun 22 – Jul 19 2026)

Updates are deviation-driven (0.5%); the 24h heartbeat only fires **within** market sessions.

- **Trading week (24/5):** stock feeds update from Mon 00:00 UTC (Sun 8pm ET session open)
  until Fri ~20:00 UTC (4pm ET close), then go fully silent. Weekend silence measured
  48–56h; July 4 long weekend 73–79h.
- **Intraweek gaps are large:** median gap ~10–100 min, but quiet stretches of 5–21h occur
  routinely (deviation feed + calm price). Feed `updatedAt` staleness therefore does NOT
  distinguish "market open" from "market closed" on timescales under ~24h.
- **Value freshness vs timestamp freshness:** while the market is open, the last answer is
  by construction within 0.5% of spot no matter how old `updatedAt` is; worst-case
  timestamp age intraweek is bounded by the 24h heartbeat.
- **USDG/USD is a 24/7 feed** updating exactly every 24h (heartbeat only; observed moves
  ≤0.05%, never hits the deviation trigger). Any staleness bound for USDG must exceed 24h.
- Pre-launch rounds (before Jun 23 13:52 UTC) published 18-dec values before switching to
  8-dec — ignore round history before that when backtesting.

## Hybrid oracle design (decided 2026-07-19, implemented in ChainlinkOracleVerifier)

No market calendar. The security boundary is the **band**, not the schedule:

1. **Silence gate (per-asset, admin-set `clSilence`, e.g. 15 min):** the in-house signer's
   quotes are accepted only while the asset's Chainlink feed has been silent longer than
   `clSilence`. Since intraweek quiet stretches exceed this routinely, the signer *can*
   quote mid-session — accepted deliberately, because every accepted quote is capped by:
2. **Anchor band (per-asset `bandBps`):** a signed price must sit within `bandBps` of the
   last Chainlink answer (the anchor). Anchor validity is capped by `maxAnchorAge`
   (must cover ~80h long weekends); no anchor → no in-house quotes (fail closed).
   `bandBps = 0` disables the in-house leg entirely (USDG).
3. **Timestamp clamping (`clFreshWindow`, default 4h):** while a Chainlink answer is
   younger than `clFreshWindow` its value is within the 0.5% deviation band of spot, so
   reads report `block.timestamp`; beyond that the raw `updatedAt` is reported and consumer
   staleness checks (`priceMaxAge`, `maxMarkAge`) naturally fail over to the in-house leg.
   Note: mid-week quiet stretches of 5–21h are routine (p90 gap ~3.4h on TSLA), so with a
   4h window the signer service actively fills in-session gaps — it must run 24/7. The
   short window also caps the dead-feed exposure (see audit CL-L03 in
   chainlink-audit-report.md).
4. **verifyPrice precedence:** feed fresh (≤ `clSilence`) → Chainlink, proof ignored;
   feed silent + proof supplied → verified in-house leg (band-checked); empty proof →
   Chainlink up to `clFreshWindow`.
5. **Multiplier split:** underlying tickers (TSLA) set `multiplierToken` so reads divide
   the feed by the token's live `uiMultiplier()`; wrapper tickers (r.TSLA) read the feed
   as-is. Both may share one aggregator.
