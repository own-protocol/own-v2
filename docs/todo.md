# Own Protocol v2 — Implementation Tracker

## Legend

- [x] Done
- [ ] Todo
- 🔄 In Progress

---

## Completed

- [x] Architecture refactor (1:1 VM-vault, removed spread, async LP deposits)
- [x] Protocol Registry (timelock, getters, unit tests)
- [x] Fee Calculator (per-asset mint/redeem fees via volatility level)
- [x] EToken with dividend support (rewards-per-share for dividend-paying assets)
- [x] Types & interfaces simplified (Order struct, OrderStatus enum, no PriceType/ClaimInfo)
- [x] VaultManager simplified (removed off-market, payment token acceptance, single VM)
- [x] OwnVault simplified (single payment token, fee flush before token swap)
- [x] OwnMarket rewritten (new order execution: claim/confirm/close/forceExecute)

---

## Phase 1: Protocol Parameters & Controls

### 1.1 LP Exit Wait Period

- [ ] Add configurable `withdrawalWaitPeriod` to OwnVault
- [ ] Enforce in `fulfillWithdrawal()` — revert if wait period not elapsed
- [ ] Post-withdrawal utilisation check

### 1.2 Vault Exposure Enforcement

- [ ] Enforce `maxUtilization` on new claims in OwnMarket
- [ ] Verify exposure tracking on claim/confirm/close/forceExecute paths

---

## Phase 2: Testing

### 2.1 Unit Tests

- [ ] OwnMarket: all functions and revert paths
- [ ] OwnVault: single payment token, fee flush, setPaymentToken
- [ ] VaultManager: simplified registration and exposure

### 2.2 Integration Tests

- [ ] Full mint happy path (place → claim → confirm)
- [ ] Full redeem happy path (place → claim → confirm)
- [ ] Mint expiry paths (unclaimed, claimed+closed, force-executed)
- [ ] Redeem expiry paths (unclaimed, claimed+closed, force-executed, never-claimed threshold)
- [ ] Cancel before claim
- [ ] Fee flow end-to-end (deposit → 3-way split → claim)
- [ ] Payment token swap (flush → set new token)

### 2.3 Invariant Tests

- [ ] Escrow integrity: funds in escrow match pending orders
- [ ] eToken supply matches confirmed mints minus confirmed redeems
- [ ] Vault health factor >= 1.0 or halted
- [ ] No funds permanently locked in contract

---

## Phase 3: Oracle Integration

### 3.1 Pyth as Primary Oracle

- [ ] Integrate Pyth Network as primary price source
- [ ] Pyth price feeds for asset prices (eToken underlyings)
- [ ] Pyth ETH/USD feed for collateral conversion in force execution
- [ ] Handle Pyth confidence intervals and staleness

### 3.2 In-House Off-Chain Oracle (Backup)

- [ ] Signed off-chain oracle for custom assets not on Pyth
- [ ] Retain existing ECDSA-signed price verification pattern
- [ ] Oracle selector logic: use Pyth when available, fall back to in-house

### 3.3 OHLC Price Proof

- [ ] Extend oracle system to support OHLC price proofs for a time range
- [ ] Implement `_verifyOHLCProof()` in OwnMarket for force execution
- [ ] Determine OHLC source (Pyth historical or in-house signed candles)

---

## Phase 4: Force Execution & Collateral Release

### 4.1 Vault Collateral Release

- [ ] Add `releaseCollateral(address to, uint256 amount)` to OwnVault (restricted to OwnMarket)
- [ ] Force mint (price not reachable): release ETH worth the stablecoin value
- [ ] Force redeem (price reachable): release ETH worth `eTokenAmount * setPrice`
- [ ] Update vault health/exposure tracking on collateral release

### 4.2 Complete Force Execution

- [ ] Wire `_forceExecuteAtSetPrice()` to vault collateral release for redeems
- [ ] Wire `_forceExecuteRefund()` to vault collateral release for mints
- [ ] ETH/USD price conversion using Pyth feed

---

## Phase 5: Cleanup & Deploy

### 5.1 Code Cleanup

- [ ] Replace all `require` strings with custom errors
- [ ] Update AGENTS.md to reflect new architecture
- [ ] Natspec review — remove unnecessary notes, ensure clear purpose
- [ ] Remove dead code from old multi-VM / multi-collateral model

### 5.2 Deployment

- [ ] Deploy script for Base
- [ ] Testnet deployment + smoke test
