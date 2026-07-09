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
maker's quoter service off-chain, then either settle it atomically as a **market order**
(`executeOrder`) or rest a **limit order** (`placeOrder`) for a maker to fill. Redeemers who can't
get a quote have an on-chain force-execution path against the oracle price.

### Vault Managers (the per-vault `manager`)

> **Terminology:** the **`VaultManager`** contract (§9) is the global risk + control hub. Each
> `OwnVault` separately has an operator address stored as `manager` (formerly `vm`). "Vault manager"
> below refers to that per-vault `manager` operator.

Professional hedge funds / trading firms that operate a vault. They:

- Provide collateral (e.g. WETH) to their vault.
- Enable other ETH holders (LPs) to deposit into the vault & share fees (accept/reject LP deposits).
- Distribute LP yield (`shareYield`).
- Can **pause** their vault (freeze LP deposits + withdrawals) — shared with the admin.
- Hedge the protocol's exposure off-chain.

Order settlement no longer flows through the per-vault `manager`. Quotes are authorized by a
**global signer registry** and funds flow to/from each signer's linked address (see below). A maker
that signs quotes need not be the same entity as any vault's `manager`.

### Quote Signers (global registry)

Authorized signers live in a single **global registry on the `VaultManager`** (admin-managed via
`registerSigner` / `updateSignerLinkedAddress` / `removeSigner`), not per-vault. Each signer carries
a **linked settlement address**: mint proceeds flow **to** it and redeem payouts come **from** it.
This decouples the hot signing key (e.g. an HSM/KMS key) from the wallet that custodies funds. The
market accepts a quote only if it recovers to a registered signer (`isSigner`).

### Protocol Admin

Governance entity (multisig) that:

- Registers contracts in the Protocol Registry (with timelock)
- Adds assets and toggles their active status in the Asset Registry (`setAssetActive`)
- Configures oracle sources and fee levels
- Manages global controls on the `VaultManager`: the signer registry, the single global **payment
  token**, the global **claim threshold**, **trading pause** (global + per-asset), permanent
  **asset halt** + **halt redeem address**, the per-asset issuance cap, and global max utilization
- Can **halt** a vault (emergency wind-down) in addition to pausing it

Trust level: trusted (timelock-governed).

### Oracle Signers

Off-chain entities that sign price attestations for the in-house oracle. Prices are verified on-chain using ECDSA signatures. The protocol also integrates Pyth Network as an oracle source.

---

## 3. Contract Architecture

The protocol is organized into three layers (vaults are deployed directly and registered on the VaultManager — there is no vault or borrow-manager factory):

### Core Contracts

| Contract                      | File                            | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **ProtocolRegistry**          | `src/core/ProtocolRegistry.sol` | Central registry of all protocol contract addresses. 2-day timelock for address changes. Stores protocol-wide parameters (`timelockDelay`, `priceMaxAge`).                                                                                                                                                                                                                                                                                 |
| **OwnMarket**                 | `src/core/OwnMarket.sol`        | RFQ order execution marketplace. Settles market orders atomically against signer-issued quotes, escrows and (partially) fills resting limit orders, provides redeem force execution against the oracle price, and the halted-asset redeem path.                                                                                                                                                                                            |
| **OwnVault**                  | `src/core/OwnVault.sol`         | ERC-4626 collateral vault. Holds LP collateral (custody), manages async deposit/withdrawal queues, distributes yield, supports lending opt-in (binds exactly one borrow manager for its lifetime — `setBorrowManager` is one-shot), and vault-level pause/halt. Risk accounting and order controls live in the VaultManager, not the vault. Operator address: `manager`.                                                                                                                                                        |
| **VaultManager**              | `src/core/VaultManager.sol`     | Central, pooled risk accounting **and** global control hub for **all** vaults. Owns global exposure, collateral marks, utilization, the per-asset issuance ceiling, per-vault collateral concentration caps, **the vault registry/allowlist** (admin `registerVault`/`deregisterVault` + `getAllVaults`), the signer registry, the global payment token, trading pause, permanent asset halt + halt redeem address, and the claim threshold. Valued at keeper-cached marks. See §9. |
| **AssetRegistry**             | `src/core/AssetRegistry.sol`    | Whitelists assets, maps tickers to eToken addresses, stores oracle configurations. Supports token migration (post-stock-split). Governs which assets are valid for **all** vaults.                                                                                                                                                                                                                                                         |

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
                    AssetRegistry
                    (assets, oracle mappings)
                                      OwnVault ───────┐ admin registers vault / keeper pulls collateral price
                                 (ERC-4626 custody)   |
                                          |           v
                    OwnMarket  <----------+      VaultManager
              (RFQ order execution) ───────────▶ (global pooled risk + controls:
                    |         |        open/close   exposure, marks, utilization,
               EToken     OracleVerifier / Pyth      caps, signers, payment token,
          (mint/burn)      (price marks & proofs)     pause, halt, claim threshold)
                                                  ◀── pull asset price (keepers)
