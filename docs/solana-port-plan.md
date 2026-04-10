# Own Protocol v2 — Solana Port Plan

## Context

Own v2 is a permissionless RWA tokenization protocol currently deployed on Base (EVM) with ~4,877 lines of Solidity across 11 contracts. This document captures the full plan for rebuilding the protocol on Solana, including architecture translation, account design, timeline, and key challenges.

---

## Part 1: Solana Development Basics

### Programs vs Smart Contracts
- On EVM, a "contract" bundles **code + state** at one address. On Solana, **programs are stateless executables** — they contain only logic (compiled to BPF bytecode). All data lives in separate **accounts** that programs read/write.
- Think of it as: EVM contract = class with fields. Solana program = pure function that takes accounts as arguments.

### The Account Model
- Every piece of data is an **account** with: owner (program that can modify it), lamports (SOL balance for rent), data (arbitrary bytes), and a public key.
- Programs can only modify accounts they own. Users sign transactions to authorize changes to their accounts.
- Accounts must be **pre-allocated** with a fixed size and funded with enough SOL to be **rent-exempt** (~0.00089 SOL per byte per year, or ~2 years' rent upfront to be exempt forever).

### PDAs (Program Derived Addresses)
- Deterministic addresses derived from seeds + program ID. Example: `PDA = findProgramAddress(["vault", vault_id], program_id)`.
- PDAs have no private key — only the deriving program can sign for them. They replace `address(this)` and serve as program-controlled token accounts, escrow wallets, etc.
- Seeds are like mapping keys: `["order", order_id_bytes]` → unique PDA per order (like `mapping(uint256 => Order)`).

### SPL Token Standard
- Solana's equivalent of ERC-20. Two key accounts: **Mint** (supply, decimals, authority) and **Token Account** (holder's balance for a specific mint).
- Token-2022 (Token Extensions) adds features like: transfer hooks, transfer fees, metadata, confidential transfers.
- No `_update()` override like ERC-20 — transfers bypass your program unless you use Token-2022 Transfer Hooks.

### Anchor Framework
- The standard framework for Solana development (like Foundry/Hardhat for EVM). Provides:
  - Account validation via derive macros (`#[account]`, `#[derive(Accounts)]`)
  - Auto-generated IDL (like ABI) and TypeScript client
  - Built-in error handling, events, access control constraints
  - Test framework with `anchor test` (uses Mocha/TypeScript)
- Language: **Rust** (compiled to BPF). Anchor abstracts most of the boilerplate.

