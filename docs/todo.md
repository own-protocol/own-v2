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

## Phase 5A: Contract Wiring & Initialization

_Resolve circular dependencies and missing cross-contract references so the protocol can actually function end-to-end._

- 🔲 Resolve OwnMarket ↔ VaultManager circular dependency: make `vaultManager` settable post-deploy (admin setter) or use two-phase initialization
- 🔲 Add `liquidationEngine` address to OwnMarket (needed for `expireOrder` Tier 3)
- 🔲 Add admin setter functions to OwnMarket: `setVaultManager(address)`, `setLiquidationEngine(address)`
- 🔲 Add vault reference/mapping to LiquidationEngine so engine can call vault methods
- 🔲 Add unit tests for initialization and admin setters
- 🔲 Update integration test deployment scripts to wire contracts correctly

---

## Phase 5B: Core Execution Logic (CRITICAL)

_`confirmOrder()` is the heart of the protocol. Currently it only records the oracle price — it must execute the actual mint/redeem with spread math._

### Spread-adjusted eToken calculation (PRD §5)

- 🔲 Mint: `effectivePrice = executionPrice * (BPS + vmSpread) / BPS`
- 🔲 eToken amount: `eTokenAmount = stablecoinAmount * 10^(18 - stablecoinDecimals) * PRECISION / effectivePrice`
- 🔲 Redeem: `effectivePrice = executionPrice * (BPS - vmSpread) / BPS`
- 🔲 Stablecoin payout: `payout = eTokenAmount * effectivePrice / PRECISION / 10^(18 - stablecoinDecimals)`
- 🔲 Handle decimal conversions: USDC/USDT (6 dec) vs USDS (18 dec) vs eTokens (18 dec) vs prices (18 dec)
- 🔲 Use `Math.mulDiv` for all cross-multiplication — never `a * b / c`

### Mint/burn execution

- 🔲 Call `EToken.mint(minter, eTokenAmount)` for mint orders on confirm
- 🔲 Call `EToken.burn(address(this), eTokenAmount)` for redeem orders on confirm (eTokens escrowed in market)

### Redeem stablecoin payout

- 🔲 For redeem confirmations: verify VM has sent stablecoins to the minter (or transfer from escrow) — currently no stablecoin transfer to user on redeem confirm

### Spread revenue distribution

- 🔲 Calculate spread revenue: difference between oracle price and effective price
- 🔲 VM keeps their stablecoin profit margin from spread
- 🔲 LP portion sent to `vault.distributeSpreadRevenue()`
- 🔲 Emit `OrderConfirmed` with real `eTokenAmount` and `spreadAmount` (currently emits 0s)

### Tests

- 🔲 Update unit tests in `OwnMarket.t.sol` for new confirmOrder logic
- 🔲 Add comprehensive unit tests with exact decimal math for each stablecoin type (6 dec, 18 dec)
- 🔲 Update integration tests to assert eToken balances after confirm

---

## Phase 5C: Price Validation & Slippage (HIGH)

_No slippage or limit price checks exist. A VM could confirm at any price._

- 🔲 Market orders: validate `|executionPrice - placementPrice| / placementPrice <= slippage`
- 🔲 Limit orders (mint): validate `executionPrice <= limitPrice` (user pays at most limitPrice)
- 🔲 Limit orders (redeem): validate `executionPrice >= limitPrice` (user receives at least limitPrice)
- 🔲 Add unit tests for slippage exceeded revert
- 🔲 Add unit tests for limit price not met revert

---

## Phase 5D: Claim Validation & Safety Checks (HIGH)

_`claimOrder()` performs no cross-contract validation. Any address can claim any open order._

### VM & asset validation

- 🔲 Validate VM is registered and active: `vaultManager.getVMConfig(msg.sender).registered && .active`
- 🔲 Validate `assetRegistry.isActiveAsset(order.asset)` — reject claims on inactive assets
- 🔲 Validate `paymentRegistry.isWhitelisted(order.stablecoin)` — reject if stablecoin delisted
- 🔲 Validate `vaultManager.isPaymentTokenAccepted(msg.sender, order.stablecoin)` — VM must accept the stablecoin
- 🔲 Set `claim.vault` to the VM's vault address via `vaultManager.getVMVault(msg.sender)` (currently `address(0)`)

