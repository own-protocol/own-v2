# Own Protocol v2 — MVP Product Requirements

**Target: Audit-Ready | March 2026**

---

## 1. MVP Scope

The MVP delivers an order-based protocol for tokenized RWA exposure on Base, with an escrow + claim marketplace, multi-collateral vaults as security pools, and vault manager delegation.

### 1.1 What's In

- Order-based minting and redemption via escrow + claim marketplace
- Market orders (with slippage) and limit orders
- Multi-stablecoin support for minters (USDC, USDT, USDS, etc.) — protocol whitelists accepted stablecoins, VMs set which they accept
- Multiple vaults, one per LP collateral type: USDC, aUSDC, ETH (as WETH), stETH (as wstETH internally)
- All vaults are public — multiple LPs deposit collateral, receive ERC-4626 shares
- Vaults act as insurance/guarantee pools — LP collateral is trustless security for pending orders
- Vault manager registration and LP delegation (mutual agreement)
- LPs can be their own vault manager (same interface, same infrastructure requirements)
- Unified spread model — VMs set their own spreads (>= minSpread floor), spread revenue split between VMs and LPs
- Protocol revenue via AUM fee on vault collateral (~0.5%/yr) + reserve factor on LP spread earnings (~10%), both configurable
- Offchain hedging by vault managers (no onchain hedging)
- eTokens as standard ERC20 + Permit per asset, with admin-updatable name/symbol
- Dividends via rewards-per-share accumulator (for dividend-paying assets like eTLT)
- Signed oracle price feeds (protocol-operated for MVP)
- Three-tier liquidation (eToken-based, organic LP deposit, DEX fallback)
- Vault halt mechanism (per-asset and vault-wide)
- Async LP withdrawal queue (ERC-7540 pattern)
- stETH vault wraps to wstETH on deposit, unwraps on withdrawal
- aUSDC vault — yield accrues naturally via ERC-4626 share price increase

### 1.2 What's Out (Post-MVP)

- Signed intents for atomic single-tx execution
- ZK proof attestation for offchain hedge positions
- Multi-signer oracle (M-of-N)
- Pyth / Chainlink oracle integration
- Morpho looping integration
- Governance and fee parameter voting
- Cross-chain deployment
- Permissionless asset listing
- Insurance fund from protocol spread revenue

---

## 2. Architecture Overview

The protocol is an order-based system with an escrow + claim marketplace. Minters pay in stablecoins, which go to vault managers for offchain hedge execution. LP collateral in vaults acts as trustless onchain security. Contract names and file structure are determined during implementation; what follows describes the logical responsibilities and interactions.

### Core Components

- **Order Escrow** — Holds minter stablecoins (for mints) or eTokens (for redeems) in escrow until a vault manager claims and fulfills the order. Supports market orders (with slippage), limit orders, directed orders (specific VM), open orders (any VM), and partial fills.

- **Collateral Vaults** — One ERC-4626 vault per LP collateral type. Holds pooled LP collateral as trustless security/guarantee for all pending orders. Vaults are NOT fund-flow intermediaries — minter stablecoins go to VMs via escrow, not through vaults. For yield-bearing assets (aUSDC, stETH/wstETH), the share price increases automatically as the underlying balance grows.

- **eTokens** — One ERC20 + EIP-2612 Permit token per synthetic asset (eTSLA, eGOLD, etc.). Mint and burn authority is restricted to the order system. eTokens are freely transferable and composable with external DeFi. Name and symbol are admin-updatable (stored as `string storage`) to support stock split token transitions. For dividend-paying assets, includes a rewards-per-share accumulator.

- **Asset Registry** — A whitelisted asset list maintained by the protocol admin. Maps each ticker to its active eToken address, oracle configuration, and collateral parameters. Tracks active vs legacy tokens (for post-split transitions).

- **Oracle Verification** — Accepts signed price data, verifies the signer, enforces staleness bounds, and exposes a generic interface so future backends (Pyth, Chainlink, multi-signer) can be swapped in without changing downstream consumers.

