# Aave Collateral Yield Vault — Design Document

## Overview

Replace plain WETH as vault collateral with wstETH deposited into Aave V3 via a periphery router. OwnVault holds awstETH (Aave's receipt token for wstETH) as its collateral type — unchanged otherwise. The vault's Aave borrowing power is delegated to a periphery BorrowManager (one per vault, deployed directly by the admin and bound via `setBorrowManager`), which handles all lending/borrowing logic without modifying the core vault.

**Core insight**: With a 2x collateral ratio for eToken issuance, the vault's Aave LTV stays at a conservative 30-35% — well below the 79.5% liquidation threshold. The same collateral simultaneously backs eTokens and secures an Aave borrow position, but the overcollateralization makes this safe.

**Key feature on top of base yield:**
- **User looping** — eToken holders can borrow stablecoins against their eTokens, buy more eTokens, borrow again, and repeat — building leveraged RWA exposure.

---

## Yield Stack for LPs

| Source | Estimated APY | Mechanism |
|--------|--------------|-----------|
| ETH staking yield (Lido) | ~3% | Embedded in wstETH exchange rate |
| Aave supply yield | ~0.1-0.5% | Earned on awstETH held by vault |
| Own protocol fees | Variable | Mint/redeem fee share (existing) |
| Lending spread | Variable | Aave borrow rate + premium charged to eToken borrowers |

LPs earn all four yield sources on the same capital.

---

## Mechanism

### Deposit Flow (via AaveRouter)

```
LP sends wstETH to AaveRouter
  → Router calls pool.supply(wstETH, amount, onBehalfOf=vault)
  → awstETH minted directly to OwnVault
  → Router calls vault.deposit() → ERC-4626 shares minted to LP
  → Vault holds awstETH + has Aave borrowing power (delegated to BorrowManager)
```

Note: awstETH is rebasing (balance grows over time). The vault tracks LP shares via ERC-4626 internally, similar to how the existing stETH vault handles wstETH. The vault's `totalAssets()` reads its awstETH balance, which auto-appreciates.

OwnVault requires no changes for this flow — it simply receives awstETH as its collateral token. The AaveRouter handles all Aave interaction, same pattern as WstETHRouter.

### eToken Issuance (Unchanged by lending)

```
Minter settles a VM-signed quote via OwnMarket (market order, or limit order filled by the VM)
  → eTokens minted at 2x collateral ratio
  → Vault exposure updated (existing logic)
```

eToken issuance follows the standard RFQ flow (see `docs/protocol.md` §4). Lending does not change it
— only the vault's collateral type changes from WETH to awstETH; the issuance and exposure logic is identical.

### Stablecoin Lending to eToken Holders

Borrowing runs through a single periphery contract, BorrowManager, that holds the vault's delegated Aave credit. eToken holders borrow stablecoins against their eTokens.

```
BorrowManager borrows stablecoins from Aave on behalf of the vault
  → manager lends stablecoins to eToken holders
  → eToken holders post their eTokens as collateral (70% LTV)
  → Borrowers pay: Aave borrow rate + variable premium
  → Variable premium increases with lending utilization (auto-recovery)
```

The manager is self-contained: it enforces its own vault-wide debt cap (`maxDebtUSD` = `VaultManager.collateralMark(vault) * targetLtvBps`), computes `utilizationBps` from its own outstanding debt, and reads the live Aave borrow rate (`baseRateBps`) directly from the pool's USDC reserve.

### User Looping (Leveraged eToken Exposure)

Users can build leveraged eToken positions by looping: buy eTokens → borrow stablecoins against them → buy more eTokens → repeat.

```
Loop 1: User has $1000 USDC
  → Mints $1000 eTSLA via OwnMarket
  → Borrows $700 USDC against eTSLA (70% LTV)

Loop 2: User has $700 USDC
  → Mints $700 eTSLA
  → Borrows $490 USDC against eTSLA (70% LTV)

Loop 3: User has $490 USDC
  → Mints $490 eTSLA
  → Borrows $343 USDC against eTSLA (70% LTV)

After 3 loops:
  Total eTSLA exposure:  $2,190  (2.19x leverage on $1000)
  Total debt:            $1,533
  Total collateral:      $2,190 eTSLA
  Effective LTV:         70% on each layer

After N loops (geometric series):
  Max theoretical exposure = $1000 / (1 - 0.7) = $3,333  (3.33x leverage)
  Practical limit: ~3x after 5-6 loops (gas costs make further loops uneconomical)
```

**Helper contract (LoopRouter)**: A periphery contract can batch multiple loops into a single transaction for better UX. User specifies desired leverage, router calculates loop count and executes all mint+borrow steps atomically.

```
User calls: LoopRouter.leverageMint(asset, amount, targetLeverage)
  → Router executes N loops in one tx
  → User ends up with leveraged eToken position + corresponding debt
```

**Unwinding a looped position**: User repays in reverse — sell/redeem eTokens → repay debt → unlock collateral → sell more → repay more → until fully unwound. The LoopRouter can also batch this.

### Repayment & Liquidation

```
Borrower repays stablecoins
  → Vault repays Aave debt
  → eToken collateral released to borrower

Borrower underwater (eToken price drops)
  → External liquidator/keeper calls liquidate()
  → Vault seizes eTokens → burns them → exposure decreases
  → Vault recovers stablecoins → repays Aave → LTV improves
  → Both health factors improve simultaneously (self-healing)
```

### Lending During Pause / Halt

Lending tracks the global trading controls on the `VaultManager`:

- **Asset trading paused or halted** → new `borrow()` is blocked (`VaultEffectivelyHalted`). `repay()` and `liquidate()` stay open so positions can keep de-risking.
- **Permanent asset halt** → leveraged positions are unwound per-borrower via `settleHaltedPosition(borrower, asset)` (callable by anyone — keeper, borrower, or admin):

```
settleHaltedPosition(borrower, asset)
  → seize the eToken collateral needed to cover the debt at the fixed halt price
  → redeem that slice via OwnMarket.redeemHalted → stablecoins from the halt redeem address
  → repay the vault's Aave debt with the proceeds (surplus swept to the manager)
  → return any excess eToken collateral to the borrower; shrink global exposure
  → if collateral can't cover the debt, the shortfall is a zero-collateral residual for absorbBadDebt
```

> Because settlement sources stablecoins through `redeemHalted`, the **halt redeem address must be
> funded to cover borrowed-against eTokens too** — not just freely-held ones. The MVP assumes the
> global payment token equals the borrow stablecoin (USDC) so redeem proceeds repay Aave directly.

### LP Withdrawal

```
LP requests withdrawal
  → If vault has Aave debt from eToken borrowers: vault may need to recall loans
  → Variable premium spikes → incentivizes borrower repayment
  → Or: manager liquidates underwater borrowers → recovers stablecoins
  → Manager repays Aave → withdraws wstETH from Aave → returns to LP
```

---

## Math

### Constants & Parameters

| Parameter | Value |
|-----------|-------|
| eToken collateral ratio | 2x (50% max utilization) |
| Max eToken exposure | 50% of vault collateral value |
| Aave borrow (% of eToken exposure) | 70% |
| Max Aave LTV (resulting) | 35% of vault value |
| Aave wstETH liquidation threshold | 79.5% |
| eToken borrower LTV | 70% of eToken value |

### Example: $100 wstETH Vault

```
Vault deposits:           $100 wstETH into Aave
eTokens issued:           $50  (2x collateral ratio, 50% utilization)
Borrowed from Aave:       $35  (70% of $50 eToken exposure)
Aave LTV:                 35%  ($35 / $100)
Buffer to liquidation:    56%  ETH must drop ~56% to trigger Aave liquidation

Lent to eToken holders:   $35  at 70% LTV against $50 of eTokens
```

### Stress Test: 50% ETH Crash

```
Before crash:
  Vault collateral:   $100 wstETH
  Aave debt:          $35 USDC
  Aave LTV:           35%
  Own health factor:  2.0x

After 50% ETH crash:
  Vault collateral:   $50 wstETH
  Aave debt:          $35 USDC
  Aave LTV:           70%  (approaching 79.5% threshold — warning zone)
  Own health factor:  1.0x (minimum)

Recovery cascade:
  → Lending premium spikes (high utilization rate)
  → eToken borrowers repay or get liquidated
  → Liquidated eTokens burned → exposure drops → Own health improves
  → Recovered stablecoins repay Aave → Aave LTV drops
  → System stabilizes
```

### At Typical Utilization (30-40% vs 50% max)

```
Vault:               $100 wstETH
eTokens issued:      $35  (35% utilization, typical)
Borrowed from Aave:  $24.5 (70% of $35)
Aave LTV:            24.5%

After 50% ETH crash:
  Aave LTV:          49%  (safe — well below 79.5%)
  Own health factor:  1.43x
```

At typical utilization, the system survives a 50% ETH crash comfortably.

---

## Interest Rate Model (Lending Premium)

The vault lends borrowed stablecoins to eToken holders at a rate above Aave's borrow cost. The premium follows a utilization-based curve (same model as Aave's own rate curves).

