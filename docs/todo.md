# Own Protocol v2 — Implementation Tracker

## Legend
- ✅ Done
- 🔲 Todo
- 🚧 In Progress

---

## Phase 0: Documentation & Architecture

- ✅ Define product vision (`docs/Own_Protocol_Vision.md`)
- ✅ Define MVP PRD with edge cases (`docs/Own_Protocol_MVP_PRD.md`)
- ✅ Define development configuration & standards (`AGENTS.md`)
- ✅ Architecture diagram (`docs/architecture.excalidraw`)
- ✅ Key architecture decisions:
  - ✅ Order-based escrow + claim marketplace (not instant-swap)
  - ✅ Vaults as security/guarantee pools (not fund-flow intermediaries)
  - ✅ Minters pay in any whitelisted stablecoin → stablecoins go to VMs
  - ✅ Spread (VM-side) and slippage (user-side) cleanly separated
  - ✅ No utilization curve — minSpread floor + maxUtilization cap + natural yield
  - ✅ Three-tier liquidation (eToken, organic LP, DEX fallback)
  - ✅ Async LP withdrawal (ERC-7540 FIFO queue)
  - ✅ Stock splits via soft migration + admin-updatable token name
  - ✅ Dividends via rewards-per-share accumulator
  - ✅ Flash-loan resistant by design

---

## Phase 1: Interfaces

_Interface-first development. Define all external APIs, events, errors, and structs before writing tests or implementations._

- ✅ `Types.sol` — Shared enums, structs, constants (`src/interfaces/types/Types.sol`)
- ✅ `IEToken` — ERC20 + ERC2612 Permit + admin-updatable name/symbol + rewards-per-share (dividends) + mint/burn restricted to order system
- ✅ `IOwnMarket` — Order placement (mint/redeem), claim, confirm, cancel, deadline enforcement
- ✅ `IOwnVault` — ERC-4626 vault for LP collateral. Deposit, async withdrawal queue (request/cancel/fulfill), health tracking, utilization, halt/unhalt (vault-wide + per-asset), wind-down
- ✅ `IVaultManager` — Registration, spread setting, exposure caps, accepted payment tokens, off-market toggles, delegation (propose/accept/remove), VM pause/resume
- ✅ `IAssetRegistry` — Asset whitelisting, active/legacy token tracking, collateral parameters per asset
- ✅ `IOracleVerifier` — Price verification (signature, staleness, deviation, sequence), signer management, per-asset config
- ✅ `ILiquidationEngine` — Tier 1 liquidation (eToken-based), Tier 3 fallback (DEX sale + expired redemption), health checks, reward distribution
- ✅ `IPaymentTokenRegistry` — Whitelisted payment token (stablecoin) management

---

## Phase 2: Test Helpers & Mocks

_Shared test infrastructure. Built before any contract tests._

- ✅ `BaseTest.sol` — Common setup, token deployments, actor addresses, utility functions
- ✅ `MockERC20.sol` — Configurable decimals mock token (for stablecoins, collateral)
- ✅ `MockWstETH.sol` — Mock wstETH with configurable exchange rate
- ✅ `MockAUSDC.sol` — Mock aUSDC with configurable rebasing
- ✅ `MockOracleVerifier.sol` — Returns configurable prices, simulates staleness/deviation
- ✅ `MockDEX.sol` — Mock Uniswap for Tier 3 liquidation testing
- ✅ `Actors.sol` — Predefined addresses (minter, lp1, lp2, vm1, vm2, admin, liquidator, attacker)

---

## Phase 3: Unit Tests

_One test file per contract. Mocked dependencies. Written BEFORE implementations._