### Vault & asset halt checks

- 🔲 Resolve VM's vault via `vaultManager.getVMVault(msg.sender)`, check `vault.vaultStatus() != Halted`
- 🔲 Check `!vault.isAssetHalted(order.asset)` (per-asset halt)
- 🔲 Wire in unused errors `MarketHalted` and `AssetNotActive` (declared in IOwnMarket but never used)

### Order placement validation

- 🔲 In `placeMintOrder()`: validate `assetRegistry.isActiveAsset(asset)` and `paymentRegistry.isWhitelisted(stablecoin)`
- 🔲 In `placeRedeemOrder()`: validate `assetRegistry.isActiveAsset(asset)` and `paymentRegistry.isWhitelisted(stablecoin)`

### Tests

- 🔲 Add unit tests for each new revert condition (VM not registered, inactive asset, delisted stablecoin, halted vault, halted asset)
- 🔲 Update integration tests to cover validation scenarios
- 🔲 Update integration test `HaltFlow.t.sol` to verify orders rejected during halt

---

## Phase 5E: Exposure & Utilization System (HIGH)

_No exposure cap or utilization enforcement exists. VMs can over-leverage without limit._

### Vault exposure tracking (CRITICAL)

- 🔲 Add `updateExposure(int256 delta) external onlyMarket` to OwnVault
- 🔲 Increment `_totalExposure` when mint orders are confirmed (called by market)
- 🔲 Decrement `_totalExposure` when redeem orders are confirmed
- 🔲 Decrement `_totalExposure` when liquidations occur
- 🔲 Emit `UtilizationUpdated` event (declared in IOwnVault but never emitted)

### VM exposure enforcement

- 🔲 Calculate claim notional: `claimAmount * executionPrice / decimalFactor` (for exposure tracking)
- 🔲 Validate `vm.currentExposure + claimNotional <= vm.maxExposure` (or `maxOffMarketExposure` during off-hours)
- 🔲 Call `vaultManager.updateExposure(msg.sender, int256(claimNotional))` on claim
- 🔲 Call `vaultManager.updateExposure(vm, -int256(claimNotional))` on confirm (for redeems)

### Vault utilization enforcement

- 🔲 Validate vault utilization won't exceed `vault.maxUtilization()` after this claim
- 🔲 In `fulfillWithdrawal()`: check that post-withdrawal health factor stays >= 1.0
- 🔲 In standard ERC-4626 `withdraw()`/`redeem()`: check utilization limits
- 🔲 `maxWithdraw()`/`maxRedeem()`: return available amount considering utilization

### Underflow protection (VaultManager)

- 🔲 Add underflow protection in `updateExposure()`: `if (uint256(-delta) > currentExposure) revert ExposureUnderflow()`
- 🔲 Add unit test for underflow scenario

### Tests

- 🔲 Add unit tests for exposure cap exceeded revert
- 🔲 Add unit tests for max utilization exceeded revert
- 🔲 Add unit tests for exposure update, health factor calculation, utilization calculation
- 🔲 Add unit tests for withdrawal blocked by utilization
- 🔲 Update integration tests to verify health/utilization after order flows

---

## Phase 5F: Market Hours & Off-Market (HIGH)

_PRD §7 & §10.2: Oracle returns `marketOpen` boolean but OwnMarket ignores it entirely._

- 🔲 In `claimOrder()`: retrieve `marketOpen` from oracle (or last known state)
- 🔲 When `!marketOpen`: enforce `vm.maxOffMarketExposure` instead of `vm.maxExposure`
- 🔲 When `!marketOpen`: check `vaultManager.isAssetOffMarketEnabled(vm, asset)` — revert if disabled
- 🔲 Add unit tests for off-market claim blocked when toggle is off
- 🔲 Add unit tests for off-market exposure cap enforcement

---

## Phase 5G: Redeem Refunds & Expiry (HIGH)

_`cancelOrder()` and `expireOrder()` only refund stablecoins for Mint orders. Redeem orders lose escrowed eTokens._