- **Vault Manager Layer** — Handles manager registration, LP-to-manager delegation, spread configuration, exposure caps, and stablecoin acceptance settings.

- **Liquidation Engine** — Monitors vault health ratios, triggers partial collateral liquidation when health drops below threshold, and pays liquidator rewards.

### Key Interactions

**Mint (Order-Based)**
1. Minter places a mint order: deposits stablecoins into escrow, specifies asset (eTSLA), price parameters (slippage or limit price), `allowPartialFill`, and optional `preferredVM`.
2. Any eligible VM calls `claimOrder()` to accept the order (full or partial). Stablecoins are released to the claiming VM.
3. VM buys the hedge offchain using the minter's stablecoins.
4. VM confirms execution onchain by submitting a signed oracle price.
5. Protocol verifies the execution price is within the minter's slippage tolerance.
6. eTokens are minted to the minter.
7. LP collateral in the vault acts as trustless security throughout.

**Redeem (Order-Based)**
1. Minter places a redeem order: eTokens are held in escrow, specifies price parameters and desired stablecoin for payout.
2. VM claims the order (must accept the requested stablecoin), unwinds the hedge offchain, and sends the requested stablecoins to the minter.
3. VM confirms execution with a signed oracle price.
4. Protocol verifies, burns the escrowed eTokens.
5. **Deadline enforcement**: if VM doesn't execute within the deadline, LP collateral is sold to pay the minter.

**LP Deposit**
LP deposits collateral into the vault and receives ERC-4626 shares proportional to the current share price. LP collateral acts as security for the protocol's outstanding exposure.

**LP Withdrawal (Async)**
LP submits a withdrawal request that enters a FIFO queue. The request is fulfilled when utilization allows (remaining collateral must still cover the minimum ratio for outstanding exposure). LPs can cancel pending requests at any time.

**Delegation**
LP sets a preferred vault manager. The vault manager accepts the delegation. From that point the manager is responsible for offchain hedging of the exposure attributable to that LP's share.

---

## 3. Escrow + Claim Marketplace

The escrow + claim marketplace is the core execution mechanism. It replaces protocol-assigned order routing with open competition among VMs.

### How It Works

- Orders sit in protocol escrow. All VMs can see them.
- VMs call `claimOrder(orderId, amount)` to accept an order (full or partial claim).
- First VM to claim gets priority (competitive — faster bots win).
- Large orders can be claimed in portions by multiple VMs independently.
- Each VM confirms their portion independently with a signed oracle price.
- eTokens are minted in tranches as each VM confirms.

### Order Modes

- **Open orders**: `preferredVM = address(0)`. Any eligible VM can claim.
- **Directed orders**: `preferredVM = <vmAddress>`. Only the specified VM can claim.
- **Cross-vault competition**: VMs from different vaults (e.g., USDC vault, ETH vault) can claim the same order. The security backing comes from whichever vault the claiming VM belongs to.

### Partial Fills

- Users set `allowPartialFill: true/false` on each order.
- If true: available VMs claim what they can; unfilled remainder is returned to the user.
- If false: order must be fully claimable or it is rejected.

---

## 4. Vault Manager Model

Multiple vault managers can register on any vault. The relationship between LPs and vault managers is based on mutual agreement:

1. LP proposes delegation to a specific vault manager.
2. Vault manager accepts the delegation.
3. The delegation is now active; the manager is responsible for offchain hedging of the LP's proportional exposure.

LPs may also act as their own vault manager. Self-managing LPs register as a VM with the same interface and are expected to run the same infrastructure (bots, monitoring, offchain hedge execution).

### Vault Manager Responsibilities

- Claiming and fulfilling mint/redeem orders via the escrow marketplace
- Offchain hedging for delegated LPs' exposure
- Setting their own spread (must be >= minSpread)
- Managing exposure within their self-set caps
- Confirming order execution with signed oracle prices

### Vault Manager Onchain State

