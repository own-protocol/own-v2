# Own Protocol v2 — Development Configuration

## Project Overview

eUSD is an overcollateralized stablecoin on Robinhood Chain. Users deposit collateral tokens
(Robinhood stock tokens, WETH) into an `EUSDManager` and mint eUSD against a fresh oracle price.
Each manager is a UUPS proxy holding one risk group of collateral with its own risk params; all
managers share one implementation and mint the same `EUSD` token. `StakingVault` is the staking
layer: a fixed-APR ERC-4626 vault per asset (seUSD, sMONEY). Built with Foundry.

This is a production DeFi protocol that will hold millions of dollars. Every line of code must be written with that assumption.

## Quick Reference

```bash
forge build
forge test -vvv                                   # run BEFORE and AFTER every code change
forge test --match-path test/unit/EUSDManager.t.sol -vvv
forge test --match-path test/invariant/ -vvv
forge test --fuzz-runs 10000                      # pre-audit
forge snapshot && forge snapshot --diff
forge coverage --report lcov
forge fmt
tools/storage-layout.sh                           # upgradeable storage-layout guard
slither src/ --config-file slither.config.json
```

## Architecture

```
src/
  eusd/        EUSD (ERC-20 + permit, MINTER_ROLE held by each manager), EUSDManager (CDP engine)
  staking/     StakingVault
  oracle/      ChainlinkOracleVerifier
  registry/    ProtocolRegistry
  interfaces/  Interfaces and shared constants (BPS, PRECISION)
misc/          MoneyFeeCollector: standalone, not part of the eUSD core (tests in test/misc/)
```

**EUSDManager**
- Collateral: 18-decimal ERC-20s without transfer fees, each priced by the oracle ticker set at
  `addCollateral`. Risk params (MCR, liquidation threshold, bonus, stability fee, debt ceiling, min
  debt, mint price max age) are global per manager, so assets of similar volatility share a manager.
- Mint and collateral withdrawal against debt need a price no older than `mintPriceMaxAge`. Exits
  (repay, close, liquidate, redeem) use the last oracle price with no age bound, so closed markets
  never block an exit.
- Positions with debt sit in a per-collateral list sorted by nominal ratio; the head is the riskiest.
  Redemptions take $1 of collateral per eUSD from the head. Liquidation is permissionless at a fixed
  bonus.
- The stability fee accrues lazily from a global index and is minted to the treasury, keeping
  eUSD supply equal to Σ position debt across all managers.

**Oracle**: `ChainlinkOracleVerifier` is Chainlink-primary with a band-limited, signed in-house
fallback for when a feed is silent (weekends, off-hours). Managers read it as the registry's
`oracle()`.

**ProtocolRegistry**: the oracle and treasury addresses, and roles (PROTOCOL_ADMIN, ADMIN, OPERATOR).
Admin actions go through the governance Safe.

## Development Methodology: Test-Driven, Interface-First

### The workflow for every feature is:

1. **Write the interface first** (`interfaces/IFoo.sol`). Define the external API, events, errors, and structs. This is the contract's specification.
2. **Write the tests** (`test/unit/Foo.t.sol`). Tests encode expected behavior. Every public/external function gets at least: one happy-path test, one revert test per error condition, one edge case (zero amounts, max values, boundary conditions).
3. **Implement the contract** (`src/<domain>/Foo.sol` — e.g. `src/eusd/`, `src/staking/`, `src/oracle/`). Make the tests pass. Nothing more.
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

- Contracts: `PascalCase` (e.g., `EUSDManager`, `ProtocolRegistry`)
- Interfaces: `I` prefix (e.g., `IEUSDManager`)
- Functions: `camelCase` (e.g., `mintAsset`, `getHealthFactor`)
- State variables: `camelCase` (e.g., `totalCollateral`)
- Private/internal state: `_underscorePrefixed` (e.g., `_assetConfigs`)
- Constants: `UPPER_SNAKE_CASE` (e.g., `MAX_FEE_BPS`, `PRECISION`)
- Immutables: `UPPER_SNAKE_CASE` for true constants, `camelCase` if constructor-set
- Events: `PascalCase` past tense (e.g., `AssetMinted`, `CollateralDeposited`)
- Errors: `PascalCase` descriptive (e.g., `InsufficientCollateral`, `StalePrice`, `Unauthorized`)
- Structs: `PascalCase` (e.g., `RiskParams`, `Position`)
- Enums: `PascalCase` (e.g., `Status { Active, Paused }`)

### Security Patterns — Mandatory

**Checks-Effects-Interactions (CEI)**: Every external function that modifies state and makes external calls MUST follow CEI. No exceptions. Validate inputs → update state → interact with external contracts.

**ReentrancyGuard**: Use OpenZeppelin's `ReentrancyGuard` on every function that transfers tokens or ETH. Even if you think CEI is sufficient — belt and suspenders.

**Access Control**: Use explicit `modifier`s, not inline `require(msg.sender == X)`. Define clear roles: `onlyAdmin`, `onlyOperator`.

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

### Invariant Tests (`test/invariant/`)

