# Own Protocol v2 — MVP Product Requirements

**Target: Audit-Ready | March 2026**

---

## 1. MVP Scope

The MVP delivers a multi-collateral, public vault system with vault manager delegation for tokenized RWA exposure on Base.

### 1.1 What's In

- Multiple vaults, one per collateral type: USDC, aUSDC, ETH (as WETH), stETH (as wstETH internally)
- All vaults are public — multiple LPs deposit collateral, receive ERC-4626 shares
- Vault manager registration and LP delegation (mutual agreement)
- LPs can be their own vault manager
- Instant mint during market hours at oracle price + minSpread
- Non-market hours: vault managers opt-in with custom spreads, minters routed to best price
- Unified spread model (no separate fee — minSpread acts as revenue floor)
- Spread revenue split: protocol / vault manager / LPs
- Offchain hedging by vault managers (no onchain hedging)
- eTokens as standard ERC20 + Permit per asset
- Signed oracle price feeds (protocol-operated for MVP)
- Liquidation engine for vault health
- Vault halt mechanism
- stETH vault wraps to wstETH on deposit, unwraps on withdrawal (avoids rebasing rounding issues)
- aUSDC vault — yield accrues naturally via ERC-4626 share price increase

### 1.2 What's Out (Post-MVP)

- ZK proof attestation for offchain positions
- Multi-signer oracle (M-of-N)
- Pyth / Chainlink oracle integration
- Morpho looping integration
- Token split migration contract
- Governance and fee parameter voting
- Cross-chain deployment
- Permissionless asset listing

---

## 2. Architecture Overview

The protocol is organized around a set of core components that coordinate to enable minting, redemption, LP management, and vault health enforcement. Contract names and file structure are determined during implementation; what follows describes the logical responsibilities and interactions.

### Core Components

- **Collateral Vaults** — One ERC-4626 vault per collateral type. Holds pooled LP collateral and tracks shares. For yield-bearing assets (aUSDC, stETH/wstETH), the share price increases automatically as the underlying balance grows, so LPs receive accrued yield on withdrawal without any claim step.

- **eTokens** — One ERC20 + EIP-2612 Permit token per synthetic asset (eTSLA, eGOLD, etc.). Mint and burn authority is restricted to the vault system. eTokens are freely transferable and composable with external DeFi.

- **Asset Registry** — A whitelisted asset list maintained by the protocol admin. Maps each ticker to its eToken address, oracle configuration, and collateral parameters.

- **Oracle Verification** — Accepts signed price data, verifies the signer, enforces staleness bounds, and exposes a generic interface so future backends (Pyth, Chainlink, multi-signer) can be swapped in without changing downstream consumers.

- **Vault Manager Layer** — Handles manager registration, LP-to-manager delegation, spread configuration, and non-market-hour participation signaling.

- **Liquidation Engine** — Monitors vault health ratios, triggers partial collateral liquidation via DEX when health drops below threshold, and pays liquidator rewards.

### Key Interactions

**Mint**
Minter submits collateral-equivalent value together with a signed oracle price. The vault verifies the price signature and staleness, calculates the eToken amount after applying the spread, mints eTokens to the minter, and absorbs the collateral into the pool.

**Redeem**
Minter burns eTokens and provides a signed oracle price. The vault calculates the collateral payout after spread. If the buffer is sufficient the payout is immediate; if not, the liquidation engine sells collateral on a DEX to cover the shortfall.

**LP Deposit**
LP deposits collateral into the vault and receives ERC-4626 shares proportional to the current share price.

**LP Withdrawal**
LP burns shares and receives proportional collateral, subject to utilization and buffer constraints. If the vault is heavily utilized, withdrawals may be partially fulfilled or queued.

**Delegation**
LP sets a preferred vault manager. The vault manager accepts the delegation. From that point the manager is responsible for offchain hedging of the exposure attributable to that LP's share.

---

## 3. Vault Manager Model

Multiple vault managers can register on any vault. The relationship between LPs and vault managers is based on mutual agreement:

1. LP proposes delegation to a specific vault manager.
2. Vault manager accepts the delegation.
3. The delegation is now active; the manager is responsible for offchain hedging of the LP's proportional exposure.

LPs may also act as their own vault manager, in which case no external delegation is required.

### Vault Manager Responsibilities

- Offchain hedging for delegated LPs' exposure
- Setting a non-market-hour spread (opt-in per manager)
- Managing risk for their delegated portion of the vault

### Vault Manager Onchain State

