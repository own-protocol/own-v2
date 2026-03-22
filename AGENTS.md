# Own Protocol v2 — Development Configuration

## Project Overview

Own Protocol is a permissionless protocol for fully collateralised tokenized real-world asset (RWA) exposure onchain. Users mint composable ERC20 eTokens (eTSLA, eGOLD, eTLT) by depositing collateral. The protocol supports multiple collateral types (USDC, aUSDC, ETH, stETH), each with its own public vault. Multiple LPs deposit into vaults and receive ERC-4626 shares representing their proportional ownership. Vault managers handle offchain hedging for their delegated LPs. Built on Base (Ethereum L2) with Foundry.

This is a production DeFi protocol that will hold millions of dollars. Every line of code must be written with that assumption.

## Quick Reference

```bash
# Build
forge build

# Test (run BEFORE and AFTER every code change)
forge test -vvv

# Test single file
forge test --match-path test/unit/OwnVault.t.sol -vvv

# Test single function
forge test --match-test testMintDuringMarketHours -vvv

# Fuzz tests (increase runs for pre-audit)
forge test --fuzz-runs 10000

# Invariant tests
forge test --match-path test/invariant/ -vvv

# Gas snapshot
forge snapshot

# Gas comparison against last snapshot
forge snapshot --diff

# Coverage
forge coverage --report lcov

# Format
forge fmt

# Slither static analysis
slither src/ --config-file slither.config.json

# Deploy (testnet)
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
```

## Architecture

See `docs/Own_Protocol_Vision.md` for full product vision and `docs/Own_Protocol_MVP_PRD.md` for MVP spec.

### High-Level Architecture

The protocol is organised around per-collateral-type vaults, each serving multiple LPs and supporting multiple vault managers. Specific contract files and structure will be defined as implementation progresses. The key architectural components are:

**One vault per collateral type:**
- USDC vault — accepts USDC deposits
- aUSDC vault — accepts aUSDC deposits (yield-bearing; ERC-4626 share price naturally appreciates as aUSDC accrues interest)
- ETH vault — accepts ETH deposits
- stETH vault — uses wstETH internally (wraps stETH on deposit, unwraps on withdrawal) to avoid rebasing transfer rounding issues. ERC-4626 share price naturally appreciates as stETH accrues staking yield.

**Public vaults with multiple LPs:**
- All vaults are public. Any LP can deposit collateral into any vault.
- ERC-4626 is used for LP share accounting. LPs receive vault shares proportional to their deposit. Share price increases as yield accrues (for aUSDC, stETH vaults) and as spread revenue is distributed.

**Vault managers (multiple per vault):**
- Multiple vault managers can register with each vault.
- LPs delegate to a chosen vault manager via mutual agreement: the LP sets their preferred manager, and the manager accepts the delegation.
- LPs can also be their own vault manager (self-delegation).
- Vault managers handle offchain hedging for their delegated LPs. There is no onchain hedging mechanism.
- Each vault manager can opt in/out of non-market-hour execution and set their own custom spread for off-hours.

**eTokens:**
- Each vault supports minting/redeeming a set of whitelisted assets (eTSLA, eGOLD, etc.).
- eTokens are standard ERC20 + ERC-2612 (Permit).

**Oracle:**
- Signed oracle price feeds verified onchain (ECDSA). MVP uses a single protocol-operated signer.

```
test/
├── unit/                    # Isolated contract tests (mocked dependencies)
├── integration/             # Multi-contract flow tests (real dependencies)
├── invariant/               # Stateful fuzz tests (protocol invariants)
├── fork/                    # Base mainnet fork tests (real DEX, real tokens)
└── helpers/                 # Shared test utilities, mocks, base contracts

script/
├── Deploy.s.sol             # Deployment script
└── AddAsset.s.sol           # Asset whitelisting script
```

## Development Methodology: Test-Driven, Interface-First

### The workflow for every feature is:

1. **Write the interface first** (`interfaces/IFoo.sol`). Define the external API, events, errors, and structs. This is the contract's specification.
2. **Write the tests** (`test/unit/Foo.t.sol`). Tests encode expected behavior. Every public/external function gets at least: one happy-path test, one revert test per error condition, one edge case (zero amounts, max values, boundary conditions).
3. **Implement the contract** (`src/core/Foo.sol`). Make the tests pass. Nothing more.
4. **Run the full suite** before committing. `forge test -vvv` must be green.
5. **Write invariant tests** for any contract that holds funds or tracks balances. These run after unit tests pass.
6. **Gas snapshot** after implementation stabilises. `forge snapshot` to baseline, `forge snapshot --diff` on subsequent changes.

### Never do these:

- Never write implementation before the interface and tests exist
- Never skip testing a revert condition ("it obviously works")
- Never use `console.log` in final contract code or committed tests
- Never leave `TODO` or `FIXME` in code — either implement it or create an issue
- Never use `pragma solidity ^0.8.x` — pin to exact version: `pragma solidity 0.8.28;`

## Solidity Standards

### Compiler & Language

- Solidity `0.8.28` (pinned, not floating)
- Optimiser: enabled, 200 runs (balance between deploy cost and runtime gas)
- Via IR: disabled for MVP (enable and benchmark if stack-too-deep issues arise)
- SPDX: `BUSL-1.1` for core contracts, `MIT` for interfaces

### Code Style

- `forge fmt` is the formatter — no exceptions
- Max line length: 120 characters
- NatSpec on every external/public function: `@notice`, `@param`, `@return`, `@dev` (if non-obvious)
- NatSpec on every custom error and event
- Order within a contract: type declarations → state variables → events → errors → modifiers → constructor → external functions → public functions → internal functions → private functions → view/pure functions
- Use named return values only when it improves readability; prefer explicit `return` statements
- Prefer `uint256` over `uint` — always explicit

### Naming Conventions

- Contracts: `PascalCase` (e.g., `OwnVault`, `AssetRegistry`)
- Interfaces: `I` prefix (e.g., `IOwnVault`)
- Functions: `camelCase` (e.g., `mintAsset`, `getHealthFactor`)
- State variables: `camelCase` (e.g., `totalCollateral`)
- Private/internal state: `_underscorePrefixed` (e.g., `_assetConfigs`)
- Constants: `UPPER_SNAKE_CASE` (e.g., `MAX_SPREAD_BPS`, `PRECISION`)
- Immutables: `UPPER_SNAKE_CASE` for true constants, `camelCase` if constructor-set
- Events: `PascalCase` past tense (e.g., `AssetMinted`, `CollateralDeposited`)
- Errors: `PascalCase` descriptive (e.g., `InsufficientCollateral`, `StalePrice`, `Unauthorized`)
- Structs: `PascalCase` (e.g., `AssetConfig`, `VaultState`)
- Enums: `PascalCase` (e.g., `VaultStatus { Active, Halted }`)

### Security Patterns — Mandatory

**Checks-Effects-Interactions (CEI)**: Every external function that modifies state and makes external calls MUST follow CEI. No exceptions. Validate inputs → update state → interact with external contracts.

**ReentrancyGuard**: Use OpenZeppelin's `ReentrancyGuard` on every function that transfers tokens or ETH. Even if you think CEI is sufficient — belt and suspenders.

**Access Control**: Use explicit `modifier`s, not inline `require(msg.sender == X)`. Define clear roles: `onlyVaultManager`, `onlyVault`, `onlyRegistry`, `onlyAdmin`.

**Safe Token Transfers**: Always use OpenZeppelin `SafeERC20` for `transfer`, `transferFrom`, `approve`. Never use raw `.transfer()` or `.call()` for ERC20.

**No Floating Pragma**: `pragma solidity 0.8.28;` — pinned.

**No delegatecall to untrusted targets**: If we ever need delegatecall, it goes to a known immutable implementation.

