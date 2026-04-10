# Leverage Buy System for Own Protocol v2

## Context

Add leveraged buying (long only) on top of existing eTokens via OwnMarket. An ETH whale delegates Aave V3 borrowing power, the protocol borrows USDC to amplify user buys, and users pay a fixed daily funding rate. No short selling — simpler, and shorts have limited upside anyway.

**Core idea**: This is margin lending on eTokens. User puts up margin, protocol borrows the rest from Aave, mints eTokens through the existing OwnMarket flow. eTokens are held in a per-user smart wallet for liquidation control.

---

## Architecture: 3 New Contracts, Zero Changes to Existing

```
src/leverage/
├── interfaces/
│   ├── ILeverageManager.sol
│   ├── IMarginAccount.sol
│   └── IAaveCreditFacility.sol
├── types/
│   └── LeverageTypes.sol
└── core/
    ├── LeverageManager.sol       -- Orchestrator: open/close/liquidate positions
    ├── MarginAccount.sol         -- Per-user smart wallet (ERC-1167 clone)
    └── AaveCreditFacility.sol    -- Aave V3 credit delegation wrapper
```

### Key Insight: MarginAccount as User Proxy

Each user gets a **MarginAccount** (minimal clone proxy) that acts as the "user" from OwnMarket's perspective. It holds USDC margin + resulting eTokens, and exposes `execute(target, data)` callable only by LeverageManager. This means:

- OwnMarket sees MarginAccount as a normal user — **zero OwnMarket changes**
- Protocol retains eToken custody for liquidation
- Standard unleveraged users are unaffected

---

## Position Lifecycle (Two-Phase, Matching Async OwnMarket)

### Opening a 5x Long TSLA with $1000 Margin

**Phase 1 — Place Order**:
1. User calls `LeverageManager.openPosition("TSLA", vault, 1000 USDC, 5x, maxPrice, expiry)`
2. LeverageManager validates leverage (5x <= maxLeverage for TSLA)
3. `AaveCreditFacility.borrow(4000 USDC)` → USDC sent to user's MarginAccount
4. MarginAccount now holds $5000 USDC (1000 margin + 4000 borrowed)
5. LeverageManager calls `MarginAccount.execute()` → `OwnMarket.placeMintOrder(vault, "TSLA", 5000 USDC, maxPrice, expiry)`
6. Position status: **PendingMint**

**Phase 2 — Confirm** (after VM claims and confirms the order):
7. Keeper/user calls `LeverageManager.confirmOpen(positionId)`
8. LeverageManager reads order status from OwnMarket (must be Confirmed)
9. Records eToken amount received, entry price
10. Position status: **Open**

### Closing a Position

**Phase 1 — Place Redeem Order**:
1. User calls `LeverageManager.closePosition(positionId)`
2. LeverageManager calls `MarginAccount.execute()` → `OwnMarket.placeRedeemOrder(vault, "TSLA", eTokenAmount, minPrice, expiry)`
3. Position status: **PendingRedeem**

**Phase 2 — Settle**:
4. After VM confirms, keeper/user calls `LeverageManager.confirmClose(positionId)`
5. USDC received in MarginAccount
6. `AaveCreditFacility.repay(4000 + accruedFunding)` — repay borrowed amount + funding
7. Remaining USDC credited to user (withdrawable from MarginAccount)
8. Position status: **Closed**

### Liquidation

1. Anyone calls `LeverageManager.liquidate(positionId)`
2. Check: `(eTokenValue - borrowedAmount - accruedFunding) / eTokenValue < maintenanceMarginBps`
3. LeverageManager force-redeems via MarginAccount → OwnMarket.placeRedeemOrder()
4. After VM confirms (or forceExecute if VM is slow):
   - Repay Aave debt
   - Pay liquidator bonus from remaining margin
   - Surplus → insurance reserve in LeverageManager
   - Deficit → covered by insurance reserve

**Async liquidation safety**: Conservative maintenance margin (10% for volatile, 5% for low-vol) absorbs price movement during the async redeem window. `forceExecute()` is the backstop if VM doesn't process promptly.

---

## Fixed Funding Rate

```
fixedDailyRate = (aaveBorrowAPR / 365) + (whalePremiumAPR / 365) + (protocolSpreadAPR / 365)
Example: (8% / 365) + (3% / 365) + (2% / 365) = ~0.0356% per day on borrowed amount
```

### Rate Components

| Component | Example | Recipient | Description |
|-----------|---------|-----------|-------------|
| Aave borrow rate | 8% APR | Aave (on repay) | Real cost of borrowing USDC against whale's ETH |
| Whale premium | 3% APR | ETH whale | Extra incentive for delegating borrowing power |
| Protocol spread | 2% APR | Protocol treasury | Protocol revenue |
| **Total user rate** | **13% APR** | | What the user sees and pays |

