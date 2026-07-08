# PSM Implementation Tracker (temporary — delete when Phase 5 ships)

Design: `docs/psm-design.md`. Work one phase at a time.

**Protocol per phase:** interface first → tests → implementation → full suite green
(`forge test -vvv`) → `forge fmt` → **STOP: notify user for review & commit** → next phase.
No phase mixes feature code with refactoring of earlier phases.

---

## Phase 1 — Per-asset forceExecute designation ✅ (committed)

- [x] `IVaultManager`: `setForceExecuteVault(bytes32 asset, address vault)`,
      `forceExecuteVault(bytes32 asset)`; update events
- [x] `VaultManager`: `_forceExecuteVault` → `mapping(bytes32 => address)`; keep operator role,
      zero-default = disabled fail-safe, registered + not-excluded checks
      (the `backedAsset == 0` guard lands in Phase 2 — leave a design-doc cross-ref, no TODO comment)
- [x] `OwnMarket.forceExecuteOrder`: read `forceExecuteVault(order.asset)`
- [x] Unit tests: setter (auth, zero-clear, unregistered/excluded reverts), per-asset isolation
      (`test_setForceExecuteVault_perAssetIsolation`,
      `test_forceExecuteOrder_perAssetDesignation_usesOrderAsset`)
- [x] Update existing forceExecute tests + deploy/ops scripts (none call the setter — verified)
- [x] `forge test` green (864/864 incl. fork tests), `forge fmt --check` clean
- [x] **STOP — user review & commit** (committed)

## Phase 2 — Vault classes + per-asset delta netting (VaultManager) ✅ (committed)

- [x] `IVaultManager`: `registerVault(vault, collateralAsset, backedAsset)` overload (2-arg form
      kept = generic, zero churn for callers), `vaultBackedAsset`, `assetRwaCollateralUSD`,
      `assetExposureUSD` views; `VaultRegistered` event carries `backedAsset`; netting NatSpec;
      new `RwaVaultNotEligible` error
- [x] `VaultManager` state: `_vaultBackedAsset`, `_assetRwaCollateralUSD`; RWA marks excluded
      from `_globalCollateralUSD`; `_globalNetExposureUSD` = Σ max(0, E_a − R_a)
- [x] Netting helpers (`_netExposure`/`_netOf`/`_setAssetExposure`/`_setAssetRwaCollateral`)
      wired into `openExposure`, `closeExposure`, `pullAssetPrice`, `haltAsset`,
      `pullCollateralPrice`, `onCollateralReleased`, `onVaultHalted`, `onVaultUnhalted`,
      `deregisterVault`, `withdrawalBreachesUtil`; fully-netted opens need no generic collateral
- [x] `setForceExecuteVault`: `RwaVaultNotEligible` guard; `setCollateralCapBps` likewise
      (concentration caps are generic-pool-only; the netting clamp bounds RWA vaults)
- [x] Unit tests (16 new): netting math (R < E, R == E, R > E clamp + no cross-asset credit),
      multi-wrapper sum, reserve-covered open with zero generic collateral, residual util breach,
      close/pull re-netting, release/halt/unhalt RWA branches, deregister guard, withdrawal gate,
      class guards
- [x] Invariant suite `NettingInvariant.t.sol` + `NettingHandler` (2 assets, generic + 3 RWA
      vaults): INV-N1 net-exposure sum, INV-N2 generic-only collateral, INV-N3 per-asset reserve
      sums — green at 1000 runs × depth 50 (50k calls each)
- [x] `forge test` green (884/884), `forge fmt --check` clean
- [x] **STOP — user review & commit** (committed)

## Phase 3 — ReserveVault + PSM entrypoints + AssetRegistry config ✅ (committed)

- [x] Interfaces: `IReserveVault` (new), PSM additions to `IOwnMarket` + `IAssetRegistry`,
      `PsmConfig` in Types.sol; events + errors throughout