- ✅ `test/unit/EToken.t.sol` — ERC20 compliance, permit, mint/burn access control, admin name/symbol update, rewards-per-share accumulator, transfer reward settlement
- ✅ `test/unit/OwnMarket.t.sol` — Place order (market/limit), claim (full/partial), confirm with oracle price, cancel, deadline expiry, directed vs open orders, partial fill logic, stablecoin routing, cross-vault claims
- ✅ `test/unit/OwnVault.t.sol` — ERC-4626 deposit/withdraw, async withdrawal queue (request/cancel/fulfill FIFO), health factor, utilization tracking, halt/unhalt, wind-down, yield-bearing share price
- ✅ `test/unit/VaultManager.t.sol` — Registration, spread setting (>= minSpread), exposure caps, accepted stablecoins, off-market toggles, delegation (propose/accept/remove), self-delegation
- ✅ `test/unit/AssetRegistry.t.sol` — Add/remove assets, active vs legacy tokens, collateral params, admin access control
- ✅ `test/unit/OracleVerifier.t.sol` — Signature verification, staleness rejection, deviation check, sequence number enforcement, chain ID validation, signer rotation
- ✅ `test/unit/LiquidationEngine.t.sol` — Tier 1 (eToken liquidation, partial, reward), Tier 3 (DEX sale fallback), health restoration check, redemption deadline trigger
- ✅ `test/unit/PaymentTokenRegistry.t.sol` — Add/remove payment tokens, whitelist checks, admin access control

---

## Phase 4: Contract Implementations

_Make the tests pass. Nothing more._

- ✅ `src/tokens/EToken.sol` — ERC20 + Permit + admin-updatable name/symbol + rewards-per-share
- ✅ `src/core/OwnMarket.sol` — Order escrow + claim marketplace
- ✅ `src/core/OwnVault.sol` — ERC-4626 security vault with async withdrawal queue
- ✅ `src/core/VaultManager.sol` — VM registration, delegation, spread/exposure management
- ✅ `src/core/AssetRegistry.sol` — Asset whitelisting and token tracking
- ✅ `src/core/OracleVerifier.sol` — Signed price verification
- ✅ `src/core/LiquidationEngine.sol` — Three-tier liquidation (stub — needs vault integration)
- ✅ `src/core/PaymentTokenRegistry.sol` — Payment token (stablecoin) whitelisting
- ✅ `src/periphery/WETHRouter.sol` — ETH ↔ WETH wrapping for ETH vault deposits
- ✅ `src/periphery/WstETHRouter.sol` — stETH ↔ wstETH wrapping for stETH vault deposits

---

## Phase 5: Integration Tests

_Multi-contract flow tests with real dependencies (no mocks)._

- ✅ `test/integration/MintFlow.t.sol` — Full mint: minter places order → VM claims → VM confirms → eTokens minted. Market + limit orders. Directed + open. (21 tests)
- ✅ `test/integration/RedeemFlow.t.sol` — Full redeem: minter places order → VM claims → VM sends stablecoins + confirms → eTokens burned. Deadline enforcement. (8 tests)
- ✅ `test/integration/LPLifecycle.t.sol` — LP deposits → delegates to VM → earns yield → requests withdrawal → withdrawal fulfilled. Async queue behavior. (15 tests)
- ✅ `test/integration/VMLifecycle.t.sol` — VM registers → sets spread/caps → claims orders → confirms → exposure tracked. Multiple VMs competing. (23 tests)
- ✅ `test/integration/LiquidationFlow.t.sol` — Vault health checks, Tier 1/3 revert on healthy vault, stub behavior documented. (10 tests)
- ✅ `test/integration/HaltFlow.t.sol` — Halt triggers → behavior during halt → unhalt → wind-down. (14 tests)
- ✅ `test/integration/CrossVault.t.sol` — VMs from different vaults competing for same order. Security attribution. (5 tests)
- ✅ `test/integration/DividendFlow.t.sol` — VM deposits dividend → holders claim → transfer settlement → new holder claims. (8 tests)
- ✅ `test/integration/MultiStablecoin.t.sol` — Orders in USDC, USDT, USDS. VM stablecoin filtering. Redeem with chosen stablecoin. (9 tests)

---

## Phase 5b: Contract Wiring & Gap Fixes

_Cross-contract integration, missing validations, and stub replacements identified during integration test audit. Each item includes updating existing unit/integration tests to cover the new behavior._

