# Oracle Architecture — Own Protocol v2

## Overview

The protocol uses a dual-oracle system per asset. Each asset can have a **primary** and **secondary** oracle source. The admin controls which is primary. This allows using Pyth for assets with established feeds and an in-house signed oracle for custom assets not available on Pyth.

---

## Oracle Sources

### Pyth Network (Primary for standard assets)

- Pull-based oracle — price updates submitted on-chain by users/keepers
- Provides `parsePriceFeedUpdates()` to verify prices within a time window
- Each asset maps to a Pyth price feed ID (bytes32)
- Used for: TSLA, GOLD, ETH/USD, and any asset with a Pyth feed
- Contract: deployed on Base at a known address

### In-House Signed Oracle (Backup / custom assets)

- ECDSA-signed price messages from authorized signers
- Supports custom assets not available on Pyth (e.g. private market tokens)
- Enforces staleness bounds, deviation limits, monotonic sequence numbers
- Existing `OracleVerifier.sol` implementation

---

## Per-Asset Oracle Configuration

Stored in `AssetRegistry` alongside existing `AssetConfig`:

```
struct OracleConfig {
    address primaryOracle;     // IOracleVerifier implementation
    address secondaryOracle;   // IOracleVerifier implementation (can be address(0))
    bytes32 pythPriceFeedId;   // Pyth feed ID (bytes32(0) if not using Pyth)
}
```

Admin can:
- Set primary and secondary oracle per asset
- Switch which is primary via `setPrimaryOracle(ticker, oracle)`
- Configure Pyth feed IDs per asset

---

## IOracleVerifier Interface

Both Pyth and in-house oracle implement the same interface:

```
verifyPrice(asset, priceData) → (price, timestamp, marketOpen)
```

The `priceData` is opaque — each backend decodes differently:
- **Pyth**: encoded Pyth update data + price feed ID
- **In-house**: ECDSA-signed payload (price, timestamp, marketOpen, sequenceNumber, signature)

---

## Price Range Verification (Force Execution)

Force execution needs to prove whether the set price was reachable during a time window.

### Mechanism

The user submits two price proofs:
1. A **low price proof** — a valid oracle price with timestamp in the window
2. A **high price proof** — a valid oracle price with timestamp in the window

The contract verifies:
1. Both proofs are valid signed oracle data (verified by the asset's primary oracle)
2. Both timestamps fall within [windowStart, windowEnd]
3. `lowPrice ≤ highPrice` (sanity check)

Then checks:
- **Mint**: `lowPrice ≤ setPrice` → price was reachable (market dropped to or below user's max)
- **Redeem**: `highPrice ≥ setPrice` → price was reachable (market rose to or above user's min)

### For Pyth

User calls `parsePriceFeedUpdates(updateData, priceIds, minPublishTime, maxPublishTime)` to get verified prices within the time bounds. The contract uses the same Pyth function to verify.

### For In-House Oracle

User submits two ECDSA-signed price payloads. The contract verifies signatures and checks timestamps.

---

## ETH/USD Price (Collateral Conversion)

Force execution may require converting stablecoin value or eToken value to ETH collateral. The ETH/USD price is fetched from:

- A dedicated ETH/USD oracle configured at the protocol level
- Uses the same `IOracleVerifier.verifyPrice()` interface with asset = bytes32("ETH")
- Or direct Pyth feed read via `getPriceNoOlderThan(ethFeedId, maxAge)`

---

## Architecture Diagram

```
                    ┌─────────────────┐
                    │  AssetRegistry  │
                    │                 │
                    │ TSLA → OracleConfig {
                    │   primary: PythOracle
                    │   secondary: InHouseOracle
                    │   pythFeedId: 0x...
                    │ }                │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
    ┌─────────▼──────┐  ┌───▼───────────┐  │
    │ PythOracle     │  │ InHouseOracle │  │
    │ (IOracleVerifier) │ (IOracleVerifier) │
    │                │  │               │  │
    │ wraps IPyth    │  │ ECDSA signed  │  │
    │ on Base        │  │ prices        │  │
    └────────────────┘  └───────────────┘  │
                                           │
                    ┌──────────────────────▼┐
                    │     OwnMarket         │
                    │                       │
                    │ forceExecute():       │
                    │  1. get primary oracle│
                    │  2. verify low price  │
                    │  3. verify high price │
                    │  4. check range       │
                    └───────────────────────┘
```

---

## Key Design Decisions

1. **Dual oracle per asset** — primary + secondary, admin-switchable. Allows graceful degradation and migration.
2. **Same interface for all backends** — `IOracleVerifier.verifyPrice()` is backend-agnostic. Downstream contracts don't know which oracle produced the data.
3. **User submits price proofs** — for force execution, the user finds two prices that bracket the set price. The contract only verifies validity and time bounds.
4. **No on-chain OHLC** — we don't need OHLC candles. Two point-in-time price proofs are sufficient to prove reachability.
5. **Pyth as primary for standard assets** — reliable, decentralized, widely available feeds.
6. **In-house as backup** — for custom assets or if Pyth is unavailable for a specific asset.