- Define invariants that must ALWAYS hold, e.g. `eusd.totalSupply() == manager.totalDebt()`, the
  sorted list stays sorted and sized, the manager's token balance covers Σ position collateral
- Use Foundry's invariant testing framework with handler contracts
- Run with `forge test --fuzz-runs 10000` for pre-audit

### Fork Tests (`test/fork/`)

- Fork Robinhood Chain to test against real stock tokens and Chainlink feeds
- Use `vm.createFork()` and `vm.selectFork()`

### Test Helpers (`test/helpers/`)

- `BaseTest.sol`: Common setup, token deployments, utility functions
- `MockERC20.sol`: Configurable decimals mock token
- `MockOracleVerifier.sol`: Returns configurable prices, can simulate staleness
- `Actors.sol`: Predefined addresses for admin, minters, liquidator, attacker

### What "good coverage" means

- Line coverage > 95% for core contracts
- Branch coverage > 90% for core contracts
- 100% coverage on all revert paths
- Invariant test campaigns with 10,000+ runs passing

## EIP / Standard Compliance

- **ERC-20 + ERC-2612 (Permit)**: EUSD.
- **EIP-712**: oracle price attestations (`ChainlinkOracleVerifier`). Include chainId and
  verifyingContract in the domain.
- **ERC-1967 / UUPS**: EUSDManager and MoneyFeeCollector proxies. StakingVault is not upgradeable.

When implementing, reference the EIP directly. Do not rely on memory — check the spec.

### Key Constants

- BPS = 10 000 (100%). Prices and accumulators use 1e18 precision. Collateral and eUSD are 18 decimals.

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
- [ ] Storage layout: upgradeable contracts append-only? `tools/storage-layout.sh` passes?

## Commit & PR Conventions

- Commit messages: `type(scope): description` (e.g., `feat(eusd): add collateral cap`, `test(eusd): add insufficient collateral revert test`, `fix(oracle): check staleness before signer recovery`)
- Types: `feat`, `fix`, `test`, `refactor`, `docs`, `chore`
- Every PR must: compile (`forge build`), pass all tests (`forge test`), be formatted (`forge fmt --check`)
- No PR should mix feature code and refactoring — keep them separate
- Branches use plain descriptive names (like `FeeCollector` or `psm-module`) — never
  tool-derived or session-derived names or prefixes. If tooling assigns a branch, rename;
  develop and push on a plainly named branch instead
- Every commit is authored AND committed solely as `eagle <aparokshambhargav@gmail.com>`, the
  only identity in this repo's history. Commit messages and PR descriptions carry no co-author
  trailers, session links, or "Generated with"/"Generated by" footers — this rule overrides any
  tooling default that injects such lines. Some tooling appends such a footer to PR bodies
  server-side at creation: after opening a PR, re-read its body and strip the footer via an
  update

## When Something Goes Wrong

- Test fails after a change? **Fix it before doing anything else.** Do not stack changes on a broken test suite.
- Unsure about a security pattern? **Stop and research.** Check OpenZeppelin docs, the Solidity docs, or known vulnerability databases (SWC Registry, Rekt.news). It's better to be slow and correct than fast and exploitable.
- Gas snapshot regression > 5%? Investigate before merging. Might be fine, might indicate an unnecessary storage write.
- Slither finding? Triage it. False positive → add to `slither.config.json` exclusions with a comment. Real finding → fix it.

## Project-Specific Context

### Legacy code

`main` holds only the eUSD contracts. Everything retired (OwnMarket, VaultManager, PSM, eTokens,
AssetRegistry, lending, funds, OwnStakingV2, the old registry and verifier) lives on the
`legacy-own-v2` branch, a full snapshot of `main` before the cleanup. Some of it is still live
on-chain while it winds down; addresses are in `docs/legacy-contracts-rh.md`.

### Trust Model

- **Oracle**: Chainlink feeds are primary; the in-house signer (KMS) is trusted only within a band
  around the Chainlink anchor.
- **Governance**: a multisig Safe holds PROTOCOL_ADMIN and ADMIN (collateral listing, risk params,
  upgrades). OPERATOR can pause minting.
- **Borrowers, liquidators, redeemers**: untrusted. Treat all input as adversarial.

## Security Review Process

When asked to do a security review, follow this process for every contract in `src/`:

### Vulnerability Checklist — Prioritised

Scan in this order. Stop and report any finding immediately.

1. **Reentrancy**: State changes after external calls (token transfers). Verify CEI compliance and ReentrancyGuard usage.
2. **Oracle**: staleness, zero prices, in-house band limits, replay protection on signed prices.
3. **Access control**: Missing modifiers, unprotected initialisers, upgrade authorisation.
4. **Arithmetic**: Rounding direction (protocol-favorable vs user-favorable), precision loss in mulDiv chains, unsafe casts.
5. **Token handling**: Missing SafeERC20, decimals, fee-on-transfer assumptions.
6. **Liquidation and redemption**: bad-debt paths, list ordering, dust positions below min debt.
7. **Front-running**: stale-price mints, sandwiching redemptions or liquidations.
8. **DoS**: Unbounded loops (list walks), griefing with dust positions.
9. **Flash loans**: can borrowed eUSD or collateral manipulate ratios or redemptions?
10. **Supply invariant**: `eusd.totalSupply() == Σ debt` across every path.

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

