# Order Execution — Own Protocol v2

## Overview

The protocol uses an escrow + claim marketplace for minting and redeeming eTokens. There is a single vault backed by ETH collateral on Base, one payment token (updatable), and one vault manager (VM, swappable). All stablecoins received from orders flow to the VM.

Orders have a single type with two parameters: **price** (limit) and **expiry**. Execution price is always the set price once an order is claimed.

---

## Price Semantics

**Mint** (user buys eTokens with stablecoins):
- `price` = maximum price per eToken the user will pay
- VM only claims when market price <= set price (operational rule)
- Execution is always at the **set price**
- VM captures the spread between market and set price

**Redeem** (user sells eTokens for stablecoins):
- `price` = minimum price per eToken the user will accept
- VM only claims when market price >= set price (operational rule)
- Execution is always at the **set price**

**No partial fills.** VM claims the full order or nothing.

---

## Order States

| State | Terminal | Who Triggers | Description |
|-------|----------|--------------|-------------|
| Open | No | User | Order placed, funds escrowed |
| Claimed | No | VM | VM committed to execute |
| Confirmed | Yes | VM | Execution complete (happy path) |
| Cancelled | Yes | User | User cancelled before claim |
| Expired | Yes | Anyone | Unclaimed order past deadline, clean refund |
| Closed | Yes | VM | VM returned funds for expired claimed order |
| ForceExecuted | Yes | User | User forced execution after grace period |

---

## State Machine

```
                                  ┌─ VM confirms ──────────→ [Confirmed]
                                  │
            ┌─ VM claims ─→ [Claimed] ─ expires ─→ VM closes ──→ [Closed]
            │                     │                      │
            │                     │               grace period passes
[Open] ─────┤                     │                      │
            │                     └──────────────→ [ForceExecuted]
            │
            ├─ user cancels ──→ [Cancelled]
            │
            ├─ expires ────────→ [Expired]
            │
            └─ (redeem only) protocol threshold, no claim
                               → [ForceExecuted]
```

---

## Mint Order Flow

### Happy Path

1. User calls `placeMintOrder(asset, amount, price, expiry)`
   - Stablecoins deposited into escrow
   - Order status: **Open**

2. VM calls `claimOrder(orderId)`
   - Stablecoins (minus escrowed fee) transferred to VM
   - Fee held in contract escrow
   - VM hedges off-chain immediately using own capital
   - Order status: **Claimed**

3. VM calls `confirmOrder(orderId)`
   - eTokens minted at **set price**: `eTokenAmount = (netStablecoin * 1e18) / setPrice`
   - Escrowed fee deposited to vault (3-way split: protocol/VM/LP)
   - Order status: **Confirmed**

### Expiry — Unclaimed

- Order deadline passes, no VM claim
- Anyone calls `expireOrder(orderId)`
- Escrowed stablecoins returned to user
- Order status: **Expired**

### Expiry — Claimed, VM Closes

