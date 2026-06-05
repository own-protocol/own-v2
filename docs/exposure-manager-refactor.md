# ExposureManager Refactor — Implementation Handoff

> Temporary working doc. Self-contained spec to implement the pooled-exposure refactor in a fresh
> session. Delete once the work lands.

## Starting state

- Branch: `lending`, at commit `b3bc3f6` ("feat: optimize vault code").
- Working tree clean except this doc (untracked). No code written yet — start from the interface
  surface below.
- Full test suite is green (554 tests) at `b3bc3f6`.
- Already shipped earlier this session (do NOT redo): fee removal + `shareYield` + ERC-4626
  `_decimalsOffset()=6` + deposit `minSharesOut` + `EnumerableSet` pending queues + lending-fee
  surplus routed to the VM with `LendingFeeAccrued`.

## Goal

Move all exposure / utilisation / collateral-valuation accounting **out of per-vault `OwnVault`**
into one central **`ExposureManager`** that pools risk globally. Vaults keep custody + LP shares +
yield + lending; the manager owns risk.

### Why
1. Fixes two real bugs in the current per-vault mint check (see `_settleMint` in `OwnMarket.sol`):
   - the projected-utilisation check (`_totalExposureUSD + additionalExposureUSD`) diverges from how
     `updateExposure` actually re-marks the whole asset book → a mint can pass the check yet land
     utilisation above `maxUtilization`;
   - the check reads a stale/uninitialised `_collateralValueUSD` (never refreshed before the check),
     so the first mint in a fresh vault bypasses the cap entirely.
   The mark-based central model makes check == committed state **by construction**.
2. Global exposure management + a real per-asset issuance ceiling (currently nothing caps total
   eTSLA across vaults).
