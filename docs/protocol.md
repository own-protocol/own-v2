# Own Protocol v2 — Protocol Documentation

## 1. Overview

Own is a permissionless protocol for bringing tokenized real-world assets (RWAs) onchain. Users mint ERC-20 tokens called **eTokens** (e.g. eTSLA, eGOLD) by using stablecoins. Each eToken tracks the price of its underlying asset through onchain oracles. The tokens are backed by on-chain collateral deposited by LPs in Own Vaults. LPs manage thier exposure via off-chain hedging performed by **Vault Managers** (VMs).

### Core Thesis

Traditional RWA tokenization requires trust in a custodian holding the physical asset. Own Protocol takes a different approach: exposure is backed by **collateral vaults** filled by liquidity providers, and **vault managers** hedge the net exposure off-chain. This means:

- No physical custody required
- Permissionless minting and redemption
- Transparent collateralization on-chain
- Competition between vault managers drives better spreads

### Supported Assets

| Ticker | eToken | Underlying  | Volatility Level |
| ------ | ------ | ----------- | ---------------- |
| TSLA   | eTSLA  | Tesla stock | 2 (Medium)       |
| GOLD   | eGOLD  | Gold (XAU)  | 1 (Low)          |

New assets can be added by the protocol admin through the Asset Registry.

---

## 2. Participants

### Minters (Users)

Regular users who want exposure to real-world assets. They place **mint orders** (deposit stablecoins to receive eTokens) or **redeem orders** (deposit eTokens to receive stablecoins). Trust level: untrusted.

### Liquidity Providers (LPs)

Provide collateral (e.g. WETH) to vaults. They receive ERC-4626 vault shares representing their proportional claim on vault assets. LPs earn a share of trading fees. Trust level: untrusted.

### Vault Managers (VMs)

Professional market makers bound 1:1 to a vault. They:

- Claim and execute user orders off-chain (hedge the exposure)
- Approve or reject LP deposits
- Manage the vault's asset exposure
- Set which assets and payment tokens the vault supports

Trust level: semi-trusted (bound to a single vault, constrained by utilization caps and force execution).

### Protocol Admin

Governance entity (multisig) that:

- Registers contracts in the Protocol Registry (with timelock)
- Adds/deactivates assets in the Asset Registry
- Configures oracle sources and fee levels
- Can pause/halt vaults in emergencies

Trust level: trusted (timelock-governed).

### Oracle Signers

Off-chain entities that sign price attestations for the in-house oracle. Prices are verified on-chain using ECDSA signatures. The protocol also integrates Pyth Network as an oracle source.

---

## 3. Contract Architecture

The protocol consists of 11 contracts organized into three layers:

### Core Contracts

| Contract             | File                            | Purpose                                                                                                                                                          |
| -------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ProtocolRegistry** | `src/core/ProtocolRegistry.sol` | Central registry of all protocol contract addresses. 2-day timelock for address changes. Stores protocol-wide parameters (e.g. `protocolShareBps`).              |
| **OwnMarket**        | `src/core/OwnMarket.sol`        | Order escrow and execution marketplace. Handles the full order lifecycle: placement, claiming, confirmation, cancellation, expiry, and force execution.          |
| **OwnVault**         | `src/core/OwnVault.sol`         | ERC-4626 collateral vault. Manages LP deposits/withdrawals (async queues), tracks per-asset exposure and utilization, distributes fees, and supports pause/halt. |
| **VaultFactory**     | `src/core/VaultFactory.sol`     | Deploys and registers OwnVault instances. Each vault is bound 1:1 to a VM.                                                                                       |
| **AssetRegistry**    | `src/core/AssetRegistry.sol`    | Whitelists assets, maps tickers to eToken addresses, stores oracle configurations. Supports token migration (post-stock-split).                                  |
| **FeeCalculator**    | `src/core/FeeCalculator.sol`    | Per-volatility-level fee lookup. Three tiers (low/medium/high) with separate mint and redeem fee rates. Max cap: 500 BPS (5%).                                   |

### Oracle Contracts