### 5b.1 — OwnMarket.confirmOrder(): Core execution logic (CRITICAL)

_Currently `confirmOrder()` only records the oracle price and marks confirmed. It must execute the actual mint/redeem._

- 🔲 Calculate eToken amount: `stablecoinAmount * decimalFactor / (executionPrice * (1 + vmSpread / BPS))` for mints
- 🔲 Call `EToken.mint(minter, eTokenAmount)` for mint orders on confirm
- 🔲 Call `EToken.burn(address(this), eTokenAmount)` for redeem orders on confirm (eTokens escrowed in market)
- 🔲 Calculate spread revenue: `stablecoinAmount * vmSpread / BPS` (split per AGENTS.md model)
- 🔲 Call `vault.distributeSpreadRevenue(lpPortion)` to increase vault share price
- 🔲 Emit `OrderConfirmed` with real `eTokenAmount` and `spreadAmount` (currently emits 0s)
- 🔲 Update unit tests in `OwnMarket.t.sol` for the new confirmOrder logic
- 🔲 Update integration tests to assert eToken balances after confirm

### 5b.2 — OwnMarket.confirmOrder(): Price validation (HIGH)

_No slippage or limit price checks exist. A VM could confirm at any price._

- 🔲 Market orders: validate `|executionPrice - placementPrice| / placementPrice <= slippage`
- 🔲 Limit orders (mint): validate `executionPrice <= limitPrice` (user pays at most limitPrice)
- 🔲 Limit orders (redeem): validate `executionPrice >= limitPrice` (user receives at least limitPrice)
- 🔲 Add unit tests for slippage exceeded revert
- 🔲 Add unit tests for limit price not met revert

### 5b.3 — OwnMarket.claimOrder(): Validation checks (HIGH)

_claimOrder performs no cross-contract validation. Any address can claim any open order._

- 🔲 Validate `assetRegistry.isActiveAsset(order.asset)` — reject claims on inactive assets
- 🔲 Validate `paymentRegistry.isWhitelisted(order.stablecoin)` — reject if stablecoin delisted
- 🔲 Validate `vaultManager.isPaymentTokenAccepted(msg.sender, order.stablecoin)` — VM must accept the stablecoin
- 🔲 Validate VM is registered and active: `vaultManager.getVMConfig(msg.sender).registered && .active`
- 🔲 Validate per-asset halt: `!vault.isAssetHalted(order.asset)`
- 🔲 Set `claim.vault` to the VM's vault address via `vaultManager.getVMVault(msg.sender)` (currently address(0))
- 🔲 Add unit tests for each new revert condition
- 🔲 Update integration tests to cover validation scenarios

### 5b.4 — OwnMarket.claimOrder(): Exposure & utilization checks (HIGH)

_No exposure cap or utilization enforcement exists. VMs can over-leverage without limit._

- 🔲 Calculate claim notional: `claimAmount * executionPrice / decimalFactor` (for exposure tracking)
- 🔲 Validate `vm.currentExposure + claimNotional <= vm.maxExposure` (or `maxOffMarketExposure` during off-hours)
- 🔲 Validate vault utilization won't exceed `vault.maxUtilization()` after this claim
- 🔲 Call `vaultManager.updateExposure(msg.sender, int256(claimNotional))` on claim
- 🔲 Call `vaultManager.updateExposure(vm, -int256(claimNotional))` on confirm (for redeems)
- 🔲 Add unit tests for exposure cap exceeded revert
- 🔲 Add unit tests for max utilization exceeded revert

### 5b.5 — OwnMarket: Redeem cancel/expiry eToken refund (HIGH)

_cancelOrder() and expireOrder() only refund stablecoins for Mint orders. Redeem orders lose escrowed eTokens._

- 🔲 In `cancelOrder()`: return escrowed eTokens for Redeem orders (`eToken.transfer(user, refundAmount)`)
- 🔲 In `expireOrder()`: return escrowed eTokens for Redeem orders
- 🔲 Add unit tests for redeem cancel eToken refund
- 🔲 Add unit tests for redeem expiry eToken refund
- 🔲 Update integration test `RedeemFlow.t.sol` (currently documents the gap with comments)