```

---

## 4. Order Execution

The protocol uses an offline **RFQ (request-for-quote)** model. A user obtains a firm, signer-issued
**quote** off-chain and settles it on-chain. The signed quote is the price attestation — the oracle
is not consulted during normal execution (only on the force path, §5). There are two paths:

- **Market order** — the user submits the signed quote and it settles atomically in one transaction. No on-chain order is persisted.
- **Limit order** — the user rests an order on-chain (escrowing the input); a maker fills it later with a signed quote whose price satisfies the user's limit. Limit orders support **partial fills**.

### The Quote

A quote is signed off-chain by one of the **globally-registered** quote signers (recovered against
`VaultManager.isSigner`, §2). It is **vault-less** — it binds: target order id (`0` for a market
order), taker, asset, side, amount, price, a unique single-use `quoteId`, and an expiry. The signed
digest also commits the chain id and market address to prevent cross-chain / cross-contract replay,
and each quote can be used only once. The settlement counterparty is the signer's **linked address**
(mint proceeds go to it; redeem payouts come from it), and the order currency is the single global
**payment token** — neither is carried in the quote.

### Order States (resting limit / redeem orders)

| Status            | Description                                                                                                               |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Open**          | Resting order placed, input escrowed. Fillable by a maker; redeem orders also force-executable after the claim threshold. |
| **Filled**        | Fully filled — remaining amount reached zero.                                                                             |
| **ForceExecuted** | Redeem order settled at the oracle price via force execution against a caller-named vault.                                |
| **Cancelled**     | Owner cancelled; remaining escrow returned.                                                                               |
| **Expired**       | Past its good-til-date; remaining escrow returned (callable by anyone).                                                   |

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

1. **User** requests a quote; a maker's quoter returns a signed quote (price, expiry).
2. **User** calls `executeOrder(quote, signature)`:
   - `VaultManager.openExposure(asset, eTokens)` runs first — an atomic check + commit of the per-asset USD ceiling and global utilization. A breach reverts cleanly before any token moves (§9).
   - The full payment-token `amount` is pulled from the user to the signer's **linked address** (the maker captures its spread off-chain).
   - eTokens minted to the user: `eTokens = amount * PRECISION / price` (decimal-adjusted for the payment token).

### Market Redeem Flow (atomic, one tx)

1. **User** requests a quote; a registered signer signs it.
2. **User** calls `executeOrder(quote, signature)`:
   - Payment tokens are pulled from the signer's **linked address** to the user: `payout = amount * price / PRECISION` (decimal-adjusted).
   - The user's eTokens are burned; `VaultManager.closeExposure(asset, units)` reduces global exposure. Exposure is purely global per asset — there is no "a vault may only close what it opened" constraint.

The signer's linked address must have approved the market to spend its payment tokens. A relayer may
submit on the user's behalf, since the signed quote carries the authorization.

### Limit Order Flow (resting, partial fills)

1. **User** calls `placeOrder(asset, orderType, amount, limitPrice, expiry)` — escrows payment tokens (mint) or eTokens (redeem). Orders are vault-less.
2. A maker (or relayer carrying a signed quote) calls `fillOrder(quote, signature)` for a chunk `≤ remaining`, at a price satisfying the limit. Settlement is identical to the market flows but funded from escrow. Repeat until filled.
3. `cancelOrder` (owner) or `expireOrder` (anyone, after expiry) returns the remaining escrow.

### Price Semantics

- **Mint**: `limitPrice` is the **maximum** price per eToken the user will pay — a fill quote must satisfy `quote.price ≤ limitPrice`.
- **Redeem**: `limitPrice` is the **minimum** price per eToken the user will accept — a fill quote must satisfy `quote.price ≥ limitPrice`. It also acts as the slippage floor for force execution.
- **Market orders** carry no separate limit — the user accepts the quote's price by submitting it.
- **Settle-price band** — independent of the user's limit, every `executeOrder` / `fillOrder` settlement must price within **±`settleBandBps`** of the asset's keeper mark (`VaultManager.assetMark`), else `PriceOutOfBand`. This caps the damage a leaked quote-signer key can inflict on a maker's balance to ~band % per unit of size (default **500 bps**). Force-execute and `redeemHalted` are exempt — they price off the oracle limit and the fixed halt price, not a signed quote.

---

## 5. Force Execution

Force execution is the user's recourse when no maker will quote. It applies to **redeem orders
only** — a redeemer holding eTokens is captive (eTokens convert back to stablecoins only through the
protocol), whereas an unfilled mint leaves the user holding their stablecoins, free to route
elsewhere. Forcing a mint would also open an unhedged position against LP collateral, so it is
disallowed (`ForceMintNotAllowed`).

After the global **claim threshold** elapses (measured from the order's creation), the owner of a
resting redeem order calls
`forceExecuteOrder(orderId, vault, assetPriceData, collateralPriceData)` to settle the remaining
amount at their committed `limitPrice`, gated by a fresh oracle price. **The caller names the
collateral-source `vault`**, chosen from the asset's **admin-approved force-execute pool**
(`AssetRegistry.setForceExecuteVaultAllowed`) — force-execution is the user's last-resort exit, so
source flexibility within a vetted pool is deliberate. A vault outside the pool reverts
(`ForceExecuteVaultNotAllowed`); an **empty pool — the pre-deploy default — disables
force-execution for the asset** (fail-safe). The named vault must also currently be registered,
not excluded, and not an RWA reserve vault (re-checked at execution, so a stale pool entry can
never route a force-execute into PSM reserves).

### Mechanism

1. **Asset price proof** (`assetPriceData`) — the current signed price of the asset (e.g. TSLA/USD).
2. **Collateral price proof** (`collateralPriceData`) — the current signed price of the named vault's collateral (e.g. ETH/USD), used to convert the USD value into collateral units.

Settlement:

- **Both proofs must be fresh** — no older than `priceMaxAge` and not future-dated, else `StaleAssetPrice` / `StaleCollateralPrice`. Force execution requires a price valid **now**, not a historical print: a favorable price that printed earlier in the order's life cannot be exercised after the market has moved away.
- The fresh asset price must satisfy the order's `limitPrice` floor, else it reverts (`PriceBelowMinimum`).
- The remaining eTokens are valued at the user's own `limitPrice` (bare oracle price, no maker spread — at or below the current price, never above it), converted to the named vault's collateral, and **that vault's collateral is released to the user**.
- The escrowed eTokens are burned and global exposure is reduced.

Force execution is **disabled while trading is paused** (`AssetPaused`) **or the asset is halted**
(`ForceDisabledDuringHalt`). A permanently halted asset is instead redeemed via `redeemHalted` (§9).
Because forced redeem prices at the bare oracle price (no maker spread), the **claim threshold delay**
keeps a fair maker quote the user's preferred path.

### Timing

| Parameter        | Description                                                                 | Default |
| ---------------- | --------------------------------------------------------------------------- | ------- |
| `claimThreshold` | Global delay after a redeem order is placed before it can be force-executed | 6 hours |

A zero `claimThreshold` **disables** force-execution (`ForceNotEnabled`) — the pre-deploy default — and
the setter rejects zero, so once configured force-execution can never be silently re-disabled.

---

## 6. LP Operations

Liquidity providers deposit collateral into vaults and receive ERC-4626 shares. Both deposits and withdrawals are async (queue-based) to give the vault's `manager` control over vault composition.

### Deposit Flow

1. LP calls `requestDeposit(assets, receiver, minSharesOut)` — collateral transferred to vault, creates a pending request
2. The `manager` calls `acceptDeposit(requestId)` — vault shares minted to receiver at current exchange rate (reverts if previewed shares < `minSharesOut`)
3. Alternatively, the `manager` calls `rejectDeposit(requestId)` — collateral returned to depositor
4. LP can call `cancelDeposit(requestId)` before the manager's decision — collateral returned

**Direct deposits** via `deposit()` / `mint()` are also supported (standard ERC-4626), but async is the primary path. (Async is required only when the vault has `requireDepositApproval` enabled.)

### Withdrawal Flow

1. LP calls `requestWithdrawal(shares)` — shares are queued (no specifc ordering)
2. Anyone can call `fulfillWithdrawal(requestId)` when:
   - A minimum wait period has passed
   - Vault utilization remains within bounds after withdrawal
3. LP can call `cancelWithdrawal(requestId)` to get shares back

**Vault status interacts with withdrawals:** a **paused** vault freezes both deposits _and_
withdrawals; a **halted** vault (emergency wind-down) blocks deposits but makes withdrawals
**instant** — the wait period and the utilization check are both bypassed, since a halted vault's
collateral is already excluded from the global risk pool (§9).

### ETH Routing

LPs can deposit native ETH using the **WETHRouter**, which wraps ETH to WETH before depositing into WETH-collateral vaults. Similarly, **WstETHRouter** handles stETH wrapping for wstETH-collateral vaults.

---

## 7. Revenue Model

The protocol charges **no on-chain mint or redeem fee**. Value accrues to makers and to the
vault manager (VM) through three live mechanisms.

### 7.1 RFQ spread (mint & redeem) — captured off-chain

Orders settle at the signer-issued `quote.price`. `OwnMarket` routes the **full** payment-token
amount to the maker (the signer's linked settlement address) and mints/burns the user's eTokens —
no fee is deducted on-chain (`_settleMint` / `_settleRedeem`). The maker's margin is the bid/ask
spread baked into the quoted price, captured off-chain. Force-executed redeems settle at the bare
oracle `limitPrice`, so they carry **no** maker spread — which is the whole reason for the
claim-threshold delay before force execution becomes available (see §6).

### 7.2 Lending premium — routed to the vault manager

Borrowers (eToken-collateralised lending) pay `max(liveAaveRate, floor) + premium(utilization)`, a
two-slope utilization curve (`InterestRateModel`; full detail in `docs/leverage-design.md`). The
**premium** — the spread charged above Aave's own rate — is the VM's lending revenue. It accrues
continuously into every borrower's debt through the global interest index, and equals the gap between
what borrowers owe (book debt) and what the vault owes Aave: `earnedInterest = bookDebt − aaveDebt`
(kept ≥ 0 by the index floor). It reaches the VM two ways:

- **On repay / liquidation (automatic).** `BorrowManager` repays Aave its actual cost and sweeps the
  **surplus** — the leftover premium — to the VM, emitting `LendingFeeAccrued`.
- **Mid-term, on demand (`claimEarnedInterest`).** The VM need not wait for borrowers to repay: it can
  pull earned-but-uncollected premium early. The cash is drawn from the vault's Aave credit line (the
  premium is not collected yet); later borrower repayments retire that draw, so the claim nets out
  automatically and the Aave **carry is borne by the VM** via a smaller repay-time surplus. It is
  bounded by `claimableInterest = earnedInterest × (BPS − interestBufferBps) / BPS` (default buffer
  10%, which keeps the claim strictly below the gap so the index floor never over-charges borrowers)
  and refused if the draw would drop the vault's Aave health factor below `minClaimHealthFactor`
  (admin param, default 1.1). Emits `InterestClaimed`. **Risk:** a claim converts unrealized premium
  into real Aave debt backed by LP collateral, so in a bad-debt event the claimed-but-uncollected
  slice is LP-borne (vs merely forgone if it were never claimed).

The premium is **pooled, not earmarked per position** — a claim does not change any borrower's debt; it
just enlarges the vault's Aave loan, which the pool's repayments settle. The VM distributes its lending
revenue downstream (off-chain split and/or `OwnVault.shareYield`, which lifts LP share price).

### 7.3 Collateral dividends — routed to the vault manager

For dividend-paying assets (e.g. eTLT), dividends accrue on the eToken collateral while it sits in
`BorrowManager` custody during a borrow. These accrue to the vault manager as lending revenue rather
than to the borrower: anyone can call `sweepDividends(eToken)` to forward them to the VM
(`DividendsSwept`). Once the collateral is returned to the borrower, future dividends accrue to them
normally again.

### 7.4 Treasury

`ProtocolRegistry.treasury()` is **not** a mint/redeem fee sink. It is the fixed destination for
**bad-debt collateral** released during lending wind-down
(`OwnVault.releaseCollateralForBadDebt`, `BorrowManager.absorbBadDebt`).

### 7.5 User price protection (not a fee)

There is no separate on-chain slippage check. A resting order's `limitPrice` bounds execution — max
price for a mint, min price for a redeem — and a market order executes at the `quote.price` the
taker submits. Force-executed redeems are floored at `limitPrice`.

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

Each vault's collateral is valued in USD by the **VaultManager**, using the oracle for the vault's
collateral asset (e.g. ETH/USD). The collateral ticker is bound at registration
(`VaultManager.registerVault(vault, collateralAsset)`), and the USD mark is refreshed by permissionless
keeper calls to `pullCollateralPrice(vault)` (§9). The collateral USD value feeds:

- Global utilization (§9)
- Force-execution collateral-equivalent returns (the market reads the caller-named vault's collateral ticker via `VaultManager.vaultCollateralAsset`)
- The lending debt cap (`BorrowManager.maxDebtUSD = collateralMark(vault) × targetLtvBps / BPS`)

---

## 9. Risk Accounting and Safety

All exposure, collateral valuation, and utilization accounting lives in a single **VaultManager**
that pools risk globally across every vault. Vaults keep custody, LP shares, yield, and lending; the
VaultManager owns risk **and** the global order-control surface (signers, payment token, trading
pause, asset halt, claim threshold). This replaces the earlier per-vault model.

### Pooled Model and Rationale

- **Pooled backing/solvency (global), isolated custody/yield (per vault).** Collateral lives in
  separate per-collateral ERC-4626 vaults (~5–6 total: USDC, aUSDC, ETH, stETH, …), but only the risk
  _math_ pools. A mint settled through any vault draws on the protocol's global collateral and global
  exposure book.
- **Cross-VM loss mutualisation (accepted tradeoff).** A VM default's shortfall is covered by the
  global pool (all vaults' LPs), Maker-style. This strengthens the eToken's backing; LP risk is
  mutualised across vaults.
- **Exposure is purely global per asset** — there is no `(vault, asset)` attribution and no "a vault
  may only close what it opened" rule. Any registered vault filling any redeem reduces the global book.
- **Why central.** The mint check is now `check == committed state` by construction (the same path
  that validates a mint commits it), a real per-asset issuance ceiling caps total eToken supply across
  vaults, and `OwnVault` bytecode shrinks.

### Three Caps (all O(1))

1. **Global utilization cap (solvency):** `globalExposureUSD / globalCollateralUSD ≤ globalMaxUtilizationBps`.
   `openExposure` (called on every mint settlement / limit fill) atomically checks and commits — if the
   projected utilization would breach the cap, settlement reverts before any tokens move. Redeems
   (`closeExposure`) reduce exposure and are never capped.
2. **Per-asset USD issuance ceiling (asset concentration):** `globalAssetUnits[asset] × assetMark ≤ assetCapUSD[asset]`.
   **`assetCapUSD == 0` blocks minting that asset** (safe default — the admin must set a ceiling to
   enable it).
3. **Per-vault collateral concentration cap (collateral diversification):** each vault may contribute at
   most `collateralCapBps[vault]` of total counted collateral. On each `pullCollateralPrice` (and
   `onVaultUnhalted`) the vault's counted contribution to `globalCollateralUSD` is
   `min(rawMark, collateralCapBps × others / (BPS − collateralCapBps))` — i.e. ≤ cap% of the total —
   and the excess is **not counted**, so it backs neither minting nor lending. `collateralCapBps == 0`
   is uncapped (opt-in per vault: cap volatile collaterals like stETH, leave the stable base uncapped).
   Re-applied on every pull, so it tracks price drift. See "Keeper-Cached Marks" below.

The global util + per-asset cap + per-vault collateral cap + halt/deregister cover the small set of
admin-vetted vaults. There are no per-vault *exposure* caps — exposure is purely global per asset.

Both `globalExposureUSD` and `globalCollateralUSD` are running totals updated on every
open/close/price-pull — no loops over vaults or assets on any path. Each asset's exact USD contribution
is stored so every update subtracts precisely what it added (no rounding drift).

### Keeper-Cached Marks (price pulls)

Exposure and collateral are valued **only** at keeper-cached marks (Maker `spot`-style), never at trade
prices. Marks are refreshed by **permissionless** calls:

- `pullAssetPrice(asset)` — pulls the asset's oracle price and re-marks global exposure for that asset.
- `pullCollateralPrice(vault)` — pulls the vault's collateral oracle price and re-marks its collateral USD, applying the vault's concentration cap (it counts at most its capped share; `CollateralCapApplied` fires when the cap binds).

`openExposure` (mint) additionally requires the asset's mark to be **fresh** — pulled within
`maxMarkAge` (default 15 min), else `StaleAssetMark` — so new exposure can't open against a stale
asset price. Collateral-side staleness (the utilization denominator) is still absorbed by the global
utilization buffer, and `closeExposure` (redeem, risk-reducing) is exempt. A new asset can only be
minted once **both** its price has been pulled (`assetMark != 0`) **and** `assetCapUSD > 0`.

### Withdrawal Gate

For an **active** vault, LP withdrawals consult `VaultManager.withdrawalBreachesUtil(vault, assets)`:
`fulfillWithdrawal` reverts (`MaxUtilizationExceeded`) if releasing that collateral would push global
utilization over the cap. The check reads the cached collateral mark (as fresh as the last price pull
— intended, per the keeper model). A **halted** vault bypasses this check entirely (its collateral is
already excluded from the pool); a **paused** vault blocks withdrawals outright.

### Registration

Vault registration is admin-driven: the admin deploys an `OwnVault` directly and calls
`VaultManager.registerVault(vault, collateralAsset)` (admin-only). The VaultManager holds the vault
allowlist (`isRegisteredVault`, `getAllVaults`) used by the market's force-execute path.
`deregisterVault` (admin-only) removes a vault and reverts if removing its collateral would breach
global utilization. There is no vault factory.

### Emergency Controls

There are two independent axes: **global trading controls** (on the VaultManager, asset-scoped) and
**vault-status controls** (on each OwnVault).

**Trading pause** — global VaultManager control, admin-set, temporary:

- `setTradingPaused(bool)` (global) and `setAssetTradingPaused(asset, bool)` (per-asset); query `isTradingPaused(asset)`.
- Blocks market execution, order placement, fills, **and force-execution** for the asset.
- Resting orders can still be cancelled or expired; LP operations continue.

**Asset halt** — global VaultManager control, admin-set, **permanent**:

- `haltAsset(asset, haltPrice)` permanently freezes an asset at a fixed settlement price (no unhalt).
- Mints are blocked (`MintBlockedDuringHalt`), normal redeem execution/fills revert (`TradingHalted`), and force-execution is disabled (`ForceDisabledDuringHalt`).
- Holders redeem via `redeemHalted(asset, eTokenAmount)`: the payout is the **global payment token**, pulled from the admin-set **halt redeem address** at the halt price, and the eTokens are burned (global exposure shrinks). Reverts if the asset is not halted, the halt redeem address is unset, or it lacks stables/allowance. The admin must size the halt fund to cover all outstanding units of the asset (including those locked as lending collateral — see §11/lending).

**Vault pause** — per-vault (OwnVault), callable by the vault's `manager` **or** the admin, temporary:

- Freezes both LP deposits **and** withdrawals. Does not by itself stop trading of an asset.

**Vault halt** — per-vault (OwnVault), **admin only**, emergency wind-down:

- Blocks deposits; LP withdrawals become **instant** (no wait period, no utilization check).
- The vault's collateral is **excluded from the global risk pool** (`onVaultHalted`); unhalt re-includes it (`onVaultUnhalted`). A **paused** vault's collateral, by contrast, still counts toward the pool.

### Vault Status Hierarchy

```
Active → Paused → Halted       (per-vault status, OwnVault)
  ↑         |        |
  +---------+--------+
     (can be reversed)