| Contract               | File                              | Purpose                                                                                                                            |
| ---------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **OracleVerifier**     | `src/core/OracleVerifier.sol`     | In-house signed oracle. Prices are pushed by an authorized signer with ECDSA verification, staleness checks, and deviation bounds. |
| **PythOracleVerifier** | `src/core/PythOracleVerifier.sol` | Wraps Pyth Network price feeds. Normalizes prices to 18 decimals. Supports both cached reads and inline proof verification.        |

### Token & Peripheral Contracts

| Contract         | File                             | Purpose                                                                                                                                                                      |
| ---------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **EToken**       | `src/tokens/EToken.sol`          | Synthetic asset token (ERC-20 + ERC-2612 Permit). Mint/burn restricted to OwnMarket. Supports admin-updatable metadata (for stock splits) and a dividend reward accumulator. |
| **WETHRouter**   | `src/periphery/WETHRouter.sol`   | Wraps native ETH to WETH for vault deposits and unwraps on redemption.                                                                                                       |
| **WstETHRouter** | `src/periphery/WstETHRouter.sol` | Wraps stETH to wstETH for alternative collateral vaults. Supports ERC-2612 permit.                                                                                           |

### Contract Interaction Diagram

See `docs/own-architecture.png` for the visual architecture diagram.

```
                    ProtocolRegistry
                    (address registry + timelock)
                          |
          +---------------+---------------+
          |               |               |
    AssetRegistry    FeeCalculator   VaultFactory
    (assets, oracles, fees)           (deploys vaults)
                                          |
                                      OwnVault
                                 (ERC-4626 collateral)
                                          |
                    OwnMarket  <----------+
               (order escrow + execution)
                    |         |
               EToken     OracleVerifier / PythOracleVerifier
          (mint/burn)      (price verification)
```

---

## 4. Order Lifecycle

Orders are the core mechanism for minting and redeeming eTokens. The protocol uses an **escrow + claim** model where user funds are escrowed in OwnMarket and vault managers claim orders to execute them off-chain.

### Order States

| Status            | Description                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| **Open**          | Order placed, funds escrowed. Waiting for a VM to claim.                                         |
| **Claimed**       | VM has claimed the order. VM received stablecoins (mint) or eTokens are held in escrow (redeem). |
| **Confirmed**     | VM confirmed execution. eTokens minted to user (mint) or stablecoins sent to user (redeem).      |
| **Cancelled**     | User cancelled an unclaimed order. Funds returned.                                               |
| **Expired**       | Order expired without being claimed. Funds returned.                                             |
| **Closed**        | VM closed an expired claimed order. Funds returned to user.                                      |
| **ForceExecuted** | User force-executed after grace period with oracle proof.                                        |

### State Machine

```
         placeMintOrder / placeRedeemOrder
                    |
                    v
                  OPEN
                /  |  \
    cancelOrder/   |   \expireOrder
              /    |    \
             v     |     v
        CANCELLED  |  EXPIRED
                   |
            claimOrder
                   |
                   v
                CLAIMED
               /   |   \
   closeOrder /    |    \ forceExecute
             /     |     \
            v      |      v
         CLOSED    |  FORCE_EXECUTED
                   |
            confirmOrder
                   |
                   v
              CONFIRMED
```

### Mint Order Flow

1. **User** calls `placeMintOrder(vault, asset, amount, maxPrice, expiry)` depositing stablecoins (e.g. USDC)
2. **VM** calls `claimOrder(orderId)` — receives `amount - fee` in stablecoins, fee held in escrow
3. **VM** hedges the exposure off-chain (e.g. buys TSLA on a CEX)
4. **VM** calls `confirmOrder(orderId, executionPrice)` — protocol mints eTokens to user: `eTokens = (amount - fee) * PRECISION / price`
5. Fees are deposited into the vault and split between protocol, VM, and LPs

### Redeem Order Flow

1. **User** calls `placeRedeemOrder(vault, asset, eTokenAmount, minPrice, expiry)` depositing eTokens
2. **VM** calls `claimOrder(orderId)` — eTokens held in market escrow
3. **VM** unwinds the hedge off-chain (e.g. sells TSLA on a CEX)
4. **VM** calls `confirmOrder(orderId, executionPrice)` — protocol burns eTokens, sends stablecoins to user: `payout = eTokenAmount * price / PRECISION - fee`
5. Fees deposited into vault

