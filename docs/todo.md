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

## Phase 1: Core MVP — Deployment Ready

_Goal: All core protocol mechanics work end-to-end. Fee model, oracle, LP exits, and redemption enforcement are complete. Contracts are deployable to testnet._

### 1.1 Protocol Registry

_Single gov-upgradable contract that stores all protocol contract addresses. All other contracts reference this instead of storing individual addresses._

- 🔲 `IProtocolRegistry` interface — getters for all protocol contracts (OracleVerifier, FeeCalculator, FeeAccrual, Market, VaultManager, LiquidationEngine, AssetRegistry, PaymentTokenRegistry)
- 🔲 `ProtocolRegistry` implementation — admin-controlled address setters with timelock for critical changes (oracle, fee calculator)
- 🔲 Refactor existing contracts to read addresses from ProtocolRegistry instead of immutable/stored references
- 🔲 Unit tests for ProtocolRegistry (address setting, access control, timelock)

### 1.2 Fee Model — Per-Asset Mint & Redemption Fees

_Replace spread-as-revenue with explicit mint/redeem fees. Fees are per-asset based on volatility level. Fixed for MVP, swappable for dynamic fees later._

- 🔲 Add `volatilityLevel` (uint8) to `AssetConfig` struct in Types.sol
- 🔲 `IFeeCalculator` interface — `getMintFee(bytes32 asset, uint8 volatilityLevel)` and `getRedeemFee(bytes32 asset, uint8 volatilityLevel)` returning fee in BPS
- 🔲 `FeeCalculator` implementation — admin-set fixed fee rates per volatility level (MVP: simple mapping volatilityLevel → feeBps)
- 🔲 Wire fee deduction into `OwnMarket.confirmOrder()`:
  - Mint: deduct fee from stablecoin amount before eToken calculation
  - Redeem: deduct fee from stablecoin payout
- 🔲 Send collected fees to FeeAccrual contract
- 🔲 Unit tests for FeeCalculator (fee lookup, admin setter, bounds validation)
- 🔲 Unit tests for fee deduction in OwnMarket (mint fee applied, redeem fee applied, correct amounts transferred)

### 1.3 Fee Accrual & Distribution

_Dedicated contract that collects all protocol fees and distributes to protocol, LPs, and VMs._

- 🔲 `IFeeAccrual` interface:
  - `accrueFee(address vault, address vm, uint256 amount, address token)` — receive fee from OwnMarket
  - `claimProtocolFees(address token)` — protocol claims its share
  - `claimLPFees(address vault, address token)` — LP share goes to vault (share price appreciation)
  - `claimVMFees(address vm, address token)` — VM claims allocated share
  - `setProtocolShareBps(uint256 bps)` — governance sets protocol's cut
  - `setVMShareBps(address vault, uint256 bps)` — LPs (or vault governance) set VM share of LP portion
- 🔲 `FeeAccrual` implementation — track accrued fees per (vault, vm, token), handle three-way split
- 🔲 Unit tests for fee accrual, split calculation, claiming by each party
- 🔲 Unit tests for edge cases (zero VM share, 100% protocol share, multiple tokens)

### 1.4 VM Strategy Declaration

_VMs declare delta neutral or short position. Informational in MVP, designed for future enforcement._

- 🔲 Add `VMStrategy` enum to Types.sol (DeltaNeutral, Short)
- 🔲 Add `strategy` field to `VMConfig` struct
- 🔲 Update `VaultManager.registerVM()` to accept strategy parameter
- 🔲 Emit event on strategy declaration for offchain tracking
- 🔲 Unit tests for strategy setting and retrieval

### 1.5 Oracle & Utilisation Service

_Signed price & utilisation data from protocol-operated service. Interface supports future transition to Pyth/Chainlink._

- 🔲 Update `IOracleVerifier` — ensure interface is generic enough for Pyth/Chainlink adapters (verify current interface suffices)
- 🔲 Make OracleVerifier upgradable via ProtocolRegistry (not immutable)
- 🔲 Add signed utilisation data to oracle payload (or separate verifier method):
  - `verifyUtilisation(address vault, bytes calldata data)` → `(uint256 utilisationBps, uint256 totalExposureUSD, uint256 timestamp)`
- 🔲 On-chain `totalCommittedUSD` counter as sanity check / circuit breaker against signed utilisation
- 🔲 Unit tests for utilisation verification, staleness, sanity check divergence

### 1.6 LP Exit Queue with Wait Period

_All LP withdrawals are queued with a mandatory wait period set at protocol level._

- 🔲 Add `withdrawalWaitPeriod` parameter (configurable via governance, e.g., 7 days)
- 🔲 Enforce wait period in `fulfillWithdrawal()` — request cannot be fulfilled before `request.timestamp + withdrawalWaitPeriod`
- 🔲 Add post-withdrawal utilisation check in `fulfillWithdrawal()` — verify vault stays above `maxUtilization` after withdrawal
- 🔲 Unit tests for wait period enforcement, early fulfillment revert, utilisation check blocking