```

Asset-level **trading pause** (reversible) and **asset halt** (permanent) are separate, global
VaultManager states — orthogonal to a vault's own status.

---

## 10. Security Patterns

### Access Control

| Action                                                    | Who Can Do It                                        |
| --------------------------------------------------------- | ---------------------------------------------------- |
| Register contracts in ProtocolRegistry                    | Protocol admin (with timelock)                       |
| Add assets / set active status (`setAssetActive`)         | Protocol admin                                       |
| Configure oracles and fees                                | Protocol admin                                       |
| Deploy + register / deregister vaults                     | Protocol admin (registerVault on VaultManager)       |
| Pause a vault (deposits + withdrawals)                    | Vault's `manager` or admin                           |
| Halt a vault (wind-down)                                  | Protocol admin                                       |
| Trading pause / asset halt (global)                       | Protocol admin (VaultManager)                        |
| Set payment token / claim threshold / halt redeem address | Protocol admin (VaultManager)                        |
| Register/update/remove quote signers                      | Protocol admin (VaultManager)                        |
| Sign order quotes (off-chain)                             | Globally-registered signers                          |
| Fill resting limit orders (RFQ)                           | Anyone with a valid signed quote                     |
| Fill resting orders vs the PSM reserve (`psmFillOrder`)   | Anyone (permissionless DvP; spread fee to treasury)  |
| PSM mint / redeem (`psmMint` / `psmRedeem`)               | Any user (permissionless wrapper ↔ eToken, no fee)   |
| Accept/reject LP deposits                                 | Vault's `manager`                                    |
| Execute market orders / place orders                      | Any user (market order needs a signed quote)         |
| Cancel orders                                             | Order owner                                          |
| Force execute redeem orders                               | Order owner (after claim threshold, names the vault) |
| Redeem a halted asset                                     | Any holder (`redeemHalted`)                          |
| Expire resting orders                                     | Anyone (permissionless, after expiry)                |
| Fulfill withdrawals                                       | Anyone (permissionless, if conditions met)           |

### Smart Contract Patterns

- **Checks-Effects-Interactions (CEI)**: all state changes happen before external calls
- **ReentrancyGuard**: on OwnMarket, OwnVault, and router contracts
- **SafeERC20**: all token transfers use OpenZeppelin's SafeERC20
- **No floating pragma**: pinned to `solidity 0.8.28`
- **Custom errors**: gas-efficient error handling (no require strings)
- **Timelock governance**: ProtocolRegistry changes require a 2-day delay

### Blocklist-freeze handling (USDC/USDT)

- **Escrow returns never brick.** If returning escrow to a user fails (e.g. the user was
  blocklisted by the token issuer after placing the order), `cancelOrder`/`expireOrder` sweep the
  funds to `registry.treasury()` and emit `EscrowSweptToTreasury(user, token, amount)` instead of
  reverting. Resolution is off-chain: genuine cases are refunded by governance from the treasury;
  illicit funds are held or forwarded to authorities. The treasury multisig is assumed
  non-freezable.
- **Halt redeem address must be monitored.** `redeemHalted` pulls payout funds *from* the
  admin-set halt redeem address; a freeze of that address blocks halt redemptions for the asset
  until the admin rotates it (`setHaltRedeemAddress`). Ops requirement: monitor the halt address
  and rotate immediately on freeze.

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

| Enum               | Values                                          | Description                                   |
| ------------------ | ----------------------------------------------- | --------------------------------------------- |
| `OrderType`        | Mint, Redeem                                    | Whether an order is buying or selling eTokens |
| `OrderStatus`      | Open, Filled, ForceExecuted, Cancelled, Expired | Resting-order lifecycle state                 |
| `WithdrawalStatus` | Pending, Fulfilled, Cancelled                   | LP withdrawal request state                   |
| `DepositStatus`    | Pending, Accepted, Rejected, Cancelled          | LP deposit request state                      |
| `VaultStatus`      | Active, Paused, Halted                          | Vault operating state                         |

### Structs

**Order** — a resting (limit / redeem) order escrowed in the marketplace. Market orders are not persisted as Orders.

- `orderId` (uint256) — unique identifier
- `user` (address) — who placed it
- `asset` (bytes32) — asset ticker (e.g. `bytes32("TSLA")`)
- `orderType` (OrderType) — Mint or Redeem
- `amount` (uint256) — original input: payment-token amount (Mint) or eToken amount (Redeem)
- `filledAmount` (uint256) — cumulative input filled so far (≤ amount)
- `limitPrice` (uint256) — max price (Mint) or min price (Redeem), 18 decimals
- `createdAt` (uint256) — placement timestamp
- `expiry` (uint256) — good-til-date timestamp after which the order can be expired
- `status` (OrderStatus) — current lifecycle state

Orders are vault-less; the collateral-source vault for a forced redeem is named at force-execution time.

**Quote** — a firm price quote signed off-chain by a globally-registered signer:

- `orderId` (uint256) — target resting order (`0` for a market order)
- `user` (address) — taker bound to the quote (must be the caller for market orders)
- `asset` (bytes32) — asset ticker
- `orderType` (OrderType) — Mint or Redeem
- `amount` (uint256) — input amount this quote fills (≤ remaining for a resting order)
- `price` (uint256) — execution price per eToken, 18 decimals
- `quoteId` (uint256) — unique nonce; each quote is single-use
- `expiry` (uint256) — timestamp after which the quote is invalid

The quote carries no vault and no payment token: the settlement counterparty is the signer's linked
address and the currency is the global payment token.

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
- `minSharesOut` (uint256) — slippage floor; `acceptDeposit` reverts if previewed shares fall below it
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

**VMConfig** — legacy vault-manager state struct (defined in `Types.sol` but unused by the current
contracts; retained for reference / future use):

- `maxExposure` (uint256) — max USD notional the manager will hedge (18 decimals)
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
| **EIP-712**  | Protocol signatures use domain name "Own Protocol", version "1": RFQ quotes (`Quote` typehash, OwnMarket domain) and oracle price attestations (`PriceAttestation` typehash, OracleVerifier domain). EToken ERC-2612 permits are the exception — their domain name is the token's **deploy-time `name()`** (version "1"), fixed for the contract's life and unchanged by `updateName`. A rename therefore breaks permits derived from the live `name()`; integrators should be aware. |

---

## 13. Token Migration (Stock Splits)

When an underlying asset undergoes a corporate action that changes its denomination (e.g. a stock
split), the asset keeps its ticker but its eToken is **migrated**: the current eToken becomes a
**legacy** token and a new eToken becomes active. A 1e18-scaled `ratio` defines new tokens per old
token (a 3:1 split → `ratio = 3e18`).

### Convert-first model

Legacy tokens are **not directly redeemable or tradeable**. A holder's only on-chain action with a
legacy token is to convert it to the current active token:

```
OwnMarket.convertLegacy(asset, legacyToken, amount)
  → burns `amount` legacy, mints `amount × ratio / 1e18` active to the caller