### CPI (Cross-Program Invocation)
- How programs call other programs (like Solidity's external calls). Example: your program calls SPL Token's `transfer` instruction.
- Max depth: 4 levels. Each CPI costs compute units.
- Relevant for: minting SPL tokens, transferring escrowed tokens, reading Pyth accounts.

### Key Constraints

| Constraint | Limit | EVM Equivalent |
|---|---|---|
| Transaction size | 1,232 bytes | No limit (gas-bounded) |
| Accounts per tx | ~35 max (each costs 32 bytes) | No limit |
| Compute units | 200K default, 1.4M max | ~30M gas |
| Account data size | 10 MB max | No limit |
| Integer types | u64 max (u128 via math) | uint256 native |
| Program size | 1.4 MB (10 MB with BPF loader v4) | 24.576 KB |

### Development Tools
- **Anchor CLI**: `anchor init`, `anchor build`, `anchor test`, `anchor deploy`
- **Solana CLI**: `solana-keygen`, `solana airdrop`, `solana program deploy`
- **solana-bankrun / anchor-bankrun**: Fast in-process test runtime (like Foundry's `forge test`)
- **@coral-xyz/anchor** (TypeScript): Auto-generated client from IDL
- **Explorer**: Solana Explorer, SolanaFM, Solscan

---

## Part 2: Vault Strategy — Build Custom, Borrow Patterns

### Research Finding: No Reusable Vault Standard on Solana

Unlike EVM's ERC-4626, **Solana has no standard vault program**. The SPL provides Token, Token-2022, Stake Pool, but no vault primitive. After researching Drift Vaults, Marinade, Kamino, Voltr, SPL Stake Pool, Token-2022, and Squads — none can be composed to meet Own's requirements (async VM-approved deposits, FIFO withdrawal queues, per-asset exposure tracking, rewards-per-share, pause/halt).

### Recommendation: Custom Anchor Vault + Borrowed Patterns

Build a custom vault program in Anchor, borrowing proven patterns:

| Pattern | Source | What to Borrow |
|---|---|---|
| Share accounting | **Drift Vaults** | `total_shares = user + manager + protocol`, VaultDepositor PDA per LP, two-phase withdraw with `redeem_period` |
| Withdrawal queue | **Marinade** | Individual **Ticket-Account PDAs** per withdrawal request (not vectors in one account). This is the "Solana way" for queues |
| LP share tokens | **SPL Stake Pool** | Mint real Token-2022 SPL tokens for vault shares — composable, tradeable, usable as collateral elsewhere |
| Share transfer hooks | **Token-2022** | Transfer hooks on share tokens for rewards settlement or compliance checks |
| Admin authority | **Squads V4** | Multisig with timelock for pause/halt/config changes (use as external admin, not embedded) |
| Vault reference | **Solana ERC-4626 guide** | ~90-line reference impl of deposit/mint/withdraw/redeem share math at solana.com/developers/evm-to-svm/erc4626 |

### What's Fully Custom (No Reference Exists)
- **Async deposit approval** (VM must accept/reject LP deposits) — fully custom
- **Per-asset USD exposure tracking** with health factor — fully custom
- **Rewards-per-share fee distribution** to LPs — custom (Drift has management fees but not the same accumulator pattern)
- **Pause/halt with price enforcement** — custom vault state flags

### Solana-Specific Vault Design Decisions
1. **Individual PDAs** for each withdrawal ticket and deposit request (not arrays in a single account) — avoids size limits, enables parallel processing
2. **Token-2022 SPL tokens** for vault shares — real transferable tokens, composable with DeFi
3. **Zero-copy deserialization** (`#[account(zero_copy)]`) for large VaultState accounts
4. **Compute budget awareness** — health factor calculations across multiple assets may need `setComputeUnitLimit` increases

---

## Part 3: Architecture Translation

### How Each EVM Pattern Maps to Solana

| EVM (Current) | Solana (Target) | Notes |
|---|---|---|
| ERC-4626 vault (OwnVault) | Custom vault program with LP Token Mint + VaultState PDA | No ERC-4626 standard on Solana; implement share math manually |
| ERC-20 (EToken) | SPL Token-2022 mint with program PDA as mint authority | Use Token-2022 for transfer hook (needed for rewards accumulator) |
| `mapping(uint256 => Order)` | Individual Order PDA accounts per order | Seeds: `["order", order_id.to_le_bytes()]` |
| `uint256[] _openOrders` | Off-chain indexing via `getProgramAccounts` + memcmp filters | No on-chain iteration; client queries by account data filters |
| `_rewardsPerShare` accumulator | Same math, separate PDA per (vault/token, user) for checkpoints | LPRewardAccount and ETokenRewardAccount PDAs |
| EToken `_update()` hook | Token-2022 Transfer Hook | Fires on every transfer; settles pending rewards |
| `ReentrancyGuard` | Not needed | Solana runtime is single-threaded per transaction |
| `nonReentrant` modifier | Not needed | No reentrancy possible |
| ECDSA signature verification | Ed25519 precompile instruction | Solana uses Ed25519, not secp256k1 |
| Pyth wrapper contract | Direct Pyth account reads | Pyth is native on Solana — simpler than EVM |
| `Ownable` / `onlyAdmin` | `has_one = admin` Anchor constraint + signer check | Admin pubkey stored in config account |
| `msg.sender` | Transaction signer | `ctx.accounts.user.key()` |
| `block.timestamp` | `Clock::get()?.unix_timestamp` | Sysvar, no block.timestamp equivalent |
| `safeTransferFrom` | SPL Token `transfer_checked` CPI | Requires explicit token account references |
| Multicall | Solana transactions are natively multi-instruction | No need for a Multicall wrapper |

### Decimal Precision — Critical Change
- Solana token amounts are `u64` (max ~18.4 × 10^18). With 18 decimals, you can only represent ~18.4 tokens.
- **Use 6 decimals for eTokens** (matching USDC). All intermediate price math uses `u128`.
- Prices remain 18-decimal internally, but token amounts are 6-decimal.

### What Gets Simpler on Solana
1. **Pyth oracle** — native on Solana. No wrapper contract needed. Just read the Pyth price account directly.
2. **No reentrancy guards** — Solana's runtime prevents reentrancy by design.
3. **Multicall** — Solana transactions natively support multiple instructions.
4. **WETH Router** — unnecessary. SOL is native; wrapped SOL (wSOL) is an SPL token.

### What Gets Harder on Solana
1. **No dynamic arrays** — can't store unbounded lists in accounts. Use individual PDAs + off-chain indexing.
2. **Transaction size limit** — forceExecute touches ~17-20 accounts, approaching the limit. Need Address Lookup Tables (ALTs).
3. **No ERC-4626** — must implement share accounting from scratch.
4. **Transfer hook for rewards** — Token-2022 transfer hooks are newer and have composability caveats.
5. **No `uint256`** — all math in u64/u128. Must be careful about overflow in fee/price calculations.

---

## Part 4: Account Architecture

### Account Types & PDA Seeds

```
1. ProtocolConfig (singleton)
   Seeds: ["protocol_config"]
   Size: ~320 bytes
   Fields: admin, market_program, vault_factory, asset_registry, fee_calculator,
           oracle_verifier, pyth_oracle, protocol_share_bps, timelock_delay,
           pending_updates[], bump

2. AssetConfig (per asset)
   Seeds: ["asset", asset_ticker_bytes]  // e.g., ["asset", "TSLA"]
   Size: ~200 bytes
   Fields: ticker (32 bytes), active_token_mint, legacy_tokens[], active,
           volatility_level, oracle_type, bump

3. FeeConfig (singleton)
   Seeds: ["fee_config"]
   Size: ~100 bytes
   Fields: mint_fees[3], redeem_fees[3], admin, bump

4. VaultState (per vault)
   Seeds: ["vault", vault_id.to_le_bytes()]
   Size: ~500 bytes
   Fields: vault_id, vm (pubkey), lp_token_mint, collateral_mint,
           payment_token_mint, status (Active/Paused/Halted),
           max_utilization, withdrawal_wait_period, grace_period,
           claim_threshold, vm_share_bps, total_exposure_usd,
           collateral_value_usd, rewards_per_share,
           protocol_fees, vm_fees, next_deposit_id, next_withdrawal_id,
           next_order_id_offset, pending_deposit_assets,
           pending_withdrawal_shares, require_deposit_approval,
           collateral_oracle_asset, bump

5. VaultAssetExposure (per vault × asset)
   Seeds: ["exposure", vault_pubkey, asset_ticker_bytes]
   Size: ~100 bytes
   Fields: asset_ticker, exposure_raw, exposure_usd, last_updated, bump

6. VaultAssetStatus (per vault × asset)
   Seeds: ["vault_asset", vault_pubkey, asset_ticker_bytes]
   Size: ~80 bytes
   Fields: supported, paused, halted, halt_price, bump

7. Order (per order)
   Seeds: ["order", order_id.to_le_bytes()]
   Size: ~250 bytes
   Fields: order_id, user, order_type, asset_ticker, amount, price,
           expiry, status, created_at, vm, vault, claimed_at,
           escrowed_fee, bump
   Rent: ~0.003 SOL (recoverable when order closes)

8. DepositRequest (per request)
   Seeds: ["deposit_req", vault_pubkey, request_id.to_le_bytes()]
   Size: ~120 bytes
   Fields: request_id, depositor, receiver, assets, timestamp, status, bump

9. WithdrawalRequest (per request)
   Seeds: ["withdrawal_req", vault_pubkey, request_id.to_le_bytes()]
   Size: ~120 bytes
   Fields: request_id, owner, shares, timestamp, status, bump

10. LPRewardAccount (per vault × LP)
    Seeds: ["lp_reward", vault_pubkey, user_pubkey]
    Size: ~80 bytes
    Fields: checkpoint (u128), accrued_fees (u64), bump

11. ETokenRewardAccount (per eToken × holder)
    Seeds: ["etoken_reward", etoken_mint_pubkey, user_pubkey]
    Size: ~80 bytes
    Fields: rewards_per_share_paid (u128), pending_rewards (u64), bump

12. MarketEscrow (token accounts per mint)
    Seeds: ["escrow", mint_pubkey]
    Type: SPL Token Account (PDA-owned)
    Purpose: holds escrowed stablecoins and eTokens for orders

13. VaultCollateralAccount
    Seeds: ["vault_collateral", vault_pubkey]
    Type: SPL Token Account
    Purpose: holds vault collateral (USDC, wSOL)

14. VaultPaymentAccount
    Seeds: ["vault_payment", vault_pubkey]
    Type: SPL Token Account
    Purpose: holds payment token for fee settlement
```

### Indexing Strategy (Replaces On-Chain Arrays)
- **Orders by user**: `getProgramAccounts` with memcmp filter on `user` field at known offset
- **Orders by asset**: Filter on `asset_ticker` field
- **Orders by status**: Filter on `status` field
- **Open orders for a vault**: Filter on `vault` + `status == Open`
- **Pending deposits/withdrawals**: Filter on vault + status

This is equivalent to the current `_userOrders`, `_openOrders`, `_pendingRequestIds` arrays but queried off-chain.

---

## Part 5: Program Structure

### Recommendation: Single Anchor Program

The 4,877 LOC of Solidity translates to ~8,000-12,000 lines of Rust (Anchor adds verbosity for account structs). This fits comfortably in one program (<1.4MB compiled).

Multiple programs would require CPI for every cross-module call (vault ↔ market), adding complexity and compute cost. One program keeps it simple.

### Directory Structure

```
own-v2-solana/
├── programs/
│   └── own-protocol/
│       └── src/
│           ├── lib.rs                    # Program entrypoint, declare_id!
│           ├── state/                    # Account definitions
│           │   ├── mod.rs
│           │   ├── protocol_config.rs
│           │   ├── vault.rs              # VaultState, VaultAssetExposure, VaultAssetStatus
│           │   ├── market.rs             # Order
│           │   ├── asset.rs              # AssetConfig, FeeConfig
│           │   ├── oracle.rs             # OracleConfig
│           │   ├── deposit.rs            # DepositRequest
│           │   ├── withdrawal.rs         # WithdrawalRequest
│           │   └── rewards.rs            # LPRewardAccount, ETokenRewardAccount
│           ├── instructions/             # Instruction handlers
│           │   ├── mod.rs
│           │   ├── admin/                # initialize, set_address, propose_timelock, execute_timelock
│           │   ├── asset/                # add_asset, update_asset_config, deactivate_asset
│           │   ├── vault/                # create_vault, deposit, request_deposit, accept_deposit,
│           │   │                         # request_withdrawal, fulfill_withdrawal, update_exposure,
│           │   │                         # deposit_fees, claim_lp_rewards, pause, halt, set_vm
│           │   ├── market/               # place_mint_order, place_redeem_order, claim_order,
│           │   │                         # confirm_order, cancel_order, expire_order,
│           │   │                         # force_execute, close_order
│           │   ├── oracle/               # update_price, set_signer, set_oracle_config
│           │   └── token/                # (transfer hook handler if using Token-2022)
│           ├── errors.rs                 # Custom error codes
│           ├── events.rs                 # Anchor events (emit!)
│           └── utils/                    # Math helpers, price normalization, fee calculation
│               ├── mod.rs
│               ├── math.rs              # mulDiv equivalent, safe u128 math
│               ├── fees.rs              # Fee calculation logic
│               └── oracle.rs            # Price verification helpers
├── tests/                               # TypeScript integration tests
│   ├── unit/
│   ├── integration/
│   └── helpers/
├── app/                                 # TypeScript client SDK & CLI
│   ├── src/
│   │   ├── client.ts                    # Generated from IDL
│   │   ├── actions/                     # Port of ts-scripts/src/actions/
│   │   └── pyth.ts
│   └── package.json
├── Anchor.toml
├── Cargo.toml
└── README.md
```

### Instruction Design (Key Instructions)

**Market Instructions:**
```
place_mint_order(asset, amount, price, expiry, vault) → creates Order PDA + escrows stablecoins
place_redeem_order(asset, amount, price, expiry, vault) → creates Order PDA + escrows eTokens
claim_order(order_id) → VM claims, transfers net stablecoins to VM, escrows fee
confirm_order(order_id, price_data) → VM confirms, mints/burns eTokens, distributes fees
cancel_order(order_id) → user cancels unclaimed order, refunds escrow
force_execute(order_id, asset_price_data, collateral_price_data) → fallback execution
expire_order(order_id) → anyone can expire past-expiry orders
close_order(order_id) → close and reclaim rent
```

**Vault Instructions:**
```
create_vault(collateral_mint, payment_token, vm, config) → creates VaultState + LP mint + token accounts
deposit(amount) → direct LP deposit (if no approval required)
request_deposit(amount, receiver) → creates DepositRequest PDA
accept_deposit(request_id) → VM accepts, mints LP shares
reject_deposit(request_id) → VM rejects, refunds
request_withdrawal(shares) → creates WithdrawalRequest PDA, escrows shares
fulfill_withdrawal(request_id) → settles after wait period
update_exposure(asset, exposure, price) → updates per-asset USD exposure
update_collateral_value(price) → updates collateral USD value
deposit_fees(amount, protocol_share, vm_share) → distributes fees to vault
claim_lp_rewards() → LP claims accrued fee rewards
```

---

## Part 6: Repo Decision

### Recommendation: **Separate Repository** (`own-v2-solana`)

**Why separate:**
- Anchor and Foundry have completely incompatible project structures (Cargo.toml vs foundry.toml, programs/ vs src/, tests/ in TS vs tests/ in Solidity)
- Independent CI/CD pipelines (Anchor build/test vs Forge build/test)
- Different deployment tooling (Solana CLI vs Forge scripts)
- Cleaner git history for each chain
- Teams can work independently without merge conflicts

**What to share:**
- Copy `docs/protocol.md` as the behavioral specification
- Reference the EVM repo in README for canonical business logic
- Share TypeScript types/interfaces if building a unified frontend

**Monorepo only makes sense if** you plan a unified frontend or shared off-chain infrastructure. Even then, use workspaces (pnpm/yarn) with the Solana program as a separate workspace.

---

## Part 7: Complexity & Time Estimates

### Per-Component Breakdown

| Component | EVM LOC | Solana Effort | Difficulty | Est. Time |
|---|---|---|---|---|
| **ProtocolConfig + Timelock** | 175 | Easy | Low | 2-3 days |
| **AssetRegistry** | 144 | Easy | Low | 2-3 days |
| **FeeCalculator** | 114 | Easy | Low | 1-2 days |
| **VaultFactory** (create_vault) | 62 | Easy | Low | 1-2 days |
| **ETokenFactory** (init_mint) | 32 | Easy | Low | 1 day |
| **PythOracleVerifier** | 212 | Simpler on Solana | Low | 3-4 days |
| **OracleVerifier (in-house)** | 192 | Medium (Ed25519) | Medium | 4-5 days |
| **EToken + rewards** | 237 | Hard (Token-2022 hook) | High | 2-3 weeks |
| **OwnVault** | 1,090 | Hardest (full redesign) | Very High | 4-5 weeks |
| **OwnMarket** | 763 | Hard (state machine + escrow) | High | 3-4 weeks |
| **Routers** | 190 | Minimal (wSOL only) | Low | 2-3 days |
| **Testing** | 9,000+ | Full rewrite in TS | High | 3-4 weeks |
| **TypeScript SDK/CLI** | ~2,000 | Port to Anchor client | Medium | 1-2 weeks |
| **Deployment + devnet** | — | New scripts | Medium | 1 week |

### Phased Timeline (1-2 developers, new to Solana)

**Phase 0: Learning & Setup (2-3 weeks)**
- Complete Solana/Anchor tutorials (Solana Cookbook, Anchor Book)
- Build a toy SPL token program
- Set up repo, CI, local validator
- Deliverable: working Anchor project with a simple "hello world" program

**Phase 1: Core Infrastructure (3-4 weeks)**
- ProtocolConfig, AssetRegistry, FeeCalculator
- Vault creation (VaultState, LP mint, token accounts)
- Pyth oracle integration (read price accounts)
- In-house oracle (Ed25519 verification)
- Deliverable: can create vaults and read oracle prices

**Phase 2: Vault Logic (4-5 weeks)**
- Direct deposit/withdrawal
- Async deposit queue (request → accept/reject)
- Async withdrawal queue (request → fulfill)
- Share accounting (deposit/withdraw math)
- Exposure tracking and utilization
- LP rewards accumulator
- Pause/halt mechanics
- Deliverable: fully functional vault with LP operations

**Phase 3: Market & Orders (4-5 weeks)**
- Place mint/redeem orders with escrow
- Claim order (VM claims, receives stablecoins)
- Confirm order (price verification, eToken mint/burn, fee distribution)
- Cancel, expire, close orders
- Force execution with dual oracle proofs
- Address Lookup Tables for complex instructions
- Deliverable: full order lifecycle working

**Phase 4: EToken & Rewards (2-3 weeks)**
- SPL Token-2022 mint with transfer hook
- Transfer hook program for rewards settlement
- EToken rewards accumulator
- Dividend distribution
- Deliverable: eTokens with automatic reward tracking

**Phase 5: Integration Testing & Hardening (3-4 weeks)**
- Full lifecycle tests (mint → redeem cycle)
- Edge cases (halt with prices, force execution, utilization limits)
- Fuzz testing with Trident
- Invariant tests (port from EVM)
- Security review
- Deliverable: production-ready test suite

**Phase 6: Devnet Deployment & CLI (2 weeks)**
- Deploy to Solana devnet
- Port TypeScript CLI
- End-to-end testing on devnet
- Documentation
- Deliverable: live devnet deployment

### Total Estimate: **18-24 weeks (4.5-6 months)**

For experienced Solana developers: **12-16 weeks (3-4 months)**.

---

## Part 8: Testing Strategy

### Framework
- **anchor-bankrun** — fast in-process tests (no validator startup). Use for unit and integration tests.
- **anchor test** — runs local validator, slower but more realistic. Use for final integration.
- **Trident** (by Ackee Blockchain) — fuzz testing framework for Anchor programs. Port invariant tests here.

### Test Structure (Mirrors EVM)

```
tests/
├── unit/
│   ├── protocolConfig.test.ts     ← ProtocolRegistry.t.sol
│   ├── assetRegistry.test.ts      ← AssetRegistry.t.sol
│   ├── feeCalculator.test.ts      ← FeeCalculator.t.sol
│   ├── vault.test.ts              ← OwnVault.t.sol
│   ├── market.test.ts             ← OwnMarket.t.sol
│   ├── etoken.test.ts             ← EToken.t.sol
│   ├── oracleVerifier.test.ts     ← OracleVerifier.t.sol
│   └── pythOracle.test.ts         ← PythOracleVerifier.t.sol
├── integration/
│   ├── mintFlow.test.ts           ← MintFlow.t.sol
│   ├── redeemFlow.test.ts         ← RedeemFlow.t.sol
│   ├── orderLifecycle.test.ts     ← OrderLifecycle.t.sol
│   ├── lpLifecycle.test.ts        ← LPLifecycle.t.sol
│   ├── asyncDeposit.test.ts       ← AsyncDepositFlow.t.sol
│   ├── haltFlow.test.ts           ← HaltFlow.t.sol
│   ├── pauseFlow.test.ts          ← PauseFlow.t.sol
│   ├── utilizationLimit.test.ts   ← UtilizationLimit.t.sol
│   ├── forceExecution.test.ts     ← HaltWithPriceFlow.t.sol
│   └── dividendFlow.test.ts       ← DividendFlow.t.sol
└── invariant/
    └── protocol.fuzz.ts           ← OwnProtocolInvariant.t.sol
```

### Key Invariants to Port
1. `totalETokenSupply * price <= totalCollateral * ratio` (solvency)
2. `sum(LP shares) == vault.totalSupply` (share accounting)
3. `sum(eToken balances) == eToken.totalSupply` (token accounting)
4. `VM exposure <= maxExposure` (exposure caps)
5. `healthFactor >= 1.0 OR vault.status == Halted` (health)
6. `escrowed amounts == sum(open order amounts)` (escrow integrity)
7. `rewardsPerShare only increases` (monotonic rewards)

---

## Part 9: Key Challenges & Risks

### 1. Transaction Size Limit (HIGH RISK)
- `forceExecute` requires: Order PDA, VaultState, 2x Oracle accounts, Pyth price accounts (2), escrow token accounts, user token accounts, eToken mint, fee destination accounts, SPL Token program, system program = ~17-20 accounts
- **Mitigation**: Address Lookup Tables (ALTs). Create ALTs for common accounts (protocol config, program IDs, oracle accounts). Reduces per-account cost from 32 bytes to 1 byte for accounts in the table.

### 2. No Dynamic Arrays (HIGH RISK)
- EVM stores arrays of order IDs, deposit request IDs, withdrawal request IDs in contract storage
- **Mitigation**: Each becomes an individual PDA. Client uses `getProgramAccounts` with memcmp filters. More expensive to query but standard Solana pattern.

### 3. Decimal Precision (HIGH RISK)
- `uint256` doesn't exist. Token amounts are `u64`. Prices are `u128` internally.
- **Mitigation**: Use 6 decimals for all tokens (matching USDC). Use `u128` for all intermediate price/fee math. Implement `checked_mul_div` helper (equivalent to OZ `Math.mulDiv`).

### 4. Collateral Types (MEDIUM RISK)
- No aUSDC or wstETH equivalents on Solana
- **Mitigation**: Launch with USDC + wSOL (native wrapped SOL). Add yield-bearing collateral later (e.g., Marinade stSOL, JitoSOL). Vault architecture supports any SPL token mint.

### 5. Compute Units (MEDIUM RISK)
- `u128` multiplication/division is more expensive than EVM's native uint256
- Complex instructions (confirmOrder, forceExecute) may approach 200K CU default
- **Mitigation**: Request higher CU budget in transactions (`setComputeUnitLimit`). Most instructions will fit in 400K CU.

### 6. Token-2022 Transfer Hook Composability (MEDIUM RISK)
- Not all DEXes and protocols support Token-2022 tokens
- Transfer hooks add gas cost to every transfer
- **Mitigation**: Evaluate if eToken rewards can use a simpler claim-based model (user must call `settle_rewards` before/after transfer). This avoids Token-2022 dependency entirely but adds UX friction.

### 7. Clock Drift (LOW RISK)
- Solana's `Clock::get()?.unix_timestamp` can drift ~1-2 seconds from real time
- **Mitigation**: Use generous staleness windows for oracle prices (already 120s in EVM version).

---

## Verification Plan

1. **Build & deploy** to Solana devnet
2. **Run full lifecycle test**: LP deposit → place mint order → VM claim → VM confirm → place redeem → VM claim → VM confirm → LP withdraw
3. **Test force execution** with Pyth price proofs
4. **Test halt/pause** mechanics with price enforcement
5. **Run invariant tests** via Trident fuzzer
6. **Compare outputs**: for identical inputs, Solana program should produce same token amounts, fees, and state transitions as the EVM contracts
7. **Gas/CU profiling**: ensure all instructions fit within compute budgets