### 1.7 Redemption Enforcement (LP Liquidation Trigger)

_LP collateral is liquidated only when a VM fails to confirm a claimed redemption within grace period during open markets._

- 🔲 Add `redemptionGracePeriod` parameter (e.g., 4 hours during market hours)
- 🔲 In `expireOrder()` for claimed-but-unconfirmed Redeem orders: check if grace period exceeded + market was open + price is valid
- 🔲 When conditions met: trigger Tier 3 liquidation — sell vault collateral via DEX to pay the user
- 🔲 Unit tests for grace period enforcement, market-closed exemption, valid price check
- 🔲 Integration test for full redeem claim → VM fails to confirm → liquidation → user payout

### 1.8 Price Validation on confirmOrder

- 🔲 Market orders: validate `|executionPrice - placementPrice| / placementPrice <= slippage`
- 🔲 Limit orders (mint): validate `executionPrice <= limitPrice`
- 🔲 Limit orders (redeem): validate `executionPrice >= limitPrice`
- 🔲 Unit tests for slippage exceeded revert
- 🔲 Unit tests for limit price not met revert

### 1.9 Claim Validation

- 🔲 Validate VM is registered and active
- 🔲 Validate `assetRegistry.isActiveAsset(order.asset)`
- 🔲 Validate `paymentRegistry.isWhitelisted(order.stablecoin)`
- 🔲 Validate `vaultManager.isPaymentTokenAccepted(msg.sender, order.stablecoin)`
- 🔲 Set `claim.vault` via `vaultManager.getVMVault(msg.sender)`
- 🔲 Unit tests for each revert path

### 1.10 Order Placement Validation

- 🔲 In `placeMintOrder()`: validate asset active + stablecoin whitelisted
- 🔲 In `placeRedeemOrder()`: validate asset active + stablecoin whitelisted
- 🔲 Unit tests for placement with inactive asset, delisted stablecoin

### 1.11 Redeem Refunds on Cancel & Expire

- 🔲 In `cancelOrder()`: return escrowed eTokens for Redeem orders
- 🔲 In `expireOrder()`: return escrowed eTokens for Redeem orders
- 🔲 Unit tests for redeem cancel/expiry → eToken refund

### 1.12 Vault Exposure & Utilisation

- 🔲 Track which assets each vault backs (vault → asset set mapping)
- 🔲 Maintain `totalCommittedUSD` running counter (update on mint confirm + redeem confirm)
- 🔲 Track per-VM asset quantities (VM → asset → minted amount)
- 🔲 Compute VM `currentExposure` dynamically or via running counter
- 🔲 In `claimOrder()`: validate VM exposure cap, vault utilisation cap
- 🔲 Vault halt check + per-asset halt check in `claimOrder()`
- 🔲 Unit tests for exposure cap, utilisation cap, exposure update on confirm

### 1.13 Wire Errors & Code Cleanup

- 🔲 Use `MarketHalted`, `AssetNotActive`, `PaymentTokenNotWhitelisted` errors
- 🔲 Replace remaining `require` strings with custom errors in OwnMarket, OwnVault, VaultManager

### 1.14 Deployment Scripts & Testnet

- 🔲 `script/Deploy.s.sol` — Deploy all contracts including ProtocolRegistry, FeeCalculator, FeeAccrual; configure and wire references
- 🔲 `script/AddAsset.s.sol` — Register asset with volatility level, deploy eToken, configure oracle
- 🔲 `script/AddStablecoin.s.sol` — Whitelist a stablecoin
- 🔲 Testnet deployment to Base Sepolia
- 🔲 Smoke test on testnet

### 1.15 Integration Tests

- 🔲 Full mint flow with fee deduction: user pays stablecoin → fee accrues → VM receives net → eTokens minted
- 🔲 Full redeem flow with fee deduction: user submits eTokens → VM confirms → fee deducted → user receives net payout
- 🔲 Fee distribution: protocol claims share, LP share reflected in vault, VM claims share
- 🔲 LP exit queue: deposit → request withdrawal → wait period → fulfill
- 🔲 Redemption enforcement: redeem order → VM claims → VM fails to confirm → liquidation → user paid
- 🔲 VM strategy declaration flow
- 🔲 ProtocolRegistry upgrade: swap OracleVerifier, verify all consumers use new one
- 🔲 Update existing integration tests for eToken balance checks, stablecoin payouts, halt checks

---

## Phase 2: Security Hardening & Code Quality

_Goal: Protocol is secure, well-tested, and audit-ready._

### 2.1 ERC-4626 Inflation Attack Protection

- 🔲 Add virtual shares/assets offset (OpenZeppelin `_decimalsOffset()`)
- 🔲 Unit test for first-depositor manipulation

### 2.2 Reentrancy Gaps