### eToken refund on cancel/expiry

- 🔲 In `cancelOrder()`: return escrowed eTokens for Redeem orders (`eToken.transfer(user, refundAmount)`)
- 🔲 In `expireOrder()`: return escrowed eTokens for Redeem orders

### Tier 3 liquidation on redeem expiry (PRD §2 & §10.10)

- 🔲 In `expireOrder()` for Redeem orders: call `liquidationEngine.liquidateExpiredRedemption(orderId, ...)`
- 🔲 Transfer stablecoin payout to the minter from liquidation proceeds
- 🔲 Burn escrowed eTokens for the fulfilled portion

### Tests

- 🔲 Add unit tests for redeem cancel eToken refund
- 🔲 Add unit tests for redeem expiry eToken refund
- 🔲 Add unit tests for redeem deadline → liquidation → minter payout
- 🔲 Update integration test `RedeemFlow.t.sol` (currently documents the gap with comments)

---

## Phase 5H: Liquidation Engine (CRITICAL)

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

---

## Phase 5I: Vault Safety & Fees (MEDIUM)

### Auto-halt on critical health (PRD §9 & §10.5)

- 🔲 Define `criticalRatio` parameter per vault (e.g., 100% for stablecoins, 120% for volatile)
- 🔲 Check health after exposure updates; auto-halt if below critical
- 🔲 Add unit tests for automatic halt trigger

### AUM fee auto-accrual

- 🔲 Call `_accrueAumFee()` at the start of `deposit()`, `withdraw()`, `redeem()`, `fulfillWithdrawal()`
- 🔲 Add unit tests for fee accrual on deposit/withdraw

### ERC-4626 inflation attack protection (AUDIT FINDING)

- 🔲 Add virtual shares/assets offset (e.g., OpenZeppelin `_decimalsOffset()`) to protect first depositor from share price manipulation
- 🔲 Add unit test for inflation attack scenario

### AUM fee transfer safety (AUDIT FINDING)

- 🔲 In `_accrueAumFee()`: cap fee transfer to available free balance (vault balance minus utilized portion) to prevent revert when vault is highly utilized
- 🔲 Add unit test for fee accrual when vault is near max utilization

---

## Phase 5J: Minor Improvements & Code Quality (LOW)

### LP withdrawal delegation tracking (PRD §10.3)

- 🔲 When LP shares are burned via withdrawal, signal VaultManager to adjust delegation proportions
- 🔲 Add event for delegation proportion change on withdrawal

### Missing event emissions

- 🔲 Emit `PartialFillCompleted` in `claimOrder()` when order becomes `PartiallyClaimed` (declared in IOwnMarket but never emitted)
- 🔲 Add events to `setMaxUtilization()`, `setAumFee()`, `setReserveFactor()` in OwnVault
- 🔲 Add event to `setMinSpread()` in VaultManager
- 🔲 Add unit tests verifying event emissions

### Replace `require` strings with custom errors (coding standard)

- 🔲 OwnMarket.sol line 222: `require(claim.vm == msg.sender, ...)` → custom error
- 🔲 OwnMarket.sol line 282-283: `require(order.status ...)` → custom error
- 🔲 OwnVault.sol lines 71, 76: modifier `require` → custom error
- 🔲 VaultManager.sol line 58, 190: `require` → custom error

### Array management (AUDIT FINDING)

- 🔲 `_openOrders` and `_userOrders` arrays are append-only, never cleaned — add cleanup on order completion/cancel/expire to prevent unbounded growth
- 🔲 Consider adding minimum order size to prevent dust order griefing

### fulfillWithdrawal access control (AUDIT FINDING)

- 🔲 Add appropriate access control to `fulfillWithdrawal()` — currently anyone can trigger fulfillment for any pending request, could force withdrawal at unfavorable share price

---

## Phase 5K: Security Hardening (AUDIT FINDINGS)

_New findings from Trail of Bits audit tools: entry-point analysis, guidelines advisor, spec compliance, token integration, and code maturity assessment._

### Reentrancy gaps (HIGH)