3. Slims `OwnVault` (bytecode — the `OwnVaultDeployer` is the tight contract at ~2 KB margin).
4. Makes vaults swappable (risk state no longer tied to a vault's lifecycle).

## Locked design decisions

- **Pooled backing/solvency (global), isolated custody/yield (separate ERC-4626 vaults per
  collateral type, ~5–6 total).** Only the risk math pools.
- **Accepted tradeoff:** cross-VM loss mutualisation. A VM default's shortfall is covered by the
  global pool (all vaults' LPs), Maker-style. This strengthens the eToken's backing; LP risk is
  mutualised. Confirmed acceptable.
- **Keeper-cached marks (Maker `spot`-style).** Per-asset price marks + per-vault collateral marks,
  refreshed by **permissionless** pokes. Exposure/collateral are valued ONLY at marks, never at
  trade prices. Staleness between pokes is absorbed by the global utilisation buffer.
- **O(1) everywhere.** `globalExposureUSD` and `globalCollateralUSD` are running totals updated on
  every open/close/poke. No loops over vaults or assets on any path.
- **Exposure is purely global per-asset.** No `(vault, asset)` attribution. No "a vault may only
  close what it opened" constraint (that was an isolated-model artifact; under pooling a VM filling
  any redeem just reduces global exposure).
- **Two caps, both O(1):**
  1. **Global utilisation cap** — solvency: `globalExposureUSD / globalCollateralUSD ≤ maxBps`.
  2. **Per-asset USD cap** — concentration: `globalAssetUnits[asset] × mark ≤ assetCapUSD[asset]`.
     `assetCapUSD == 0` means **minting blocked** (safe default; admin must set a ceiling to enable).
  - **No per-vault caps** (5–6 admin-vetted vaults; global + per-asset + halt/deregister suffice).
- **Caps + global max-util are admin-set.** Registration is factory-driven (see below).
- **Drop per-vault asset registration.** Remove `enableAsset`/`disableAsset`/`isAssetSupported`/
  `_supportedAssets` from the vault. The **global `AssetRegistry`** governs which assets are valid
  for ALL vaults automatically. `OwnMarket._validateVaultAndAsset` keeps the
  `AssetRegistry.isActiveAsset` check and drops the `IOwnVault.isAssetSupported` check.

## New contract: `src/core/ExposureManager.sol` (SPDX BUSL-1.1)

First create the interface `src/interfaces/IExposureManager.sol` (SPDX MIT) from the surface below,
then implement against it.

### Interface surface (`IExposureManager`)
```solidity
// Events
event VaultRegistered(address indexed vault, bytes32 indexed collateralAsset);
event VaultDeregistered(address indexed vault);
event ExposureOpened(address indexed vault, bytes32 indexed asset, uint256 units, uint256 markUSD);
event ExposureClosed(address indexed vault, bytes32 indexed asset, uint256 units, uint256 markUSD);
event AssetPricePoked(bytes32 indexed asset, uint256 oldMark, uint256 newMark);
event CollateralPoked(address indexed vault, uint256 oldMarkUSD, uint256 newMarkUSD);
event AssetCapUpdated(bytes32 indexed asset, uint256 capUSD);
event GlobalMaxUtilizationUpdated(uint256 oldBps, uint256 newBps);

// Errors
error OnlyMarket(); error OnlyFactory(); error OnlyAdmin();
error ZeroAddress(); error ZeroAmount();
error VaultNotRegistered(address vault); error VaultAlreadyRegistered(address vault);
error AssetCapBreached(bytes32 asset, uint256 attemptedUSD, uint256 capUSD);
error GlobalUtilizationBreached(uint256 projectedBps, uint256 maxBps);
error InsufficientExposure(bytes32 asset, uint256 have, uint256 want);
error CollateralNotInitialized(); error PriceUnavailable(bytes32 asset);
error DeregisterWouldBreachUtilization();

// Mutation — market only
function openExposure(address vault, bytes32 asset, uint256 units) external;   // atomic check+commit
function closeExposure(address vault, bytes32 asset, uint256 units) external;
// Keeper — permissionless
function pokeAssetPrice(bytes32 asset) external;
function pokeCollateral(address vault) external;
// Registration — factory only
function registerVault(address vault, bytes32 collateralAsset) external;
function deregisterVault(address vault) external;
// Admin
function setAssetCapUSD(bytes32 asset, uint256 capUSD) external;
function setGlobalMaxUtilizationBps(uint256 bps) external;
// Views
function withdrawalBreachesUtil(address vault, uint256 assets) external view returns (bool);
function globalUtilizationBps() external view returns (uint256);
function globalExposureUSD() external view returns (uint256);
function globalCollateralUSD() external view returns (uint256);
function assetMark(bytes32 asset) external view returns (uint256);
function collateralMark(address vault) external view returns (uint256);
function globalAssetUnits(bytes32 asset) external view returns (uint256);
function assetCapUSD(bytes32 asset) external view returns (uint256);
function globalMaxUtilizationBps() external view returns (uint256);
function isRegisteredVault(address vault) external view returns (bool);
```

### State
```
IProtocolRegistry public immutable registry;
uint256 public globalMaxUtilizationBps;
uint256 private _globalExposureUSD;                      // running Σ globalAssetUnits[a]×assetMark[a]/1e18
uint256 private _globalCollateralUSD;                    // running Σ collateralMark[vault]
mapping(bytes32 => uint256) private _assetMark;          // 18-dec USD per 18-dec unit
mapping(bytes32 => uint256) private _globalAssetUnits;   // total outstanding eTokens per asset
mapping(bytes32 => uint256) private _assetCapUSD;        // per-asset issuance ceiling (0 = blocked)
mapping(address => bool)    private _registered;
mapping(address => bytes32) private _vaultCollateralAsset;
mapping(address => uint256) private _collateralScale;    // 10**(18-collateralDecimals), cached at register
mapping(address => uint256) private _collateralMark;     // 18-dec USD per vault
```

### Auth
- `openExposure` / `closeExposure`: `onlyMarket` (`msg.sender == registry.market()`).
- `registerVault` / `deregisterVault`: `onlyFactory` (`msg.sender == registry.vaultFactory()`).
- `setAssetCapUSD` / `setGlobalMaxUtilizationBps`: `onlyAdmin` (`Ownable(address(registry)).owner()`).
- `pokeAssetPrice` / `pokeCollateral`: permissionless.
- No `ReentrancyGuard` needed — no external calls into untrusted code; oracle/vault reads are views.

### Algorithms (all O(1))
```
openExposure(vault, asset, units):
  require _registered[vault]                         else VaultNotRegistered
  require units != 0                                 else ZeroAmount
  mark = _assetMark[asset]; require mark != 0        else PriceUnavailable
  require _globalCollateralUSD != 0                  else CollateralNotInitialized
  newUnits   = _globalAssetUnits[asset] + units
  newAssetUSD = newUnits.mulDiv(mark, 1e18)
  cap = _assetCapUSD[asset]; require newAssetUSD <= cap   else AssetCapBreached
  addUSD = units.mulDiv(mark, 1e18)
  projExposure = _globalExposureUSD + addUSD
  projUtil = projExposure.mulDiv(BPS, _globalCollateralUSD)
  require projUtil <= globalMaxUtilizationBps         else GlobalUtilizationBreached
  // commit
  _globalAssetUnits[asset] = newUnits
  _globalExposureUSD = projExposure
  emit ExposureOpened(vault, asset, units, mark)

closeExposure(vault, asset, units):
  require units != 0                                  else ZeroAmount
  have = _globalAssetUnits[asset]; require have >= units  else InsufficientExposure
  mark = _assetMark[asset]
  _globalAssetUnits[asset] = have - units
  _globalExposureUSD -= units.mulDiv(mark, 1e18)       // no underflow: term is part of the sum
  emit ExposureClosed(vault, asset, units, mark)

pokeAssetPrice(asset):
  price = _resolvePrice(asset); require price != 0     else PriceUnavailable
  old = _assetMark[asset]; u = _globalAssetUnits[asset]
  _globalExposureUSD = _globalExposureUSD - u.mulDiv(old,1e18) + u.mulDiv(price,1e18)
  _assetMark[asset] = price; emit AssetPricePoked(asset, old, price)

pokeCollateral(vault):
  require _registered[vault]                           else VaultNotRegistered
  price = _resolvePrice(_vaultCollateralAsset[vault]); require price != 0 else PriceUnavailable
  newMark = (IERC4626(vault).totalAssets() * _collateralScale[vault]).mulDiv(price, 1e18)
  old = _collateralMark[vault]
  _globalCollateralUSD = _globalCollateralUSD - old + newMark
  _collateralMark[vault] = newMark; emit CollateralPoked(vault, old, newMark)

registerVault(vault, collateralAsset):  // onlyFactory
  require vault != 0 else ZeroAddress; require !_registered[vault] else VaultAlreadyRegistered
  _registered[vault] = true
  _vaultCollateralAsset[vault] = collateralAsset
  _collateralScale[vault] = 10 ** (18 - IERC20Metadata(IERC4626(vault).asset()).decimals())
  emit VaultRegistered(vault, collateralAsset)

deregisterVault(vault):  // onlyFactory
  require _registered[vault] else VaultNotRegistered
  // removing this collateral must not breach global util
  projCollateral = _globalCollateralUSD - _collateralMark[vault]
  if (_globalExposureUSD != 0):
     require projCollateral != 0 && _globalExposureUSD.mulDiv(BPS, projCollateral) <= globalMaxUtilizationBps
        else DeregisterWouldBreachUtilization
  _globalCollateralUSD = projCollateral
  delete _collateralMark[vault]; delete _registered[vault]; (clear collateralAsset/scale)
  emit VaultDeregistered(vault)

withdrawalBreachesUtil(vault, assets) view -> bool:
  ta = IERC4626(vault).totalAssets(); if ta == 0 return true
  releasedUSD = _collateralMark[vault].mulDiv(assets, ta)
  projCollateral = _globalCollateralUSD - releasedUSD     // floor at 0
  if projCollateral == 0 return _globalExposureUSD != 0
  return _globalExposureUSD.mulDiv(BPS, projCollateral) > globalMaxUtilizationBps

globalUtilizationBps() view:
  if _globalCollateralUSD == 0 return _globalExposureUSD == 0 ? 0 : type(uint256).max
  return _globalExposureUSD.mulDiv(BPS, _globalCollateralUSD)

_resolvePrice(asset) view -> uint256:
  oType = IAssetRegistry(registry.assetRegistry()).getOracleType(asset)
  oracle = oType == 0 ? registry.pythOracle() : registry.inhouseOracle()
  (price,) = IOracleVerifier(oracle).getPrice(asset)   // cached last-verified price, mirrors OwnVault
```
`BPS`/`PRECISION` from `interfaces/types/Types.sol`. Use OZ `Math.mulDiv`.

## `OwnVault` + `IOwnVault` changes

**Remove** (now lives in the manager):
- State: `_assetExposure`, `_assetExposureUSD`, `_assetLastUpdated`, `_totalExposureUSD`,
  `_collateralValueUSD`, `_collateralOracleAsset`, `_maxUtilization`, `_supportedAssets`.
- Functions: `updateExposure`, `updateAssetValuation`, `updateCollateralValuation`, `healthFactor`,
  `utilization`, `projectedUtilization`, `projectedExposureUtilization`, `maxUtilization`,
  `setMaxUtilization`, `totalExposureUSD`, `collateralValueUSD`, `assetExposure`, `assetExposureUSD`,
  `assetLastUpdated`, `_refreshCollateralValue`, `_getOracleForAsset`, `collateralOracleAsset`,
  `setCollateralOracleAsset`, `enableAsset`, `disableAsset`, `isAssetSupported`.
- The `shareYield` call to `_refreshCollateralValue()` is removed (manager owns collateral marks now;
  `shareYield` just transfers collateral in + emits).
- Their events/errors in `IOwnVault` (AssetValuationUpdated, CollateralValuationUpdated,
  AssetEnabled/Disabled, CollateralValueNotInitialized, etc.) — prune the now-unused ones.

**Rewire:** `fulfillWithdrawal` replaces its local utilisation block with:
`if (IExposureManager(registry.exposureManager()).withdrawalBreachesUtil(address(this), assets)) revert MaxUtilizationExceeded(...)`.

**Keep:** ERC-4626 custody + `_decimalsOffset()=6`, async deposit/withdrawal queues (EnumerableSet),
`shareYield`, lending opt-in, status/halt, payment token, quote signers, `releaseCollateral`,
`setVM`, `requireDepositApproval`.

> Constructor: drop `maxUtilBps` param (utilisation is global now). Update `OwnVaultDeployer`,
> `VaultFactory.createVault`, `IVaultFactory`, and all callers.

## `OwnMarket` + `IOwnMarket` changes

- `_settleMint`: replace the `projectedExposureUtilization` + `updateExposure` pair with a single
  `IExposureManager(registry.exposureManager()).openExposure(vault, asset, eTokenAmount)` (atomic
  check+commit). Keep mint of eTokens + stablecoin routing to VM.
- `_settleRedeem` and the force-execute redeem path: replace `vault.updateExposure(asset, -units, price)`
  with `manager.closeExposure(vault, asset, units)`.
- `_validateVaultAndAsset`: keep `AssetRegistry.isActiveAsset`; drop the `IOwnVault.isAssetSupported`
  check.

## Registry / factory / deploy wiring

- `ProtocolRegistry` + `IProtocolRegistry`: add `EXPOSURE_MANAGER` key + `exposureManager()` getter.
- `VaultFactory.createVault`: add a `bytes32 collateralAsset` (oracle ticker) param; after deploying
  the vault, call `exposureManager.registerVault(vault, collateralAsset)`. `deregisterVault`
  (rename/extend the existing `deregisterVault`) also calls the manager.
- `Deploy.s.sol`: deploy `ExposureManager(registry)`, register it
  (`registry.setAddress(EXPOSURE_MANAGER, ...)`), set an initial `globalMaxUtilizationBps`, and set
  `assetCapUSD` for each launched asset.

## Tests

- **New** `test/unit/ExposureManager.t.sol`: open/close happy + reverts (asset cap, global util,
  insufficient exposure, zero-collateral `CollateralNotInitialized`, unpoked-price `PriceUnavailable`),
  poke math updates running totals, `withdrawalBreachesUtil`, `onlyMarket`/`onlyFactory`/`onlyAdmin`
  guards, deregister util gate, `assetCapUSD==0` blocks minting.
- **Update** every test that used vault exposure/util/asset-registration: `OwnVault.t.sol`,
  `OwnMarket.t.sol`, all integration flows, fork tests. `setUp` must deploy + register + **poke** the
  manager (collateral + asset marks) before mints, and set `assetCapUSD` + `globalMaxUtilizationBps`.
  Drop `enableAsset`/`setCollateralOracleAsset`/`setMaxUtilization`/`updateExposure` usage.
- **Invariants** (`OwnProtocolInvariant.t.sol`): replace the per-vault exposure invariant with
  globals — e.g. `globalAssetUnits[asset] == eToken.totalSupply()` and
  `globalExposureUSD == Σ globalAssetUnits[a] × assetMark[a] / 1e18`, plus
  `globalUtilizationBps ≤ max` (or vault halted).
- Add a regression test that previously failed: a mint that passes today's per-vault check but
  would land util > max — under the manager it must revert.
- `forge build` + `forge test` green; `forge fmt`.

## Build order (suggested)
1. `ExposureManager.sol` + `ExposureManager.t.sol` (TDD, isolated — mock registry/oracle/vault).
2. Registry `EXPOSURE_MANAGER` wiring.
3. Slim `OwnVault` (+ `IOwnVault`, deployer, factory, `IVaultFactory`).
4. Rewire `OwnMarket`.
5. Factory auto-register + `Deploy.s.sol`.
6. Fix all existing tests + invariants; green.

## Watch-outs
- Order of operations in `_settleMint`: call `openExposure` (effect/guard) before external token
  transfers; revert unwinds cleanly.
- `withdrawalBreachesUtil` reads the cached collateral mark — only as fresh as the last poke; that's
  intended (keeper model + util buffer).
- `globalAssetUnits[asset]` must equal the eToken's `totalSupply` for that asset — useful invariant
  and a sanity check while wiring `open`/`close`.
- A new asset can't be minted until BOTH its price is poked (`assetMark != 0`) and `assetCapUSD > 0`.
  Document this in deploy/runbook.
