# Own Protocol v2 — Implementation Tracker

## Legend

- ✅ Done
- 🔲 Todo
- 🚧 In Progress

---

## Completed

- ✅ All interfaces, contracts, unit tests, integration tests (initial build)
- ✅ Architecture refactor (1:1 VM-vault, removed spread, async LP deposits)
- ✅ Protocol Registry (timelock, getters, unit tests)
- ✅ Fee Calculator (per-asset mint/redeem fees via volatility level)
- ✅ Fee wiring in OwnMarket (mint fee escrowed at claim, redeem fee at confirm)
- ✅ Per-vault fee accrual (3-way split: protocol/VM/LP — Uniswap-style, replaces FeeAccrual contract)
- ✅ LP rewards-per-share accumulator (multi-token, auto-settle on transfer, auto-claim on withdrawal)
- ✅ Per-vault payment token management (VM-controlled, max 3, replaces PaymentTokenRegistry)
- ✅ Removed FeeAccrual and PaymentTokenRegistry contracts

---

## Phase 1: Core MVP — Deployment Ready

### 1.1 Order Validation

_Ensure all orders and claims are properly validated before execution._

- 🔲 **Placement validation** — asset active + stablecoin accepted by at least one vault
- 🔲 **Claim validation** — VM registered & active, asset active, payment token accepted by VM's vault, resolve vault
- 🔲 **Price validation on confirm** — slippage check (market orders), limit price check (limit orders)
- 🔲 **Redeem refunds** — return escrowed eTokens on cancel & expire

### 1.2 Vault Exposure & Utilisation

_Track and enforce exposure limits so vaults stay solvent._

- 🔲 Track per-vault total committed USD (update on mint/redeem confirm)
- 🔲 Enforce utilisation cap on `claimOrder()` — reject if vault would exceed `maxUtilization`
- 🔲 Vault halt + per-asset halt checks in `claimOrder()`

### 1.3 LP Exit Wait Period

_Mandatory queue time before LP withdrawals can be fulfilled._

- 🔲 Add configurable `withdrawalWaitPeriod` (governance-set)
- 🔲 Enforce in `fulfillWithdrawal()` — revert if wait period not elapsed
- 🔲 Post-withdrawal utilisation check

### 1.4 Redemption Enforcement

_LP collateral liquidated when VM fails to confirm a claimed redemption in time._

- 🔲 Add `redemptionGracePeriod` (e.g., 4 hours during market hours)
- 🔲 Trigger Tier 3 liquidation in `expireOrder()` for unconfirmed redeems past grace period
- 🔲 Integration test: redeem claim → VM fails to confirm → liquidation → user paid

### 1.5 VM Strategy Declaration

_VMs declare delta neutral or short position. Informational in MVP, designed for future enforcement._

- 🔲 Add `VMStrategy` enum to Types.sol (DeltaNeutral, Short)
- 🔲 Add strategy field to VM registration flow
- 🔲 Emit event on strategy declaration

### 1.6 Oracle & Utilisation Service

_Signed utilisation data from protocol service, with on-chain sanity check._

- 🔲 Add `verifyUtilisation(address vault, bytes calldata data)` to IOracleVerifier
- 🔲 On-chain `totalCommittedUSD` counter as sanity check / circuit breaker against signed utilisation
- 🔲 Staleness + divergence checks for utilisation data

### 1.7 Cleanup & Errors

- 🔲 Replace remaining `require` strings with custom errors across all contracts
- 🔲 Update AGENTS.md to reflect removed FeeAccrual/PaymentTokenRegistry

### 1.8 Fix Tests

- 🔲 Update all tests for new OwnVault constructor (protocolShareBps, vmShareBps params)
- 🔲 Update all tests to remove FeeAccrual/PaymentTokenRegistry references
- 🔲 All tests green (`forge test`)

### 1.9 Deployment

- 🔲 Deploy script
- 🔲 Testnet deployment + smoke test