```

After conversion the holder uses the normal redeem/trade paths. `convertLegacy` is intentionally
**exempt from trading pause and asset halt** — it is a 1:1 re-denomination (no price exposure), so
legacy holders can always reach the active token, and therefore redemption, even while trading is
frozen. Conversion does not change global exposure (see `applySplit` below); it only re-denominates
the holder's tokens.

Each legacy token stores a single ratio that converts it **directly to the current active token**.
On every subsequent split, prior legacy ratios are re-based (multiplied by the new ratio), so a token
two splits back still converts to the live active token in one call.

### Exposure re-denomination (`VaultManager.applySplit`)

A split is **USD-neutral** for protocol exposure — only the unit count and per-unit mark change.
`applySplit(asset, ratio)` sets `globalAssetUnits *= ratio` and `assetMark /= ratio`, leaving the
per-asset exposure USD and the per-asset USD cap invariant. It is **driven by
`AssetRegistry.migrateToken`** (callable only by the AssetRegistry — `OnlyAssetRegistry`), so the unit
re-denomination and the token migration commit in the same transaction (see the runbook below).

### Resting orders across a migration

A resting order snapshots the exact token it escrowed (`Order.escrowToken`). After a migration:

- `cancelOrder` / `expireOrder` return the **original** escrowed (now legacy) token — never stranded.
- `fillOrder` / `forceExecuteOrder` on a redeem order whose escrow is now a legacy token revert
  (`OrderTokenMigrated`); the owner cancels to recover the original token and converts it.

### Borrow positions across a migration

A borrow position snapshots the exact eToken posted (`Position.collateralToken`). The position is
left untouched by the split — it stays denominated in the legacy token and is **valued at its split
ratio**: `effectivePrice = activePrice × legacyRatio`. As a result:

- The position's health factor is **unchanged** the instant a split is applied (collateral amount
  constant, effective price tracks the active token). A split alone never triggers a liquidation.
- `repay` returns the original (legacy) collateral; the borrower converts it afterward.
- `liquidate` values and seizes the legacy collateral at its effective price; the liquidator converts
  the seized tokens.
- `settleHaltedPosition` (used when the asset is later halted) converts the position's legacy
  collateral to the active token internally, then settles at the halt price via `redeemHalted`.

### Admin runbook for a split

1. Pause the asset's trading (`setAssetTradingPaused(asset, true)`).
2. Deploy the new eToken; `AssetRegistry.migrateToken(ticker, newToken, ratio)` — this also applies
   the exposure re-denomination (`VaultManager.applySplit`) atomically, in the same transaction.
3. Push the split-adjusted oracle price and pull the mark.
4. **Wait `≥ priceMaxAge`** (the inline-proof freshness bound; deploy value 2 min), measured from the
   last pre-split price signature, so every old-denomination attestation has expired before borrowing
   reopens. **Do not unpause early** (see the note below).
5. Unpause (`setAssetTradingPaused(asset, false)`).
6. Holders call `convertLegacy`; borrowers' positions continue and resolve through normal
   repay/liquidate/settle.

**Stale pre-split price — why the wait (step 4) is mandatory.** Signed price attestations price the
*ticker* and carry no split epoch, and `BorrowManager.borrow` values posted collateral at the
caller-supplied inline price with **no settle-band check** (the rebased mark feeds only the vault-wide
debt cap, not the per-position LTV). So a price signed at the *old* per-token denomination (e.g. $300
before a 3:1 split) stays a valid, fresh proof for up to `priceMaxAge` after the split, and would value
the new $100 tokens at $300 (3× over) — enabling an undercollateralized borrow against LP collateral.
Pausing alone does **not** close this: the signature survives the pause and `borrow` reopens at unpause.
The asset must stay paused until those proofs age out, which step 4 guarantees. (Surfaced by the
2026-06-22 GPT-5 validation pass, GPT5-H-08; accepted with this operational mitigation — see
`audit-report.md` §3. On-chain alternatives: a settle-band check on the borrow collateral price, or
blocking unpause until `priceMaxAge` after a migration.)

**Atomicity (enforced on-chain).** The migration and the exposure re-denomination are coupled in
code: `migrateToken` calls `applySplit` with the same `ratio` in one transaction, and `applySplit`
reverts `OnlyAssetRegistry` if invoked any other way. There is no window where the new legacy ratio
is live (`convertLegacy` mintable) while the exposure book is still in old units, so the two ratios
cannot diverge and the calls cannot be separated. (Previously a manual single-batch ops requirement;
hardened in code 2026-06-19 — audit finding L-07.)

---

## 14. PSM & Reserve Vaults

The PSM (peg-stability module) is a second, quote-less issuance channel: users convert an
issuer's **wrapper token** (a 1:1-backed tokenized stock, e.g. a Dinari dShare) directly to and
from the protocol's eToken for the same equity. Full design + rationale: `docs/psm-design.md`.

### Vault classes

`VaultManager.registerVault` has two forms:

| Class       | Registration                            | Collateral accounting                                  |
| ----------- | --------------------------------------- | ------------------------------------------------------ |
| **Generic** | `registerVault(vault, collateralAsset)` | Mark accrues to the global pool (`globalCollateralUSD`) |
| **RWA**     | `registerVault(vault, wrapperTicker, backedAsset)` | Mark accrues to `assetRwaCollateralUSD[backedAsset]` |

Per-asset **delta netting**: with gross exposure `E_a` and RWA reserve value `R_a`, the global
net exposure sums `max(0, E_a − R_a)` per asset. A PSM mint adds equal USD to both sides, so a
matched book adds **zero** net risk and needs no generic LP collateral. RWA vaults never join the
generic pool, never take LP deposits, never source force-executions, and never enter the lending
allowlist.

### ReserveVault

A share-less custody vault holding one wrapper token as protocol-owned backing for one asset:

- `deposit(amount)` — permissionless backfill (maker hedge delivery); syncs the reserve mark
  inline so the deposit nets immediately.
- `releaseCollateral(to, amount)` — market-only exit for PSM redemptions (mark-sync before
  transfer).
- `withdraw(amount)` — **maker recovery**: a registered quote signer, allowlisted for the backed
  asset, withdraws surplus to its **linked settlement address** (never the hot key). Works
  off-hours (no freshness gate — nothing is minted).
- `skimExcess(amount)` / `sweepToken(token)` — **manager-or-operator**, paid to the caller.
  `sweepToken` recovers non-wrapper balances (e.g. issuer dividend stablecoins) and can never
  touch the wrapper. Every wrapper exit is clamped by the **surplus guard**: the remaining
  reserve must still cover the asset's gross exposure.
- `manager` — the operating VM bound at construction (admin-rotatable via `setManager`).

### PSM mint / redeem

`OwnMarket.psmMint(asset, wrapper, amount)` / `psmRedeem(asset, wrapper, amount)` convert at a
**derived ratio** — `oracle wrapper-token price ÷ VaultManager asset mark` — the same numbers the
netting books use, so unit conversion and USD accounting can never disagree. No stored ratio; a
total-return issuer's sValue drift and stock splits re-derive automatically.

Safety gates (all fail-closed):

| Gate | Behavior |
| ---- | -------- |
| **Ratio-jump guard** | Per-(asset, wrapper) `lastUsedRatio`; a per-op move beyond the global bps bound reverts. Bound 0 (pre-deploy default) keeps PSM mint/redeem inert; the setter can never return it to zero. Operator `resetRatioGuard` disarms once (corporate-action acknowledgment). |
| **Per-wrapper pause** | `setPsmPaused(asset, wrapper, paused)` — operator, instant. |
| **Freshness** | Mint needs fresh wrapper + asset marks; redeem works off-hours and during halts (pays the frozen halt price) but needs a fresh wrapper leg. |

### PSM fills (`psmFillOrder`)

Resting limit orders can also be filled **permissionlessly** against the PSM reserve — atomic
delivery-vs-payment, no quote, no signer, no maker allowlist. A mint fill pulls wrapper from the
filler into the ReserveVault (ceil-rounded) and pays them the order's stablecoin escrow; a redeem
fill pulls the filler's stablecoins to the order owner and releases reserve wrapper to the filler
(floor-rounded, **bounded by the reserve balance** — buffer-backed supply cannot drain the
reserve through this path).

- **Settle price = the order's limit price**, bounded by the settle band (±`settleBandBps` of a
  keeper-fresh mark). The wrapper leg must always be fresh — fills are discretionary trades, not
  holder exits — and fills are blocked while the asset is paused or halted (halted holders exit
  via `psmRedeem`/`redeemHalted`).
- **Spread fee**: the protocol collects `AssetRegistry.psmFillSpreadShareBps` (admin-set, default
  0, max 100%) of the filler's spread over the mark, paid in the fill's stablecoin leg to the
  treasury — deducted from the mint payout, charged on top of the redeem payout. Zero edge → zero
  fee, so the fee can never turn a profitable fill unprofitable, and the wrapper/eToken legs (and
  therefore backing) are untouched. The order owner's terms are unaffected; `psmMint`/`psmRedeem`
  and the RFQ channel stay fee-free.
- **Per-asset fill kill switch**: `setPsmFillPaused(asset, paused)` — operator, default live —
  darkens the fill channel alone; `psmMint`/`psmRedeem` and the RFQ paths stay up. Composes with
  the per-wrapper `setPsmPaused`.

Full decision log: `docs/psm-design.md` §8.0.

### Per-asset allowlists (AssetRegistry)

All default-deny; armed by the deploy scripts; admin-granted, revocation always possible:

| Allowlist | Gates | Consumer |
| --------- | ----- | -------- |
| `setMakerAllowed(asset, signer)` | Quote settlement + reserve recovery | `OwnMarket._consumeQuote`, `ReserveVault.withdraw` |
| `setLendingVaultAllowed(asset, vault)` | New borrows (repay/liquidate unaffected) | `BorrowManager._validateEligibility` |
| `setForceExecuteVaultAllowed(asset, vault)` | Force-execute collateral source pool | `OwnMarket.forceExecuteOrder` (§5) |

### Corporate-action runbook (operator)

On an issuer corporate action (split / ticker change) with ≥24h notice:

1. `setPsmPaused(asset, wrapper, true)` before the event window.
2. After the issuer re-syncs (rebase or sValue jump) and the oracle publishes the post-event
   wrapper token price: verify the derived ratio, `resetRatioGuard(asset, wrapper)` (disarms the
   jump guard once), then unpause. The next PSM operation re-arms the guard.

**Oracle note:** the wrapper ticker publishes the wrapper **token** price — for a price-tracking
issuer (Dinari) that is the share price (splits rebase balances in place); for a total-return
issuer (Ondo) it is share price × sValue. It equals the underlying equity feed only while the
multiplier is 1.