- [x] `ReserveVault` (`src/core/ReserveVault.sol`): immutable wrapper, `asset()`/`totalAssets()`
      (balance-based), `releaseCollateral` onlyMarket with mark-sync-before-transfer,
      `skimExcess` onlyOperator → treasury with inline re-mark + surplus guard (remaining
      reserve must still cover gross exposure) + `VaultNotRwaRegistered` misconfig guard
- [x] `AssetRegistry`: `setPsmConfig` (admin; validates `vaultBackedAsset == ticker` and
      `IReserveVault.asset() == wrapper`; reconfig resets guard, no duplicate wrapper entries),
      `setPsmPaused` (operator), `setRatioJumpBoundBps` (admin, ≤ BPS, 0 = off),
      `resetRatioGuard` (operator, disarm semantics), `notePsmRatio` (onlyMarket),
      `getPsmConfig`/`getPsmWrappers`/`ratioJumpBoundBps` views
- [x] **Derived conversion ratio**: `ratio = oracle wrapper-token price / vmgr assetMark(asset)`
      — numerator identical to what `pullCollateralPrice` marks the reserve with in the same tx,
      denominator identical to what open/closeExposure value units with → unit conversion and
      USD netting can never disagree; no stored ratio, no applySplit hook (verified by the split
      integration test)
- [x] **Ratio-jump guard**: per-(ticker, wrapper) `lastUsedRatio`, global bps bound, revert
      `RatioJumpExceeded`, operator `resetRatioGuard` disarms (re-arms on next op)
- [x] **Guard is FAIL-CLOSED** (design §8.3.4): bound 0 = pre-deploy default → PSM mint/redeem
      revert `RatioGuardNotConfigured`; `setRatioJumpBoundBps` requires 0 < bps ≤ BPS and can
      never return to zero; backfill exempt. Phase 5 deploy script MUST set the bound.
      Rationale: guard also catches intraday oracle-push vs keeper-pull ratio desync
- [x] `OwnMarket.psmMint` / `psmRedeem` per design (mint: active+tradeable+fresh wrapper price;
      redeem: works off-hours, allowed while halted with fresh wrapper leg, blocked by pauses);
      floor rounding both directions; fee-on-transfer checks; CEI + nonReentrant
- [x] Backfill moved to `ReserveVault.deposit` (design §4.5): deposits are vault-local,
      ungated (additions are inherently ungateable and only add backing), sync the mark inline
- [x] `ReserveVault.withdraw` — maker recovery path (registered signer → linked
      settlement address, same surplus clamp as skimExcess, works off-hours); replaces the
      mint+redeem extraction loop (design §4.2)
- [x] Unit tests: `ReserveVault.t.sol` (17: custody, release auth/bounds/mark-sync, skim guard
      incl. unmarked-donation re-mark, withdraw auth/linked-payout/clamp),
      AssetRegistry PSM section (8: config validation, pause, bound, reset/note auth)
- [x] Integration `PsmFlow.t.sol` (26): happy paths incl. 6-dec wrapper scaling, sValue drift,
      every revert gate, ratio-guard trip/ack, off-hours redeem with frozen pair, halted redeem
      at halt price + stale-wrapper revert, backfill-frees-buffer loop, PSM-mint→RFQ-redeem
      surplus + skim, maker recovery via withdraw (incl. off-hours), 2:1 split
      auto-rescale, multi-wrapper netting, dust rounding
- [x] Invariant `PsmInvariant.t.sol` + `PsmHandler` (mixed PSM + RFQ channels + price drift):
      supply == units, netting identity, collateral segregation, reserve-mark sanity — green at
      1000 runs × depth 50 (50k calls each)
- [x] `forge test` green (944/944), `forge fmt --check` clean
- [x] Deploy note for Phase 5: wrapper tickers (`ONDO.TSLA` etc.) must be `addAsset`-registered
      in AssetRegistry so `getOracleType` resolves their feeds (same pattern as the ETH ticker)
