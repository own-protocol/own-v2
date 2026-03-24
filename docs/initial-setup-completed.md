# Own Protocol v2 — Completed Initial Setup

_This file records all work completed during the initial build. Extracted from the original tracker for archival._

---

## 1. Documentation & Architecture ✅

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

## 2. Interfaces ✅

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

## 3. Test Helpers & Mocks ✅

- ✅ `BaseTest.sol` — Common setup, token deployments, actor addresses, utility functions
- ✅ `MockERC20.sol` — Configurable decimals mock token (for stablecoins, collateral)
- ✅ `MockWstETH.sol` — Mock wstETH with configurable exchange rate
- ✅ `MockAUSDC.sol` — Mock aUSDC with configurable rebasing
- ✅ `MockOracleVerifier.sol` — Returns configurable prices, simulates staleness/deviation
- ✅ `MockDEX.sol` — Mock Uniswap for Tier 3 liquidation testing
- ✅ `Actors.sol` — Predefined addresses (minter, lp1, lp2, vm1, vm2, admin, liquidator, attacker)

---

## 4. Unit Tests ✅

- ✅ `test/unit/EToken.t.sol` — ERC20 compliance, permit, mint/burn access control, admin name/symbol update, rewards-per-share accumulator, transfer reward settlement
- ✅ `test/unit/OwnMarket.t.sol` — Place order (market/limit), claim (full/partial), confirm with oracle price, cancel, deadline expiry, directed vs open orders, partial fill logic, stablecoin routing, cross-vault claims
- ✅ `test/unit/OwnVault.t.sol` — ERC-4626 deposit/withdraw, async withdrawal queue (request/cancel/fulfill FIFO), health factor, utilization tracking, halt/unhalt, wind-down, yield-bearing share price
- ✅ `test/unit/VaultManager.t.sol` — Registration, spread setting (>= minSpread), exposure caps, accepted stablecoins, off-market toggles, delegation (propose/accept/remove), self-delegation
- ✅ `test/unit/AssetRegistry.t.sol` — Add/remove assets, active vs legacy tokens, collateral params, admin access control
- ✅ `test/unit/OracleVerifier.t.sol` — Signature verification, staleness rejection, deviation check, sequence number enforcement, chain ID validation, signer rotation
- ✅ `test/unit/LiquidationEngine.t.sol` — Tier 1 (eToken liquidation, partial, reward), Tier 3 (DEX sale fallback), health restoration check, redemption deadline trigger
- ✅ `test/unit/PaymentTokenRegistry.t.sol` — Add/remove payment tokens, whitelist checks, admin access control

---

## 5. Contract Implementations ✅

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

## 6. Integration Tests ✅

- ✅ `test/integration/MintFlow.t.sol` — Full mint lifecycle (21 tests)
- ✅ `test/integration/RedeemFlow.t.sol` — Full redeem lifecycle (8 tests)
- ✅ `test/integration/LPLifecycle.t.sol` — LP deposit → delegate → yield → withdrawal (15 tests)
- ✅ `test/integration/VMLifecycle.t.sol` — VM register → configure → claim → confirm (23 tests)
- ✅ `test/integration/LiquidationFlow.t.sol` — Health checks, Tier 1/3 stubs (10 tests)
- ✅ `test/integration/HaltFlow.t.sol` — Halt/unhalt/wind-down (14 tests)
- ✅ `test/integration/CrossVault.t.sol` — Multi-vault VM competition (5 tests)
- ✅ `test/integration/DividendFlow.t.sol` — Dividend flow (8 tests)
- ✅ `test/integration/MultiStablecoin.t.sol` — Multi-stablecoin orders (9 tests)

---

## 7. Contract Wiring & Initialization ✅

- ✅ Resolve OwnMarket ↔ VaultManager circular dependency: `vaultManager` is now a state variable with one-time admin setter
- ✅ Add `liquidationEngine` address to OwnMarket with one-time admin setter
- ✅ Add admin setter functions to OwnMarket: `setVaultManager(address)`, `setLiquidationEngine(address)`
- ✅ Add `market` reference to LiquidationEngine with one-time admin setter (`setMarket(address)`)
- ✅ Add unit tests for initialization and admin setters (OwnMarket: 10 tests, LiquidationEngine: 5 tests)
- ✅ Update integration test deployment scripts to wire contracts correctly (all 9 integration test files updated)

---

## 8. Core Execution Logic ✅

### Spread-adjusted eToken calculation (PRD §5)

- ✅ Mint: `effectivePrice = Math.mulDiv(executionPrice, BPS + vmSpread, BPS)`
- ✅ eToken amount: `Math.mulDiv(claim.amount * decimalScaler, PRECISION, effectivePrice)` — rounds down (protocol-favorable)
- ✅ Redeem: `effectivePrice = Math.mulDiv(executionPrice, BPS - vmSpread, BPS)`
- ✅ Stablecoin payout: `Math.mulDiv(claim.amount, effectivePrice, PRECISION * decimalScaler)` — rounds down (protocol-favorable)
- ✅ Handle decimal conversions: USDC/USDT (6 dec) vs USDS (18 dec) vs eTokens (18 dec) vs prices (18 dec)
- ✅ Use `Math.mulDiv` for all cross-multiplication — never `a * b / c`

### Mint/burn execution

- ✅ Call `EToken.mint(minter, eTokenAmount)` for mint orders on confirm
- ✅ Call `EToken.burn(address(this), eTokenAmount)` for redeem orders on confirm (eTokens escrowed in market)

### Redeem stablecoin payout

- ✅ For redeem confirmations: `safeTransferFrom(vm, minter, stablecoinPayout)` — VM must pre-approve OwnMarket

### Spread revenue distribution

- ✅ Calculate spread revenue: `Math.mulDiv(claim.amount, vmSpread, BPS + vmSpread)` for mint, `valueAtOracle - payout` for redeem
- ✅ VM keeps their stablecoin profit margin from spread (full spread for MVP — LP distribution deferred)
- ✅ Emit `OrderConfirmed` with real `eTokenAmount` and `spreadAmount`

### Tests

- ✅ Update unit tests in `OwnMarket.t.sol` for new confirmOrder logic (7 new tests)
- ✅ Add comprehensive unit tests with exact decimal math for each stablecoin type (6 dec, 18 dec)
- ✅ Update integration tests to assert eToken balances after confirm and stablecoin payouts on redeem