| Field | Type | Description |
|---|---|---|
| `spread` | `uint` | VM's posted spread in BPS (must be >= minSpread) |
| `maxExposure` | `uint` | Max USD notional the VM is willing to hedge |
| `maxOffMarketExposure` | `uint` | Max exposure during off-market hours (typically lower) |
| `currentExposure` | `uint` | Tracked on claim/confirm — current outstanding notional |
| `acceptedStablecoins` | `mapping` | Which stablecoins this VM accepts for orders |
| `assetOffMarketEnabled` | `mapping` | Per-asset toggle for off-hours execution |
| Delegated LP shares | `mapping` | Tracks which LPs have delegated and their proportional share |

---

## 5. Spread & Slippage Model

### Spread (VM-Side)

There is no separate protocol fee. All revenue comes through the spread.

- Each VM sets their own spread onchain (in BPS). Must be >= `minSpread` (protocol-enforced floor).
- The spread is known upfront before the user places an order.
- Applied at execution on the oracle price:
  - **Mint**: user pays `oraclePrice * (1 + vmSpread)` per eToken
  - **Redeem**: user receives `oraclePrice * (1 - vmSpread)` per eToken
- VMs compete on spread — lower spreads attract more orders.
- VMs adjust their own spreads based on market conditions, risk, and hedging costs.

### Slippage (User-Side, Market Orders Only)

- Maximum oracle price movement tolerance between order placement and execution.
- Protects the user against price moving during async execution.
- Verification at confirmation: `|executionOraclePrice - placementOraclePrice| / placementOraclePrice <= slippage`
- Slippage is **separate from spread** — spread is the cost of service (known upfront), slippage is price risk tolerance.

### Limit Orders

- User sets an exact execution price. No slippage parameter.
- VM can only confirm when the oracle price matches (or is better than) the limit price.
- Order stays open until filled, cancelled, or expired.

### Revenue Distribution

Spread revenue from each order is split between VMs and LPs. The protocol earns separately via AUM fee and reserve factor — it does not take a direct cut of the spread.

| Recipient | Source | Description |
|---|---|---|
| Vault Manager | Spread (VM portion) | VM keeps their portion of spread revenue to cover hedging costs. VM receives full minter stablecoins — their spread portion is the profit margin after hedging. |
| LPs | Spread (LP portion) | Remaining spread revenue accrues to the vault, increasing LP share price. |
| Protocol | AUM fee | Annual fee on total vault collateral (~0.5%/yr default). Deducted continuously from `totalAssets()`. Steady revenue tied to TVL. |
| Protocol | Reserve factor | Percentage of LP spread earnings (~10% default). Skimmed from the LP portion before it accrues to the vault. Variable revenue tied to volume. |

**AUM fee implementation**: On every vault interaction (deposit, withdraw, claim, liquidation), the protocol calculates elapsed time since last fee accrual and deducts the proportional fee from `totalAssets()` to a protocol treasury address. Similar to Yearn's management fee.

**Reserve factor implementation**: When a VM confirms an order, the spread revenue attributable to LPs is calculated. The reserve factor percentage is deducted and sent to the protocol treasury. The remainder accrues to the vault. Similar to Aave's reserve factor and Uniswap's fee switch.

Both `aumFee` and `reserveFactor` are configurable by the protocol admin and can be updated at any time. They may differ per vault type.

**LP net earnings** = native yield (aUSDC/wstETH) + spread earnings after reserve factor - AUM fee.

### Protocol Controls

- **`minSpread`**: Protocol-enforced floor. No VM can set a spread below this. Guarantees minimum spread on every order.
- **`maxUtilization`**: Hard cap per vault. When vault utilization exceeds this threshold, VMs from that vault cannot claim new orders. Protects against insufficient security coverage.
- **`aumFee`**: Annual fee on vault collateral (default: 50 BPS / 0.5%). Configurable per vault.
- **`reserveFactor`**: Percentage of LP spread earnings taken by protocol (default: 10%). Configurable per vault.

---

## 6. Collateral & Yield-Bearing Assets

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

## 7. Oracle Design (MVP)

