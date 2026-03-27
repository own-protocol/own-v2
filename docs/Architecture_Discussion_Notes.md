# Own Protocol V2 -- Architecture Discussion Notes

This document captures the architectural discussions and design decisions from the Own Protocol V2 design sessions. It serves as a detailed technical reference for contributors and auditors.

---

## Table of Contents

1. [Protocol Overview & Contract Architecture](#1-protocol-overview--contract-architecture)
2. [ERC-4626 Vault Deep Dive](#2-erc-4626-vault-deep-dive)
3. [Rebasing Token Handling](#3-rebasing-token-handling)
4. [Token Transfer Edge Cases](#4-token-transfer-edge-cases)
5. [ERC-7575 Multi-Asset Vaults](#5-erc-7575-multi-asset-vaults)
6. [T-Bill Tokenization Design](#6-t-bill-tokenization-design)
7. [Oracle Architecture](#7-oracle-architecture)
8. [Oracle Swappability](#8-oracle-swappability)
9. [Vault Exposure & Utilization Tracking](#9-vault-exposure--utilization-tracking)
10. [Asset Config & Risk Parameters](#10-asset-config--risk-parameters)
11. [Withdrawal Safety Gap](#11-withdrawal-safety-gap)
12. [ZK Proofs for Oracle & Utilization](#12-zk-proofs-for-oracle--utilization)
13. [Pyth & Chainlink for RWA Feeds](#13-pyth--chainlink-for-rwa-feeds)
14. [forceApprove Pattern](#14-forceapprove-pattern)
15. [Fee Model: Mint & Redemption Fees](#15-fee-model-mint--redemption-fees-replacing-spread-revenue)
16. [Fee Accrual & Distribution](#16-fee-accrual--distribution)
17. [VM Strategy Declaration](#17-vm-strategy-declaration-delta-neutral-vs-short)
18. [Protocol Registry](#18-protocol-registry-centralized-contract-address-management)
19. [LP Exit Queue & Redemption Enforcement](#19-lp-exit-queue--redemption-enforcement)

---

## 1. Protocol Overview & Contract Architecture

**Status: Decided**

### Core Contracts

| Contract | Role |
|---|---|
| **OwnMarket** | Escrow marketplace -- accepts user orders (mint/redeem), holds funds in escrow, releases eTokens or underlying on fulfillment |
| **OwnVault** | ERC-4626 collateral vault -- LPs deposit collateral (e.g., USDC, WETH), receive vault shares representing their pro-rata claim |
| **VaultManager (VM)** | Authorized operator that fulfills orders, manages vault capital, bridges on-chain collateral to off-chain brokerage operations |
| **EToken** | ERC-20 tokens representing tokenized real-world assets (e.g., eAAPL, eTSLA, eTBILL) |
| **OracleVerifier** | Verifies signed price data on-chain -- ECDSA signature verification against an authorized signer |
| **AssetRegistry** | Registry of supported real-world assets with configuration (active status, risk parameters) |
| **PaymentTokenRegistry** | Registry of accepted payment/collateral tokens (USDC, WETH, etc.) |
| **LiquidationEngine** | Handles liquidation of undercollateralized vault positions via a 3-tier mechanism |
| **Routers** | Convenience contracts (e.g., WETHRouter) that wrap ETH/WETH conversions for user-facing flows |

### Main User Journeys

#### Minting eTokens (Buy RWA exposure)

1. User places a mint order on OwnMarket, depositing payment tokens (e.g., USDC) into escrow.
2. OracleVerifier provides a signed price for the target asset.
3. VaultManager claims the order -- payment moves from escrow into the OwnVault as collateral.
4. VaultManager mints the corresponding eTokens to the user.
5. Off-chain, the VM hedges by purchasing the actual asset via brokerage.

#### Redeeming eTokens (Sell RWA exposure)

1. User places a redeem order on OwnMarket, depositing eTokens into escrow.
2. OracleVerifier provides a signed price.
3. VaultManager claims the order -- burns the eTokens, releases payment tokens from OwnVault to the user.
4. Off-chain, the VM sells the corresponding asset.

#### LP Deposits / Withdrawals

1. **Deposit**: LP calls `deposit()` or `mint()` on OwnVault, depositing collateral and receiving vault shares.
2. **Withdrawal**: LP requests withdrawal. A keeper (or VM) fulfills the withdrawal, returning collateral proportional to shares burned. Withdrawal fulfillment is an explicit step (not instant) to prevent front-running and ensure vault health.

#### VaultManager Operations

- Claim mint/redeem orders from OwnMarket.
- Manage collateral allocation.
- Interact with OwnVault to deposit/withdraw capital for off-chain hedging.

#### Liquidation (3-Tier)

The LiquidationEngine enforces vault health through three escalating tiers:

1. **Tier 1 -- Margin Call**: VM is notified and given a grace period to restore collateralization.
2. **Tier 2 -- Forced Rebalance**: Protocol can force the VM to rebalance positions.
3. **Tier 3 -- Full Liquidation**: Vault is unwound; LPs are made whole (to the extent possible) from remaining collateral and any liquidation rewards.

---

## 2. ERC-4626 Vault Deep Dive

**Status: Decided**

### Core Mechanics

ERC-4626 is a standard for tokenized vaults. The fundamental relationship is between **shares** (vault tokens) and **assets** (underlying tokens like USDC).

```
exchangeRate = totalAssets() / totalSupply()
```

- **shares to assets**: `shares * totalAssets() / totalSupply()`
- **assets to shares**: `assets * totalSupply() / totalAssets()`

**Rounding directions** are critical for vault security:
- When the vault gives assets to the user (withdraw, redeem): round **down** on assets, round **up** on shares burned. The vault never overpays.
- When the user gives assets to the vault (deposit, mint): round **up** on assets required, round **down** on shares minted. The vault never underpays.

### The Four Entry/Exit Functions

| Function | User specifies | User receives | Direction |
|---|---|---|---|
| `deposit(assets, receiver)` | Exact assets in | Shares out (calculated) | Entry |
| `mint(shares, receiver)` | Exact shares out | Assets in (calculated) | Entry |
| `withdraw(assets, receiver, owner)` | Exact assets out | Shares burned (calculated) | Exit |
| `redeem(shares, receiver, owner)` | Exact shares burned | Assets out (calculated) | Exit |

### Preview Functions

Each entry/exit function has a corresponding preview:
- `previewDeposit(assets)` returns shares
- `previewMint(shares)` returns assets
- `previewWithdraw(assets)` returns shares
- `previewRedeem(shares)` returns assets

These allow UIs and integrators to display expected outcomes before committing.

### `totalAssets()` as the Override Point

`totalAssets()` is the single function that defines how much underlying value the vault holds. It is the primary override point for custom vault behavior. In OwnVault, this returns the actual balance of the underlying token held by the vault contract. Any yield, fees, or losses are reflected by changes to `totalAssets()` relative to `totalSupply()`.

### What ERC-4626 CAN Do

- **Automatic fair share accounting**: LPs get proportional claims without explicit bookkeeping.
- **Composability**: Any ERC-4626 vault can be plugged into DeFi protocols that understand the standard (aggregators, yield optimizers, lending markets).
- **Yield without claiming**: As `totalAssets()` grows relative to `totalSupply()`, each share is worth more -- yield accrues automatically.
- **Standardized integration**: Wallets, dashboards, and aggregators can display vault positions uniformly.

### What ERC-4626 CANNOT Do

- **Async operations**: Deposits/withdrawals are synchronous. For async (like Own's keeper-fulfilled withdrawals), custom logic must wrap the standard functions.
- **Multiple underlying assets**: The standard assumes a single `asset()`. Multi-collateral vaults require extensions (see ERC-7575).
- **Access control on deposits**: The standard has no built-in permissioning. OwnVault adds `whenActive` and role checks on top.
- **Track what assets are backing**: The vault knows `totalAssets()` but has no concept of individual asset positions or what the collateral is backing.
- **Non-fungible positions**: All shares are fungible. There is no way to distinguish LP-A's shares from LP-B's shares for different terms.
- **Fee-on-withdraw**: The standard does not natively support withdraw fees. Custom logic is required.
- **Handle rebasing tokens**: The standard assumes a fixed-balance underlying. Rebasing tokens cause accounting drift (see Section 3).

### The Inflation Attack & OZ v5 Mitigation

The classic ERC-4626 inflation attack:

1. Attacker deposits 1 wei to get 1 share.
2. Attacker donates a large amount of the underlying directly to the vault.
3. Now `totalAssets()` is large but `totalSupply()` is 1 share.
4. Next depositor's deposit rounds down to 0 shares -- attacker gets everything.

**OpenZeppelin v5 mitigation**: A virtual offset is applied to both `totalAssets()` and `totalSupply()` in the share calculation:

```solidity
// OZ v5 ERC4626 internals (simplified)
function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
    return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
}
```

The `_decimalsOffset()` (default 0, typically set to match underlying decimals) creates a virtual supply that makes the attack economically infeasible. The attacker would need to donate an astronomically large amount to move the exchange rate.

### OwnVault's Additions

OwnVault's `deposit()` and `mint()` are thin guard wrappers on top of OZ's ERC4626 implementation:

```solidity
function deposit(uint256 assets, address receiver)
    public override whenActive nonReentrant returns (uint256)
{
    return super.deposit(assets, receiver);
}
```

The guards add:
- `whenActive`: Vault must not be paused or in shutdown.
- `nonReentrant`: Prevents reentrancy attacks during deposit/mint flows.

The core share/asset math is entirely inherited from OpenZeppelin.

---

## 3. Rebasing Token Handling

**Status: Recommended -- wrap rebasing tokens via standard wrappers**

### The stETH Problem

Lido's stETH is a rebasing token: holder balances increase daily to reflect staking rewards. This creates three issues for ERC-4626 vaults:

1. **Balance changes without transfers**: `totalAssets()` drifts upward between transactions. Share accounting becomes inconsistent with actual balances.
2. **Transfer rounding dust**: stETH transfers can lose 1-2 wei due to internal shares-to-balance conversion. Over many transfers, this dust accumulates.
3. **ERC-4626 accounting drift**: The vault's `totalAssets()` changes between blocks even with no deposits or withdrawals, breaking the assumption that `totalAssets()` only changes on vault operations.

### wstETH Solution

Lido provides **wstETH** (wrapped stETH) -- a non-rebasing wrapper:

- Fixed balance: 1 wstETH always equals 1 wstETH in your wallet.
- The wstETH/stETH conversion rate appreciates over time as staking rewards accrue.
- ERC-4626 compatible: `totalAssets()` only changes when actual deposits/withdrawals occur.
- No transfer dust.

### aUSDC (Aave aTokens)

Aave v2/v3 aTokens (e.g., aUSDC) exhibit the same rebasing behavior -- balances increase as lending interest accrues. The dust issue is smaller with USDC's 6 decimals (vs stETH's 18), but it still exists.

### Aave's stataTokens (Static aTokens)

Aave provides **stataTokens** -- ERC-4626 wrappers around aTokens:

- Use rate-based conversion instead of balance-based.
- The wrapper holds aTokens internally and tracks the exchange rate.
- External balance is fixed; value appreciates through the exchange rate.
- Directly compatible with ERC-4626 vaults.

### Options Considered

| Approach | Pros | Cons |
|---|---|---|
| **Wrap it** (wstETH, stataToken) | Cleanest, no accounting drift, ERC-4626 compatible | Extra contract interaction, wrapping gas cost |
| **Use raw** (pragmatic for 6-decimal) | Simpler, fewer dependencies | Dust accumulation, accounting drift, non-standard |
| **Internal accounting** (defensive) | Can handle any token | Complex, error-prone, more code to audit |

### Recommendation

**Wrap aUSDC via Aave's staticAToken** for consistency with the stETH/wstETH approach. Both rebasing tokens get the same treatment:

- stETH -> wstETH (Lido wrapper)
- aUSDC -> stataUSDC (Aave staticAToken wrapper)

This gives OwnVault a uniform assumption: all underlying tokens have fixed balances that only change on explicit transfers.

---

## 4. Token Transfer Edge Cases

**Status: Decided -- add rescueTokens() admin function**

### Sending the Wrong Token (e.g., USDC to a WETH vault)

If a user accidentally sends USDC directly to a vault that uses WETH as its underlying:

- The USDC is **invisible to share accounting** -- `totalAssets()` only counts WETH.
- The USDC is **stuck forever** with no recovery mechanism.
- Share prices are unaffected (the USDC doesn't enter the WETH accounting).

**Mitigation**: Implement a `rescueTokens(address token, address to, uint256 amount)` admin function that can recover non-underlying tokens sent to the vault. This function must explicitly revert if `token == asset()` to prevent admin from draining the actual collateral.

### Sending the Underlying Directly (e.g., WETH to a WETH vault)

If someone sends the underlying token directly to the vault contract (not through `deposit()`):

- `totalAssets()` increases (it reads the vault's actual balance).
- `totalSupply()` stays the same (no new shares were minted).
- The exchange rate `totalAssets() / totalSupply()` increases.
- This effectively **donates value to all existing LPs** via a share price increase.

This is closely related to the inflation attack vector (Section 2). The OZ v5 virtual offset mitigates the attack variant, but the donation effect remains by design -- it is a feature of ERC-4626 that direct transfers benefit existing shareholders.

---

## 5. ERC-7575 Multi-Asset Vaults

**Status: Deferred -- future consideration**

ERC-7575 extends ERC-4626 to support vaults with multiple underlying assets. This is relevant for a future scenario where OwnVault accepts multiple collateral types (e.g., USDC + WETH) in a single vault rather than requiring separate vaults per collateral type.

Not needed for MVP. Noted as a potential upgrade path if multi-collateral vaults become a requirement.

---

## 6. T-Bill Tokenization Design

**Status: Decided -- Rolling NAV token approach**

### Background: T-Bill vs. Treasury Note Characteristics

| Instrument | Coupon | Maturity | Price Behavior |
|---|---|---|---|
| **T-Bill** | Zero coupon, bought at discount, matures at par ($100) | 4-52 weeks | Very stable, price appreciates toward par |
| **10Y Treasury Note** | Semi-annual coupon | 10 years | Price volatile with interest rate changes (duration risk) |

Tokenized products in the market (e.g., Ondo's OUSG, Backed's bIB01) mostly use **T-Bills** for their stable, appreciating NAV.

### Three Approaches Considered

#### Approach A: Discount Token (mirrors actual T-Bill)

- Each eToken represents a specific T-Bill cohort (e.g., "13-week T-Bill maturing June 2026").
- Token minted at discount, redeemable at par on maturity.
- **Problem**: Cohort fragmentation. Each maturity date creates a new token. Liquidity is split across cohorts. Rolling into new T-Bills requires redeem + re-mint.
- **Verdict**: Rejected due to fragmentation.

#### Approach B: Rolling NAV Token (Recommended)

- Single token: `eTBILL`.
- Price appreciates continuously as underlying T-Bills accrue toward par.
- VaultManager handles rolling off-chain: as T-Bills mature, proceeds are reinvested into new T-Bills.
- Oracle provides the current NAV price (reflecting the weighted average of the underlying T-Bill portfolio).
- Users see a single token with a steadily rising price.

**Why this fits Own Protocol**:
- Oracle provides NAV price -- same infrastructure as equity eTokens.
- VM buys/rolls T-Bills off-chain -- same operational model.
- Single token, single liquidity pool, no fragmentation.
- `eTBILL` price appreciates continuously -- LPs and holders both benefit from clean accounting.

#### Approach C: Yield-Bearing Vault Token

- T-Bill yield accrues directly to a vault share token.
- Bypasses the marketplace entirely.
- **Verdict**: Doesn't fit Own's architecture, which requires marketplace-mediated minting/redeeming.

### Risk Parameters for T-Bills

T-Bills are extremely low volatility, so collateral ratios can be much tighter:

| Asset Class | Typical Collateral Ratio | Buffer |
|---|---|---|
| T-Bills | 101-105% | 1-5% |
| Equities (AAPL) | 120-130% | 20-30% |
| Volatile equities (TSLA) | 140-150% | 40-50% |

### Vault Manager Simplification

Since T-Bill "hedging" is simply buying the bill (no complex hedge strategy), a single authorized VM may suffice for T-Bill vaults, rather than a competitive multi-VM model.

---

## 7. Oracle Architecture

**Status: Decided for MVP; evolution path defined**

### Current Design: Signed Oracle

A single off-chain signer service signs price data. The on-chain `OracleVerifier` contract verifies the ECDSA signature.

#### Signed Message Structure

The signed payload includes:

| Field | Purpose |
|---|---|
| `asset` | Asset identifier (e.g., bytes32 of "AAPL") |
| `price` | Price in USD, scaled to appropriate decimals |
| `timestamp` | When the price was observed |
| `marketOpen` | Boolean: is the market currently open? |
| `sequenceNumber` | Monotonically increasing, prevents replay and ensures ordering |
| `chainId` | Target chain (prevents cross-chain replay) |
| `contractAddress` | Target OracleVerifier address (prevents cross-contract replay) |

#### On-Chain Verification Checks

1. **Authorized signer**: `ecrecover` matches the registered signer address.
2. **Staleness**: `block.timestamp - priceData.timestamp < maxStaleness`.
3. **Sequence number**: Must be strictly greater than the last accepted sequence number (monotonic).
4. **Deviation**: Price deviation from last accepted price within configured bounds (circuit breaker).

#### Gas Cost

On Base L2, `verifyPrice()` costs approximately **25-40k gas** (~$0.01-0.05 at typical gas prices).

### Infrastructure Required

#### Price Signer Service (Critical Path)

The signer service is the most critical piece of infrastructure. It must be:
- Highly available (downtime = users cannot trade).
- Secure (key compromise = protocol risk).
- Accurate (wrong prices = incorrect minting/redeeming).

#### Key Management Options

| Option | Cost | Security | Complexity |
|---|---|---|---|
| **AWS CloudHSM** | ~$1,100/month | FIPS 140-2 Level 3 | High |
| **AWS KMS** | ~$1/month | FIPS 140-2 Level 2 | Low |
| **Self-hosted HSM** | $5,000+ upfront | Highest | Very High |
| **Multisig** (Gnosis Safe-style) | Gas costs only | Good (distributed) | Medium |

#### Price Data Feed Sources

- **Primary**: IEX Cloud, Polygon.io, Alpha Vantage (traditional finance data providers).
- **Cross-reference**: Pyth, Chainlink (on-chain oracles for sanity checks).
- **Aggregation**: Multi-source median with outlier rejection.

#### Monitoring & Alerting

- Signer uptime monitoring.
- Price deviation alerts (if published price diverges from reference sources).
- Sequence number gap detection.
- Staleness alerting (if prices not updating).

#### Total Operational Cost Estimate

~$200-2,300/month depending on key management choice and data feed subscriptions.

### Risks & Mitigations

#### Key Compromise

| Mitigation | Description |
|---|---|
| HSM/KMS | Private key never leaves hardware security module |
| Rate limiting | Max N price updates per minute |
| Deviation checks | On-chain circuit breaker rejects wild prices |
| Future M-of-N | No single key can publish prices (see below) |

#### Downtime

| Mitigation | Description |
|---|---|
| Redundant instances | Multiple signer instances across regions |
| Staleness window | Orders can still settle within the staleness window |
| Order deadlines | Users set max acceptable delay |

#### Stale Price Exploitation

An attacker could try to use old-but-valid prices if the signer goes down.

| Mitigation | Description |
|---|---|
| `maxStaleness` | On-chain rejection of prices older than threshold |
| Sequence numbers | Prevents replaying old signed data |
| Slippage checks | Users specify acceptable price range |

#### Price Source Manipulation

| Mitigation | Description |
|---|---|
| Multi-source aggregation | Median of 3+ sources |
| Cross-reference | Compare traditional feeds against on-chain oracles |
| Circuit breakers | Reject prices deviating > X% from last known |

### M-of-N Signing: Three Approaches

#### Approach A: Multi-sig on Same Price

All M-of-N signers must agree on the **exact same price** before signing. Requires an off-chain consensus round.

```
Off-chain: Signers negotiate price -> all sign same (asset, price, timestamp, ...)
On-chain:  Contract verifies M signatures against the same message
Gas:       ~9-15k additional per extra signature verification
```

- **Pro**: Simple on-chain logic.
- **Con**: Off-chain consensus protocol needed. Single point of failure if consensus stalls.

#### Approach B: Threshold Signatures (TSS)

M-of-N parties use MPC (multi-party computation) to produce a **single ECDSA signature**. The on-chain contract is completely unchanged -- it sees one signature from one address.

```
Off-chain: M parties participate in TSS protocol -> produce single signature
On-chain:  Existing verifyPrice() unchanged -- single ecrecover
Gas:       Zero additional gas
Contract:  Zero changes required
```

- **Pro**: No contract changes. No additional gas. Clean upgrade from single signer.
- **Con**: Requires TSS infrastructure (e.g., tss-lib, multi-party-ecdsa). Key ceremony for share distribution.

#### Approach C: Independent Signers + On-Chain Aggregation

Each signer independently fetches prices and signs their own price data. The contract verifies all signatures and takes the **median** price.

```
Off-chain: Each signer independently signs their observed price
On-chain:  Contract verifies all M signatures, takes median price
           Deviation check: reject any signer > X% from median (detects compromise)
Gas:       Higher (M verifications + sort + median)
```

- **Pro**: Most decentralized. No off-chain coordination. Detects compromised signers.
- **Con**: Higher gas cost. More complex on-chain logic.

#### Decision

- **MVP**: Approach B (Threshold Signatures). Zero contract changes, zero additional gas. Requires TSS infrastructure but keeps on-chain simplicity.
- **Production**: Migrate to Approach C (Independent Signers) or integrate with Pyth. Approach C provides the strongest security properties and signer accountability.

---

## 8. Oracle Swappability

**Status: Recommended -- implement admin setter with timelock**

### Current Issue

The oracle address is declared as `immutable` in both `OwnMarket` and `LiquidationEngine`. This means the oracle implementation cannot be changed after deployment without redeploying the consuming contracts.

### Recommendation

Make the oracle updatable via an admin-controlled setter with a timelock delay:

```solidity
address public oracle;
address public pendingOracle;
uint256 public oracleUpdateTimestamp;
uint256 public constant ORACLE_UPDATE_DELAY = 48 hours;

function proposeOracle(address newOracle) external onlyAdmin {
    pendingOracle = newOracle;
    oracleUpdateTimestamp = block.timestamp;
    emit OracleUpdateProposed(newOracle, block.timestamp + ORACLE_UPDATE_DELAY);
}

function executeOracleUpdate() external onlyAdmin {
    require(block.timestamp >= oracleUpdateTimestamp + ORACLE_UPDATE_DELAY, "Timelock not expired");
    require(pendingOracle != address(0), "No pending update");
    oracle = pendingOracle;
    pendingOracle = address(0);
    emit OracleUpdated(oracle);
}
```

The 48-hour delay gives LPs and users time to react if a malicious oracle update is proposed.

### Why This Matters

The `IOracleVerifier` interface is abstract -- consuming contracts call `verifyPrice()` without knowing the implementation. This enables swapping in:

- A ZK oracle (see Section 12).
- A Pyth adapter.
- A Chainlink adapter.
- A multi-signer aggregator (Approach C from Section 7).
- Any future oracle design.

The consuming contracts (OwnMarket, LiquidationEngine) never need to change.

---

## 9. Vault Exposure & Utilization Tracking

**Status: Decided -- single running counter + off-chain utilization oracle**

This is a key architecture decision that affects scalability, gas costs, and accuracy.

### The Problem

Vault **exposure** is defined as:

```
exposure = SUM over all assets( eToken.totalSupply(asset) * currentPrice(asset) )
```

Both dimensions are dynamic:
- `eToken.totalSupply()` changes with every mint/redeem.
- `currentPrice()` changes continuously with market movements.

For non-stablecoin vaults, the collateral value is also dynamic (e.g., WETH vault -- WETH price moves).

**Iterating over thousands of assets on-chain is not viable** -- the gas cost scales linearly with the number of supported assets and would exceed block gas limits for any meaningful number of assets.

### Approaches Analyzed

| # | Approach | Accuracy | Gas | Feasibility |
|---|---|---|---|---|
| 1 | Fully on-chain real-time | Stale the moment prices move | O(n) per query | Not viable |
| 2 | Account in units, price at query time | Accurate | Requires oracle calls for ALL assets | Expensive, O(n) |
| 3 | Hybrid cached + periodic snapshot | Approximate | Keeper tx per snapshot | Staleness gap |
| 4 | Hybrid + inline refresh on critical paths | Better | Still O(n) for full snapshot | Complex |

None of these scale to hundreds or thousands of assets.

### The Solution: Single Running Counter

The vault tracks a single number:

```solidity
uint256 public totalCommittedUSD;
```

This counter is updated atomically on every mint and redeem at the execution price:

- **On mint**: `totalCommittedUSD += eTokenAmount * executionPrice`
- **On redeem**: `totalCommittedUSD -= eTokenAmount * executionPrice`

Utilization is then:

```solidity
function utilization() public view returns (uint256) {
    return totalCommittedUSD * BPS / totalAssets();
}
```

This is **one SLOAD** -- constant gas regardless of whether the vault backs 1 asset or 10,000 assets.

### Why This Works: Collateral Ratio as Price Drift Buffer

The `totalCommittedUSD` counter does not track real-time price changes -- it records the USD value at the moment of each mint/redeem. The gap between this recorded value and the actual current exposure is the **price drift**.

The collateral ratio IS the price drift buffer. That is its design purpose:

| Asset Volatility | Collateral Ratio | Drift Buffer | Meaning |
|---|---|---|---|
| T-Bills (very low vol) | 105% | 5% | T-Bill prices won't move more than 5% |
| Blue-chip equities (moderate vol) | 125% | 25% | Can absorb 25% price swing |
| Volatile equities (high vol) | 150% | 50% | Can absorb 50% price swing |

For non-stablecoin vaults (e.g., WETH collateral), the collateral ratio must be higher to absorb **double drift** -- both the eToken price and the collateral price can move.

### When Precision Matters: Liquidation Time

Precise health is computed **only at liquidation time**. The liquidator provides fresh signed price data for the specific assets in question and pays the gas cost for verification. This is acceptable because:

- Liquidation is infrequent.
- Liquidators are economically motivated (they earn liquidation rewards).
- The gas cost is borne by the liquidator, not the protocol.

### Off-Chain Utilization Oracle (Recommended Enhancement)

The same signed oracle pattern used for prices can be applied to utilization:

1. An off-chain service maintains a complete view of all eToken supplies (via an indexer) and live prices.
2. It computes precise utilization: `SUM(eToken.totalSupply(asset) * livePrice(asset)) / vaultTotalAssets()`.
3. It signs the result and publishes it.
4. On-chain: one ECDSA verification -- constant gas regardless of asset count.

```solidity
struct SignedUtilization {
    address vault;
    uint256 utilization;     // in BPS
    uint256 totalExposure;   // USD value
    uint256 timestamp;
    uint256 sequenceNumber;
    bytes signature;
}
```

This can be bundled with price data in a single signed payload.

**Belt and suspenders**: Keep the on-chain `totalCommittedUSD` counter as a sanity check and circuit breaker. If the signed utilization diverges significantly from the on-chain approximation, something is wrong.

**Trust model**: Same as the price oracle -- no additional trust assumptions. The utilization oracle is trusted to the same degree as the price oracle.

**Who pays**: The caller in each context:
- VM pays on `claimOrder()`
- Keeper pays on `fulfillWithdrawal()`
- Liquidator pays on `liquidate()`

---

## 10. Asset Config & Risk Parameters

**Status: Deferred**

### Current Design

`AssetConfig` contains per-asset risk parameters:

```solidity
struct AssetConfig {
    bool isActive;
    uint256 liquidationThreshold;
    uint256 minCollateralRatio;
    uint256 liquidationReward;
    // ...
}
```

### The Problem

Risk depends on **both** the asset and the collateral:

- eAAPL backed by USDC: moderate risk (AAPL moves, USDC doesn't).
- eAAPL backed by WETH: higher risk (both AAPL and WETH move -- double drift).
- eTBILL backed by USDC: very low risk (neither moves much).
- eTBILL backed by WETH: moderate risk (WETH moves, T-Bill doesn't).

Per-asset config alone cannot capture this two-dimensional risk.

### Options Discussed

| Option | Description | Pros | Cons |
|---|---|---|---|
| **Per-vault thresholds** | Each vault has one set of risk params | Simplest | Blunt -- same ratio for all assets in vault |
| **Per-asset thresholds** (current) | Each asset has its own risk params | Moderate granularity | Incomplete -- ignores collateral volatility |
| **Per-(vault, asset) pair matrix** | Risk params for each (vault, asset) combination | Most expressive | Lots of configuration -- N vaults * M assets |
| **Compose from both sides** | Formula: `ratio = f(assetVol, collateralVol)` | Less config, principled | More opinionated, harder to override edge cases |

### Decision

Deferred for later consideration. The per-asset approach works for MVP where vaults are primarily USDC-collateralized (single collateral volatility profile). The issue becomes pressing when WETH or other volatile collateral vaults are introduced.

---

## 11. Withdrawal Safety Gap

**Status: Recommended -- implement post-withdrawal utilization check**

### The Problem

The current `fulfillWithdrawal()` function has **no utilization check**. A keeper can fulfill a withdrawal that drops the vault below healthy collateralization:

1. Vault is at 120% collateralization.
2. Large withdrawal is fulfilled.
3. Vault drops to 95% collateralization -- undercollateralized.
4. Remaining LPs and eToken holders are now at risk.

### Recommendation

Add a post-withdrawal utilization check. After the withdrawal is processed, verify that the vault remains above the minimum collateralization threshold:

```solidity
function fulfillWithdrawal(uint256 withdrawalId, bytes calldata utilizationProof) external {
    // ... process withdrawal ...

    // Post-withdrawal health check
    uint256 postUtilization = _verifyUtilization(utilizationProof);
    require(postUtilization <= maxUtilization, "Withdrawal would undercollateralize vault");
}
```

This can use either:
- The on-chain `totalCommittedUSD` counter (approximate but gas-cheap).
- A signed utilization proof from the off-chain oracle (precise but requires signature verification).

---

## 12. ZK Proofs for Oracle & Utilization (Future Vision)

**Status: Deferred -- design interfaces now, implement later**

### Fundamental Constraint

ZK proofs prove **computation correctness**, NOT **input truth**.

- **On-chain state** (eToken supplies, vault balances, contract storage) IS provable via storage proofs -- the data exists in Ethereum's state trie and can be verified.
- **Off-chain real-world prices** (stock prices, T-Bill NAV) are NOT inherently provable -- there is no cryptographic proof that AAPL is trading at $185.

This distinction shapes what ZK can and cannot do for the oracle system.

### Layer 1: ZK-Proven Utilization Computation (Medium-term, 1-2 years)

**What it proves**: Given on-chain eToken supplies and a set of prices, the utilization was computed correctly.

**How it works**:
1. ZK circuit reads on-chain state via storage proofs (verifiable against block hash).
2. Circuit computes `SUM(supply_i * price_i) / totalAssets`.
3. Proof attests: "this utilization value was correctly computed from these on-chain supplies and these prices."

**What it eliminates**: The oracle signer lying about utilization derived from their own price data. The computation is provably correct.

**What it does NOT eliminate**: The trust in price data itself (prices still come from a signer).

**Gas cost**: ~250-350k for proof verification (SNARK/STARK verify on-chain).

### Layer 2: ZK-Proven Price Aggregation (Medium-term)

**What it proves**: The published price is the median of multiple independent on-chain sources.

**How it works**:
1. Circuit reads prices from multiple on-chain oracles (Pyth, Chainlink, own signer) via storage proofs.
2. Each source is verified via storage proof or in-circuit ECDSA signature verification.
3. Circuit computes the median and proves it.

**What it eliminates**: Single oracle signer manipulation. No single source can move the published price.

**Trust reduced to**: Majority of price sources are not colluding.

### Layer 3: zkTLS for Direct Exchange Data (Long-term, 2-3+ years)

**What it proves**: Price data came directly from a specific HTTPS endpoint (e.g., `api.nasdaq.com`).

**How it works**:
1. TLSNotary / zkTLS proves that a TLS session occurred with a specific server.
2. ZK circuit verifies the TLS proof and extracts the price from the HTTP response body.
3. Proof attests: "this price was served by api.nasdaq.com at this timestamp."

**What it eliminates**: The trusted oracle signer entirely. No intermediary between the exchange and the smart contract.

**Trust reduced to**: The exchange API serves correct data (minimal, unavoidable trust).

**Current state**: TLSNotary works for TLS 1.2. TLS 1.3 support is improving but not production-ready. Estimated 1-2 years from being viable for production use.

### Implementation Strategy

**Design for ZK swappability now, build ZK infrastructure later.**

The key insight is that `bytes calldata` is opaque -- it works for ECDSA signatures today and ZK proofs tomorrow. The `IOracleVerifier` interface does not need to change:

```solidity
interface IOracleVerifier {
    function verifyPrice(bytes calldata priceData) external returns (PriceInfo memory);
}
```

Today, `priceData` contains `(price, timestamp, signature)`. Tomorrow, it could contain a ZK proof. The consuming contracts (OwnMarket, LiquidationEngine) never know or care.

Combined with oracle swappability (Section 8), the upgrade path is:

1. Deploy `ZKOracleVerifier` implementing `IOracleVerifier`.
2. Propose oracle update via timelock.
3. After delay, execute update.
4. All consuming contracts now use ZK-verified prices with zero code changes.

---

## 13. Pyth & Chainlink for RWA Feeds

**Status: Decided -- hybrid approach long-term; own signer for MVP**

### Current Coverage

Both Pyth and Chainlink have **limited RWA coverage** as of the design phase. Most feeds are crypto-native (BTC/USD, ETH/USD, etc.). Equity and T-Bill feeds are sparse.

### Trust Models

Neither oracle network is fully decentralized for RWA prices:

**Pyth**:
- ~90+ institutional publishers (CBOE, Binance, Jane Street, etc.).
- Publishers submit price updates; Pyth aggregates.
- Trust: need a majority of publishers to collude to corrupt a price.
- More transparent about publisher identity.

**Chainlink**:
- Decentralized Oracle Network (DON) with node operators.
- Chainlink Labs has influence on node selection and feed configuration.
- Trust: node operators are reputable but selection is somewhat centralized.

### Fundamental Limitation for RWA

For real-world asset prices, there is **no on-chain source of truth**. The price of AAPL stock exists on NASDAQ -- everything on-chain is a reflection of that off-chain reality. Whether the price comes from Pyth, Chainlink, or Own's signer, the trust ultimately traces back to off-chain data sources.

### Likely Future: Hybrid Approach

- **Pyth/Chainlink** for assets they cover (if/when they add equity and T-Bill feeds).
- **Own signers** for niche or newly listed assets not covered by existing oracle networks.
- **Cross-reference**: Use Pyth/Chainlink as sanity checks against own signer data, or vice versa.

### USDY Price Feed

For Ondo's USDY (yield-bearing stablecoin), check Pyth and Chainlink for existing feeds. If unavailable, may need to source price data directly from Ondo's published NAV or API.

---

## 14. forceApprove Pattern

**Status: Decided -- use forceApprove as safe default**

### What It Is

`forceApprove` is a helper from OpenZeppelin's `SafeERC20` library, used in the WETHRouter and other contracts that need to approve token spending.

### The Problem It Solves

Some ERC-20 tokens (notably USDT / Tether) **revert** on `approve(spender, newAmount)` if the current allowance is non-zero. This is a known quirk of USDT's implementation intended to prevent the approve/transferFrom race condition.

Standard pattern that fails with USDT:

```solidity
// This reverts if current allowance > 0 for USDT
token.approve(spender, amount);
```

### The forceApprove Solution

```solidity
// OpenZeppelin SafeERC20.forceApprove
function forceApprove(IERC20 token, address spender, uint256 value) internal {
    // First set allowance to 0
    // Then set to desired value
}
```

It sets the allowance to 0 first, then to the desired amount. This works with all ERC-20 tokens regardless of their `approve()` implementation.

### Usage in Own Protocol

While WETH itself does not have the USDT approval quirk, using `forceApprove` is a safe default pattern that:

- Costs negligible extra gas (one additional zero-approval in the worst case).
- Prevents subtle bugs if the pattern is copy-pasted to other token contexts.
- Is the OpenZeppelin-recommended approach for all token approvals.

```solidity
// In WETHRouter
IERC20(weth).forceApprove(address(vault), amount);
```

---

## 15. Fee Model: Mint & Redemption Fees (Replacing Spread Revenue)

**Status: Decided**

### The Change

Spread is **no longer** the primary source of revenue for the protocol or LPs. The fundamental problem: when a VM applies a spread on execution price, there is no clean way to track and distribute that spread to the LPs whose collateral backs the trade. The spread goes to the VM as part of their execution, and routing it back to LPs requires complex accounting.

### New Model: Per-Asset Mint & Redemption Fees

The protocol charges a **mint fee** and a **redemption fee** on every order. These fees are:

- **Set independently per asset** based on the asset's volatility profile.
- **Stored in the asset config** as a volatility level number (1 = low volatile, 2 = medium, 3 = high, etc.) which maps to fee tiers.
- **Fixed for MVP** — all assets use a static fee based on their volatility level.
- **Dynamic later** — a swappable fee calculator contract can make fees dynamic based on utilisation, volatility level, market conditions, etc.

### Contract Structure for Swappability

```
AssetConfig {
    ...existing fields...
    uint8 volatilityLevel;    // 1=low, 2=medium, 3=high — determines fee tier
}

// MVP: simple fixed fee lookup
IFeeCalculator {
    function getMintFee(bytes32 asset, uint8 volatilityLevel) → uint256 feeBps;
    function getRedeemFee(bytes32 asset, uint8 volatilityLevel) → uint256 feeBps;
}
```

For MVP, `FeeCalculator` is a simple contract with admin-set fixed fee rates per volatility level. Later, it can be swapped (via the protocol registry) for a `DynamicFeeCalculator` that factors in utilisation, recent volatility, time of day, etc.

### Fee Application

- **Mint**: fee is deducted from the stablecoin amount before eToken calculation. User pays `amount`, protocol takes `amount * mintFeeBps / BPS` as fee, remaining goes to the VM for execution.
- **Redeem**: fee is deducted from the stablecoin payout. User receives `payout - (payout * redeemFeeBps / BPS)`.

### Spread Still Exists (VM-Side)

VMs still set their own spread for competitive pricing. But spread is the VM's margin — it is NOT the protocol/LP revenue mechanism. VMs keep their spread. Protocol and LP revenue comes from the mint/redeem fee.

---

## 16. Fee Accrual & Distribution

**Status: Decided**

### Fee Accrual Contract

All mint and redemption fees accrue in a dedicated **FeeAccrual** contract. This contract holds collected fees and distributes them according to configured splits.

### Distribution Model

Fees are split three ways:

1. **Protocol share** — set by protocol governance (e.g., 20%). Goes to the protocol treasury.
2. **LP share** — the remainder after protocol share. Goes to the LP pool backing the trade.
3. **VM share** — LPs decide how much of THEIR share goes to VMs. Can be zero. This is set at the LP level (or vault level for simplicity in MVP).

```
totalFee = orderAmount * feeBps / BPS
protocolFee = totalFee * protocolShareBps / BPS
lpFee = totalFee - protocolFee
vmFee = lpFee * vmShareBps / BPS    // vmShareBps set by LPs, can be 0
lpNet = lpFee - vmFee
```

### Claiming

- Protocol claims its share to treasury.
- LPs claim their share (reflected in vault share price or claimable balance).
- VMs claim their share if any is allocated by the LPs.

---

## 17. VM Strategy Declaration (Delta Neutral vs Short)

**Status: Decided — declare now, enforce later**

### Design

Each VM declares its hedging strategy when registering:

- **Delta neutral** — VM hedges fully, maintaining no net exposure to price movement.
- **Short position** — VM takes directional risk, not fully hedging.

```solidity
enum VMStrategy {
    DeltaNeutral,
    Short
}

VMConfig {
    ...existing fields...
    VMStrategy strategy;
}
```

### MVP Behavior

- VMs set their strategy on registration. It is recorded onchain.
- **No liquidation of LPs in MVP.** The protocol does not enforce strategy compliance or liquidate LPs based on VM behavior.
- Strategy declaration is informational for LPs choosing which VM to delegate to.

### Future Enforcement

The architecture is designed so that liquidation logic can be integrated later based on:
- **Strategy type** — delta neutral VMs have different risk profiles than short VMs.
- **Collateral type** — WETH-collateral vaults have different liquidation thresholds than USDC vaults.
- **Delta neutral verification** — via zkTLS-based ZK proofs of offchain asset holdings (see Section 12, Layer 3).
- **Liquidation triggers** — different triggers for delta neutral (verify hedge exists) vs short (monitor exposure ratio).

The `LiquidationEngine` interface already supports extensibility. Adding strategy-aware liquidation is a matter of deploying a new `LiquidationEngine` implementation.

---

## 18. Protocol Registry (Centralized Contract Address Management)

**Status: Decided**

### Problem

Multiple contracts need references to each other (OwnMarket → OracleVerifier, OwnMarket → VaultManager, etc.). Currently, each contract stores its own references as immutables or admin-set addresses. Upgrading any component (e.g., swapping OracleVerifier) requires updating every consuming contract individually.

### Solution: ProtocolRegistry

A single **ProtocolRegistry** contract that:

1. Stores addresses of all protocol contracts (OwnMarket, VaultManager, OracleVerifier, FeeCalculator, FeeAccrual, LiquidationEngine, AssetRegistry, PaymentTokenRegistry, etc.).
2. Is governance-upgradable (timelock + admin multisig).
3. All other contracts reference `ProtocolRegistry` to look up addresses.

```solidity
interface IProtocolRegistry {
    function getOracleVerifier() external view returns (address);
    function getFeeCalculator() external view returns (address);
    function getFeeAccrual() external view returns (address);
    function getMarket() external view returns (address);
    function getVaultManager() external view returns (address);
    function getLiquidationEngine() external view returns (address);
    function getAssetRegistry() external view returns (address);
    function getPaymentTokenRegistry() external view returns (address);
    // ... other protocol contracts
}
```

### Benefits

- **Single point of upgrade**: Swap OracleVerifier by updating one address in ProtocolRegistry. All consumers automatically use the new one.
- **Future Pyth/Chainlink transition**: Deploy a PythOracleVerifier implementing `IOracleVerifier`, update ProtocolRegistry. Done.
- **Fee calculator swapping**: Deploy DynamicFeeCalculator, update ProtocolRegistry. All fee lookups now use the new logic.
- **Governance protection**: ProtocolRegistry changes go through timelock, giving users time to react.

### Gas Consideration

Each cross-contract call adds one extra SLOAD (reading the address from registry). This is ~2100 gas — negligible on Base L2.

---

## 19. LP Exit Queue & Redemption Enforcement

**Status: Decided**

### LP Exit Queue

All LP withdrawals are queued with a **protocol-level wait period**:

- LP calls `requestWithdrawal(shares)`.
- Request enters FIFO queue with a mandatory wait period (e.g., 7 days, set at protocol level).
- After the wait period, the withdrawal can be fulfilled if utilisation allows.
- Wait period is configurable by governance via ProtocolRegistry or vault config.

This wait period serves multiple purposes:
- Prevents bank-run scenarios.
- Gives VMs time to unwind positions.
- Allows the protocol to manage utilisation smoothly.

### LP Collateral Liquidation: Redemption Enforcement

The **only** scenario where LP collateral is forcibly liquidated:

1. A user places a **redeem order**.
2. A VM **claims** the order (commits to fulfilling it).
3. The VM **fails to confirm** (execute) the redemption within a **set duration**.
4. The market is **open** during that duration (not off-hours).
5. The execution price set by the user is **valid** (within slippage/limit bounds at current oracle price).

When all conditions are met, the protocol liquidates LP collateral from the VM's backing vault to pay the user. This is the Tier 3 liquidation path — selling vault collateral via DEX to generate stablecoin payout for the user.

### Key Parameters

- `redemptionGracePeriod` — how long a VM has to confirm after claiming (e.g., 4 hours during market hours).
- `withdrawalWaitPeriod` — mandatory queue time for LP exits (e.g., 7 days).
- Both are protocol-level parameters, set via governance.

---

## Appendix: Decision Summary

| Topic | Status | Decision |
|---|---|---|
| Contract architecture | Decided | OwnMarket + OwnVault + VM + Oracle pattern |
| ERC-4626 vault | Decided | OZ v5 with virtual offset, thin guard wrappers |
| Rebasing tokens | Recommended | Wrap via wstETH / stataToken |
| Wrong-token rescue | Decided | Add `rescueTokens()` admin function |
| ERC-7575 multi-asset | Deferred | Future consideration |
| T-Bill tokenization | Decided | Rolling NAV token (eTBILL) |
| Oracle (MVP) | Decided | Single signed oracle, ECDSA verification |
| Oracle (M-of-N MVP) | Decided | Threshold signatures (TSS) |
| Oracle (Production) | Recommended | Independent signers + on-chain aggregation, or Pyth |
| Oracle swappability | Recommended | Admin setter with 48h timelock |
| Utilization tracking | Decided | `totalCommittedUSD` running counter |
| Utilization oracle | Recommended | Off-chain signed utilization + on-chain sanity check |
| Risk parameters | Deferred | Per-asset for MVP; per-(vault,asset) pair later |
| Withdrawal safety | Recommended | Post-withdrawal utilization check |
| ZK oracle | Deferred | Design interfaces now; implement in 1-3 years |
| Pyth/Chainlink | Decided | Hybrid long-term; own signer for MVP |
| forceApprove | Decided | Use as safe default in all approvals |
| Fee model | Decided | Per-asset mint/redeem fees (not spread); fixed for MVP, dynamic later |
| Fee accrual | Decided | Dedicated FeeAccrual contract; split between protocol, LPs, VMs |
| VM strategy | Decided | VMs declare delta neutral or short; informational in MVP, enforced later |
| Protocol registry | Decided | Single gov-upgradable contract holding all protocol addresses |
| LP exit queue | Decided | Mandatory wait period for all LP withdrawals |
| LP liquidation | Decided | Only on failed redemption by VM within grace period during market hours |