### 5b.6 — OwnMarket: Order placement validation (MEDIUM)

_No validation that asset is active or stablecoin is whitelisted when placing orders._

- 🔲 In `placeMintOrder()`: validate `assetRegistry.isActiveAsset(asset)`
- 🔲 In `placeMintOrder()`: validate `paymentRegistry.isWhitelisted(stablecoin)`
- 🔲 In `placeRedeemOrder()`: validate `assetRegistry.isActiveAsset(asset)`
- 🔲 In `placeRedeemOrder()`: validate `paymentRegistry.isWhitelisted(stablecoin)`
- 🔲 Add unit tests for inactive asset revert and non-whitelisted stablecoin revert

### 5b.7 — OwnVault: Exposure tracking (CRITICAL)

_`_totalExposure` state variable exists but is never updated. No setter method. Health factor and utilization always return trivial values._

- 🔲 Add `updateExposure(int256 delta) external onlyMarket` to OwnVault
- 🔲 Increment `_totalExposure` when mint orders are confirmed (called by market)
- 🔲 Decrement `_totalExposure` when redeem orders are confirmed
- 🔲 Decrement `_totalExposure` when liquidations occur
- 🔲 Emit `UtilizationUpdated` event (declared in IOwnVault but never emitted)
- 🔲 Add unit tests for exposure update, health factor calculation, utilization calculation
- 🔲 Update integration tests to verify health/utilization after order flows

### 5b.8 — OwnVault: Utilization-gated withdrawals (MEDIUM)

_LP withdrawals don't check if withdrawal would push vault below safety threshold._

- 🔲 In `fulfillWithdrawal()`: check that post-withdrawal health factor stays >= 1.0
- 🔲 In standard ERC-4626 `withdraw()`/`redeem()`: check utilization limits
- 🔲 `maxWithdraw()`/`maxRedeem()`: return available amount considering utilization
- 🔲 Add unit tests for withdrawal blocked by utilization

### 5b.9 — OwnVault: AUM fee auto-accrual (LOW)

_AUM fees only accrue when `accrueAumFee()` is explicitly called._

- 🔲 Call `_accrueAumFee()` at the start of `deposit()`, `withdraw()`, `redeem()`, `fulfillWithdrawal()`
- 🔲 Add unit tests for fee accrual on deposit/withdraw

### 5b.10 — LiquidationEngine: Replace all stubs (CRITICAL)

_All core functions are hardcoded stubs. No vault integration._

- 🔲 Replace `_getHealthFactor()`: call `IOwnVault(vault).healthFactor()`
- 🔲 Replace `_isLiquidatable()`: compare health factor against asset liquidation threshold from AssetRegistry
- 🔲 Replace `_getMaxLiquidatable()`: calculate amount needed to restore health above minCollateralRatio
- 🔲 `liquidate()`: burn liquidator's eTokens, transfer collateral from vault + liquidation reward
- 🔲 `dexLiquidate()`: pull collateral from vault, execute DEX swap, return stablecoins
- 🔲 `liquidateExpiredRedemption()`: integrate with OwnMarket for expired redeem orders, pay user from vault
- 🔲 Add vault reference / mapping so engine can call vault methods
- 🔲 Add unit tests for each liquidation tier with real health factor drops
- 🔲 Update integration test `LiquidationFlow.t.sol` to test actual liquidation scenarios

### 5b.11 — VaultManager.updateExposure(): Underflow protection (MEDIUM)

_Negative delta cast to uint256 can underflow if exposure tracking gets out of sync._

- 🔲 Add underflow protection: `if (uint256(-delta) > currentExposure) revert ExposureUnderflow()`
- 🔲 Add unit test for underflow scenario

### 5b.12 — OwnMarket: Market hours / off-market enforcement (HIGH)

_PRD §7 & §10.2: Oracle returns `marketOpen` boolean but OwnMarket ignores it entirely. Off-market caps and per-asset toggles are never checked._