The MVP uses a pull-based, signed price feed operated by the protocol team. The oracle verifier is a **verification layer**, not a price feed — VMs submit prices, and the verifier checks validity.

### Flow

1. Protocol oracle service fetches prices from market data providers and signs `(asset, price, timestamp, sequenceNumber, marketOpen, chainId, contractAddress)` with a known ECDSA private key.
2. VM receives signed price data from the oracle service (via API or websocket).
3. VM submits the signed price data onchain when confirming an order.
4. The onchain oracle verifier recovers the signer via ECDSA, checks authorization, enforces staleness bounds, validates the sequence number, checks price deviation, and extracts market status.
5. If valid, the verified price and market status are returned to OwnMarket for order confirmation.

### Market Status

The oracle includes a per-asset `marketOpen` boolean in every signed price update. This allows OwnMarket to enforce different rules based on market state:

- **Market open**: VMs use their standard spread. Standard exposure caps apply.
- **Market closed**: VMs use their off-market spread (typically wider). `maxOffMarketExposure` caps apply. Per-asset off-hours toggles are checked.

Market hours differ by asset class (equities, commodities, bonds), so `marketOpen` is per-asset and determined by the oracle service.

### Backend-Agnostic Interface

The oracle verifier exposes a generic interface where `priceData` is opaque bytes — each backend implementation interprets it differently:

```
verifyPrice(bytes32 asset, bytes calldata priceData) → (price, timestamp, marketOpen)
```

Downstream contracts (OwnMarket, LiquidationEngine) only call `verifyPrice()` and receive a validated result. They never know or care what backend produced the data. This allows swapping backends without modifying any downstream contracts.

### Backend Implementations

| Backend | MVP? | priceData contents | Trust model |
|---|---|---|---|
| In-house signed oracle | Yes | price, timestamp, sequenceNumber, marketOpen, signature | Protocol-operated signer |
| Chainlink | Post-MVP | Asset identifier (reads from feed contract) | Chainlink node network |
| Pyth | Post-MVP | Pyth update data (Pyth verifies internally) | Pyth validator network |
| Multi-signer M-of-N | Post-MVP | price, timestamp, sequenceNumber, marketOpen, signature[] | M-of-N independent signers |
| Composite (multi-backend) | Post-MVP | Multiple backend payloads | Cross-checks between backends for extra safety |

To switch backends: deploy a new verifier contract implementing the interface, admin updates the verifier address in OwnMarket. No changes to OwnMarket, OwnVault, or LiquidationEngine.

### Why In-House Oracle for RWAs

Standard DeFi oracles (Chainlink, Pyth) have gaps for RWA price feeds: they may not update during off-market hours, may lack feeds for all listed assets, and have heartbeat intervals (1-60 min) that are too slow for tight spreads. The in-house oracle provides sub-second updates, off-market pricing, and permissionless asset coverage. Post-MVP, Chainlink/Pyth can serve as a validation layer alongside the in-house oracle (composite approach).

### Safety Mechanisms

| Mechanism | Description |
|---|---|
| Staleness bounds | Per-asset max price age (stocks: 60s, gold: 120s, treasuries: 300s) |
| Price deviation | Per-asset max movement from last known price (eTSLA: 10%, eGOLD: 5%, eTLT: 3%) |
| Sequence numbers | Monotonically increasing per asset; prevents replaying older valid prices |
| Chain ID + contract | Included in signed message; prevents cross-chain and cross-contract replay |
| Signer rotation | Admin can rotate the signer address without redeploying contracts |
| Market status | Per-asset marketOpen boolean; enables differentiated on/off-market behavior |

---

## 8. Vault Health & Liquidation

Each vault maintains a collateral ratio defined as the total LP collateral value divided by the total outstanding eToken exposure. Health parameters vary by collateral risk profile:

| Collateral | Min Ratio | Liquidation Threshold | Liquidation Reward |
|---|---|---|---|
| USDC | 110% | 103% | 1-2% |
| aUSDC | 115% | 105% | 2-3% |
| ETH / WETH | 200% | 155% | 5-10% |
| stETH / wstETH | 210% | 160% | 5-10% |

