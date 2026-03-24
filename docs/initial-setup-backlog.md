# Own Protocol v2 — Initial Setup Backlog

_All uncompleted items from the original tracker, preserved for reference. These items have been reorganized into the new 5-phase plan in `docs/todo.md`._

---

## 1. Spread Revenue — Deferred

- 🔲 LP portion of spread sent to `vault.distributeSpreadRevenue()` — requires VM/LP split ratio design and stablecoin/vault asset matching

---

## 2. Price Validation & Slippage (HIGH)

_No slippage or limit price checks exist. A VM could confirm at any price._

- 🔲 Market orders: validate `|executionPrice - placementPrice| / placementPrice <= slippage`
- 🔲 Limit orders (mint): validate `executionPrice <= limitPrice` (user pays at most limitPrice)
- 🔲 Limit orders (redeem): validate `executionPrice >= limitPrice` (user receives at least limitPrice)
- 🔲 Add unit tests for slippage exceeded revert
- 🔲 Add unit tests for limit price not met revert

---

## 3. Claim Validation & Safety Checks (HIGH)

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

## 4. Exposure & Utilization System (HIGH)

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

## 5. Market Hours & Off-Market (HIGH)

_PRD §7 & §10.2: Oracle returns `marketOpen` boolean but OwnMarket ignores it entirely._

- 🔲 In `claimOrder()`: retrieve `marketOpen` from oracle (or last known state)
- 🔲 When `!marketOpen`: enforce `vm.maxOffMarketExposure` instead of `vm.maxExposure`
- 🔲 When `!marketOpen`: check `vaultManager.isAssetOffMarketEnabled(vm, asset)` — revert if disabled
- 🔲 Add unit tests for off-market claim blocked when toggle is off
- 🔲 Add unit tests for off-market exposure cap enforcement

---

## 6. Redeem Refunds & Expiry (HIGH)

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

## 7. Liquidation Engine (CRITICAL)

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

## 8. Vault Safety & Fees (MEDIUM)

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

## 9. Code Quality (LOW)

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

## 10. Security Hardening (AUDIT FINDINGS)

_Findings from Trail of Bits audit tools: entry-point analysis, guidelines advisor, spec compliance, token integration, and code maturity assessment._

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

## 11. Bad Debt & Edge Cases (MEDIUM)

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

## 12. Invariant Tests

_Stateful fuzz tests. Protocol invariants that must always hold._

- 🔲 `test/invariant/handlers/OrderHandler.sol` — Fuzzed order placement, claiming, confirming, cancelling
- 🔲 `test/invariant/handlers/VaultHandler.sol` — Fuzzed LP deposits, withdrawals, delegation changes
- 🔲 `test/invariant/handlers/LiquidationHandler.sol` — Fuzzed liquidation triggers and execution
- 🔲 `test/invariant/OwnProtocolInvariant.t.sol` — Assert all invariants:
  - Solvency: LP collateral value >= outstanding exposure \* min ratio
  - ERC-4626 accounting: shares ↔ assets consistent
  - Escrow integrity: escrowed amounts == pending order amounts
  - Exposure caps: VM currentExposure <= maxExposure
  - Spread floor: all claimed orders use spread >= minSpread
  - Utilization cap: no claims when vault exceeds maxUtilization
  - Rewards accounting: no double-claim, no lost rewards on transfer

---

## 13. Fork Tests

_Base mainnet fork tests against real contracts._

- 🔲 `test/fork/RealUSDC.t.sol` — Test with real USDC (6 decimals) on Base
- 🔲 `test/fork/RealWstETH.t.sol` — Test wstETH wrapping/unwrapping with real Lido contracts
- 🔲 `test/fork/RealAUSDC.t.sol` — Test aUSDC rebasing with real Aave contracts
- 🔲 `test/fork/RealDEX.t.sol` — Test Tier 3 liquidation against real Uniswap pools

---

## 14. Deployment & Scripting

- 🔲 `script/Deploy.s.sol` — Full protocol deployment (all contracts + configuration)
- 🔲 `script/AddAsset.s.sol` — Whitelist a new asset (deploy eToken, configure oracle, register in registry)
- 🔲 `script/AddStablecoin.s.sol` — Whitelist a new stablecoin
- 🔲 `script/CreateVault.s.sol` — Deploy a new collateral vault with parameters
- 🔲 Testnet deployment to Base Sepolia
- 🔲 Deployment verification and smoke tests

---

## 15. Security & Audit Prep

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