```
lendingRate = aaveBorrowRate + premium(utilization)

where:
  utilization = totalLent / maxLendingCapacity
  maxLendingCapacity = 70% of current eToken exposure value

  if utilization <= optimalUtilization (e.g., 80%):
    premium = basePremium + utilization * slope1
  else:
    premium = basePremium + optimalUtilization * slope1
             + (utilization - optimalUtilization) * slope2

  slope2 >> slope1 (steep increase above optimal — forces repayment)
```

### Example Rate Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| basePremium | 1% APR | Minimum protocol spread |
| optimalUtilization | 80% | Kink point |
| slope1 | 4% APR | Gradual increase below kink |
| slope2 | 75% APR | Steep increase above kink (auto-recovery) |

```
At 50% utilization: rate = aaveBorrowRate + 1% + 50%*4% = aaveBorrow + 3%
At 80% utilization: rate = aaveBorrowRate + 1% + 80%*4% = aaveBorrow + 4.2%
At 95% utilization: rate = aaveBorrowRate + 4.2% + 15%*75% = aaveBorrow + 15.45%
```

The steep slope2 above optimal utilization strongly incentivizes repayment, acting as an automatic deleveraging mechanism.

### Rate Distribution

| Recipient | Source |
|-----------|--------|
| Aave | Borrow interest (paid on repay) |
| LPs | Premium portion → accrues to vault share price |
| Protocol | Protocol spread → treasury |