| Field | Type | Description |
|---|---|---|
| `isActiveOffMarket` | `bool` | Whether the manager accepts mints/redeems outside market hours |
| `offMarketSpread` | `uint` | Custom spread applied during non-market hours (must be >= minSpread) |
| Delegated LP shares | mapping | Tracks which LPs have delegated and their proportional share |

---

## 4. Spread Model (Unified)

There is no separate protocol fee. Everything is captured through a single spread applied on every mint and redeem.

### Parameters

- **`minSpread`** — Protocol-enforced floor (e.g., 30 BPS). Guarantees minimum revenue on every operation. Set by the protocol admin.

### Market Hours Behavior

- Spread equals `minSpread`.
- Fully pooled liquidity: any mint or redeem hits the unified vault pool.

### Non-Market Hours Behavior

- Spread equals `max(minSpread, managerCustomSpread)`.
- Each vault manager independently opts in or out of non-market execution.
- Willing managers expose their delegated LPs' proportional share of the pool.
- Minters are routed to the best-priced (lowest spread) manager first; overflow routes to the next cheapest manager, and so on.

### Revenue Distribution

Spread revenue is split three ways according to a configurable ratio:

| Recipient | Description |
|---|---|
| Protocol | Platform revenue, controlled by protocol admin |
| Vault Manager | Compensation for hedging and risk management |
| LPs | Return on deposited collateral beyond any native yield |

The split percentages are set at the protocol level and may differ by vault type.

---

## 5. Collateral & Yield-Bearing Assets

| Collateral | Vault Asset | Yield | Notes |
|---|---|---|---|
| USDC | USDC | None | Simplest vault, no wrapping or rebasing |
| aUSDC | aUSDC | Aave lending yield | Balance rebases; ERC-4626 captures yield naturally via share price |
| ETH | WETH | None | Wrapped to WETH on deposit via router, unwrapped on withdrawal |
| stETH | wstETH | Lido staking yield | Wrapped to wstETH on deposit (non-rebasing); unwrapped to stETH on withdrawal |

The ERC-4626 `totalAssets()` function returns the current vault balance of the underlying asset. For yield-bearing collateral, this balance grows over time as yield accrues, which increases the share price. LPs therefore receive their proportional share of accrued yield automatically when they withdraw — no separate claim mechanism is needed.

### wstETH Wrapping Rationale

stETH is a rebasing token: holder balances change daily as staking rewards are distributed. This creates rounding issues in share accounting. The vault wraps stETH to wstETH (a non-rebasing wrapper) on deposit and stores wstETH internally. Yield still accrues because the wstETH-to-stETH exchange rate increases over time, which is reflected in `totalAssets()`. On withdrawal, wstETH is unwrapped back to stETH for the LP.

---

## 6. Oracle Design (MVP)

The MVP uses a pull-based, signed price feed operated by the protocol team.

### Flow

1. Protocol oracle service signs `(asset, price, timestamp)` with a known private key.
2. Minter or bot submits the signed price data as a transaction parameter.
3. The onchain oracle verifier checks the signature, confirms the signer is authorized, and enforces a staleness bound (e.g., price must be no older than 60 seconds).
4. If valid, the price is forwarded to the vault for mint/redeem calculation.

### Interface

The oracle verification layer exposes a generic interface that accepts a price payload and returns a validated price. This abstraction allows future backends (Pyth, Chainlink, multi-signer M-of-N) to be integrated without modifying vault or mint logic.

### Staleness & Safety

- Maximum price age is a configurable parameter per asset.
- If no valid price is available, mint operations revert.
- Redemptions may use the last known valid price within a wider staleness window to avoid trapping user funds.

---

## 7. Vault Health & Liquidation

Each vault maintains a collateral ratio defined as the total collateral value divided by the total outstanding eToken liability. Health parameters vary by collateral risk profile:

| Collateral | Min Ratio | Liquidation Threshold | Liquidation Reward |
|---|---|---|---|
| USDC | 110% | 103% | 1-2% |
| aUSDC | 115% | 105% | 2-3% |
| ETH / WETH | 200% | 155% | 5-10% |
| stETH / wstETH | 210% | 160% | 5-10% |

### Liquidation Process

1. A bot or keeper monitors vault health ratios offchain.
2. When the collateral ratio drops below the liquidation threshold, anyone can trigger a partial liquidation.
3. The liquidation engine sells a portion of vault collateral on a DEX (e.g., Uniswap) to bring the ratio back above the minimum.
4. The liquidator receives a reward (percentage of liquidated collateral) as incentive.