- 🔲 In `claimOrder()`: retrieve `marketOpen` from oracle (or last known state)
- 🔲 When `!marketOpen`: enforce `vm.maxOffMarketExposure` instead of `vm.maxExposure`
- 🔲 When `!marketOpen`: check `vaultManager.isAssetOffMarketEnabled(vm, asset)` — revert if disabled
- 🔲 Add unit tests for off-market claim blocked when toggle is off
- 🔲 Add unit tests for off-market exposure cap enforcement

### 5b.13 — OwnMarket: Vault halt blocks new orders (HIGH)

_PRD §9: When a vault is halted, no new orders should be accepted for assets backed by that vault. Currently OwnMarket has no vault awareness._

- 🔲 In `claimOrder()`: resolve VM's vault via `vaultManager.getVMVault(msg.sender)`, check `vault.vaultStatus() != Halted`
- 🔲 In `claimOrder()`: check `!vault.isAssetHalted(order.asset)` (per-asset halt)
- 🔲 Errors `MarketHalted` and `AssetNotActive` are declared in IOwnMarket but never used — wire them in
- 🔲 Add unit tests for claim blocked when vault is halted
- 🔲 Add unit tests for claim blocked when specific asset is halted
- 🔲 Update integration test `HaltFlow.t.sol` to verify orders rejected during halt

### 5b.14 — OwnMarket: Spread-adjusted eToken calculation (CRITICAL)

_PRD §5: Mint price = `oraclePrice * (1 + vmSpread)`, Redeem price = `oraclePrice * (1 - vmSpread)`. This determines how many eTokens a minter gets/burns. Currently no spread math exists._

- 🔲 In `confirmOrder()` for Mint: `effectivePrice = executionPrice * (BPS + vmSpread) / BPS`
- 🔲 eToken amount for mint: `eTokenAmount = stablecoinAmount * 10^(18 - stablecoinDecimals) * PRECISION / effectivePrice`
- 🔲 In `confirmOrder()` for Redeem: `effectivePrice = executionPrice * (BPS - vmSpread) / BPS`
- 🔲 Stablecoin payout for redeem: `payout = eTokenAmount * effectivePrice / PRECISION / 10^(18 - stablecoinDecimals)`
- 🔲 Spread revenue = difference between oracle price and effective price applied to claim amount
- 🔲 VM keeps their stablecoin (profit margin from spread); LP portion sent to `vault.distributeSpreadRevenue()`
- 🔲 Handle decimal conversions correctly: USDC/USDT (6 dec) vs USDS (18 dec) vs eTokens (18 dec) vs prices (18 dec)
- 🔲 Add comprehensive unit tests with exact decimal math for each stablecoin type

### 5b.15 — OwnVault: Auto-halt on critical health (MEDIUM)

_PRD §9 & §10.5: Vault should auto-halt when health drops below critical ratio. Currently halt is only manual._

- 🔲 Define `criticalRatio` parameter per vault (e.g., 100% for stablecoins, 120% for volatile)
- 🔲 Check health after exposure updates; auto-halt if below critical
- 🔲 Add unit tests for automatic halt trigger

### 5b.16 — OwnMarket.expireOrder(): Trigger Tier 3 liquidation for redeems (HIGH)

_PRD §2 & §10.10: If VM doesn't execute a redeem within deadline, LP collateral is sold to pay the minter. Currently `expireOrder()` just marks Expired._

- 🔲 In `expireOrder()` for Redeem orders: call `liquidationEngine.liquidateExpiredRedemption(orderId, ...)`
- 🔲 Transfer stablecoin payout to the minter from liquidation proceeds
- 🔲 Burn escrowed eTokens for the fulfilled portion
- 🔲 Add integration with LiquidationEngine reference in OwnMarket
- 🔲 Add unit tests for redeem deadline → liquidation → minter payout

### 5b.17 — OwnVault: LP withdrawal reduces VM delegation tracking (LOW)

_PRD §10.3: On fulfillment — burn shares, transfer collateral, reduce delegation to VM. Currently delegation accounting is independent of withdrawals._