---

## Liquidation of eToken Borrowers

### Parameters

| Parameter | Value |
|-----------|-------|
| Borrow LTV | 70% of eToken value |
| Liquidation threshold | 80% of eToken value |
| Liquidation bonus | 5% |

### Health Factor

```
healthFactor = (eTokenCollateralValue * liquidationThreshold) / debtValue

Liquidation triggers when healthFactor < 1.0
```

### Liquidation Flow

1. External liquidator calls `liquidate(borrower, debtAmount)`
2. Vault verifies `healthFactor < 1.0` using oracle price for the eToken's underlying asset
3. Liquidator repays up to 50% of borrower's stablecoin debt
4. Vault transfers equivalent eToken collateral + liquidation bonus to liquidator
5. Vault uses repaid stablecoins to reduce Aave debt
6. If remaining eToken collateral is dust, vault burns it and reduces exposure

### Self-Healing Property

Liquidation of eToken borrowers simultaneously improves both health factors:
- **Own protocol**: burned eTokens reduce exposure → health factor increases
- **Aave**: recovered stablecoins repay debt → LTV decreases

This creates a natural stabilization loop under stress.

---

## Comparison: Why Not stataTokens?

| Approach | Aave Yield | Borrowing Power | OwnVault Changes | Complexity |
|----------|-----------|----------------|-------------------|------------|
| Accept stataTokens (waBaswstETH) | Yes | No — wrapper contract holds Aave position | None | Low |
| Accept awstETH (transferred) | Yes | Yes — but vault didn't deposit, needs `setUserUseReserveAsCollateral` | Minor | Low |
| AaveRouter deposits on behalf of vault | Yes | Yes — vault IS the Aave depositor via `onBehalfOf` | One function | Medium |

**This design uses the third approach.** AaveRouter calls `pool.supply(onBehalfOf=vault)`, making the vault the Aave depositor with full borrowing power. The protocol admin opts a vault into lending via the vault's provider-neutral seam — `setBorrowManager(manager)` then (for Aave) `grantCreditDelegation(debtToken)`, which delegates borrowing power to the vault's BorrowManager. stataTokens are not used because they sacrifice borrowing power — and we need it.