Liquidations are always partial — only enough collateral is sold to restore health. Full vault liquidation is not supported in the MVP.

---

## 8. Vault Halt Conditions

A vault can be halted under the following conditions:

- **Health failure** — Collateral ratio drops below a critical threshold and liquidation alone cannot restore it.
- **Oracle staleness** — No valid price update has been received within the maximum allowed window.
- **Vault-manager-initiated** — A vault manager requests a halt for their delegated portion (e.g., hedging failure).
- **Admin emergency** — Protocol admin triggers an emergency halt.

### Behavior When Halted

- No new mints are accepted.
- Redemptions continue to function (users must be able to exit).
- Liquidation continues to function (health must be recoverable).
- LP withdrawals continue subject to utilization constraints.

The halt is lifted by the protocol admin once the triggering condition is resolved.

---

## 9. Edge Cases

### Insufficient Redemption Buffer

If the vault does not hold enough idle collateral to fulfill a redemption, the liquidation engine sells collateral on a DEX. If DEX liquidity is insufficient, the redemption is partially fulfilled and the remainder is queued.

### Vault Manager Disappearance

Collateral remains locked onchain regardless of vault manager availability. If a manager goes offline, their delegated LPs' funds are still safe in the vault. LPs can re-delegate to a different manager or act as their own manager. Non-market-hour minting through the absent manager is simply unavailable.

### Oracle Manipulation Mitigations

- Signed prices are verified against a known signer set.
- Staleness bounds reject stale or replayed prices.
- Price deviation checks reject updates that diverge excessively from the last known price within a short window.
- The MVP oracle is protocol-operated, reducing the attack surface to key compromise (mitigated by key rotation and monitoring).

### Flash Loan Resistance

- Minting and redemption use externally signed prices, not onchain AMM prices, so flash-loan-driven price manipulation is ineffective.
- ERC-4626 share price is based on actual vault balances, not spot DEX rates.
- Deposits and withdrawals in the same transaction can be restricted if needed.

### LP Exit Constraints

- LPs cannot withdraw collateral that is actively backing outstanding eToken liabilities beyond the minimum ratio.
- Withdrawal requests that would push the vault below its minimum collateral ratio are rejected or partially fulfilled.
- In extreme utilization scenarios, LPs may need to wait for redemptions to free collateral before withdrawing.

---

## 10. Extension Points

The following capabilities are explicitly out of scope for the MVP but the architecture is designed to accommodate them:

- **Multi-signer oracle** — M-of-N signature verification for price feeds, reducing single-point-of-failure risk.
- **ZK attestation** — Zero-knowledge proofs of offchain hedging positions, enabling trustless verification of vault manager behavior.
- **Morpho looping** — Integration with Morpho to loop collateral for leveraged yield strategies within vaults.
- **Cross-chain deployment** — Deploying vaults and eTokens on additional L2s and L1s with bridged oracle data.
- **Permissionless asset listing** — Allowing anyone to propose new synthetic assets via governance rather than admin whitelisting.
- **Governance** — Onchain governance for fee parameters, asset listing, collateral ratios, and protocol upgrades.

---

## 11. Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Share standard | ERC-4626 | Industry-standard tokenized vault interface; composable with aggregators and yield tooling; automatic yield capture for rebasing/accruing assets |
| Fee model | Unified spread (no separate protocol fee) | Simpler UX, single parameter to reason about, minSpread guarantees revenue floor |
| Vault manager model | Delegation with mutual agreement | Lets LPs choose their risk manager; managers compete on spread and reputation; LPs retain self-management option |
| stETH handling | Wrap to wstETH internally | Avoids rebasing rounding errors in share accounting; yield still accrues via exchange rate |
| aUSDC handling | Hold aUSDC directly | ERC-4626 totalAssets() naturally reflects accrued Aave yield without additional accounting |
| Oracle (MVP) | Protocol-signed, pull-based | Fastest path to audit-ready; generic interface ensures future Pyth/Chainlink integration is non-breaking |
| Collateral per vault | One collateral type per vault | Simplifies accounting, risk parameterization, and liquidation logic; multi-collateral vaults deferred |
| Liquidation | Partial, DEX-based, bot-triggered | Capital-efficient; does not require protocol-held reserve; incentivized via liquidator reward |
| Non-market routing | Best-price-first across opted-in managers | Competitive dynamics drive spreads down; minters get best available price |
| Target chain | Base | Low gas costs, Coinbase ecosystem alignment, strong DeFi liquidity for USDC and ETH pairs |