- VM claimed but price never became executable, order deadline passes
- VM calls `closeOrder(orderId)` — stablecoins transferred back to user **in that transaction**
- Escrowed fee returned to user
- VM unwinds its hedge (off-chain, VM's problem)
- Order status: **Closed**

### Force Execution — VM Fails to Confirm or Close

Triggered when: VM claimed but hasn't confirmed or closed, and **protocol grace period** has passed since claim.

User calls `forceExecute(orderId, ohlcProofData)` with OHLC price proof for [claimTime, now]:

- **Set price WAS reachable** (price fell within OHLC range):
  - eTokens minted at set price
  - **No fees charged**
  - VM now has unhedged exposure (their problem)
  - Order status: **ForceExecuted**

- **Set price was NOT reachable**:
  - User receives original stablecoin value as ETH collateral from vault
  - ETH amount = `stablecoinValue / ethPrice`
  - **No fees charged**
  - Order status: **ForceExecuted**

### User Cancels (Before Claim Only)

- User calls `cancelOrder(orderId)` while status is Open
- Escrowed stablecoins returned
- Order status: **Cancelled**

---

## Redeem Order Flow

### Happy Path

1. User calls `placeRedeemOrder(asset, amount, price, expiry)`
   - eTokens deposited into escrow
   - Order status: **Open**

2. VM calls `claimOrder(orderId)`
   - eTokens remain in escrow
   - VM sells underlying off-chain, prepares stablecoins
   - Order status: **Claimed**

3. VM calls `confirmOrder(orderId)`
   - VM sends stablecoins to user: `payout = eTokenAmount * setPrice - fees`
   - eTokens burned from escrow
   - Fees deposited to vault
   - Order status: **Confirmed**

### Expiry — Unclaimed

- Order deadline passes, no VM claim
- Anyone calls `expireOrder(orderId)`
- Escrowed eTokens returned to user
- Order status: **Expired**

### Expiry — Claimed, VM Closes

- VM claimed but price never became executable, order deadline passes
- VM calls `closeOrder(orderId)` — eTokens returned to user
- VM unwinds off-chain (their problem)
- Order status: **Closed**

### Force Execution — Claimed, VM Fails to Confirm or Close

Same trigger as mint: grace period passed since claim, VM silent.

User calls `forceExecute(orderId, ohlcProofData)`:

- **Set price WAS reachable**:
  - User receives ETH collateral equivalent: `eTokenAmount * setPrice / ethPrice`
  - eTokens burned
  - **No fees charged**
  - Order status: **ForceExecuted**

- **Set price was NOT reachable**:
  - eTokens returned to user
  - Order status: **ForceExecuted**

### Force Execution — Never Claimed, Protocol Threshold Passes

If VM ignores a redeem order entirely and the **protocol claim threshold** passes:

User calls `forceExecute(orderId, ohlcProofData)` with proof for [placementTime, now]:

- **Set price WAS reachable**:
  - User receives ETH collateral equivalent: `eTokenAmount * setPrice / ethPrice`
  - eTokens burned
  - **No fees charged**
  - Order status: **ForceExecuted**

- **Set price was NOT reachable**:
  - eTokens returned to user
  - Order status: **ForceExecuted**

### User Cancels (Before Claim Only)

- User calls `cancelOrder(orderId)` while status is Open
- Escrowed eTokens returned
- Order status: **Cancelled**

---

## Protocol Parameters

| Parameter | Description |
|-----------|-------------|
| `gracePeriod` | Time after claim before user can force-execute |
| `claimThreshold` | Time after placement before unclaimed redeem can be force-executed |
| `paymentToken` | Single accepted stablecoin (updatable) |

---

## OwnMarket Interface (Simplified)

```
// User actions
placeMintOrder(asset, amount, price, expiry) -> orderId
placeRedeemOrder(asset, amount, price, expiry) -> orderId
cancelOrder(orderId)                           // before claim only
forceExecute(orderId, ohlcProofData)           // after grace/threshold

// VM actions
claimOrder(orderId)                            // full fill only
confirmOrder(orderId)                          // execute at set price
closeOrder(orderId)                            // return funds for expired claimed order

// Permissionless
expireOrder(orderId)                           // unclaimed + past deadline
```

---

## Key Design Decisions

1. **Execution always at set price** — once claimed, the price is locked. No oracle needed at confirm.
2. **Stablecoins to VM on claim** — VM gets capital immediately to hedge. `closeOrder` and `forceExecute` are the safety mechanisms.
3. **No partial fills** — single VM, takes full order or nothing.
4. **Cancel before claim only** — after claim, VM has committed and may have hedged.
5. **Force execution is the user's backstop** — incentivizes VM to confirm or close promptly.
6. **No fees on forced execution** — penalty for VM non-performance.
7. **OHLC oracle proof** — used to determine if set price was reachable during the claim window. Exact oracle mechanics TBD.