---

## Base Chain Considerations

- Current wstETH on Aave Base: ~$40M TVL
- Aave wstETH (Base) contract: `0x99cbc45ea5bb7ef3a5bc08fb1b7e56bb2442ef0d`
- wstETH (Base) contract: `0xc1cba3fcea344f92d9239c08c0568f6f2f0ee452`

### Growth Flywheel

```
Own offers triple yield on wstETH
  → LPs bridge wstETH from Ethereum mainnet to Base
  → Aave Base wstETH TVL grows
  → Deeper Aave liquidity → lower borrow rates for the vault
  → Better lending spread for Own → more attractive LP yields
  → More LPs → more bridging → cycle continues
```

### Concentration Risk Mitigation

If Own protocol becomes a significant share of Aave Base wstETH pool:
- Monitor vault's share of total Aave wstETH supply on Base
- Set a protocol-level cap on total wstETH deposited (e.g., max 25% of Aave pool)
- As Aave TVL grows via the flywheel, the cap can increase

---

## Architecture

### Design Principle: Core + Periphery (OwnVault Unchanged)

OwnVault stays venue-neutral — it accepts awstETH as just another ERC-20 collateral type and knows nothing about Aave. All Aave-specific logic lives in the BorrowManager + periphery. The vault's borrow manager is bound via `setBorrowManager`, and (for Aave) its borrowing power is delegated to that manager via `grantCreditDelegation`.

