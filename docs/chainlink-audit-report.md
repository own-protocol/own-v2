# ChainlinkOracleVerifier — Audit Findings (2026-07-19)

Internal security review of `src/core/ChainlinkOracleVerifier.sol` (Chainlink-primary oracle with
band-limited in-house fallback) performed at implementation time, before deployment. Design
context: `docs/chainlink-feeds-robinhood.md`.

Summary: **0 critical, 0 high, 0 medium, 3 low, 4 info.** All findings acknowledged. One
dead-code item fixed during the review; test gaps closed in the same change set (49 tests:
unit + fuzz + integration + live-fork).

## Findings

### CL-L01 — Reverting aggregator bricks both legs, including a fresh in-house price
`_chainlink()` lets `latestRoundData()` reverts bubble up. A *stale* feed correctly fails over
to the in-house leg, but a *reverting* one (unset/bricked proxy) DoSes `getPrice` and blocks
`updatePrice` (the anchor read reverts before the band check). Availability-only; funds safe;
recoverable via `setChainlinkConfig` / `disableAsset`.
**Status: Acknowledged (won't fix).** Fail-closed behavior accepted; a `try/catch` fallback was
considered and declined — with no anchor the in-house leg is unusable by design anyway.

### CL-L02 — Cached `clDecimals` can rot on an aggregator upgrade
`setChainlinkConfig` caches `decimals()` once. A Chainlink aggregator upgrade behind the proxy
that changes decimals would silently mis-scale prices by 10^n. Very low probability (all
current Robinhood feeds are 8-dec); severe if it ever occurs.
**Status: Acknowledged.** Ops mitigation: monitor the proxies for aggregator changes and re-run
`setChainlinkConfig` on any upgrade (added to migration/ops checklist below).

### CL-L03 — A feed that dies mid-session reads as current for up to `clFreshWindow`
The timestamp clamp assumes "no update ⇒ price within the 0.5% deviation band," which fails if
feed infrastructure dies silently: the last answer reads as current (marks, borrows, PSM) until
`clFreshWindow` elapses. Chosen default: **4h** (reduced from the originally proposed 24.5h,
then 12h, precisely to shrink this window). A 15-min-quiet feed is indistinguishable on-chain
from a dead one, so this is inherent to the freshness semantics. Mitigations: in-house signer
can override within band after `clSilence`; instant operator `disableAsset`; consumers
independently band-check against VM marks.
**Status: Acknowledged.** Ops mitigation: feed-age alerting in the signer service, well before 4h.

### CL-I01 — Compromised-signer damage cap = `bandBps` during any quiet stretch
The silence gate opens routinely mid-session (intraweek quiet stretches of 5–21h are normal),
so a compromised signer can move the served price up to `bandBps` off the anchor whenever the
feed is >`clSilence` quiet — not only on weekends. Explicit design decision: the band, not a
market-hours schedule, is the security boundary. Second belt: BorrowManager/OwnMarket band
checks vs VM marks; instant `removeSigner` (operator).
**Status: Acknowledged (by design).**

### CL-I02 — Timestamp-ignoring consumers accept prices up to `maxAnchorAge` old
`VaultManager._resolvePrice` (mark pulls) discards the returned timestamp. Under the old
oracle, `getPrice` hard-reverted past 1h staleness; the new verifier serves the Chainlink leg
up to `maxAnchorAge` (~5 days). Intended: weekend marks should track Friday's close (the
canonical closed-market price), optionally refined by band-limited in-house quotes.
**Status: Acknowledged (by design).**

### CL-I03 — `verifyPriceForSession` self-call drops `msg.value`
`this.verifyPrice(...)` forwards no ETH. Harmless — `verifyFee` is always 0 for this verifier;
same pattern as the original `OracleVerifier`.
**Status: Acknowledged.**

### CL-I04 — Multicall + payable `verifyPrice`
OZ Multicall's known `msg.value`-reuse hazard does not apply: no function in the contract reads
`msg.value`. Verified during review.
**Status: Acknowledged (no issue).**

## Fixed during review

- Unused `NonPositiveAnswer` error removed (dead code — `_chainlink` treats non-positive
  answers as an invalid leg rather than reverting).
- Test gaps closed: multiplier×band interaction, non-8-dec feed normalization,
  `verifyPriceForSession` proof leg, multicall batch push, equal-timestamp replay skip,
  garbage-proof revert, fuzz (band boundary exactness, timestamp-window semantics), integration
  (VaultManager mark pulls through the production `PYTH_ORACLE`-slot wiring), and fork tests
  against the live RHTSLA / USDG feeds + live `uiMultiplier()` on chain 4663.

## Verified non-issues

- Reentrancy: all external calls are staticcalls; effects precede nothing observable.
- Signature replay: EIP-712 domain binds chainId + verifying contract; monotonic-timestamp
  guard prevents overwrite replays; per-asset digest prevents cross-asset replay.
- Circuit-breaker pinning: live TSLA aggregator has `minAnswer = 1`, `maxAnswer = int192.max`
  — LUNA-style pinned-price scenarios not possible on these feeds (checked on-chain 2026-07-19).
- No spot/AMM prices anywhere; flash-loan surface absent.

## Migration / ops checklist (open)

- [ ] Verify on-chain `registry.priceMaxAge` and `VaultManager.maxMarkAge` on Robinhood are
      consistent with `clFreshWindow = 4h` and the intended in-house cadence.
- [ ] Signer service: 24/7 operation, band pre-check before signing, feed-age alerting (<4h),
      aggregator-upgrade monitoring on all feed proxies (CL-L02).