- 🔲 Add `nonReentrant` to `OwnVault.withdraw()`, `OwnVault.redeem()`
- 🔲 Add `nonReentrant` to `EToken.depositRewards()`, `EToken.claimRewards()`
- 🔲 Add `nonReentrant` to `OwnVault.accrueAumFee()`

### 2.3 VM Registration Security

- 🔲 Admin approval or vault existence validation for `VaultManager.registerVM()`
- 🔲 Prevent deregistration with outstanding exposure or active delegations

### 2.4 Admin Setter Bounds Validation

- 🔲 Bounds on `setMaxUtilization()`, `setAumFee()`, `setReserveFactor()`, fee calculator params
- 🔲 Unit tests for each

### 2.5 Token Safety

- 🔲 Fee-on-transfer protection or explicit documentation
- 🔲 stETH 1-2 wei rounding in WstETHRouter
- 🔲 Router vault validation (whitelist or immutable)
- 🔲 WstETHRouter permit try/catch for front-running

### 2.6 Code Quality

- 🔲 Replace remaining `require` strings with custom errors (OwnVault, VaultManager)
- 🔲 Emit `PartialFillCompleted` event
- 🔲 Add events to admin setters in all contracts
- 🔲 Remove redundant `_settleRewards()` in EToken.mint()/burn()
- 🔲 `_openOrders`/`_userOrders`: cleanup on completion/cancel/expire
- 🔲 `fulfillWithdrawal()`: access control
- 🔲 Minimum order size consideration
- 🔲 Pending withdrawal queue: O(1) removal

### 2.7 USDC/USDT Blocklist Handling

- 🔲 Admin rescue/sweep for blocked addresses on cancel/fulfill
- 🔲 Unit test for transfer failure to blocklisted address

### 2.8 Tests

- 🔲 Unit tests for all event emissions, bounds validation, permit griefing, EIP-712 after updateName()

---

## Phase 3: Invariant Tests, Fork Tests, Audit Prep

_Goal: High confidence in correctness. Invariants hold under fuzz. Real token integrations verified. Documentation complete._

### 3.1 Invariant Tests

- 🔲 `test/invariant/handlers/OrderHandler.sol` — Fuzzed order lifecycle with fee deduction
- 🔲 `test/invariant/handlers/VaultHandler.sol` — Fuzzed LP operations with wait period
- 🔲 `test/invariant/handlers/FeeHandler.sol` — Fuzzed fee accrual and distribution
- 🔲 `test/invariant/handlers/LiquidationHandler.sol` — Fuzzed liquidation
- 🔲 `test/invariant/OwnProtocolInvariant.t.sol` — Solvency, ERC-4626 accounting, escrow integrity, exposure caps, fee accounting, utilisation cap, rewards accounting

### 3.2 Fork Tests (Base mainnet)

- 🔲 `test/fork/RealUSDC.t.sol` — Real USDC (6 decimals)
- 🔲 `test/fork/RealWstETH.t.sol` — Real Lido wstETH
- 🔲 `test/fork/RealAUSDC.t.sol` — Real Aave aUSDC rebasing
- 🔲 `test/fork/RealDEX.t.sol` — Real Uniswap for Tier 3

### 3.3 Deployment & Verification

- 🔲 `script/CreateVault.s.sol` — Deploy vault with parameters
- 🔲 Deployment verification and smoke tests
- 🔲 Gas snapshot baseline (`forge snapshot`)

### 3.4 Audit Prep

- 🔲 `forge build --deny-warnings` clean
- 🔲 `forge test -vvv` all pass
- 🔲 `forge fmt --check` clean
- 🔲 Invariant tests with 10,000+ runs
- 🔲 Coverage >95% line, >90% branch
- 🔲 Slither static analysis (create `slither.config.json`)

### 3.5 Documentation

- 🔲 Threat model: trust assumptions for oracle signers, admin, VMs, LPs, minters
- 🔲 Actors & privileges matrix
- 🔲 Order lifecycle state machine (including fee deduction points)
- 🔲 Fee flow diagram (collection → accrual → distribution)
- 🔲 Vault status state transitions
- 🔲 OwnMarket ↔ VaultManager ↔ OwnVault ↔ FeeAccrual interaction flow
- 🔲 Glossary of domain terms
- 🔲 Complete `@return` NatSpec tags
- 🔲 Manual security review

### 3.6 Deferred (post-audit or post-MVP)

- 🔲 Dynamic fee calculator (utilisation-based, volatility-aware)
- 🔲 ZK proof verification for VM asset holdings (delta neutral enforcement)
- 🔲 LP liquidation based on VM strategy + collateral type
- 🔲 Pyth/Chainlink oracle adapter deployment
- 🔲 LP withdrawal delegation tracking
- 🔲 VM default / re-delegation
- 🔲 Delegation enforcement in order flow
- 🔲 Timelock/delay on admin operations
- 🔲 Emergency LP withdrawal during extended halts
- 🔲 Two-step admin transfer
- 🔲 Oracle sequence number policy documentation