- [x] **STOP — user review & commit** (committed)

## Phase 4 — Per-asset lending-vault allowlist ✅ (awaiting review & commit)

- [x] `IAssetRegistry` + `AssetRegistry`: `setLendingVaultAllowed(ticker, vault, allowed)`
      (admin; registered-ticker + non-zero-vault checks, `RwaVaultNotEligible` guard on allow —
      ReserveVaults never enter the allowlist; revoke stays unguarded so entries always clear),
      `isLendingVaultAllowed(ticker, vault)` view, `LendingVaultAllowedUpdated` event
- [x] `BorrowManager._validateEligibility`: require own bound vault is allowed for the asset
      (new `LendingVaultNotAllowed` error; composes with existing per-asset borrow blocklist;
      check ordered after the active-asset gate)
- [x] Revocation stance: **borrow-only gate** — only `_validateEligibility` reads the allowlist,
      so repay / liquidate / settleHaltedPosition / absorbBadDebt keep working on open positions
      after a revoke (documented in interface + `_validateEligibility` NatSpec)
- [x] Unit tests: registry toggle/auth/validation + RWA-guard (3 in AssetRegistry.t.sol),
      borrow gated per (asset, vault) + revocation leaves repay & liquidate working (3 in
      BorrowManager.t.sol); fixtures updated to default-deny (BorrowManager ×2 suites,
      BorrowBrickPoC, BorrowAndLiquidateFlow, RFQAusdcFlows, BorrowManagerInvariant,
      BorrowManagerAaveFork). Phase 5 deploy bundle must call `setLendingVaultAllowed` per
      (asset, vault) — borrows are inert until allowlisted
- [x] `forge test` green (950/950), `forge fmt --check` clean
- [ ] **STOP — user review & commit**

## Phase 4b — Per-asset maker allowlist ✅ (added 2026-07-08; awaiting review & commit)

- [x] `IAssetRegistry` + `AssetRegistry`: `setMakerAllowed(ticker, signer, allowed)` (admin;
      registered-ticker + non-zero-signer checks, grant requires `vmgr.isSigner(signer)` —
      new `SignerNotRegistered` error — revoke unguarded so entries clear even after signer
      removal), `isMakerAllowed(ticker, signer)` view, `MakerAllowedUpdated` event
- [x] `OwnMarket._consumeQuote`: after `isSigner`, require `isMakerAllowed(quote.asset, signer)`
      (new `MakerNotAllowed` error) — scopes each signer key to its assets, composing with the
      settle band as leaked-key blast-radius containment
- [x] `ReserveVault.withdraw`: same gate on the vault's `backedAsset` (new `MakerNotAllowed`
      error); single flag gates both quoting and recovery — off-boarding makers recover their
      wrapper before revocation
- [x] Unit tests: registry toggle/auth/validation + signer-guard + revoke-after-removal (3 in
      AssetRegistry.t.sol, stub VM gained `isSigner`), `MakerNotAllowed` on executeOrder
      (OwnMarket.t.sol) and on withdraw (ReserveVault.t.sol, stub registry gained the
      allowlist); 13 integration/invariant fixtures + OwnMarket mock fixture updated to
      default-deny (grants after signer registration, quoted tickers only). Phase 5 deploy
      bundle must call `setMakerAllowed` per (asset, signer) — RFQ settlement inert until
      granted
- [x] `forge test` green (955/955), `forge fmt --check` clean
- [ ] **STOP — user review & commit**

## Phase 4c — forceExecute vault allowlist, moved to AssetRegistry ✅ (added 2026-07-08; awaiting review & commit)