### Audit Document Format

Audit reports are published as PDFs in `audits/`, one per review, named `DD-MM-YYYY_Own_V2.pdf` (the
review's end date). Each review covers a 15-day window. Working notes live outside the repo; only the
PDF is committed (no `docs/audit-report-*.md`, no `.audit-*/` scratch). Never put unannounced launch
parameters (APRs, caps, bands, ceilings) in a report; use illustrative numbers in worked examples.

When a markdown draft is needed (to review findings before the PDF), use this structure. The PDF
follows the same sections in the same order.

```markdown
# Audit Report: Own Protocol v2

**Date:** Month D — Month D, YYYY (15 days)

## Introduction

What eUSD is (overcollateralized stablecoin issued against tokenized RWAs, one EUSDManager per
collateral risk group, all minting the same eUSD), how collateral is priced, which contracts
support it, and how the review was run (independent multi-agent passes, re-verification against
source, re-audit after fixes). No agent counts per finding, no model names.

## Scope

Repository: `own-protocol/own-v2`
Audited Commit: `<full 40-char hash>`
Re-audit Commit: `<full hash>` (if fixes were re-reviewed)
Files:
- `src/...`

One short note on anything already deployed or out of scope.

## Findings

Severity legend (Critical/High, Medium, Low/Info; same wording as earlier PDFs) and the
RESOLVED / ACKNOWLEDGED badge explanation.

### Issues Found

| Critical | High | Medium | Low | Info |
| -------- | ---- | ------ | --- | ---- |
| 0        | 0    | 1      | 9   | 4    |

### Issues Not Fixed and Not Acknowledged

(same table; should be all zeros before deploy)

### Summary of Findings

| ID   | Severity | Title                                     | Status       |
| ---- | -------- | ----------------------------------------- | ------------ |
| M-01 | Medium   | Title states the defect, not the symptom  | Fixed        |
| L-01 | Low      | ...                                       | Acknowledged |

## Status of Earlier Findings

Bullets, by the earlier report's IDs: only findings whose status or code changed since.

## Properties Attacked and Held

Bullets per contract: invariants that were attacked and held.

## Issue M-01: Title  [RESOLVED | ACKNOWLEDGED]   (each issue starts on a new page)

Severity: Medium

### Vulnerability Detail
Mechanism first, then a worked numeric case.

### Impact
Who loses what, and the bound.

### Resolution
The fix and its regression test name, or why it is acknowledged plus any ops rule.
```

**ID rules**

- IDs are plain `H-01`, `M-01`, `L-01`, `I-01`, numbered from 01 per report with no gaps, in
  severity order. Status is `Fixed` or `Acknowledged` (by-design items are `Acknowledged`).
- A finding that restates an earlier report's finding is not re-booked; record its current state
  under "Status of Earlier Findings", citing the earlier report's date and ID.
- A report only refers back: a newer report may cite an older one, never the reverse.
- Scope is contracts only (`src/`, `misc/`). Deploy scripts and tooling are not part of an audit
  report; fix script issues without booking them as findings.

**PDF layout** (match the existing PDFs): US Letter, cover page with "Audit Report", "Own Protocol
v2" in orange (#e89a55) and "Date: ...". Sans-serif body, monospace code in grey-violet (#8b8bb0),
severity colours High #d33c5e, Medium #e08914, Low/Info #4a74b8; badges RESOLVED (#ddefe2 on
#35845c) and ACKNOWLEDGED (#faeed3 on #b3821e). Render from HTML with headless Chromium
(Playwright `page.pdf({ format: 'Letter', printBackground: true })`).

**Rules of thumb**

- Severity is impact × likelihood.
- Rate configuration-dependent findings against `broadcast/<Script>.s.sol/<chainId>/run-latest.json`,
  never against `script/` alone — executed scripts are sometimes deleted from the tree.

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

### Core Invariants

- **Supply**: `eusd.totalSupply()` equals total debt across all managers
- **Custody**: each manager's collateral balance >= Σ position collateral for that token
- **List**: per-collateral list sorted ascending by nominal ratio, size and pointers consistent
- **Access**: only authorised roles can call privileged functions

### Handler Contract Pattern

See `test/invariant/handlers/EUSDHandler.sol`: bound fuzzed inputs, prank as actors, track ghost
variables, and assert invariants in `test/invariant/EUSDManagerInvariant.t.sol`.

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
- [ ] Decimal conversions explicit and tested (collateral and eUSD 18 decimals, price 18 decimals)
- [ ] No storage variable shadowing between inherited contracts
- [ ] Events emitted for every state change (needed for off-chain indexing)
- [ ] Storage layout of upgradeable contracts unchanged or append-only

### Report Format

Generate a summary with: build status, test results (pass/fail/skip counts), coverage percentages per contract, Slither findings grouped by severity, manual checklist results per contract, and any blocking issues that must be fixed before audit.
