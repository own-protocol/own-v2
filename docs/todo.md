# Own Protocol v2 — Implementation Tracker

_Completed work archived at `docs/initial-setup-completed.md`. Original backlog preserved at `docs/initial-setup-backlog.md`._

## Legend

- ✅ Done
- 🔲 Todo
- 🚧 In Progress

---

## Completed Work

- ✅ 1: Documentation & Architecture
- ✅ 2: Interfaces (all 9 interfaces)
- ✅ 3: Test helpers & mocks
- ✅ 4: Unit tests (10 files)
- ✅ 5: Contract implementations (all 10 contracts)
- ✅ 6: Integration tests (9 files, 113+ tests)

---

## Phase 1: Happy Path — Mint, Redeem, LP, Cancel

_Goal: The primary user flows work end-to-end with proper validation. An LP deposits into a vault, a VM registers and configures, a user mints eTokens, redeems eTokens, cancels orders. Deployable to testnet for demo._

### 1.1 Price validation on confirmOrder

- 🔲 Market orders: validate `|executionPrice - placementPrice| / placementPrice <= slippage`
- 🔲 Limit orders (mint): validate `executionPrice <= limitPrice` (user pays at most their limit)
- 🔲 Limit orders (redeem): validate `executionPrice >= limitPrice` (user receives at least their limit)
- 🔲 Unit tests for slippage exceeded revert
- 🔲 Unit tests for limit price not met revert

### 1.2 Claim validation (who can claim what)

