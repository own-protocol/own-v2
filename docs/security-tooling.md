# Security Tooling Guide

This project uses [Trail of Bits Claude Code skills](https://github.com/trailofbits/skills) combined with a custom `/audit` skill for smart contract security analysis.

## Setup

The Trail of Bits marketplace and plugins are installed at the **project scope** (`.claude/settings.json`). They activate automatically in any Claude Code session within this repo.

**Prerequisites for full functionality:**
- [Slither](https://github.com/crytic/slither) — `pip install slither-analyzer`
- [Semgrep](https://semgrep.dev/) — `pip install semgrep` (optional, for pattern scanning)
- [CodeQL](https://codeql.github.com/) — `brew install codeql` (optional, for deep data-flow analysis)
- [OpenAI Codex CLI](https://github.com/openai/codex) — `npm i -g @openai/codex` (optional, for second-opinion)
- [Google Gemini CLI](https://github.com/google/gemini-cli) — `npm i -g @google/gemini-cli` (optional, for second-opinion)

## Installed Plugins

| Plugin | Skills | Purpose |
|--------|--------|---------|
| `audit-context-building` | `audit-context-building` | Deep line-by-line code comprehension before bug hunting |
| `building-secure-contracts` | `audit-prep-assistant`, `token-integration-analyzer`, `guidelines-advisor`, `code-maturity-assessor` | Pre-audit prep, ERC20/721 conformity, secure development |
| `differential-review` | `differential-review` | Security review of PRs, branches, uncommitted changes |
| `entry-point-analyzer` | `entry-point-analyzer` | Maps attack surface — all state-changing entry points |
| `second-opinion` | `second-opinion` | Cross-validates via external LLMs (Codex, Gemini) |
| `spec-to-code-compliance` | `spec-to-code-compliance` | Verifies code matches PRD / whitepaper spec |
| `static-analysis` | `codeql`, `semgrep`, `sarif-parsing` | Automated vulnerability scanning |
| `variant-analysis` | `variant-analysis` | Finds variants of a known bug across the codebase |

## Custom `/audit` Skill

Project-specific auditor at `.claude/commands/audit.md`. Combines automated analysis with manual expert review tailored to Own Protocol's architecture.

### Usage

```
/audit full                          # Full audit of all src/ contracts
/audit diff                          # Audit only uncommitted changes
/audit file src/core/OwnVault.sol    # Audit a specific file
/audit check reentrancy in OwnMarket # Focused concern
```

### What it does (5 phases)

1. **Spec-to-Code Compliance** — Maps every PRD requirement to implementation status (IMPLEMENTED / PARTIAL / STUB / MISSING / DIVERGENT)
2. **Security Vulnerability Scan** — Runs AGENTS.md prioritised checklist (reentrancy, oracle, access control, arithmetic, etc.)
3. **Code Quality & Simplification** — Finds dead code, stubs, unnecessary boilerplate, missing events/NatSpec
4. **Gas Optimization** — Storage packing, sload caching, calldata vs memory, immutables
5. **Test Gap Analysis** — Missing happy-path, revert-path, and edge-case tests

## Trail of Bits Skills — When to Use Each

### Before Starting an Audit

#### `audit-context-building`
Build deep understanding of the codebase before looking for bugs. Use this FIRST.

```
Analyze src/core/OwnVault.sol using ultra-granular code analysis to build deep context
```

- Line-by-line semantic analysis
- Builds mental model of invariants, assumptions, data flows
- Does NOT find bugs — only builds understanding
- Use before any other security skill

#### `entry-point-analyzer`
Map the attack surface.

```
Analyze the entry points and attack surface of the contracts in src/
```

- Lists all state-changing external/public functions
- Classifies by access level (Public / Role-Restricted / Contract-Only)
- Identifies unprotected functions that need review
- Supports Slither integration for deeper analysis

#### `audit-prep-assistant`
Prepare the codebase for a formal audit engagement.

```
Help me prepare this codebase for a security audit
```

- Sets review goals and documents concerns
- Runs Slither static analysis
- Analyses test coverage gaps
- Removes dead code
- Generates documentation (flowcharts, user stories, glossary)
- Creates audit prep checklist

### During Code Review

#### `differential-review`
Review specific changes — PRs, branches, or uncommitted work.

```
Review the security implications of my uncommitted changes
Review the diff between main and this branch
```

- Risk-classifies changed files (HIGH/MEDIUM/LOW)
- Checks git blame for removed security-relevant code
- Calculates blast radius (what else is affected)
- Analyses test coverage of changes
- Generates markdown report with findings

#### `spec-to-code-compliance`
Verify implementation matches the specification.

```
Check if the contracts in src/ match the spec in docs/Own_Protocol_MVP_PRD.md
```

- 7-phase workflow: discovery, normalisation, spec IR, code IR, alignment, classification, report
- Maps every spec requirement to code with confidence scores
- Classifies divergences by severity (CRITICAL/HIGH/MEDIUM/LOW)
- Identifies undocumented behaviour and missing implementations

#### `token-integration-analyzer`
Analyse ERC20/ERC721 token implementations and integrations.

```
Analyze the EToken contract for ERC20 conformity and weird token patterns
Analyze how our vaults handle external token integrations (USDC, WETH, wstETH)
```

- Checks 20+ weird ERC20 patterns (missing return values, fee-on-transfer, rebasing, etc.)
- Runs `slither-check-erc` for conformity
- Analyses owner privileges and centralisation risks
- Identifies integration risks with external tokens

### Automated Scanning

#### `semgrep`
Fast pattern-based vulnerability scanning.

```
Run a Semgrep security scan on the Solidity contracts
```

- Supports "run all" and "important only" modes
- Uses Trail of Bits + community rulesets
- Parallel execution across rulesets
- No build required — works on source directly
- Good for first-pass scanning

#### `codeql`
Deep interprocedural data-flow analysis.

```
Run CodeQL analysis on the codebase
```

- Builds a database from source for deep analysis
- Tracks taint across function boundaries
- Uses security-extended + Trail of Bits query packs
- Best for complex vulnerability patterns
- Requires successful `forge build`

#### `sarif-parsing`
Process and triage results from Semgrep/CodeQL.

```
Parse and summarise the SARIF results from the scan
```

- Filters, deduplicates, and prioritises findings
- Aggregates results from multiple tools
- Converts to actionable reports

### Finding Bug Variants

#### `variant-analysis`
After finding one bug, search for similar instances.

```
I found a reentrancy issue in OwnMarket.confirmOrder(). Find similar patterns across the codebase.
```

- Understands root cause, not just symptoms
- Starts specific, generalises incrementally
- Uses ripgrep, Semgrep, or CodeQL depending on complexity
- Triages results by confidence and exploitability

### Cross-Validation

#### `second-opinion`
Get a review from a different AI model (OpenAI Codex or Google Gemini).

```
Get a second opinion on my uncommitted changes
Get a second opinion on the branch diff against main
```

- Supports Codex CLI and Gemini CLI
- Can run both in parallel
- Focus options: general, security, performance, error handling
- Useful for catching blind spots

## Recommended Audit Workflow

```
1. /audit full                           # Custom: full project audit
2. Build context with audit-context-building on critical contracts
3. Map attack surface with entry-point-analyzer
4. Run spec-to-code-compliance against MVP PRD
5. Run Semgrep scan for automated pattern detection
6. Review uncommitted changes with differential-review
7. For any finding, run variant-analysis to find similar bugs
8. Get second-opinion on high-risk changes
9. Run audit-prep-assistant before formal engagement
```

## Severity Definitions

| Severity | Description |
|----------|-------------|
| **Critical** | Direct loss of funds, no preconditions |
| **High** | Loss of funds with specific conditions, permanent state corruption |
| **Medium** | Conditional loss, griefing, value leakage below 1% |
| **Low** | Best practice violation, no direct fund risk |
| **Info** | Gas optimisation, code quality |