- Accrues per-second using a cumulative accumulator (same pattern as EToken's `_rewardsPerShare`)
- Settled when position closes or is liquidated — deducted from USDC proceeds
- Rate updated daily by admin/keeper to track Aave borrow cost (whale premium and protocol spread can be updated independently)
- Users see the combined fixed rate upfront before opening position

### Funding Distribution
- User pays: `borrowedAmount * fixedDailyRate * daysElapsed`
- Aave gets: actual borrow interest (paid automatically on repay)
- Whales get: **two income streams**:
  1. **Aave supply APY** on their deposited ETH (automatic via aWETH, protocol doesn't touch this)
  2. **Whale premium** — paid by protocol from funding rate collections, distributed pro-rata to delegation share via `AaveCreditFacility.claimPremium()`
- Protocol keeps: protocol spread portion

---

## Credit Delegation (Aave V3)

### Whale Onboarding
1. Whale deposits ETH into Aave V3 (receives aWETH, earns supply APY)
2. Whale calls `aaveVariableDebtUSDC.approveDelegation(AaveCreditFacility, amount)`
3. AaveCreditFacility records whale's delegation capacity

### Multi-Whale Pooling
- Multiple whales can delegate to the same AaveCreditFacility
- Borrows drawn from whales proportionally (or round-robin)
- Max 80% utilization of total delegation to protect whales
- AaveCreditFacility monitors aggregate whale health factor

### Whale Premium Distribution
- As funding payments are collected from users, the whale premium portion accumulates in AaveCreditFacility
- Each whale's share is tracked pro-rata to their delegation amount
- Whales call `AaveCreditFacility.claimPremium()` to withdraw earned premium (USDC)
- Premium accrues only on utilized delegation (not idle capacity)

---

## Risk Parameters

| Parameter | TSLA (volatile) | GOLD (low-vol) | TLT (low-vol) |
|-----------|-----------------|----------------|----------------|
| Max leverage | 5x | 20x | 20x |
| Initial margin | 20% | 5% | 5% |
| Maintenance margin | 10% | 5% | 3% |
| Liquidation bonus | 2% | 1% | 1% |
| Max total OI | $5M | $25M | $25M |

---

## UX Flow

### Trader
1. User deposits USDC into their MarginAccount (auto-created on first use via clone)
2. Selects asset, leverage (slider 1x-5x or 1x-20x depending on asset), amount
3. UI shows: total position size, liquidation price, daily funding rate, estimated cost
4. Confirms → `openPosition()` tx — order placed on OwnMarket
5. VM processes order (same speed as normal mint) → position goes Open
6. Dashboard shows: live P&L, margin health, funding accrued, eToken balance in MarginAccount
7. Close position → redeem order placed → VM processes → user gets USDC minus debt and funding

### ETH Whale (Capital Provider)
1. Deposit ETH into Aave V3 + delegate borrowing power to AaveCreditFacility (2 txs)
2. Dashboard: delegation utilization, yield earned (Aave supply APY + protocol yield share)
3. Adjust delegation up/down as desired

---

## Implementation Phases

### Phase 1: Core (LeverageTypes + MarginAccount + LeverageManager)
- Position struct, leverage configs
- MarginAccount clone factory with execute() proxy
- LeverageManager: openPosition, confirmOpen, closePosition, confirmClose
- Use a simple USDC pool (not Aave) for initial testing
- Unit + integration tests

### Phase 2: Credit Delegation (AaveCreditFacility)
- Aave V3 borrow/repay wrapper
- Whale delegation tracking
- Fork tests against Aave V3 on Base

### Phase 3: Funding + Liquidation
- Cumulative funding rate accumulator
- Liquidation logic with async redeem + forceExecute fallback
- Insurance reserve
- Invariant tests

### Phase 4: Integration
- End-to-end tests with full flow (deposit → open → fund → close)
- Gas optimization
- Deployment script + ProtocolRegistry registration

---

## Key Files to Reference During Implementation

| File | Why |
|------|-----|
| `src/core/OwnMarket.sol` | placeMintOrder/placeRedeemOrder/forceExecute signatures, escrow behavior |
| `src/interfaces/IOwnMarket.sol` | Interface for MarginAccount.execute() calls |
| `src/interfaces/types/Types.sol` | Order struct, OrderStatus enum, BPS/PRECISION constants |
| `src/core/OwnVault.sol` | Exposure tracking, utilization checks, paymentToken() |
| `src/core/OracleVerifier.sol` / `PythOracleVerifier.sol` | getPrice() for health ratio calculation |
| `src/tokens/EToken.sol` | Confirm minting is restricted to OwnMarket (onlyOrderSystem) |
| `src/core/AssetRegistry.sol` | Asset configs, volatility levels for leverage tier mapping |