- 🔲 Add `nonReentrant` to `OwnVault.withdraw()` and `OwnVault.redeem()` — these ERC-4626 functions transfer tokens but lack reentrancy protection (unlike `deposit`/`mint` which have it)
- 🔲 Add `nonReentrant` to `EToken.depositRewards()` and `EToken.claimRewards()` — both transfer tokens externally without reentrancy guards
- 🔲 Add `nonReentrant` to `OwnVault.accrueAumFee()` — permissionless function that transfers tokens to treasury

### VM registration security (HIGH)

- 🔲 Add admin approval or vault existence validation to `VaultManager.registerVM()` — currently fully permissionless, any address can register as a VM with any (potentially fake) vault address
- 🔲 Prevent `VaultManager.deregisterVM()` when VM has outstanding exposure (`currentExposure > 0`) or active delegations
- 🔲 Add unit tests for registration with invalid vault, deregistration with active exposure

### Admin setter bounds validation (MEDIUM)

- 🔲 Add upper bound validation to `OwnVault.setMaxUtilization()` — currently accepts any value including > 10000 BPS
- 🔲 Add bounds validation to `OwnVault.setAumFee()` — no upper limit check
- 🔲 Add bounds validation to `OwnVault.setReserveFactor()` — no upper limit check
- 🔲 Add bounds validation to `VaultManager.setMinSpread()` — could be set above BPS or to 0
- 🔲 Add unit tests for bounds validation on all admin setters

### WstETHRouter permit front-running (MEDIUM)

- 🔲 Wrap `IERC20Permit.permit()` call in try/catch in `depositStETHWithPermit()` — an attacker can front-run the permit call with the same parameters, consuming it and causing the original tx to revert
- 🔲 Add unit test for permit griefing scenario

### EToken EIP-712 domain separator (LOW)

- 🔲 Verify that `updateName()` does not break EIP-712 domain separator for permit signatures — OpenZeppelin v5 computes domain separator dynamically, but this should be explicitly tested
- 🔲 Add unit test: permit signature valid after `updateName()` call

### Oracle sequence number policy (LOW)

- 🔲 Decide if oracle sequence number gaps are intentional (current: `>=` allows gaps) vs strict increment (`==` only)
- 🔲 Document the decision and add test for gap behavior
- 🔲 Consider griefing vector: any external caller can call `verifyPrice()` to advance sequence numbers, potentially consuming valid oracle messages before OwnMarket uses them

### Double reward settlement gas waste (INFO)

- 🔲 Remove explicit `_settleRewards()` calls in `EToken.mint()` and `EToken.burn()` — the `_update()` override already settles rewards for both sender and receiver, making the explicit calls redundant no-ops that waste gas

### Fee-on-transfer token protection (HIGH — Token Integration)

- 🔲 Add balance-before/after check in `OwnMarket.placeMintOrder()` and `placeRedeemOrder()` for stablecoin/eToken transfers — or explicitly ban fee-on-transfer tokens in PaymentTokenRegistry with documentation
- 🔲 Same issue in `OwnVault.distributeSpreadRevenue()` — assumes `totalRevenue` received equals requested amount
- 🔲 Document which token patterns are supported/unsupported (fee-on-transfer, rebasing, blocklist, pausable)

### stETH transfer rounding (MEDIUM — Token Integration)

- 🔲 In `WstETHRouter._depositStETHInternal()`: use balance-before/after pattern when pulling stETH — stETH transfers are known to have 1-2 wei rounding errors, which could cause `wstETH.wrap()` to revert
- 🔲 Add unit test for stETH 1-2 wei rounding scenario

### Router vault validation (HIGH — Token Integration)

- 🔲 Both `WETHRouter` and `WstETHRouter` accept an arbitrary `IERC4626 vault` parameter — a malicious vault could steal deposited WETH/wstETH. Add a vault whitelist/registry check, or make vault an immutable constructor parameter
- 🔲 Add unit test for router interaction with non-whitelisted vault

### USDC/USDT blocklist handling (MEDIUM — Token Integration)

- 🔲 If a minter/LP address gets blocklisted by USDC/USDT after placing an order, `cancelOrder()` and `fulfillWithdrawal()` will revert permanently — consider adding admin rescue/sweep function or alternative recipient address
- 🔲 Add unit test for transfer failure to blocklisted address

