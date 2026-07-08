# PSM Implementation Tracker (temporary — delete when Phase 5 ships)

Design: `docs/psm-design.md`. Work one phase at a time.

**Protocol per phase:** interface first → tests → implementation → full suite green
(`forge test -vvv`) → `forge fmt` → **STOP: notify user for review & commit** → next phase.
No phase mixes feature code with refactoring of earlier phases.

---

## Phase 1 — Per-asset forceExecute designation ✅ (awaiting review & commit)

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
- [ ] **STOP — user review & commit**

## Phase 2 — Vault classes + per-asset delta netting (VaultManager)

- [ ] `IVaultManager`: `registerVault(vault, collateralAsset, backedAsset)`,
      `vaultBackedAsset(vault)`, `assetRwaCollateralUSD(asset)`, netting-aware NatSpec on
      exposure/collateral views; new events
- [ ] `VaultManager` state: `_vaultBackedAsset`, `_assetRwaCollateralUSD`; RWA marks excluded
      from `_globalCollateralUSD`; `_globalExposureUSD` = Σ max(0, E_a − R_a)
- [ ] Internal helper `_renetAsset(bytes32 a)` (recompute net contribution O(1)); wire into:
      `openExposure`, `closeExposure`, `pullAssetPrice`, `haltAsset`, `pullCollateralPrice`,
      `onCollateralReleased`, `onVaultHalted`, `onVaultUnhalted`, `deregisterVault`
- [ ] `setForceExecuteVault`: add `backedAsset == 0` guard (Phase 1 cross-ref)
- [ ] Unit tests: netting math (R < E, R == E, R > E clamp), multi-wrapper sum, generic vaults
      unchanged, util-neutrality of matched changes, withdrawal gate on netted figures,
      halt/unhalt + release branches per class, deregister guard on netted util
- [ ] Invariant test: `_globalExposureUSD == Σ max(0, E_a − R_a)` and
      `_globalCollateralUSD == Σ generic marks` after any op sequence (handler update)
- [ ] `forge test -vvv` green, `forge fmt`
- [ ] **STOP — user review & commit**

## Phase 3 — ReserveVault + PSM entrypoints + AssetRegistry config

- [ ] Interfaces: `IReserveVault`, PSM additions to `IOwnMarket` + `IAssetRegistry`
      (`PsmConfig`, events, errors)
- [ ] `ReserveVault` (`src/core/ReserveVault.sol`): immutable wrapper `asset()`, `totalAssets()`,
      `releaseCollateral(to, amount)` onlyMarket (mark-sync via `onCollateralReleased` before
      transfer, mirroring OwnVault), `skimExcess(amount)` onlyOperator → treasury with the
      net-exposure-must-not-increase guard (design §4.2)
- [ ] `AssetRegistry`: `setPsmConfig(ticker, wrapper, config)` (admin; requires ReserveVault
      registered with `backedAsset == ticker`), `psmConfig` / `psmWrappers` views,
      `setLendingVaultAllowed` **deferred to Phase 4**
- [ ] **Derived conversion ratio** (design §4.3 / §8.3 — wrapper is a total-return tracker,
      ratio ≡ Ondo sValue): `ratio = mark(WRAPPER_TICKER) / mark(ASSET_TICKER)` from cached
      VaultManager marks at execution time; no stored/static ratio, no applySplit hook
- [ ] **Ratio-jump guard**: store `lastUsedRatio` per (ticker, wrapper); PSM op reverts if
      derived ratio moved > `ratioJumpBoundBps` since last use; operator
      `acknowledgeRatio(ticker, wrapper)` resets it (this is also the manual confirmation
      step after our own eToken splits and Ondo corporate actions)
- [ ] `OwnMarket.psmMint`: gates (asset active, not paused, not halted, config set + not paused,
      **wrapper mark fresh** vs `maxMarkAge`; asset-mark freshness via openExposure) → pull
      wrapper → ReserveVault (fee-on-transfer check) → `pullCollateralPrice` → `openExposure` →
      mint eToken; floor rounding
- [ ] `OwnMarket.psmRedeem`: gates (config set + not paused, **not trading-paused**;
      **allowed while halted** — frozen halt mark makes the derived ratio settle at
      haltPrice-worth of wrapper; halted redeems gate on wrapper-mark freshness only) →
      burn → `closeExposure` → `releaseCollateral`; floor rounding
- [ ] `OwnMarket.psmBackfill`: gates (config set + not paused) → transfer → `pullCollateralPrice`
- [ ] Unit tests: mint/redeem/backfill happy paths + every revert (paused asset, paused PSM,
      halted mint blocked, halted redeem **allowed** and settles at halt price, stale wrapper
      mark blocks mint + halted redeem, redeem exceeding reserve, zero amounts, unregistered
      wrapper, conversion rounding at 1-wei boundaries, wrapper decimals ≠ 18)
- [ ] Unit tests: derived ratio — sValue drift (wrapper mark rises vs asset mark: mint gives
      more eTokens per wrapper, redeem gives fewer wrapper per eToken), ratio-jump guard trips
      + operator ack path, post-`applySplit` ratio scales by N automatically with no
      AssetRegistry state change
- [ ] Unit tests: `skimExcess` (only clamped surplus spendable, guard reverts otherwise, auth;
      dividend-drift scenario: wrapper mark appreciation creates skimmable surplus — design
      §8.3.5)
- [ ] Integration test: full loop — RFQ mint → psmBackfill frees buffer → psmRedeem in-kind →
      books consistent; PSM mint → RFQ redeem cross-channel
- [ ] Invariant tests: supply == globalAssetUnits across all mint/burn paths incl. PSM;
      psmRedeem bounded by reserve; reserve leaves only via psmRedeem/skimExcess;
      matched-mint util-neutrality
- [ ] `forge test -vvv` green, `forge fmt`
- [ ] **STOP — user review & commit**

## Phase 4 — Per-asset lending-vault allowlist

- [ ] `IAssetRegistry` + `AssetRegistry`: `setLendingVaultAllowed(ticker, vault, allowed)`
      (admin), `isLendingVaultAllowed(ticker, vault)` view, event
- [ ] `BorrowManager._validateEligibility`: require own bound vault is allowed for the asset
      (composes with existing per-asset borrow blocklist)
- [ ] Decide + implement stance for existing open positions when an allowlist entry is revoked
      (borrow blocked; repay/liquidate must keep working)
- [ ] Unit tests: borrow gated per (asset, vault); repay + liquidate unaffected by revocation;
      auth; existing BorrowManager suite updated (allowlist setup in fixtures)
- [ ] `forge test -vvv` green, `forge fmt`
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
      designations; PSM configs; wrapper oracle ticker)
- [ ] Oracle service ops notes: wrapper ticker publishes **token price** (underlying × sValue —
      numerically equal to the underlying feed only while sValue = 1); runbook for Ondo
      corporate-action pause windows (≥24h notice → set `psmPaused` for the wrapper; unpause +
      `acknowledgeRatio` after Ondo re-syncs — design §8.3)
- [ ] `docs/audit-report.md`: note superseded/affected findings per audit-doc conventions
- [ ] Gas snapshot diff reviewed
- [ ] Delete this file
- [ ] **STOP — user review & commit**