### Liquidation — Three Tiers

**Tier 1: Liquidator Provides eTokens (Primary)**
1. When the collateral ratio drops below the liquidation threshold, anyone can trigger a partial liquidation.
2. Liquidator provides eTokens by calling `liquidate(asset, eTokenAmount)`.
3. The vault burns the eTokens (reducing outstanding exposure).
4. The vault sends the liquidator equivalent LP collateral at a discount (liquidation reward).
5. Partial only — enough to restore the ratio above the minimum.

**Tier 2: New LP Deposits (Organic)**
- When a vault is distressed, the ERC-4626 share price drops (totalAssets/totalSupply).
- New LPs deposit at the depressed share price, increasing vault collateral and restoring the ratio.
- High utilization produces higher yield per LP share, naturally attracting new deposits.

**Tier 3: Vault Sells Collateral on DEX (Fallback)**
- If Tier 1 and 2 do not restore health within a time window, the vault can sell LP collateral on a DEX.
- Also triggered on redemption deadline expiry — if a VM fails to fulfill a redemption within the deadline, LP collateral is sold to pay the minter.

---

## 9. Vault Halt Conditions

### Triggers

| Trigger | Initiator | Scope |
|---|---|---|
| Health failure (ratio < critical) | Automatic | Entire vault |
| Oracle staleness | Automatic | Per asset |
| Price deviation circuit breaker | Automatic | Per asset |
| VM request | Vault Manager | VM's participation only |
| Admin emergency | Admin | Any vault or protocol-wide |

### Behavior When Halted

- No new orders are accepted.
- Pending orders can be cancelled by users (stablecoins returned).
- Redemptions continue to function (users must be able to exit).
- Liquidation continues to function (health must be recoverable).
- LP withdrawals continue subject to utilization constraints.

The halt is lifted by the protocol admin once the triggering condition is resolved.

### Wind-Down (Nuclear Option)

- Admin marks vault as "winding down."
- No new orders accepted, no new LP deposits.
- VMs must execute pending orders or return stablecoins to users.
- All remaining eTokens are redeemable at oracle price.
- After all eTokens are redeemed, LPs withdraw remaining collateral.
- Vault is decommissioned.

---

## 10. Edge Cases

### 10.1 Buffer Management

**Small orders**: VMs maintain pre-hedged buffer offchain. VM bots auto-confirm small orders in ~2 seconds from buffer. No buffer management issue.

**Large orders**: Standard async flow. VM receives stablecoins to execute offchain.

**VM exposure cap**: Each VM sets `maxExposure` onchain. When reached, the VM cannot claim new orders. Protocol has an optional `protocolMaxExposurePerVM` that can cap any single VM (available but not required to be set).

### 10.2 Market Closed

Same order model applies. VMs can execute during off-hours (pre/post-market, futures, etc.) at their own spread based on their risk and hedging model. The protocol does not restrict when VMs execute.

- `maxOffMarketExposure` per VM (typically lower than market-hours cap).
- Per-asset off-hours toggle per VM.
- If the user's slippage is exceeded by execution time, the order is unfulfilled and stablecoins are returned.
- Redemption deadline enforcement is always active regardless of market hours.

### 10.3 LP Exit — Async Withdrawal

LPs submit withdrawal requests that enter a FIFO queue (ERC-7540 pattern). Requests are fulfilled when utilization allows — remaining collateral must cover the minimum ratio for outstanding exposure.

- LPs can cancel pending requests at any time.
- On fulfillment: burn shares, transfer collateral, reduce delegation to VM, emit event.
- High utilization naturally produces higher yield per LP share, attracting new LP deposits and lowering utilization over time (organic equilibrium).

### 10.4 Liquidation

See Section 8 for the three-tier liquidation mechanism. Additional notes:

- Liquidation is always partial — only enough to restore the ratio above minimum.
- Liquidators can bootstrap by self-minting eTokens (deposit collateral → mint at oracle + spread → liquidate for discounted collateral → profit if discount > spread).
- Redemption deadline expiry triggers Tier 3 (LP collateral sold to pay the minter).

### 10.5 Bad Debt (Collateral < Liabilities)

LPs bear loss first — their collateral is the security layer they signed up to provide.

1. Liquidation (all tiers) sells LP collateral to reduce outstanding exposure.
2. LP share price drops as collateral is liquidated.
3. If still undercollateralized after all liquidation avenues are exhausted:
   - Vault auto-halts at `criticalRatio` (e.g., 100% for stablecoins, 120% for volatile assets).
   - Remaining redemptions are paid proportionally: `payout = eTokenAmount * (totalCollateral / totalLiabilities)`.
   - Bad debt socializes to eToken holders for the remaining shortfall.
4. Post-MVP: an insurance fund from the protocol's share of spread revenue provides a first-loss tranche.

### 10.6 Oracle Manipulation

- ECDSA signature verification against a known protocol signer.
- Per-asset staleness bounds reject stale prices.
- Price deviation checks reject prices that move too much from the last known value.
- Monotonic sequence numbers prevent replaying older valid prices.
- Chain ID and contract address are included in the signed message for replay prevention.
- Admin can rotate the signer address without redeploying.
- VM order confirmations are verified: the execution oracle price must be within the user's slippage parameters.

### 10.7 Pool Pause / Halt

See Section 9 for triggers, behavior, and wind-down procedures. Additional notes:

- Per-asset halt: if one asset's oracle is stale, only that asset's orders are halted. Other assets continue.
- VM-level pause: a VM can opt out of order routing without triggering a vault-wide halt. Their delegated LPs' collateral remains safe.
- Unhalt preconditions: vault health must be restored and the oracle must be providing valid prices.

### 10.8 Stock Splits — Soft Migration

- Old eToken continues to trade at pre-split price (e.g., eTSLA at $300 before a 3:1 split).
- Admin renames the old token (e.g., "eTSLA" → "eTSLA-legacy-1") via admin-updatable `name()`/`symbol()`.
- A new eToken deploys as "eTSLA" at the post-split price ($100) and takes the primary name.
- The asset registry tracks which token is the active version per asset.
- Old tokens remain valid and redeemable at the pre-split price.
- Migration is organic — users redeem old tokens over time as they exit positions. There is no arbitrage incentive (the economic value is identical pre/post).
- No forced migration, no friction for existing holders or DeFi positions.
- Oracle serves prices for both old and new tokens during the transition period.
- For reverse splits: same approach — old tokens at old price, new mints at new price.

### 10.9 Dividends — Rewards-Per-Share Accumulator

- Uses the standard staking rewards pattern (Synthetix/MasterChef).
- VM receives the actual dividend offchain (they hold the real hedge) and deposits equivalent stablecoins into the reward contract.
- `rewardsPerShare += dividendAmount / totalSupply`
- Any holder can claim at any time: `claimable = balance * (rewardsPerShare - userLastRewardsPerShare)`
- Pending rewards are auto-settled on every transfer (both sender and receiver).
- No snapshot needed. No double-claim possible. No claim deadline.
- eTSLA: no dividends (TSLA does not pay dividends). eGOLD: no dividends. eTLT: monthly dividends (~4% yield).
- DeFi composability: tokens held in Uniswap pools or other contracts accrue rewards to the contract address. Unclaimed rewards stay in the reward pool for MVP.

### 10.10 VM Default / Disappearance

- LP collateral remains safe onchain regardless of VM availability.
- If a VM goes offline, their delegated LPs can re-delegate to a different VM or register as their own VM.
- Pending orders claimed by the absent VM: if confirmation deadline passes, LP collateral is sold to pay the user (Tier 3 liquidation).
- Unclaimed open orders can be claimed by other VMs.

### 10.11 Flash Loan Resistance

