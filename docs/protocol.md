# Own Protocol v2 — Protocol Documentation

## 1. Overview

Own is a permissionless protocol to mint synthetic real-world assets (RWAs) onchain. Users mint ERC-20 tokens called **eTokens** (e.g. eTSLA, eGOLD) by using stablecoins. Each eToken tracks the price of its underlying asset through onchain oracles. The tokens are backed by on-chain ETH collateral deposited in Own Vaults. Any Hedge fund, trading firm or RWA custodian can become a Vault Manager by posting ETH as collateral and start backing the issued eTokens.

### Core Thesis

Traditional RWA tokenization requires trust in a single custodian holding the physical asset. Own Protocol takes a different approach: exposure is backed by **collateral vaults** & multiple custodians / hedge funds can permissionlessly choose to back these assets:

- Permissionless minting and redemption
- Transparent collateralization on-chain
- Competition between funds drives better spreads

### Supported Assets

| Ticker | eToken | Underlying  | Volatility Level |
| ------ | ------ | ----------- | ---------------- |
| TSLA   | eTSLA  | Tesla stock | 2 (Medium)       |
| GOLD   | eGOLD  | Gold (XAU)  | 1 (Low)          |

New assets can be added by the protocol admin through the Asset Registry.

---

## 2. Participants

### Buyers

Regular users who want exposure to real-world assets. They request a firm price **quote** from a
VM's quoter service off-chain, then either settle it atomically as a **market order**
(`executeOrder`) or rest a **limit order** (`placeOrder`) for the VM to fill. Redeemers who can't
get a quote have an on-chain force-execution path against the oracle price.

### Vault Managers (VMs)

Professional hedge funds, trading firms. They:

- Provide collateral (e.g. WETH) to vaults.
- Sign firm price **quotes** off-chain (via their quoter service) that users settle on-chain.
- Fill resting limit orders by submitting their signed quotes (partial fills supported).
- Hedge the resulting exposure off-chain.
- Enable other ETH holders (LPs) to deposit into vault & share fees.
- Manage the vault's asset exposure and its authorized **quote signers**.
- Set which assets and payment tokens the vault supports

### Quote Signers

Each vault holds a set of addresses authorized to sign order quotes (managed by the VM or admin via
`addQuoteSigner` / `removeQuoteSigner`). These are decoupled from the operational `vm` address — a
hot signing key (e.g. an HSM/KMS key) signs quotes without ever custodying funds. The market accepts
a quote only if it recovers to one of the vault's authorized signers.

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

The protocol consists of 13 contracts organized into three layers:

### Core Contracts

| Contract             | File                            | Purpose                                                                                                                                                          |
| -------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ProtocolRegistry** | `src/core/ProtocolRegistry.sol` | Central registry of all protocol contract addresses. 2-day timelock for address changes. Stores protocol-wide parameters (e.g. `protocolShareBps`).              |
| **OwnMarket**        | `src/core/OwnMarket.sol`        | RFQ order execution marketplace. Settles market orders atomically against VM-signed quotes, escrows and (partially) fills resting limit orders, and provides redeem force execution against the oracle price.          |
| **OwnVault**         | `src/core/OwnVault.sol`         | ERC-4626 collateral vault. Holds LP collateral (custody), manages async deposit/withdrawal queues, distributes fees/yield, supports lending opt-in, and pause/halt. Risk accounting lives in the ExposureManager, not the vault. |
| **ExposureManager**  | `src/core/ExposureManager.sol`  | Central, pooled risk accounting for **all** vaults. Owns global exposure, collateral marks, utilization, and the per-asset issuance ceiling. Valued at keeper-cached marks. See §9. |
| **VaultFactory**     | `src/core/VaultFactory.sol`     | Deploys OwnVault instances and registers them with the ExposureManager. Each vault is bound 1:1 to a VM.                                                          |
| **AssetRegistry**    | `src/core/AssetRegistry.sol`    | Whitelists assets, maps tickers to eToken addresses, stores oracle configurations. Supports token migration (post-stock-split). Governs which assets are valid for **all** vaults. |
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
    (assets, oracles, fees)           (deploys + registers vaults)
                                          |
                                      OwnVault ───────┐ register / pull collateral price
                                 (ERC-4626 custody)   |
                                          |           v
                    OwnMarket  <----------+      ExposureManager
              (RFQ order execution) ───────────▶ (global pooled risk:
                    |         |        open/close   exposure, marks,
               EToken     OracleVerifier / Pyth      utilization, caps)
          (mint/burn)      (price marks & proofs) ◀── pull asset price (keepers)
