# Own Protocol v2 — Implementation Tracker

## Legend

- Done
- Todo
- In Progress

---

## Completed

- Architecture refactor (1:1 VM-vault, removed spread, async LP deposits)
- Protocol Registry (timelock, getters, unit tests)
- Fee Calculator (per-asset mint/redeem fees via volatility level)
- Per-vault fee accrual (3-way split: protocol/VM/LP, Uniswap-style rewards-per-share)
- LP rewards-per-share accumulator (multi-token, auto-settle on transfer, auto-claim on withdrawal)
- EToken with dividend support (rewards-per-share for dividend-paying assets)
- Oracle Verifier (signed prices, staleness, deviation, sequence replay protection)

---

## Phase 1: Simplify Architecture

_Restructure contracts to match the simplified model: single vault (ETH collateral on Base), one payment token, one VM, no partial fills._

### 1.1 Vault Simplification

- Simplify OwnVault to single collateral type (ETH/WETH)
- Single payment token (updatable by VM)
- Remove multi-payment-token support (max 3 array)
- Remove multi-collateral references from vault

### 1.2 VM Simplification

- Single VM per protocol (swappable)
- Remove multi-VM competition logic from OwnMarket
- Remove directed orders / preferredVM
- Remove partial fill support

### 1.3 Type & Interface Cleanup

- Remove PriceType enum (Market/Limit) — single order type with price + expiry
- Remove slippage field from Order struct
- Remove allowPartialFill from Order struct
- Remove preferredVM from Order struct
- Simplify OrderStatus enum: Open, Claimed, Confirmed, Cancelled, Expired, Closed, ForceExecuted
- Update Order struct to match new model
- Update ClaimInfo struct (single claim per order, no multi-claim)

---

## Phase 2: New Order Execution Flow

_Implement the order lifecycle as defined in `docs/order-execution.md`._

### 2.1 Place Order

- `placeMintOrder(asset, amount, price, expiry)` — escrow stablecoins
- `placeRedeemOrder(asset, amount, price, expiry)` — escrow eTokens
- Validate: amount > 0, expiry > now, valid asset, valid payment token

### 2.2 Claim Order

- `claimOrder(orderId)` — VM only, full fill
- Mint: transfer stablecoins (minus fee) to VM, hold fee in escrow
- Redeem: eTokens stay in escrow
- Update exposure tracking

### 2.3 Confirm Order

- `confirmOrder(orderId)` — VM only
- Mint: mint eTokens at set price, deposit escrowed fee to vault
- Redeem: VM sends stablecoins at set price (minus fee) to user, burn eTokens, deposit fee to vault
- No oracle price needed at confirm (execution at set price)

### 2.4 Cancel Order

- `cancelOrder(orderId)` — user only, Open status only
- Return escrowed stablecoins (mint) or eTokens (redeem)

### 2.5 Expire Order

- `expireOrder(orderId)` — permissionless, past deadline, Open status only
- Return escrowed stablecoins (mint) or eTokens (redeem)

### 2.6 Close Order

- `closeOrder(orderId)` — VM only, Claimed status, past deadline
- Mint: VM returns stablecoins to user in same txn, escrowed fee returned to user
- Redeem: eTokens returned to user

### 2.7 Force Execute

- `forceExecute(orderId, ohlcProofData)` — user only, after grace period
- Works for claimed orders (mint & redeem) after grace period
- Works for unclaimed redeem orders after protocol claim threshold
- Price reachable: mint eTokens (mint) or liquidate collateral (redeem), no fees
- Price not reachable: return original value in ETH collateral (mint) or return eTokens (redeem)
- Needs ETH/USD price feed for collateral conversion

---

## Phase 3: Protocol Parameters & Controls

### 3.1 Grace Period & Thresholds

- Add `gracePeriod` — time after claim before force execution allowed
- Add `claimThreshold` — time after placement before unclaimed redeem can be force-executed
- Governance-settable via ProtocolRegistry or admin

### 3.2 LP Exit Wait Period

- Add configurable `withdrawalWaitPeriod`
- Enforce in `fulfillWithdrawal()` — revert if wait period not elapsed
- Post-withdrawal utilisation check

### 3.3 Vault Exposure & Utilisation

- Track exposure on claim, reduce on confirm/close/forceExecute
- Enforce maxUtilization on new claims

---

## Phase 4: Oracle

### 4.1 Pyth as Primary Oracle

- Integrate Pyth Network as primary price source
- Use Pyth for asset prices (eToken underlying) and ETH/USD
- Handle Pyth price confidence intervals and staleness

### 4.2 In-House Off-Chain Oracle (Backup)

- Signed off-chain oracle as fallback for custom assets not on Pyth
- Retain existing ECDSA-signed price verification
- Oracle selector logic: use Pyth when available, fall back to in-house

### 4.3 OHLC Price Support

- Extend oracle system to support OHLC price proofs for a time range
- Used by `forceExecute` to prove set price was reachable
- Determine OHLC source (Pyth historical or in-house signed candles)

### 4.4 ETH/USD Price Feed

- Pyth ETH/USD feed for collateral conversion in force execution

---

## Phase 5: Testing

### 5.1 Unit Tests

- All new/modified contract functions
- Every revert path and custom error
- Boundary conditions (zero amounts, exact deadlines, grace period edges)

### 5.2 Integration Tests

- Full mint happy path (place → claim → confirm)
- Full redeem happy path (place → claim → confirm)
- Mint expiry paths (unclaimed, claimed+closed, force-executed)
- Redeem expiry paths (unclaimed, claimed+closed, force-executed, never-claimed threshold)
- Cancel before claim
- Fee flow end-to-end

### 5.3 Invariant Tests

- Escrow integrity: funds in escrow match pending orders
- eToken supply matches confirmed mints minus confirmed redeems
- Vault health factor >= 1.0 or halted
- No funds permanently locked in contract

---

## Phase 6: Cleanup & Deploy

### 6.1 Code Cleanup

- Replace all `require` strings with custom errors
- Update AGENTS.md to reflect new architecture
- Remove dead code from old multi-VM / multi-collateral model

### 6.2 Deployment

- Deploy script for Base
- Testnet deployment + smoke test