**Integer Safety**: Solidity 0.8+ has overflow protection. Use `unchecked` blocks ONLY for provably safe operations (e.g., loop counter increment) and comment WHY it's safe. Use `Math.mulDiv` from OpenZeppelin for safe fixed-point math.

**Ceiling Division**: When calculating minimum collateral or protocol-favorable amounts, use `Math.Rounding.Ceil`. When calculating user-favorable amounts, use `Math.Rounding.Floor`. Comment the rounding direction and why.

### Oracle-Specific Security

- Price staleness: always enforce `block.timestamp - priceTimestamp <= maxStaleness`
- Price non-zero: `require(price > 0, ZeroPrice())`
- Signature verification: use OpenZeppelin `ECDSA.recover`, check against authorised signers
- Include `chainId` and `verifierAddress` in signed message to prevent cross-chain/cross-contract replay
- Never use onchain spot prices (Uniswap reserves, etc.) for valuation — external oracle only

### Gas Optimisation Guidelines

- Use `immutable` for values set once in constructor
- Use `constant` for compile-time constants
- Pack related storage variables (e.g., `uint128 amount; uint64 timestamp; uint8 status;` fits one slot)
- Prefer `mapping` over `array` when you don't need iteration
- Use custom errors (`error InsufficientCollateral()`) instead of revert strings — saves ~50 gas per revert
- Cache storage reads in memory when used more than once in a function
- Use `calldata` instead of `memory` for external function array/struct parameters that aren't modified
- Avoid `sload` in loops — read once, loop in memory, write back
- Benchmark with `forge snapshot --diff` before and after optimisation

## Dependencies

Use OpenZeppelin Contracts v5.x via Foundry's git submodule system. Keep dependencies minimal.

```
lib/
├── forge-std/              # Foundry test utilities (Test, console, Vm)
├── openzeppelin-contracts/ # v5.x: ERC20, ERC4626, SafeERC20, ECDSA, ReentrancyGuard, Math, Ownable
└── (no other dependencies unless explicitly discussed)
```

Remappings (in `remappings.txt`):

```
forge-std/=lib/forge-std/src/
@openzeppelin/=lib/openzeppelin-contracts/
```

Do NOT add dependencies without discussion. Every dependency is attack surface. If a utility is < 50 lines, inline it in `libraries/`.

## Testing Standards

### Unit Tests (`test/unit/`)

- One test file per contract
- Mock external dependencies. Unit tests should not depend on other protocol contracts.
- Test naming: `test_functionName_condition_expectedResult()` (e.g., `test_mint_insufficientCollateral_reverts()`)
- Use `setUp()` for common state. Each test should be independent.
- Use Foundry cheatcodes: `vm.prank()`, `vm.expectRevert()`, `vm.expectEmit()`, `vm.warp()`, `vm.deal()`
- Test boundary values: `0`, `1`, `type(uint256).max`, minimum amounts, exact threshold values
- Every `revert` / custom error in the code must have a corresponding test that triggers it

### Integration Tests (`test/integration/`)

- Test complete flows: LP deposits collateral → LP receives vault shares → minter mints eToken → minter redeems → LP withdraws
- Use real contract instances (not mocks)
- Test multi-actor scenarios: multiple LPs, multiple vault managers, multiple minters, multiple assets, concurrent operations
- Test delegation flows: LP delegates to vault manager, vault manager accepts, vault manager handles parameters
- Test state transitions: active → halted → active

### Invariant Tests (`test/invariant/`)

- Define protocol invariants that must ALWAYS hold:
  - `totalETokenSupply * price <= totalCollateral * collateralRatio` (solvency)
  - `sum(LP vault shares) == vault.totalSupply()` (ERC-4626 accounting)
  - `sum(all eToken supplies) == sum(vault.mintedNotional for each asset)` (eToken accounting)
  - `eToken.totalSupply() >= 0` (no negative supply — sounds obvious, test it)
  - After any operation: `vault health factor >= 1.0` OR `vault is halted`
  - `sum(delegated LP shares per manager) == total delegated shares` (delegation accounting)
  - Spread applied is always >= `minSpread` (spread floor invariant)