- Minting: stablecoins exit to VM via escrow. They cannot be recovered in the same transaction, so flash-borrowed stablecoins cannot be repaid.
- Redemption: eTokens are burned. Flash-borrowed eTokens cannot be returned.
- The only flash-loan-enabled use case is healthy DEX arbitrage (mint + sell on DEX, or buy on DEX + redeem), which is beneficial for price alignment.

---

## 11. Extension Points

The following capabilities are explicitly out of scope for the MVP but the architecture is designed to accommodate them:

- **Signed intents** — Atomic single-transaction execution (user signs EIP-712 intent, VM fills in one tx). Deferred to Phase 2 for UX optimization.
- **Multi-signer oracle** — M-of-N signature verification for price feeds, reducing single-point-of-failure risk.
- **ZK attestation** — Zero-knowledge proofs of offchain hedging positions, enabling trustless verification of vault manager behavior.
- **Morpho looping** — Integration with Morpho to loop collateral for leveraged yield strategies within vaults.
- **Cross-chain deployment** — Deploying vaults and eTokens on additional L2s and L1s with bridged oracle data.
- **Permissionless asset listing** — Allowing anyone to propose new synthetic assets via governance rather than admin whitelisting.
- **Governance** — Onchain governance for fee parameters, asset listing, collateral ratios, and protocol upgrades.
- **Insurance fund** — A portion of protocol spread revenue funds a first-loss insurance pool for bad debt events.

---

## 12. Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Execution model | Order-based with escrow + claim marketplace | Bridges onchain/offchain gap correctly; VMs compete openly; flash-loan resistant; supports async and near-instant execution |
| Share standard | ERC-4626 | Industry-standard tokenized vault interface; composable with aggregators and yield tooling; automatic yield capture for rebasing/accruing assets |
| Fee model | Spread (VM + LP) + AUM fee + reserve factor | Spread goes to VMs and LPs. Protocol earns via AUM fee (TVL-based, steady) and reserve factor (volume-based, variable). VM hedge capital untouched. Inspired by Aave reserve factor + Yearn management fee. |
| Vault role | Insurance/guarantee pool | LP collateral is security, not fund-flow intermediary; minter stablecoins go directly to VMs |
| Vault manager model | Delegation with mutual agreement | LPs choose their risk manager; managers compete on spread and reputation; LPs retain self-management option |
| Order routing | Escrow + claim (open marketplace) | No protocol routing logic needed; VMs self-select; cross-vault competition; handles splits organically |
| Spread vs slippage | Separated | Spread = cost of service (VM-set, known upfront). Slippage = price movement tolerance (user-set). Clean separation of concerns. |
| Minter payment | Any whitelisted stablecoin | VMs set which they accept; routing filters by token; maximizes accessibility |
| stETH handling | Wrap to wstETH internally | Avoids rebasing rounding errors in share accounting; yield still accrues via exchange rate |
| aUSDC handling | Hold aUSDC directly | ERC-4626 totalAssets() naturally reflects accrued Aave yield without additional accounting |
| Oracle (MVP) | Protocol-signed, pull-based, with market status | Fastest path to audit-ready; includes per-asset marketOpen boolean; backend-agnostic interface (opaque priceData bytes) ensures future Pyth/Chainlink/multi-signer integration is non-breaking |
| Collateral per vault | One collateral type per vault | Simplifies accounting, risk parameterization, and liquidation logic |
| Liquidation | Three-tier: eToken-based, organic LP, DEX fallback | Covers all scenarios; primary mechanism directly reduces liabilities; organic mechanism provides natural recovery |
| Stock splits | Soft migration with admin-updatable token name | No forced migration; no supply changes; old tokens stay valid; composability preserved |
| Dividends | Rewards-per-share accumulator | No snapshots needed; transfer-safe; standard proven pattern; works for continuous accrual |
| LP withdrawal | Async queue (ERC-7540) | Handles high-utilization scenarios gracefully; FIFO fairness; cancellable |
| Target chain | Base | Low gas costs, Coinbase ecosystem alignment, strong DeFi liquidity for USDC and ETH pairs |