- 🔲 When LP shares are burned via withdrawal, signal VaultManager to adjust delegation proportions
- 🔲 Add event for delegation proportion change on withdrawal

### 5b.18 — OwnMarket: Emit PartialFillCompleted event (LOW)

_Event declared in IOwnMarket but never emitted._

- 🔲 Emit `PartialFillCompleted` in `claimOrder()` when order becomes `PartiallyClaimed`
- 🔲 Add unit test verifying event emission

### 5b.19 — OwnMarket: `vaultManager` immutable is address(0) (HIGH)

_The OwnMarket constructor accepts `vaultManager_` but it was deployed with `address(0)` in integration tests because of circular dependency (market needs vaultMgr, vaultMgr needs market). This means all VaultManager calls from OwnMarket would revert._

- 🔲 Resolve the circular dependency: either make `vaultManager` settable post-deploy (admin setter), or deploy with a two-phase initialization pattern
- 🔲 Same issue exists for LiquidationEngine reference — OwnMarket has no reference to it at all
- 🔲 Add `liquidationEngine` address to OwnMarket (needed for `expireOrder` Tier 3)
- 🔲 Add admin setter functions: `setVaultManager(address)`, `setLiquidationEngine(address)`
- 🔲 Add unit tests for initialization and admin setters

---

## Phase 6: Invariant Tests

_Stateful fuzz tests. Protocol invariants that must always hold._

- 🔲 `test/invariant/handlers/OrderHandler.sol` — Fuzzed order placement, claiming, confirming, cancelling
- 🔲 `test/invariant/handlers/VaultHandler.sol` — Fuzzed LP deposits, withdrawals, delegation changes
- 🔲 `test/invariant/handlers/LiquidationHandler.sol` — Fuzzed liquidation triggers and execution
- 🔲 `test/invariant/OwnProtocolInvariant.t.sol` — Assert all invariants:
  - Solvency: LP collateral value >= outstanding exposure * min ratio
  - ERC-4626 accounting: shares ↔ assets consistent
  - Escrow integrity: escrowed amounts == pending order amounts
  - Exposure caps: VM currentExposure <= maxExposure
  - Spread floor: all claimed orders use spread >= minSpread
  - Utilization cap: no claims when vault exceeds maxUtilization
  - Rewards accounting: no double-claim, no lost rewards on transfer

---

## Phase 7: Fork Tests

_Base mainnet fork tests against real contracts._

- 🔲 `test/fork/RealUSDC.t.sol` — Test with real USDC (6 decimals) on Base
- 🔲 `test/fork/RealWstETH.t.sol` — Test wstETH wrapping/unwrapping with real Lido contracts
- 🔲 `test/fork/RealAUSDC.t.sol` — Test aUSDC rebasing with real Aave contracts
- 🔲 `test/fork/RealDEX.t.sol` — Test Tier 3 liquidation against real Uniswap pools

---

## Phase 8: Deployment & Scripting

- 🔲 `script/Deploy.s.sol` — Full protocol deployment (all contracts + configuration)
- 🔲 `script/AddAsset.s.sol` — Whitelist a new asset (deploy eToken, configure oracle, register in registry)
- 🔲 `script/AddStablecoin.s.sol` — Whitelist a new stablecoin
- 🔲 `script/CreateVault.s.sol` — Deploy a new collateral vault with parameters
- 🔲 Testnet deployment to Base Sepolia
- 🔲 Deployment verification and smoke tests

---

## Phase 9: Security & Audit Prep

- 🔲 Run full test suite (`forge test -vvv`)
- 🔲 Run invariant tests with 10,000+ runs
- 🔲 Run coverage (`forge coverage --report lcov`) — target >95% line, >90% branch
- 🔲 Run Slither static analysis
- 🔲 Gas snapshot baseline (`forge snapshot`)
- 🔲 Manual security review against AGENTS.md vulnerability checklist
- 🔲 Pre-audit checklist (AGENTS.md) — all items green
- 🔲 Documentation review — all NatSpec complete, no TODOs remaining