```

---

## 4. Order Execution

The protocol uses an offline **RFQ (request-for-quote)** model. A user obtains a firm, VM-signed
**quote** off-chain and settles it on-chain. The signed quote is the price attestation — the oracle
is not consulted during normal execution (only on the force path, §5). There are two paths:

- **Market order** — the user submits the signed quote and it settles atomically in one transaction. No on-chain order is persisted.
- **Limit order** — the user rests an order on-chain (escrowing the input); the VM fills it later with a signed quote whose price satisfies the user's limit. Limit orders support **partial fills**.

### The Quote

A quote is signed off-chain by one of the vault's authorized quote signers (recovered against
`isQuoteSigner`, §2). It binds: target order id (`0` for a market order), taker, vault, asset, side,
amount, price, a unique single-use `quoteId`, and an expiry. The signed digest also commits the
chain id and market address to prevent cross-chain / cross-contract replay, and each quote can be
used only once.

### Order States (resting limit / redeem orders)

| Status            | Description                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------- |
| **Open**          | Resting order placed, input escrowed. Fillable by the VM; redeem orders also force-executable after the claim threshold. |
| **Filled**        | Fully filled — remaining amount reached zero.                                                      |
| **ForceExecuted** | Redeem order settled at the oracle (or halt) price via force execution.                            |
| **Cancelled**     | Owner cancelled; remaining escrow returned.                                                        |
| **Expired**       | Past its good-til-date; remaining escrow returned (callable by anyone).                            |

Market orders execute atomically and are never persisted, so they have no status.

### State Machine (resting order)

```
        placeOrder (escrow input)
               |
               v
             OPEN ──fillOrder (×N, partial)──▶ OPEN ──(remaining = 0)──▶ FILLED
            / |  \
 cancelOrder/  |   \ forceExecuteOrder (redeem only, after claimThreshold)
           /   |    \
          v    |     v
    CANCELLED  |  FORCE_EXECUTED
               |
          expireOrder (after expiry)
               |
               v
            EXPIRED