### Pending withdrawal queue efficiency (INFO)

- 🔲 Consider replacing O(n) linear scan in `_removePendingRequest()` with a mapping-based O(1) approach — current swap-and-pop requires iterating through the array

---

## Phase 5L: Bad Debt & Edge Cases (MEDIUM)

_PRD §10.5 and §10.10 requirements not yet implemented._

### Bad debt handling (PRD §10.5)

- 🔲 When vault is undercollateralized after all liquidation avenues exhausted: implement proportional redemption `payout = eTokenAmount * (totalCollateral / totalLiabilities)`
- 🔲 Add bad debt socialization to eToken holders for remaining shortfall
- 🔲 Add unit tests for proportional redemption scenario

### VM default / re-delegation (PRD §10.10)

- 🔲 When a VM goes offline: allow delegated LPs to re-delegate to a different VM without requiring the absent VM's participation
- 🔲 Add mechanism for admin or LP to force-remove delegation from a deregistered/inactive VM
- 🔲 Add unit tests for re-delegation after VM disappearance

### Delegation enforcement in order flow

- 🔲 VaultManager stores delegation data but OwnMarket never queries it — decide if delegation enforcement is needed in the claim flow (VM can only act on exposure attributable to delegated LPs) or if it's purely informational

### Decentralization improvements (Code Maturity: 1/4)

- 🔲 Add timelock or delay to critical admin operations (halt, fee changes, signer rotation) — currently single admin with instant effect
- 🔲 Add emergency withdrawal mechanism for LPs when vault is halted — currently no way for LPs to exit during extended halts if fulfillWithdrawal is blocked
- 🔲 Consider two-step admin transfer pattern (propose + accept) instead of single-step for all Ownable contracts

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

### Pre-audit setup

- 🔲 Create `slither.config.json` at project root (does not exist yet)
- 🔲 Create and freeze `audit-march-2026` branch from stable commit

### Automated checks

- 🔲 `forge build --deny-warnings` — clean compile with no warnings
- 🔲 `forge test -vvv` — all tests pass
- 🔲 `forge fmt --check` — formatting clean
- 🔲 Run invariant tests with 10,000+ runs
- 🔲 Run coverage (`forge coverage --report lcov`) — target >95% line, >90% branch
- 🔲 Run Slither static analysis — triage all findings
- 🔲 Gas snapshot baseline (`forge snapshot`)

### Manual review

- 🔲 Manual security review against AGENTS.md vulnerability checklist
- 🔲 Pre-audit checklist (AGENTS.md) — all items green
- 🔲 Documentation review — all NatSpec complete, no TODOs remaining

### Documentation gaps (from ToB audit)

- 🔲 Document formal threat model: trust assumptions for oracle signers, admin, VMs, LPs, minters
- 🔲 Create actors & privileges matrix as standalone document
- 🔲 Document order lifecycle state machine (formal spec with sequence diagrams)
- 🔲 Document vault status state transitions (Active → Halted → Active, Active → WindingDown)
- 🔲 Document interaction flow between OwnMarket, VaultManager, and OwnVault during claim/confirm
- 🔲 Create glossary of domain terms (eToken, VM, spread, slippage, exposure, utilization, etc.)
- 🔲 Add `@return` NatSpec tags on all functions (many only have `@inheritdoc`)

### Unused interface declarations (wire in or remove)

- 🔲 Wire in 13 declared-but-unused errors: `MarketHalted`, `AssetNotActive`, `PaymentTokenNotWhitelisted`, `InvalidOrderType`, `InvalidPriceType`, `SlippageExceeded`, `LimitPriceNotMet`, `VMNotEligible` (IOwnMarket); `InsufficientCollateral`, `MaxUtilizationExceeded`, `WithdrawalNotReady`, `ZeroAddress`, `AssetIsHalted` (IOwnVault)
- 🔲 Wire in 2 declared-but-never-emitted events: `PartialFillCompleted` (IOwnMarket), `UtilizationUpdated` (IOwnVault)