### Price Semantics

- **Mint orders**: `price` is the **maximum** price per eToken the user will accept (protection against price going up)
- **Redeem orders**: `price` is the **minimum** price per eToken the user will accept (protection against price going down)

---

## 5. Force Execution

Force execution protects users when a VM fails to act on a claimed order. After a **grace period** (e.g. 1 day after claim, or claim threshold for unclaimed orders), the user can force-execute by providing oracle price proofs.

### Two-Price Proof Mechanism

The user must provide:

1. **Asset price proof** — proves the current price of the asset (e.g. TSLA/USD)
2. **Collateral price proof** — proves the current price of the collateral (e.g. ETH/USD)

### Execution Logic

- **If the order price was reachable** (user's limit price was achievable based on oracle data): execute at the user's specified price, with **no fees charged** (VM penalty)
- **If the order price was NOT reachable** (market moved against the user): return the escrowed funds — stablecoins (mint) or eTokens (redeem)

### Timing

| Parameter        | Description                                                             | Default |
| ---------------- | ----------------------------------------------------------------------- | ------- |
| `gracePeriod`    | Time after claim before force execution is allowed                      | 1 day   |
| `claimThreshold` | Time after order creation before unclaimed orders can be force-executed | 6 hours |

---

## 6. LP Operations

Liquidity providers deposit collateral into vaults and receive ERC-4626 shares. Both deposits and withdrawals are async (queue-based) to give VMs control over vault composition.

### Deposit Flow

1. LP calls `requestDeposit(assets, receiver)` — collateral transferred to vault, creates a pending request
2. VM calls `acceptDeposit(requestId)` — vault shares minted to receiver at current exchange rate
3. Alternatively, VM calls `rejectDeposit(requestId)` — collateral returned to depositor
4. LP can call `cancelDeposit(requestId)` before VM decision — collateral returned

**Direct deposits** via `deposit()` / `mint()` are also supported (standard ERC-4626), but async is the primary path.

### Withdrawal Flow

1. LP calls `requestWithdrawal(shares)` — shares are queued (FIFO)
2. Anyone can call `fulfillWithdrawal(requestId)` when:
   - A minimum wait period has passed
   - Vault utilization remains within bounds after withdrawal
3. LP can call `cancelWithdrawal(requestId)` to get shares back

### ETH Routing

LPs can deposit native ETH using the **WETHRouter**, which wraps ETH to WETH before depositing into WETH-collateral vaults. Similarly, **WstETHRouter** handles stETH wrapping for wstETH-collateral vaults.

---

## 7. Fee Model

Fees are charged on every confirmed order and split three ways.

### Fee Tiers

Fees are based on the asset's **volatility level** (configured in AssetRegistry):

| Volatility Level | Mint Fee        | Redeem Fee      | Example Assets |
| ---------------- | --------------- | --------------- | -------------- |
| 1 (Low)          | 0.50% (50 BPS)  | 0.25% (25 BPS)  | GOLD           |
| 2 (Medium)       | 1.00% (100 BPS) | 0.50% (50 BPS)  | TSLA           |
| 3 (High)         | 2.00% (200 BPS) | 1.00% (100 BPS) | --             |

Maximum fee cap: **500 BPS (5%)** enforced by FeeCalculator.

### Fee Distribution

When a VM confirms an order, the fee is split:

1. **Protocol share**: `fee * protocolShareBps / BPS` — sent to treasury via `claimProtocolFees()`
2. **VM share**: `fee * (BPS - protocolShareBps) / BPS` — claimable by VM via `claimVMFees()`
3. **LP share**: remaining portion accrues to vault share value (benefits all LPs)

The `protocolShareBps` is a global parameter set in ProtocolRegistry.

### No Fees on Force Execution

When an order is force-executed, no fees are charged. This serves as a penalty to the VM for failing to execute promptly.

---

## 8. Oracle System

The protocol uses a **dual-oracle architecture** — each asset can have a primary and secondary oracle, both implementing the `IOracleVerifier` interface.

### Oracle Types

**In-House Signed Oracle (`OracleVerifier`)**

- Push model: authorized signer submits signed price updates
- ECDSA verification: `keccak256(abi.encode(asset, price, timestamp, chainId, contractAddress))`
- Staleness check: rejects prices older than `maxStaleness`
- Deviation check: rejects prices that deviate more than `maxDeviation` from the last known price
- Used for custom assets or when Pyth feeds are unavailable

**Pyth Network Oracle (`PythOracleVerifier`)**

- Wraps the Pyth Network on-chain contract
- Each asset maps to a Pyth feed ID (configured per-asset)
- Normalizes Pyth's variable-exponent prices to 18 decimals
- Supports both cached reads (`getPrice`) and inline proof verification (`verifyPrice`)
- Max price age configurable (default: 120 seconds)

### Per-Asset Configuration

Each asset in the AssetRegistry has an `OracleConfig`:

- `primaryOracle` — the default oracle used for price reads
- `secondaryOracle` — backup oracle (can be swapped to primary by admin)

The admin can call `switchPrimaryOracle(ticker)` to swap primary and secondary.

### Collateral Pricing

The vault tracks its collateral value in USD using an oracle for the collateral asset (e.g. ETH/USD). This is used for:

- Utilization ratio calculation
- Force execution collateral-equivalent returns
- Vault health monitoring

---

## 9. Vault Health and Safety

### Utilization Tracking

The vault tracks two key metrics:

- **Total exposure (USD)**: sum of all per-asset exposure values (`units * assetPrice`)
- **Collateral value (USD)**: total collateral in vault \* collateral price

**Utilization ratio** = `totalExposureUSD / collateralValueUSD`

The vault enforces a **max utilization cap** (e.g. 80%). When a VM claims an order, the projected utilization is checked — if it would breach the cap, the claim reverts.

### Valuation Updates

Exposure and collateral values are updated by keepers calling:

- `updateAssetValuation(asset)` — re-prices a specific asset's exposure using oracle
- `updateCollateralValuation()` — re-prices vault collateral using oracle

These are incremental updates (delta-based) to avoid iterating over all assets.

### Emergency Controls

**Pause** (per-vault or per-asset):

- Prevents new orders from being placed
- Existing orders can still be confirmed, cancelled, or expired
- LP operations continue

**Halt** (per-vault or per-asset):

- Full stop — no new orders, no confirmations
- Admin sets settlement prices for affected assets
- Users can close/settle existing positions at the halt price
- Used for extreme market events or protocol incidents

### Vault Status Hierarchy

```
Active → Paused → Halted
  ↑         |        |
  +---------+--------+
     (can be reversed)
```

---

## 10. Security Patterns

### Access Control

| Action                                 | Who Can Do It                              |
| -------------------------------------- | ------------------------------------------ |
| Register contracts in ProtocolRegistry | Protocol admin (with timelock)             |
| Add/deactivate assets                  | Protocol admin                             |
| Configure oracles and fees             | Protocol admin                             |
| Create vaults                          | Protocol admin (via VaultFactory)          |
| Pause/halt vaults                      | Protocol admin                             |
| Claim/confirm orders                   | Vault manager (of the specific vault)      |
| Accept/reject LP deposits              | Vault manager                              |
| Place/cancel orders                    | Any user                                   |
| Force execute orders                   | Order owner (after grace period)           |
| Expire unclaimed orders                | Anyone (permissionless)                    |
| Fulfill withdrawals                    | Anyone (permissionless, if conditions met) |

### Smart Contract Patterns

- **Checks-Effects-Interactions (CEI)**: all state changes happen before external calls
- **ReentrancyGuard**: on OwnMarket, OwnVault, and router contracts
- **SafeERC20**: all token transfers use OpenZeppelin's SafeERC20
- **No floating pragma**: pinned to `solidity 0.8.28`
- **Custom errors**: gas-efficient error handling (no require strings)
- **Timelock governance**: ProtocolRegistry changes require a 2-day delay

### Decimal Conventions

| Value Type     | Decimals    | Example                        |
| -------------- | ----------- | ------------------------------ |
| Prices         | 18          | `250000000000000000000` = $250 |
| BPS values     | 0 (raw BPS) | `100` = 1%                     |
| eToken amounts | 18          | Standard ERC-20                |
| USDC amounts   | 6           | Standard USDC                  |
| Vault shares   | 18          | ERC-4626                       |

---

## 11. Types Reference

### Constants

```
BPS       = 10,000    // Basis-point denominator (10,000 = 100%)
PRECISION = 1e18      // Fixed-point precision for prices and per-share accumulators
```

### Enums

| Enum               | Values                                                              | Description                                   |
| ------------------ | ------------------------------------------------------------------- | --------------------------------------------- |
| `OrderType`        | Mint, Redeem                                                        | Whether an order is buying or selling eTokens |
| `OrderStatus`      | Open, Claimed, Confirmed, Cancelled, Expired, Closed, ForceExecuted | Order lifecycle state                         |
| `WithdrawalStatus` | Pending, Fulfilled, Cancelled                                       | LP withdrawal request state                   |
| `DepositStatus`    | Pending, Accepted, Rejected, Cancelled                              | LP deposit request state                      |
| `VaultStatus`      | Active, Paused, Halted                                              | Vault operating state                         |

### Structs

**Order** — an order placed by a user in the escrow marketplace:

- `orderId` (uint256) — unique identifier
- `user` (address) — who placed it
- `orderType` (OrderType) — Mint or Redeem
- `asset` (bytes32) — asset ticker (e.g. `bytes32("TSLA")`)
- `amount` (uint256) — stablecoin amount (Mint) or eToken amount (Redeem)
- `price` (uint256) — max price (Mint) or min price (Redeem), 18 decimals
- `expiry` (uint256) — timestamp after which the order can be expired
- `status` (OrderStatus) — current lifecycle state
- `createdAt` (uint256) — placement timestamp
- `vm` (address) — VM that claimed (zero if unclaimed)
- `vault` (address) — vault backing the claim (zero if unclaimed)
- `claimedAt` (uint256) — claim timestamp (zero if unclaimed)

**WithdrawalRequest** — async LP withdrawal:

- `requestId` (uint256) — unique identifier
- `owner` (address) — LP who requested
- `shares` (uint256) — vault shares to redeem
- `timestamp` (uint256) — when submitted
- `status` (WithdrawalStatus)

**DepositRequest** — async LP deposit:

- `requestId` (uint256) — unique identifier
- `depositor` (address) — who initiated
- `receiver` (address) — who receives vault shares
- `assets` (uint256) — collateral amount deposited
- `timestamp` (uint256) — when submitted
- `status` (DepositStatus)

**AssetConfig** — whitelisted asset configuration:

- `activeToken` (address) — current eToken address
- `legacyTokens` (address[]) — previous eToken addresses (post-split)
- `active` (bool) — whether accepting new orders
- `volatilityLevel` (uint8) — fee tier (1=low, 2=medium, 3=high)

**OracleConfig** — per-asset oracle setup:

- `primaryOracle` (address) — main IOracleVerifier
- `secondaryOracle` (address) — backup (zero if none)

**VMConfig** — vault manager state:

- `maxExposure` (uint256) — max USD notional the VM will hedge (18 decimals)
- `currentExposure` (uint256) — current outstanding notional (18 decimals)
- `registered` (bool) — whether registered
- `active` (bool) — whether currently active

---

## 12. EIP/Standard Compliance

| Standard     | Usage                                                                     |
| ------------ | ------------------------------------------------------------------------- |
| **ERC-20**   | EToken implements full ERC-20 for synthetic asset tokens                  |
| **ERC-2612** | EToken supports gasless approvals via `permit()`                          |
| **ERC-4626** | OwnVault implements the tokenized vault standard for LP shares            |
| **ERC-7540** | OwnVault follows the async deposit/withdrawal pattern (request → fulfill) |
| **EIP-712**  | Used for typed structured data hashing in permit signatures               |