```

### Market Mint Flow (atomic, one tx)

1. **User** requests a quote; the VM's quoter returns a signed quote (price, expiry).
2. **User** calls `executeOrder(quote, signature)`:
   - `ExposureManager.openExposure(vault, asset, eTokens)` runs first — an atomic check + commit of the per-asset USD ceiling and global utilization. A breach reverts cleanly before any token moves (§9).
   - Stablecoins pulled from the user: `amount - fee` to the VM, `fee` to the vault.
   - eTokens minted to the user: `eTokens = (amount - fee) * PRECISION / price`.

### Market Redeem Flow (atomic, one tx)

1. **User** requests a quote; the VM signs it.
2. **User** calls `executeOrder(quote, signature)`:
   - Stablecoins pulled from the VM: gross `= amount * price / PRECISION`, `gross - fee` to the user, `fee` to the vault.
   - The user's eTokens are burned; `ExposureManager.closeExposure(vault, asset, units)` reduces global exposure. Any registered vault filling any redeem reduces the global book — there is no "a vault may only close what it opened" constraint.

The VM must have approved the market to spend its stablecoins. A relayer may submit on the VM's
behalf, since the signed quote carries the authorization.

### Limit Order Flow (resting, partial fills)

1. **User** calls `placeOrder(vault, asset, orderType, amount, limitPrice, expiry)` — escrows stablecoins (mint) or eTokens (redeem).
2. **VM** (or a relayer carrying a VM-signed quote) calls `fillOrder(quote, signature)` for a chunk `≤ remaining`, at a price satisfying the limit. Settlement is identical to the market flows but funded from escrow. Repeat until filled.
3. `cancelOrder` (owner) or `expireOrder` (anyone, after expiry) returns the remaining escrow.

### Price Semantics

- **Mint**: `limitPrice` is the **maximum** price per eToken the user will pay — a fill quote must satisfy `quote.price ≤ limitPrice`.
- **Redeem**: `limitPrice` is the **minimum** price per eToken the user will accept — a fill quote must satisfy `quote.price ≥ limitPrice`. It also acts as the slippage floor for force execution.
- **Market orders** carry no separate limit — the user accepts the quote's price by submitting it.

---

## 5. Force Execution

Force execution is the user's recourse when a VM will not quote. It applies to **redeem orders
only** — a redeemer holding eTokens is captive (eTokens convert back to stablecoins only through the
protocol), whereas an unfilled mint leaves the user holding their stablecoins, free to route
elsewhere. Forcing a mint would also open an unhedged position against LP collateral, so it is
disallowed (`ForceMintNotAllowed`).

After the vault's **claim threshold** elapses (measured from the order's creation), the owner of a
resting redeem order can call `forceExecuteOrder(orderId, assetPriceData, collateralPriceData)` to
settle the remaining amount at the oracle price.

### Mechanism

1. **Asset price proof** (`assetPriceData`) — the current signed price of the asset (e.g. TSLA/USD). During a halt, the admin-set halt price is used instead and no asset proof is needed.
2. **Collateral price proof** (`collateralPriceData`) — the current signed price of the collateral (e.g. ETH/USD), used to convert the USD value into collateral units.

Settlement:

- The oracle price must satisfy the order's `limitPrice` floor, else it reverts (`PriceBelowMinimum`).
- The remaining eTokens are valued at the oracle price, converted to collateral, and **vault collateral is released to the user** (net of the standard redeem fee, which the vault retains).
- The escrowed eTokens are burned and vault exposure is reduced.

Because forced redeem prices at the bare oracle price (no VM spread), the **claim threshold delay**
plus the standard redeem fee keep a fair VM quote the user's preferred path.

### Timing

| Parameter        | Description                                                              | Default |
| ---------------- | ----------------------------------------------------------------------- | ------- |
| `claimThreshold` | Delay after a redeem order is placed before it can be force-executed     | 6 hours |

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

Fees are charged on every settlement — market execution, limit fill, and force execution — and split three ways. The VM's quoted `price` is the pure execution price; the protocol fee is applied on top.

### Fee Tiers

Fees are based on the asset's **volatility level** (configured in AssetRegistry):

| Volatility Level | Mint Fee        | Redeem Fee      | Example Assets |
| ---------------- | --------------- | --------------- | -------------- |
| 1 (Low)          | 0.50% (50 BPS)  | 0.25% (25 BPS)  | GOLD           |
| 2 (Medium)       | 1.00% (100 BPS) | 0.50% (50 BPS)  | TSLA           |
| 3 (High)         | 2.00% (200 BPS) | 1.00% (100 BPS) | --             |

Maximum fee cap: **500 BPS (5%)** enforced by FeeCalculator.

### Fee Distribution

On settlement, the fee is split:

1. **Protocol share**: `fee * protocolShareBps / BPS` — sent to treasury via `claimProtocolFees()`
2. **VM share**: `fee * (BPS - protocolShareBps) / BPS` — claimable by VM via `claimVMFees()`
3. **LP share**: remaining portion accrues to vault share value (benefits all LPs)

The `protocolShareBps` is a global parameter set in ProtocolRegistry.

### Fees on Force Execution

When a redeem order is force-executed, the standard redeem fee is charged on the collateral payout (same rate as a normal redeem). The fee portion of collateral is retained by the vault, so the protocol and LPs continue to earn regardless of whether the VM fills the order or the user force-executes.

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

Each vault's collateral is valued in USD by the **ExposureManager**, using the oracle for the vault's
collateral asset (e.g. ETH/USD). The collateral ticker is bound at registration
(`VaultFactory.createVault(..., collateralAsset)`), and the USD mark is refreshed by permissionless
keeper calls to `pullCollateralPrice(vault)` (§9). The collateral USD value feeds:

- Global utilization (§9)
- Force-execution collateral-equivalent returns (the market reads the vault's collateral ticker via `ExposureManager.vaultCollateralAsset`)
- The lending debt cap (`UserBorrowManager.maxDebtUSD = collateralMark(vault) × targetLtvBps / BPS`)

---

## 9. Risk Accounting and Safety

All exposure, collateral valuation, and utilization accounting lives in a single **ExposureManager**
that pools risk globally across every vault. Vaults keep custody, LP shares, yield, and lending; the
manager owns risk. This replaces the earlier per-vault model.

### Pooled Model and Rationale

- **Pooled backing/solvency (global), isolated custody/yield (per vault).** Collateral lives in
  separate per-collateral ERC-4626 vaults (~5–6 total: USDC, aUSDC, ETH, stETH, …), but only the risk
  *math* pools. A mint settled through any vault draws on the protocol's global collateral and global
  exposure book.
- **Cross-VM loss mutualisation (accepted tradeoff).** A VM default's shortfall is covered by the
  global pool (all vaults' LPs), Maker-style. This strengthens the eToken's backing; LP risk is
  mutualised across vaults.
- **Exposure is purely global per asset** — there is no `(vault, asset)` attribution and no "a vault
  may only close what it opened" rule. Any registered vault filling any redeem reduces the global book.
- **Why central.** The mint check is now `check == committed state` by construction (the same path
  that validates a mint commits it), a real per-asset issuance ceiling caps total eToken supply across
  vaults, and `OwnVault` bytecode shrinks.

### Two Caps (both O(1))

1. **Global utilization cap (solvency):** `globalExposureUSD / globalCollateralUSD ≤ globalMaxUtilizationBps`.
   `openExposure` (called on every mint settlement / limit fill) atomically checks and commits — if the
   projected utilization would breach the cap, settlement reverts before any tokens move. Redeems
   (`closeExposure`) reduce exposure and are never capped.
2. **Per-asset USD issuance ceiling (concentration):** `globalAssetUnits[asset] × assetMark ≤ assetCapUSD[asset]`.
   **`assetCapUSD == 0` blocks minting that asset** (safe default — the admin must set a ceiling to
   enable it). There are no per-vault caps; the global util + per-asset cap + halt/deregister suffice
   for the small set of admin-vetted vaults.

Both `globalExposureUSD` and `globalCollateralUSD` are running totals updated on every
open/close/price-pull — no loops over vaults or assets on any path. Each asset's exact USD contribution
is stored so every update subtracts precisely what it added (no rounding drift).

### Keeper-Cached Marks (price pulls)

Exposure and collateral are valued **only** at keeper-cached marks (Maker `spot`-style), never at trade
prices. Marks are refreshed by **permissionless** calls:

- `pullAssetPrice(asset)` — pulls the asset's oracle price and re-marks global exposure for that asset.
- `pullCollateralPrice(vault)` — pulls the vault's collateral oracle price and re-marks its collateral USD.

Staleness between pulls is absorbed by the global utilization buffer. A new asset can only be minted
once **both** its price has been pulled (`assetMark != 0`) **and** `assetCapUSD > 0`.

### Withdrawal Gate

LP withdrawals consult `ExposureManager.withdrawalBreachesUtil(vault, assets)`: `fulfillWithdrawal`
reverts (`MaxUtilizationExceeded`) if releasing that collateral would push global utilization over the
cap. The check reads the cached collateral mark (as fresh as the last price pull — intended, per the
keeper model).

### Registration

Vault registration is factory-driven: `VaultFactory.createVault(collateral, vm, name, symbol, collateralAsset)`
deploys the vault and calls `ExposureManager.registerVault`. Deregistration goes through the factory too
and reverts if removing the vault's collateral would breach global utilization.

### Emergency Controls

**Pause** (per-vault or per-asset):

- Blocks market execution, order placement, and fills
- Resting orders can still be cancelled or expired
- LP operations continue

**Halt** (per-vault or per-asset):

- Full stop on normal execution — mints are blocked, normal redeem execution/fills revert (`TradingHalted`)
- Admin sets a settlement (halt) price for affected assets
- Redeemers exit via `forceExecuteOrder`, which settles at the halt price
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
| Sign order quotes (off-chain)          | Vault's authorized quote signers           |
| Add/remove quote signers               | Vault manager or admin                     |
| Fill resting limit orders              | Anyone with a valid VM-signed quote        |
| Accept/reject LP deposits              | Vault manager                              |
| Execute market orders / place orders   | Any user (market order needs a signed quote) |
| Cancel orders                          | Order owner                                |
| Force execute redeem orders            | Order owner (after claim threshold)        |
| Expire resting orders                  | Anyone (permissionless, after expiry)      |
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
| `OrderStatus`      | Open, Filled, ForceExecuted, Cancelled, Expired                    | Resting-order lifecycle state                 |
| `WithdrawalStatus` | Pending, Fulfilled, Cancelled                                       | LP withdrawal request state                   |
| `DepositStatus`    | Pending, Accepted, Rejected, Cancelled                              | LP deposit request state                      |
| `VaultStatus`      | Active, Paused, Halted                                              | Vault operating state                         |

### Structs

**Order** — a resting (limit / redeem) order escrowed in the marketplace. Market orders are not persisted as Orders.

- `orderId` (uint256) — unique identifier
- `user` (address) — who placed it
- `vault` (address) — vault the order is bound to
- `asset` (bytes32) — asset ticker (e.g. `bytes32("TSLA")`)
- `orderType` (OrderType) — Mint or Redeem
- `amount` (uint256) — original input: stablecoin amount (Mint) or eToken amount (Redeem)
- `filledAmount` (uint256) — cumulative input filled so far (≤ amount)
- `limitPrice` (uint256) — max price (Mint) or min price (Redeem), 18 decimals
- `createdAt` (uint256) — placement timestamp
- `expiry` (uint256) — good-til-date timestamp after which the order can be expired
- `status` (OrderStatus) — current lifecycle state

**Quote** — a firm price quote signed off-chain by an authorized vault signer:

- `orderId` (uint256) — target resting order (`0` for a market order)
- `user` (address) — taker bound to the quote (must be the caller for market orders)
- `vault` (address) — vault the quote is issued against
- `asset` (bytes32) — asset ticker
- `orderType` (OrderType) — Mint or Redeem
- `amount` (uint256) — input amount this quote fills (≤ remaining for a resting order)
- `price` (uint256) — execution price per eToken, 18 decimals
- `quoteId` (uint256) — unique nonce; each quote is single-use
- `expiry` (uint256) — timestamp after which the quote is invalid

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