- Use Foundry's invariant testing framework with handler contracts
- Handler contracts should exercise: deposit, withdraw, mint eToken, redeem eToken, delegate to vault manager, set spread, halt vault
- Run with `forge test --fuzz-runs 10000` for pre-audit

### Fork Tests (`test/fork/`)

- Fork Base mainnet to test against real Uniswap pools, real USDC, real price feeds
- Use `vm.createFork()` and `vm.selectFork()`
- Test with real token decimals and edge cases (USDC = 6 decimals, WETH = 18, aUSDC = 6, stETH = 18)
- Test wstETH wrapping/unwrapping in the stETH vault

### Test Helpers (`test/helpers/`)

- `BaseTest.sol`: Common setup, token deployments, utility functions
- `MockERC20.sol`: Configurable decimals mock token
- `MockOracleVerifier.sol`: Returns configurable prices, can simulate staleness
- `Actors.sol`: Predefined addresses for minter, vaultManager, lp, admin, attacker

### What "good coverage" means

- Line coverage > 95% for core contracts
- Branch coverage > 90% for core contracts
- 100% coverage on all revert paths
- Invariant test campaigns with 10,000+ runs passing

## EIP / Standard Compliance

Contracts should implement or be compatible with these standards where applicable:

- **ERC-20 + ERC-2612 (Permit)**: eToken. Use OpenZeppelin's `ERC20Permit`. Enables single-tx mint flows.
- **ERC-4626 (Tokenized Vaults)**: Used for LP share accounting in all vaults. Each vault is an ERC-4626 vault where the underlying asset is the collateral type (USDC, aUSDC, WETH, wstETH). Share price naturally appreciates for yield-bearing collateral (aUSDC, stETH) and as spread revenue is distributed.
- **ERC-7540 (Async Vaults)**: Design pattern for non-market-hours redemption queue (future consideration). Keep the interface compatible.
- **ERC-7575 (Multi-Asset Vaults)**: Relevant for multi-collateral vaults (future consideration). The eToken being external to the vault is already ERC-7575 aligned.
- **ERC-7535 (Native Asset Vaults)**: For ETH collateral vaults (future consideration). Use via a router periphery contract.
- **EIP-712 (Typed Structured Data)**: Used in oracle signed price messages. Follow the standard for domain separator and type hashing.

When implementing, reference the EIP directly. Do not rely on memory — check the spec.

## Spread Model

The protocol uses a unified spread model. There is no separate protocol fee — all revenue comes through the spread.

### How it works

- **`minSpread`**: Protocol-enforced floor (e.g., 0.3% = 30 BPS). Guarantees minimum protocol revenue on every mint/redeem.
- **Market hours**: spread = `minSpread`. All vault managers execute at the same spread.
- **Non-market hours**: spread = `max(minSpread, managerCustomSpread)`. Each vault manager independently opts in or out of non-market-hour execution and sets their own custom spread for off-hours.
- **Routing during off-hours**: Minters are routed to the best available price (lowest spread) among vault managers willing to execute. Available liquidity per manager during off-hours is determined by their delegated LPs' proportional share of the vault.

### Spread revenue split

Spread revenue is split three ways:
- A portion goes to the protocol
- A portion goes to the vault manager
- A portion goes to the LPs (reflected in vault share price appreciation)

### Key constants

- Spread: defined in BPS (basis points). `10000` = 100%.
- `minSpread`: protocol-enforced floor, set by admin (e.g., 30 BPS = 0.3%)
- Precision constant: `1e18` for price math, `10000` (BPS) for spread math
- USDC: 6 decimals. aUSDC: 6 decimals. ETH/WETH: 18 decimals. stETH/wstETH: 18 decimals. eTokens: 18 decimals. Prices: 18 decimals. Always be explicit about decimal conversions.

