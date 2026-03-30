# Own Protocol v2 — Implementation Tracker

## Legend

- [x] Done
- [ ] Todo
- 🔄 In Progress

---

## Completed

- [x] Architecture refactor (1:1 VM-vault, removed spread, async LP deposits)
- [x] Protocol Registry (timelock, getters, unit tests)
- [x] Fee Calculator (per-asset mint/redeem fees via volatility level)
- [x] EToken with dividend support (rewards-per-share for dividend-paying assets)
- [x] Types & interfaces simplified (Order struct, OrderStatus enum, no PriceType/ClaimInfo)
- [x] VaultManager simplified (removed off-market, payment token acceptance, single VM)
- [x] OwnVault simplified (single payment token, fee flush before token swap)
- [x] OwnMarket rewritten (new order execution: claim/confirm/close/forceExecute)
- [x] LP exit wait period + post-withdrawal utilization check (OwnVault)
- [x] Vault utilization enforcement on claim (OwnMarket)
- [x] Unit tests: OwnMarket (48 tests), OwnVault (54 tests), VaultManager (15 tests)
- [x] Integration tests: OrderLifecycle (13 tests — close, force-execute, fees, payment token swap, exposure tracking)
- [x] Oracle architecture: dual oracle per asset (primary/secondary), admin-switchable
- [x] OracleConfig struct + AssetRegistry oracle management (setOracleConfig, switchPrimaryOracle)
- [x] PythOracleVerifier (wraps IPyth, normalizes to 18 decimals, parsePriceInWindow)
- [x] Price range verification in OwnMarket (_verifyPriceRange: two price proofs, timestamp validation)
- [x] Vault collateral release (releaseCollateral on OwnVault, restricted to OwnMarket)
- [x] Force execution wired to collateral release + ETH/USD oracle conversion

---

## Phase 1: Cleanup & Deploy

### 1.1 Code Cleanup

- [ ] Replace all `require` strings with custom errors
- [ ] Update AGENTS.md to reflect new architecture
- [ ] Natspec review — remove unnecessary notes, ensure clear purpose
- [ ] Remove dead code from old multi-VM / multi-collateral model

### 1.2 Deployment

- [ ] Deploy script for Base
- [ ] Testnet deployment + smoke test