**Why this works**: The vault holds awstETH → has Aave borrowing power → delegates it to its BorrowManager. The manager borrows from Aave (debt accrues to vault's Aave position), manages per-user lending state, enforces its own vault-wide debt cap, and handles liquidations. Aave's own LTV limits enforce a hard ceiling on top of the manager's cap.

### Lending Setup (Opt-In, provider-neutral)

Lending is opt-in and wired through the vault's provider-neutral seam — the core vault embeds no Aave types. For an Aave-funded vault the admin authorises the manager and then grants Aave credit delegation:

```
Deployment (all admin-driven; no factories):
  1. Admin deploys `new OwnVault(awstETH, ...)` and calls VaultManager.registerVault(vault, collateralAsset)
     → standard OwnVault, no Aave awareness
  2. Admin deploys `new BorrowManager(vault, stablecoin, debtToken, aavePool, registry, targetLtvBps, rateParams)`
     → the vault's single BorrowManager (1:1 binding enforced by setBorrowManager)
  3. Protocol admin calls vault.setBorrowManager(borrowManager)
     → authorises the manager (also the address allowed to call releaseCollateralForBadDebt)
  4. Protocol admin calls vault.grantCreditDelegation(debtToken)
     → Vault internally calls:
        ICreditDelegation(debtToken).approveDelegation(borrowManager, type(uint256).max)
     → Aave LTV enforces a hard borrowing limit on top of the manager's cap
```

Two small admin-only functions on OwnVault, both **safe by construction** — the credit-delegation
beneficiary is always the bound manager (never an admin-chosen address), and neither call grants any
allowance or transfer of the vault's own collateral:

```solidity
function setBorrowManager(address manager_) external onlyAdmin;          // authorise (one-shot)
function grantCreditDelegation(address creditToken) external onlyAdmin;  // delegate to the bound manager
```

In-house lending uses only `setBorrowManager` (no external delegation). Vaults with non-Aave
collateral that never enable lending simply call neither — no impact.

### New/Modified Contracts

```
src/
├── core/
│   ├── OwnVault.sol              -- EXISTING, venue-neutral seam added: setBorrowManager + grantCreditDelegation (onlyAdmin)
│   └── BorrowManager.sol         -- Stateful (Aave-funded): borrows via delegation, per-user lending, liquidation, self-contained debt cap
├── periphery/
│   ├── AaveRouter.sol            -- Stateless: wstETH → Aave deposit → awstETH → OwnVault
│   └── LoopRouter.sol            -- Stateless: batches N mint+borrow loops into single tx
├── interfaces/
│   ├── IBorrowManager.sol
│   ├── ILoopRouter.sol
│   └── IAaveV3Pool.sol           -- Minimal Aave V3 Pool interface
└── libraries/
    └── InterestRateModel.sol     -- Utilization-based rate curve
```

### AaveRouter (Periphery — Stateless)

Same pattern as existing WstETHRouter. Handles LP deposits/withdrawals with Aave wrapping.

```
Deposit:
  User sends wstETH → AaveRouter
    → Router calls pool.supply(wstETH, amount, onBehalfOf=vault)
    → awstETH minted directly to OwnVault
    → Router calls vault.deposit() → shares minted to user

Withdraw:
  User calls AaveRouter.withdraw(vault, shares)
    → Router calls vault.redeem(shares) → receives awstETH
    → Router calls pool.withdraw(wstETH, amount, receiver=user)
    → User receives wstETH
```

### BorrowManager (Core — Stateful)

Manages all borrowing/lending using delegated credit from OwnVault. One manager is bound 1:1 to a vault via the vault's one-shot `setBorrowManager`. It is self-contained — it owns the vault-wide debt cap, utilization tracking, and live Aave rate read directly.

**eToken borrowing (for all users — enables looping):**
- `borrow(asset, eTokenAmount, stablecoinAmount, priceData)`: user deposits eTokens as collateral → manager borrows from Aave via delegation → sends stablecoins to user
- `repay(asset, amount)`: user repays → manager repays Aave → eToken collateral released
- `liquidate(borrower, asset, priceData)`: external liquidator repays debt → receives eToken collateral + bonus

**Self-contained risk controls:**
- `targetLtvBps` / `setTargetLtvBps(ltvBps)`: admin-configured vault-wide LTV target
- `maxDebtUSD()`: `VaultManager.collateralMark(vault) * targetLtvBps / BPS` — hard cap enforced on every borrow (`BorrowExceedsCap` revert)
- `totalDebtUSD()`: aggregate outstanding debt across all borrowers
- `utilizationBps()`: `totalDebtUSD / maxDebtUSD` — drives the premium curve
- `baseRateBps()`: reads `pool.getReserveData(stablecoin).currentVariableBorrowRate` (RAY → BPS) as the floor

**State managed by the manager:**
- Per-(borrower, asset) Position: eToken collateral deposited, principal, and accrued interest
- Per-asset cumulative interest index for accrual
- Per-borrower health factor: based on eToken oracle price vs debt

**Aave interaction (all via delegated credit):**
- Borrows: `pool.borrow(usdc, amount, 2, 0, onBehalfOf=vault)` — debt on vault's position
- Repays: `pool.repay(usdc, amount, 2, onBehalfOf=vault)` — reduces vault's debt
- Reads: `pool.getReserveData(usdc)` — live borrow rate; `pool.getUserAccountData(vault)` — vault's Aave health factor

### LoopRouter (Periphery — Stateless)

Batches multiple borrow+mint loops into a single transaction for leveraged eToken exposure. Calls BorrowManager internally.

- `leverageMint(asset, amount, loops, maxPrice, expiry)`: executes N loops of mint+borrow
- `leverageUnwind(asset, loops)`: executes N loops of redeem+repay to close position
- `calculateMaxLoops(amount, ltv)`: returns max economical loops for given LTV
- `estimateExposure(amount, ltv, loops)`: preview total exposure for given parameters

Purely a UX convenience — users can manually loop by calling BorrowManager directly.

### InterestRateModel (Library)

Pure library implementing the two-slope rate curve:

- `calculateRate(utilization, aaveBorrowRate, params)`: returns current lending rate
- `params`: basePremium, optimalUtilization, slope1, slope2

---

## Implementation Phases

### Phase 1: OwnVault Change + AaveRouter
- Add the venue-neutral lending seam to OwnVault (`onlyAdmin`): `setBorrowManager(manager)` + `grantCreditDelegation(debtToken)`
- AaveRouter: stateless periphery for wstETH → Aave → awstETH → OwnVault deposits/withdrawals
- Deploy OwnVault with awstETH as collateral type
- Fork tests against Aave V3 on Base
- No borrowing yet — just yield-bearing collateral with Aave routing

### Phase 2: BorrowManager + eToken Borrowing + Liquidation
- Admin deploys the vault's BorrowManager directly and calls `vault.setBorrowManager(manager)` + `vault.grantCreditDelegation(debtToken)` to activate
- `borrow()`: any user deposits eTokens, borrows stablecoins via the manager's delegated credit
- Self-contained risk controls: `targetLtvBps` debt cap, `utilizationBps`, `baseRateBps`
- InterestRateModel with utilization-based premium
- Per-borrower health factor tracking using existing oracle infrastructure
- External liquidator/keeper flow with liquidation bonus
- eToken burn on liquidation → exposure reduction (self-healing)
- Unit + integration + invariant tests: Aave LTV, borrower health, vault solvency

### Phase 3: LoopRouter + Risk Controls
- LoopRouter periphery: batch N loops of mint+borrow in single tx (calls BorrowManager)
- Unwind helper: batch N loops of redeem+repay
- Concentration cap (max % of Aave pool)
- Automated deleveraging keeper (repay Aave when health factor drops)
- End-to-end flow tests (manual loop + router loop + unwind)
- Deployment scripts + ProtocolRegistry integration

---

## Key Invariants

These must hold at all times:

1. **Aave solvency**: `vault Aave LTV <= 35%` under normal conditions
2. **Aave safety**: `vault Aave health factor >= 1.5` (target; liquidation at 1.0)
3. **Own solvency**: `awstETH value >= eToken exposure * collateral ratio` (existing)
4. **Manager debt cap**: `totalDebtUSD() <= maxDebtUSD()` (= `VaultManager.collateralMark(vault) * targetLtvBps`)
5. **Borrower health**: `eTokenCollateralValue * liquidationThreshold >= debtValue` per borrower
6. **Accounting**: `Aave debt == sum(all eToken borrower debt)`
7. **Concentration**: `vault's Aave deposit <= 25% of total Aave wstETH pool on Base`

---

## Key Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| ETH crash → Aave liquidation | High | 35% LTV with 79.5% threshold = 56% buffer; automated deleveraging keeper |
| eToken borrowers default en masse | Medium | Liquidation bonus incentivizes external liquidators; self-healing via eToken burn |
| Aave wstETH pool illiquidity (100% utilization) | Medium | LP withdrawals can accept awstETH; concentration cap limits vault's pool share |
| Smart contract risk (Aave integration) | Medium | Fork tests against live Aave; use battle-tested Aave interfaces |
| Correlated stress (ETH crash + eToken crash) | High | Conservative parameters; steep rate curve forces deleveraging before crisis |
| Oracle manipulation on eToken prices | Medium | Existing oracle security (signed prices, staleness checks) applies unchanged |

---

## References

- Aave V3 Pool (Base): wstETH supply/borrow via `IPool.supply()`, `IPool.borrow()`
- Aave V3 wstETH risk parameters: LTV 68.5%, liquidation threshold 79.5%, liquidation bonus 7%
- wstETH (Base): `0xc1cba3fcea344f92d9239c08c0568f6f2f0ee452`
- awstETH (Base): `0x99cbc45ea5bb7ef3a5bc08fb1b7e56bb2442ef0d`
- Existing leverage design: `docs/leverage-design.md` (complementary — that doc covers leveraged eToken trading via credit delegation from external whales; this doc covers vault-level Aave integration for LP yield)

---

## Relationship to leverage-design.md

Both designs enable leveraged eToken exposure but via different mechanisms:

| Aspect | leverage-design.md | This design |
|--------|-------------------|-------------|
| **Borrowing source** | External ETH whales delegate Aave borrowing power | Vault's own Aave position (LP collateral) |
| **Who provides capital** | External whale depositors | LPs themselves (their wstETH) |
| **Leverage mechanism** | MarginAccount proxies, per-user smart wallets | User looping via LoopRouter (simpler) |
| **LP role** | Passive collateral provider | Passive collateral provider; earns the lending spread |
| **Max leverage** | 5-20x (configurable per asset) | ~3.3x theoretical (limited by 70% LTV per loop) |
| **Complexity** | 3 new contracts + margin accounts | 1 function on OwnVault + BorrowManager + routers |

These can coexist: the whale credit delegation (leverage-design.md) provides deep borrowing capacity for high-leverage traders, while this design lets eToken holders take leveraged RWA positions against the vault's own Aave borrowing power.