## Security Vulnerability Checklist

Before any PR to `main`, mentally (or actually) run through this list for every changed contract:

- [ ] Reentrancy: state changes after external calls? CEI followed? ReentrancyGuard present?
- [ ] Access control: every state-changing function has appropriate modifier? No unprotected initialiser?
- [ ] Oracle manipulation: using external signed prices only? Staleness checked? Replay prevented?
- [ ] Integer issues: any `unchecked` blocks? Safe? Rounding direction correct (protocol-favorable)?
- [ ] Front-running: can a transaction be sandwiched for profit? (Mint/redeem use oracle price, not spot)
- [ ] DoS: unbounded loops? Can a single actor grief the protocol?
- [ ] Token assumptions: does the code handle tokens with different decimals? Fee-on-transfer tokens? (We don't support fee-on-transfer, but assert that)
- [ ] Precision loss: multiplications before divisions? `mulDiv` used for cross-multiplication?
- [ ] Event emission: every state change emits an event? (Needed for off-chain indexing and auditing)
- [ ] Storage collision: no variable shadowing between inherited contracts?
- [ ] Signature replay: `chainId` + `contractAddress` in signed messages? Nonce if applicable?
- [ ] ERC-4626 compliance: share/asset conversion rounding correct? Deposit/withdraw/mint/redeem all consistent?
- [ ] wstETH wrapping: wrap/unwrap handled correctly? No stETH rounding dust left behind?

## Commit & PR Conventions

- Commit messages: `type(scope): description` (e.g., `feat(vault): add mint with signed price`, `test(vault): add insufficient collateral revert test`, `fix(oracle): check staleness before signer recovery`)
- Types: `feat`, `fix`, `test`, `refactor`, `docs`, `chore`
- Every PR must: compile (`forge build`), pass all tests (`forge test`), be formatted (`forge fmt --check`)
- No PR should mix feature code and refactoring — keep them separate

## When Something Goes Wrong

- Test fails after a change? **Fix it before doing anything else.** Do not stack changes on a broken test suite.
- Unsure about a security pattern? **Stop and research.** Check OpenZeppelin docs, the Solidity docs, or known vulnerability databases (SWC Registry, Rekt.news). It's better to be slow and correct than fast and exploitable.
- Gas snapshot regression > 5%? Investigate before merging. Might be fine, might indicate an unnecessary storage write.
- Slither finding? Triage it. False positive → add to `slither.config.json` exclusions with a comment. Real finding → fix it.

## Project-Specific Context

### Trust Model

- **Oracle signer**: Trusted (protocol-operated). Single signer for MVP, M-of-N later.
- **Vault managers**: Semi-trusted. Multiple vault managers can register per vault. They manage spread parameters for their delegated LPs and handle offchain hedging. LPs choose which vault manager to delegate to (or self-delegate). Vault managers cannot access LP collateral directly — only the vault contract controls funds.
- **Protocol admin**: Multisig. Can whitelist assets, halt vaults, set `minSpread`, register/deregister vault managers.
- **LPs**: Deposit collateral into public vaults. Delegate to a vault manager of their choice. Can withdraw their proportional share at any time (subject to utilisation limits).
- **Minters**: Untrusted. Treat all minter input as adversarial.

### Decimal Handling

```
Collateral amount → price (18 decimals) → eToken amount (18 decimals)

For USDC/aUSDC (6 decimals):
eTokenAmount = collateralAmount * 1e18 / price * decimalFactor

For ETH/stETH (18 decimals):
eTokenAmount = collateralAmount * 1e18 / price
```

Always use `Math.mulDiv` for these conversions. Never do `a * b / c` — use `mulDiv(a, b, c)`.

## Security Review Process

When asked to do a security review, follow this process for every contract in `src/`:

### Vulnerability Checklist — Prioritised for Vault Protocols

Scan in this order. Stop and report any finding immediately.

1. **Reentrancy**: State changes after external calls (token transfers). Verify CEI compliance and ReentrancyGuard usage.
2. **Oracle manipulation**: Signed price validation, staleness checks, replay protection (chainId + contract address in signed message).
3. **Access control**: Missing modifiers on state-changing functions, unprotected initialisers, privilege escalation paths. Check vault manager delegation logic for unauthorized actions.
4. **Arithmetic**: Rounding direction (protocol-favorable vs user-favorable), precision loss in mulDiv chains, unsafe casting between uint sizes. Check ERC-4626 share/asset conversions.
5. **Token handling**: Missing SafeERC20, decimal mismatch between collateral types and eTokens, wstETH wrapping edge cases.
6. **Delegation logic**: Can a vault manager act on behalf of LPs who have not delegated to them? Can delegation be manipulated?
7. **Front-running**: Mint/redeem with stale price, sandwich attacks on vault deposits/withdrawals.
8. **DoS**: Unbounded loops, block gas limit, single-actor griefing (e.g., dust amounts blocking operations).
9. **Flash loan**: Can flash-minted tokens manipulate vault health or oracle prices?
10. **Signature replay**: Cross-chain, cross-contract, nonce handling for signed oracle prices.
11. **ERC-4626 compliance**: Inflation attack on vault shares? Correct rounding in all conversion functions?

### Severity Definitions

- **Critical**: Direct loss of funds, no preconditions
- **High**: Loss of funds with specific conditions, permanent state corruption
- **Medium**: Conditional loss, griefing, value leakage below 1%
- **Low**: Best practice violation, no direct fund risk
- **Info**: Gas optimisation, code quality

### Finding Report Format

For each finding:

```
### [SEVERITY] Title
**Contract**: filename.sol
**Function**: functionName()
**Line**: approximate line number
**Description**: What the vulnerability is
**Impact**: What an attacker could achieve
**Proof of Concept**: Foundry test skeleton or attack steps
**Recommendation**: Specific code fix
```

After all findings, provide a summary table with severity counts and overall risk assessment.

## Gas Optimisation Review Process

When asked to do a gas review on a contract:

1. Run `forge snapshot` to baseline current gas
2. Read the contract and identify optimisation opportunities
3. Apply optimisations one at a time
4. After each change: run `forge test -vvv` (must pass), then `forge snapshot --diff`
5. Report total gas savings

### Optimisation Checklist (check in this order)

1. **Storage reads**: Cache `sload` results in memory if read more than once in a function
2. **Storage packing**: Can related variables fit in fewer slots? (uint128+uint64+uint8 = 1 slot)
3. **Calldata vs memory**: External function params that aren't modified should use `calldata`
4. **Short-circuiting**: Put cheaper checks first in `require` / `if` chains
5. **Immutable/constant**: Any state variable that never changes after construction?
6. **Custom errors**: Replace any remaining revert strings with custom errors
7. **Unchecked blocks**: Loop counters, provably-safe arithmetic (with `// SAFETY:` comment)
8. **Unnecessary zero-init**: `uint256 i;` not `uint256 i = 0;`
9. **Event indexed params**: Index params used for filtering (addresses, IDs)

### Rules

- NEVER sacrifice security for gas savings
- NEVER remove checks or guards for gas savings
- Every `unchecked` block gets a `// SAFETY:` comment explaining why it's safe
- Run full test suite after each change — a gas optimisation that breaks tests is not an optimisation

## Invariant Test Generation Process

When asked to write invariant tests for a contract:

1. Read the contract source and its interface
2. Identify all protocol invariants that must hold after ANY sequence of operations
3. Create a Handler contract that exercises all external/public state-changing functions with fuzzed inputs
4. Create the invariant test contract that asserts all invariants after each handler call
5. Run `forge test --match-path test/invariant/ -vvv` to verify

### Core Protocol Invariants

These must ALWAYS hold, regardless of operation sequence:

- **Solvency**: total collateral value >= total minted notional * min collateral ratio
- **ERC-4626 Accounting**: sum of all LP vault shares == vault.totalSupply(); vault.totalAssets() >= sum of all deposits minus withdrawals (accounting for yield)
- **eToken Accounting**: eToken totalSupply matches vault's tracked minted amount per asset
- **Delegation**: sum of delegated shares across all vault managers <= vault.totalSupply(); each LP is delegated to at most one vault manager
- **Health**: vault health factor >= 1.0 OR vault is halted
- **Spread floor**: spread applied on any mint/redeem >= `minSpread`
- **Access**: only authorised roles can call privileged functions
- **Supply**: sum of all eToken holder balances == eToken.totalSupply() for every asset
- **wstETH**: stETH vault's wstETH balance == total deposited stETH (converted to wstETH) minus total withdrawn

### Handler Contract Pattern

```solidity
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    OwnVault vault;

    // Ghost variables for invariant checking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalMinted;
    uint256 public ghost_totalRedeemed;

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 1_000_000e6); // 1 USDC to 1M USDC
        // ... prank as LP, approve, call vault.deposit()
        ghost_totalDeposited += amount;
    }

    function withdraw(uint256 shares) external {
        shares = bound(shares, 1, vault.balanceOf(lp));
        // ... prank as LP, call vault.redeem()
        ghost_totalWithdrawn += shares;
    }

    function mintEToken(uint256 amount, uint256 priceIndex) external {
        amount = bound(amount, 1e6, 1_000_000e6);
        // ... setup signed price, prank as minter, call vault.mint()
        ghost_totalMinted += amount;
    }

    function redeemEToken(uint256 amount) external {
        amount = bound(amount, 1, eToken.totalSupply());
        // ... setup signed price, prank as minter, call vault.redeem()
        ghost_totalRedeemed += amount;
    }

    function delegateToManager(uint256 managerIndex) external {
        // ... prank as LP, call vault.delegateTo(manager)
    }
}
```

### Output

- `test/invariant/handlers/VaultHandler.sol`
- `test/invariant/OwnVaultInvariant.t.sol`

## Pre-Audit Checklist

When asked to run a pre-audit check, execute ALL of these steps and report results.

### Automated Checks

```bash
# 1. Compile clean (no warnings)
forge build --deny-warnings

# 2. All tests pass
forge test -vvv

# 3. Format check
forge fmt --check

# 4. Coverage report
forge coverage --report summary

# 5. Gas snapshot
forge snapshot

# 6. Slither static analysis
slither src/ --config-file slither.config.json
```

### Manual Review (for each contract in src/)

- [ ] Complete NatSpec on all external/public functions
- [ ] Every custom error has a corresponding test that triggers it
- [ ] Every event emission has a corresponding test that checks it
- [ ] No `TODO`, `FIXME`, `HACK`, or `XXX` comments remain
- [ ] No `console.log` or `console2.log` imports
- [ ] License header present (`SPDX-License-Identifier`)
- [ ] Correct access control modifiers on every state-changing function
- [ ] ReentrancyGuard on functions that make external calls after state changes
- [ ] SafeERC20 used for all token transfers
- [ ] Rounding direction commented and correct (protocol-favorable where applicable)
- [ ] Decimal conversions explicit and tested (USDC/aUSDC 6 decimals, ETH/stETH 18 decimals, eToken 18 decimals, price 18 decimals)
- [ ] No storage variable shadowing between inherited contracts
- [ ] Events emitted for every state change (needed for off-chain indexing)
- [ ] ERC-4626 share/asset conversions tested for rounding correctness
- [ ] wstETH wrap/unwrap logic tested for edge cases and rounding dust
- [ ] Vault manager delegation logic tested for authorization edge cases

### Report Format

Generate a summary with: build status, test results (pass/fail/skip counts), coverage percentages per contract, Slither findings grouped by severity, manual checklist results per contract, and any blocking issues that must be fixed before audit.