- 🔲 Validate VM is registered and active: check `.registered && .active` from VaultManager
- 🔲 Validate `assetRegistry.isActiveAsset(order.asset)` — reject claims on deactivated assets
- 🔲 Validate `paymentRegistry.isWhitelisted(order.stablecoin)` — reject if stablecoin delisted
- 🔲 Validate `vaultManager.isPaymentTokenAccepted(msg.sender, order.stablecoin)` — VM must accept the stablecoin
- 🔲 Set `claim.vault` via `vaultManager.getVMVault(msg.sender)` (currently hardcoded `address(0)`)
- 🔲 Unit tests for each revert (VM not registered, VM inactive, asset not active, stablecoin not whitelisted, VM doesn't accept stablecoin)

### 1.3 Order placement validation

- 🔲 In `placeMintOrder()`: validate `assetRegistry.isActiveAsset(asset)` and `paymentRegistry.isWhitelisted(stablecoin)`
- 🔲 In `placeRedeemOrder()`: validate `assetRegistry.isActiveAsset(asset)` and `paymentRegistry.isWhitelisted(stablecoin)`
- 🔲 Unit tests for placement with inactive asset, delisted stablecoin

### 1.4 Redeem refunds on cancel & expire

- 🔲 In `cancelOrder()`: return escrowed eTokens for Redeem orders
- 🔲 In `expireOrder()`: return escrowed eTokens for Redeem orders
- 🔲 Unit tests for redeem cancel → eToken refund
- 🔲 Unit tests for redeem expiry → eToken refund

### 1.5 Wire unused errors & replace require strings

- 🔲 Use `MarketHalted`, `AssetNotActive`, `PaymentTokenNotWhitelisted` errors (declared in IOwnMarket, never used)
- 🔲 Replace `require` strings with custom errors in OwnMarket (lines 264, 340-342)

### 1.6 Deployment script & testnet

- 🔲 `script/Deploy.s.sol` — Deploy all contracts, configure, wire references
- 🔲 `script/AddAsset.s.sol` — Register an asset (deploy eToken, configure oracle, add to registry)
- 🔲 `script/AddStablecoin.s.sol` — Whitelist a stablecoin
- 🔲 Testnet deployment to Base Sepolia
- 🔲 Smoke test on testnet

### 1.7 Integration test updates

- 🔲 Update integration tests to verify eToken balances after mint confirm (users receive real eTokens)
- 🔲 Update integration tests to verify stablecoin payouts after redeem confirm
- 🔲 Update `RedeemFlow.t.sol` to test redeem cancel/expiry returns eTokens
- 🔲 Update `HaltFlow.t.sol` to verify orders rejected during halt (once halt checks wired)

---

## Phase 2: Vault Safety — Exposure, Utilization, Health

_Goal: Vaults enforce economic safety. Exposure tracked per VM and per vault. Utilization caps prevent over-leverage. LP withdrawals respect utilization. Market hours enforced._

### 2.1 Vault exposure & health — dynamic price-based calculation

_Exposure and collateral value are both functions of live oracle prices, not static counters. A simple `+delta`/`-delta` on mint/redeem is insufficient because: (a) asset price changes alter total exposure (`Σ eToken.totalSupply(asset) × currentPrice(asset)`), and (b) collateral price changes alter collateral value for non-stablecoin vaults (WETH, wstETH)._

- 🔲 Track which assets each vault backs (vault → asset set mapping)
- 🔲 Compute `totalExposure` dynamically: `Σ eToken.totalSupply(asset) × oraclePrice(asset)` for all assets the vault backs
- 🔲 Compute `collateralValueUSD` dynamically: `totalAssets() × oraclePrice(collateral)` for non-stablecoin vaults (WETH, wstETH); for stablecoin vaults (USDC, aUSDC) use 1:1 or a stablecoin oracle
- 🔲 `healthFactor()` and `utilization()` must use live oracle prices for both sides of the ratio
- 🔲 Decide oracle query pattern: on-demand (query oracle in view functions) vs. keeper-updated cache with staleness bounds
- 🔲 Emit `UtilizationUpdated` event in OwnVault (declared but never emitted)
- 🔲 Handle decimal normalization: asset prices (18 decimals), collateral amounts (6 or 18 decimals depending on vault type), eToken supply (18 decimals)

### 2.2 VM exposure enforcement

_VM exposure also depends on live asset prices, not just accounting deltas. VM's `currentExposure` should reflect the current USD value of all eTokens minted through that VM._

- 🔲 Track per-VM asset quantities (VM → asset → eToken amount minted through that VM)
- 🔲 Compute VM `currentExposure` dynamically: `Σ vmMintedAmount(asset) × oraclePrice(asset)`
- 🔲 In `claimOrder()`: validate `currentExposure + claimNotional <= maxExposure`
- 🔲 Update per-VM asset quantities on mint confirm (`+amount`) and redeem confirm (`-amount`)
- 🔲 Underflow protection: cap at 0

### 2.3 Vault utilization enforcement

_Utilization = totalExposure / collateralValueUSD — both sides are price-dependent. Utilization checks must use live prices._

- 🔲 In `claimOrder()`: check vault utilization (using live prices) won't exceed `vault.maxUtilization()` after claim
- 🔲 In `fulfillWithdrawal()`: check post-withdrawal utilization (using live prices) stays within bounds
- 🔲 `maxWithdraw()`/`maxRedeem()`: return available amount considering utilization at current prices
- 🔲 Vault halt check in `claimOrder()`: `vault.vaultStatus() != Halted`
- 🔲 Per-asset halt check: `!vault.isAssetHalted(order.asset)`

### 2.4 Market hours & off-market

- 🔲 In `claimOrder()`: retrieve `marketOpen` from oracle
- 🔲 When `!marketOpen`: enforce `maxOffMarketExposure` instead of `maxExposure`
- 🔲 When `!marketOpen`: check `vaultManager.isAssetOffMarketEnabled(vm, asset)`

### 2.5 Tests

- 🔲 Unit tests for exposure cap exceeded, utilization exceeded, exposure update on confirm
- 🔲 Unit tests for withdrawal blocked by utilization
- 🔲 Unit tests for off-market claim blocked, off-market exposure cap
- 🔲 Unit tests for vault halt / asset halt blocking claims
- 🔲 Unit tests for health/utilization changing due to asset price movement (no mint/redeem, just price change)
- 🔲 Unit tests for health/utilization changing due to collateral price movement (WETH/wstETH vaults)
- 🔲 Integration tests verifying health/utilization after full order flows
- 🔲 Integration tests: vault becomes undercollateralized purely from price movement (no user action)

---

## Phase 3: Liquidation & Redeem Expiry

_Goal: Liquidation engine works end-to-end. Expired redeems trigger Tier 3. Bad debt handled gracefully._

### 3.1 Liquidation engine — Tier 1

- 🔲 `liquidate()`: burn liquidator's eTokens, transfer collateral from vault + liquidation reward
- 🔲 `_getMaxLiquidatable()`: calculate amount to restore health above minCollateralRatio
- 🔲 Call `vault.updateExposure(-delta)` after liquidation
- 🔲 Partial liquidation only — cap at what's needed

### 3.2 Liquidation engine — Tier 3 (DEX fallback)

- 🔲 `dexLiquidate()`: pull collateral from vault, execute DEX swap, return stablecoins
- 🔲 `liquidateExpiredRedemption()`: sell vault collateral to pay minter for expired redeems

### 3.3 Redeem expiry → liquidation

- 🔲 In `expireOrder()` for Redeem orders with claimed (unconfirmed) portions: trigger Tier 3
- 🔲 Transfer stablecoin payout to minter from liquidation proceeds
- 🔲 Burn escrowed eTokens for fulfilled portion

### 3.4 Auto-halt on critical health

- 🔲 Define `criticalRatio` per vault
- 🔲 Check health after exposure updates; auto-halt if below critical

### 3.5 Bad debt handling

- 🔲 Proportional redemption when vault undercollateralized
- 🔲 Bad debt socialization to eToken holders

### 3.6 Tests

- 🔲 Unit tests for Tier 1 with real collateral transfer and reward
- 🔲 Unit tests for Tier 3 DEX liquidation
- 🔲 Unit tests for expired redemption → liquidation → minter payout
- 🔲 Unit tests for bad debt proportional redemption, auto-halt
- 🔲 Integration tests: real liquidation and redeem expiry scenarios

---

## Phase 4: Fees, Security Hardening, Code Quality

_Goal: Protocol economics complete. Security gaps closed. Code audit-ready._

### 4.1 AUM fee accrual

- 🔲 Call `_accrueAumFee()` at start of `deposit()`, `withdraw()`, `redeem()`, `fulfillWithdrawal()`
- 🔲 Cap fee transfer to available free balance
- 🔲 Unit tests for fee accrual, fee when vault near max utilization

### 4.2 ERC-4626 inflation attack protection

- 🔲 Add virtual shares/assets offset (OpenZeppelin `_decimalsOffset()`)
- 🔲 Unit test for first-depositor manipulation

### 4.3 Reentrancy gaps

- 🔲 Add `nonReentrant` to `OwnVault.withdraw()`, `OwnVault.redeem()`
- 🔲 Add `nonReentrant` to `EToken.depositRewards()`, `EToken.claimRewards()`
- 🔲 Add `nonReentrant` to `OwnVault.accrueAumFee()`

### 4.4 VM registration security

- 🔲 Admin approval or vault existence validation for `VaultManager.registerVM()`
- 🔲 Prevent deregistration with outstanding exposure or active delegations

### 4.5 Admin setter bounds validation

- 🔲 Bounds on `setMaxUtilization()`, `setAumFee()`, `setReserveFactor()`, `setMinSpread()`
- 🔲 Unit tests for each

### 4.6 Token safety

- 🔲 Fee-on-transfer protection or explicit documentation
- 🔲 stETH 1-2 wei rounding in WstETHRouter
- 🔲 Router vault validation (whitelist or immutable)
- 🔲 WstETHRouter permit try/catch for front-running

### 4.7 Code quality

- 🔲 Replace remaining `require` strings with custom errors (OwnVault, VaultManager)
- 🔲 Emit `PartialFillCompleted` event
- 🔲 Add events to admin setters in OwnVault and VaultManager
- 🔲 Remove redundant `_settleRewards()` in EToken.mint()/burn()
- 🔲 `_openOrders`/`_userOrders`: cleanup on completion/cancel/expire
- 🔲 `fulfillWithdrawal()`: access control
- 🔲 Minimum order size consideration
- 🔲 Pending withdrawal queue: O(1) removal

### 4.8 USDC/USDT blocklist handling

- 🔲 Admin rescue/sweep for blocked addresses on cancel/fulfill
- 🔲 Unit test for transfer failure to blocklisted address

### 4.9 Tests

- 🔲 Unit tests for all event emissions, bounds validation, permit griefing, EIP-712 after updateName()

---

## Phase 5: Invariant Tests, Fork Tests, Audit Prep

_Goal: High confidence in correctness. Invariants hold under fuzz. Real token integrations verified. Documentation complete._

### 5.1 Invariant tests

- 🔲 `test/invariant/handlers/OrderHandler.sol` — Fuzzed order lifecycle
- 🔲 `test/invariant/handlers/VaultHandler.sol` — Fuzzed LP operations
- 🔲 `test/invariant/handlers/LiquidationHandler.sol` — Fuzzed liquidation
- 🔲 `test/invariant/OwnProtocolInvariant.t.sol` — Solvency, ERC-4626 accounting, escrow integrity, exposure caps, spread floor, utilization cap, rewards accounting

### 5.2 Fork tests (Base mainnet)

- 🔲 `test/fork/RealUSDC.t.sol` — Real USDC (6 decimals)
- 🔲 `test/fork/RealWstETH.t.sol` — Real Lido wstETH
- 🔲 `test/fork/RealAUSDC.t.sol` — Real Aave aUSDC rebasing
- 🔲 `test/fork/RealDEX.t.sol` — Real Uniswap for Tier 3

### 5.3 Deployment & verification

- 🔲 `script/CreateVault.s.sol` — Deploy vault with parameters
- 🔲 Deployment verification and smoke tests
- 🔲 Gas snapshot baseline (`forge snapshot`)

### 5.4 Audit prep

- 🔲 `forge build --deny-warnings` clean
- 🔲 `forge test -vvv` all pass
- 🔲 `forge fmt --check` clean
- 🔲 Invariant tests with 10,000+ runs
- 🔲 Coverage >95% line, >90% branch
- 🔲 Slither static analysis (create `slither.config.json`)

### 5.5 Documentation

- 🔲 Threat model: trust assumptions for oracle signers, admin, VMs, LPs, minters
- 🔲 Actors & privileges matrix
- 🔲 Order lifecycle state machine
- 🔲 Vault status state transitions
- 🔲 OwnMarket ↔ VaultManager ↔ OwnVault interaction flow
- 🔲 Glossary of domain terms
- 🔲 Complete `@return` NatSpec tags
- 🔲 Manual security review

### 5.6 Deferred (post-audit or post-MVP)

- 🔲 LP spread revenue distribution (VM/LP split ratio + stablecoin→collateral matching)
- 🔲 LP withdrawal delegation tracking
- 🔲 VM default / re-delegation
- 🔲 Delegation enforcement in order flow
- 🔲 Timelock/delay on admin operations
- 🔲 Emergency LP withdrawal during extended halts
- 🔲 Two-step admin transfer
- 🔲 Oracle sequence number policy documentation