Decisions: ALL per-asset config lives in AssetRegistry; VaultManager keeps no forceExecute
state. Single-tier allowlist (no operator designation): the REDEEMER picks any admin-approved
vault at execution time — force-execute is the user's last-resort exit, so source flexibility
is deliberate (supersedes Phase 1's single-designation model).

- [x] `IAssetRegistry` + `AssetRegistry`: `setForceExecuteVaultAllowed(ticker, vault, allowed)`
      (admin; grant requires vmgr-registered + non-RWA — new `VaultNotRegistered` error; revoke
      unguarded, bites immediately since the pool is read at use time),
      `isForceExecuteVaultAllowed` view, `ForceExecuteVaultAllowedUpdated` event; empty pool
      (default) = force-execution disabled (fail-safe)
- [x] `IVaultManager` + `VaultManager`: `setForceExecuteVault`/`forceExecuteVault`/
      `ForceExecuteVaultUpdated` removed (VM −677 B)
- [x] `OwnMarket.forceExecuteOrder`: caller-supplied vault checked against the registry pool
      (`ForceExecuteVaultNotAllowed` replaces `ForceExecuteVaultNotSet`/`VaultNotDesignated`);
      registered/excluded checks kept; NEW use-time RWA guard (`RwaVaultNotEligible`) — a stale
      pool entry re-registered as RWA must not drain a ReserveVault (its releaseCollateral is
      market-gated, which this call would pass); pause/halt/threshold/fresh-price unchanged
- [x] Tests: AssetRegistry pool toggle/validation (stub VM gained isRegisteredVault); OwnMarket
      empty-pool, per-asset keying, vault-not-in-pool, and RWA-drift reverts (fixtures grant the
      pool entry); OrderLifecycle + HaltWithPriceFlow fixtures grant-only; stale
      `_setForceExecuteVault` BaseTest helper deleted
- [x] Note for Phase 5: deploy bundle calls `setForceExecuteVaultAllowed` per (asset, vault) —
      force-execution inert until granted; design-doc §4.3/§4.4 updated in the docs pass;
      ops note: multi-vault pools let redeemers choose their payout collateral — pool
      composition is the risk lever (keep pools small/homogeneous per asset)
- [x] `forge test` green (950/950), `forge fmt --check` clean
- [ ] **STOP — user review & commit**

## Phase 5 — Full-system verification, docs, deployment

- [ ] Extend invariant handlers to exercise PSM paths alongside RFQ/lending/withdrawals;
      10k-run campaign green
- [ ] **Resolve wrapper availability on Base** (design §8.7 — Ondo GM is Ethereum/BNB/Solana
      only as of July 2026): confirm Ondo Base launch, or select a Base-native issuer
      (e.g. Dinari) and verify its corporate-action mechanics per §8.3 before configuring it
- [ ] Fork test (Base): the selected wrapper token — decimals, transfer behavior (re-verify
      no transfer restrictions on-chain, design §8.1), ReserveVault custody round-trip
- [ ] Update `docs/protocol.md` (new §: PSM + reserve vaults; forceExecute per-asset; vault
      classes) and `docs/deployment.md`
- [ ] Deployment scripts: v2.1 bundle (redeploy VaultManager, OwnMarket, AssetRegistry;
      deploy ReserveVault(s); re-register vaults with `backedAsset`; per-asset forceExecute
      designations; PSM configs; wrapper oracle ticker; **`setRatioJumpBoundBps` — required,
      PSM mint/redeem inert until set** — recommend 100–200 bps)
- [ ] Oracle service ops notes: wrapper ticker publishes **token price** (underlying × sValue —
      numerically equal to the underlying feed only while sValue = 1); runbook for Ondo
      corporate-action pause windows (≥24h notice → set `psmPaused` for the wrapper; unpause +
      `acknowledgeRatio` after Ondo re-syncs — design §8.3)
- [ ] `docs/audit-report.md`: note superseded/affected findings per audit-doc conventions
- [ ] Gas snapshot diff reviewed
- [ ] Delete this file
- [ ] **STOP — user review & commit**
