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
