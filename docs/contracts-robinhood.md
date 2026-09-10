# Own Protocol v2 — Robinhood Chain Deployment

**Network:** Robinhood Chain (chainId `4663`)
**Deployed:** 2026-07-14 via `script/robinhood/` suite (branch `robinhood`, commit `12b8467`);
gen-2 market/vault stack redeployed 2026-08-03 (branch `upgrade-borrow-manager`).
**Status:** Core + assets + lending + yield automation + PSM live. All contracts verified on
[Blockscout](https://robinhoodchain.blockscout.com).

## Core contracts

| Contract                            | Address                                      |
| ----------------------------------- | -------------------------------------------- |
| ProtocolRegistry                    | `0x93e08ca467046737F75AAD4C936356c196AaA36F` |
| AssetRegistry                       | `0xDfEFfe8C385A28351Cc07a249A3B2C15Fe7b928A` |
| OwnMarket (gen-3, ERC-1967/UUPS)    | `0x5feC69cB6ADC42031570735c3B61Dc2CfEd4ee64` |
| — implementation                    | `0xd8Fd80d09E172276fe46b422Ea9DAEE2337ED2Eb` |
| — ForceExecuteLib (linked)          | `0x8b41ef72A703F413Ab98A0268d8958995cfE999D` |
| VaultManager                        | `0xfA2981bA6F5E955f3FF4c9DBd9a79Ff29015d352` |
| ETokenFactory                       | `0x21C8Ab24844101EE7A2625A7f281f7ceD679782A` |
| ChainlinkOracleVerifier (in-house)  | `0x72158ca9C5Dab08f3c470188a34c6e609fa6af9b` |
| OwnLendingPool                      | `0xaDa84daebD59053Cdbc49740E1f06F039BB4FbBa` |
| — oUSDG (aToken)                    | `0x8673efc9f9a561625b9b560a28127bCa42290143` |
| — odUSDG (debt token)               | `0xB722B898897e3221eE09C51F03935d437FfBc85e` |
| LendingRouter (`withdrawFromVault`) | `0xDB0156762acB807C84B15130b94caCd8B17C888c` |
| OwnVault (oUSDG, shares `ovUSDG`)   | `0x61f4a9008B3EF2f11993b7F969E72593Edfc8196` |
| BorrowManager (ERC-1967/UUPS proxy) | `0xfb6b4dcEe64963CB9D5dD0762504eFAd06C19860` |
| — implementation                    | `0x13De29530958A38f9b543E2DAdDC34A5EFdD03d6` |
| VaultYieldManager                   | `0xc2b96848d288d7497edcF04AA70779F9a2Ac06Ee` |

## PSM ReserveVaults

All 12 assets are PSM-backed by Gen-2 tokens. Every wrapper address was validated on-chain
(symbol/decimals/uiMultiplier) and passed the WrapperRobinhoodFork custody suite before deploy;
the script re-asserts symbol+decimals on-chain before broadcasting.

| Asset | Wrapper ticker | Gen-2 token                                  | ReserveVault                                 |
| ----- | -------------- | -------------------------------------------- | -------------------------------------------- |
| TSLA  | `R.TSLA`       | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0xD3331E0D2b8D5D82932E2A9f4B98b1F2bDC11a39` |
| MU    | `R.MU`         | `0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD` | `0x054a4ecf967A61b5994B2043bBd8cAD342a12476` |
| SPCX  | `R.SPCX`       | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | `0x130e5d3D8CC1235c9c72f479F6e343dDB29381d9` |
| MSFT  | `R.MSFT`       | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | `0x4497a1dB93c49dCce83102B28e1393ab36ffc675` |
| GOOGL | `R.GOOGL`      | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | `0x568c614A703a5B9A53fA08Fc805e7b8aDc496E19` |
| SPY   | `R.SPY`        | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | `0x2c47516319B56519ada1433701F2673877f168Ea` |
| QQQ   | `R.QQQ`        | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | `0x9a1c1E979B9D58824a5162f320533860f4A8A2BE` |
| NVDA  | `R.NVDA`       | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0x601C3C82d07079Dd3cD36727DcF46D9502a344E1` |
| AAPL  | `R.AAPL`       | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0x6C1Be50aeB4Dd0f7291579423802158da9CF4B3E` |
| AMZN  | `R.AMZN`       | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | `0xf74E57Ca6D72D282ce61649ee378eec780Eb0bD0` |
| AMD   | `R.AMD`        | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` | `0x9aD08012f3bA1a2E3E71384A2235d9320c811B2D` |
| META  | `R.META`       | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | `0x059ED684C4895A67aF8f3B7f665fC3B2B8A567Ac` |

## eTokens (12 assets, $1M cap each, all grants armed)

| Asset | eToken | Address                                      |
| ----- | ------ | -------------------------------------------- |
| MU    | eMU    | `0xBd9cD65B2E323c2E19E2814079E429f8c581747f` |
| SPCX  | eSPCX  | `0x1712272D906cf2C69141C01F7655F096ED829c7D` |
| MSFT  | eMSFT  | `0x2BFC548AB80dE31a7134BAf1D0b1b9e309d99E1B` |
| GOOGL | eGOOGL | `0xec054872FcDc5F2bAC4E5c393198B8B952792445` |
| TSLA  | eTSLA  | `0x82D2F4e0649Fc77C2dF7fcF3b6c7e50a1F2F50f4` |
| SPY   | eSPY   | `0xb9D2F8A79F59b84269Adf7d82Fe44ad41139FcF5` |
| QQQ   | eQQQ   | `0xA49938669141fEb6FD55D240bED06cCb1784Bbd4` |
| NVDA  | eNVDA  | `0x6d3eC34E847b51D719CE2fcE35D132d2e1b83E10` |
| AAPL  | eAAPL  | `0x0b198f155Ad9b440D9c934db2a987c505882670F` |
| AMZN  | eAMZN  | `0x40cba880C193BC98b958428C0F40F9fB0a9b7721` |
| AMD   | eAMD   | `0x4b7d2EF63C7B811bE100ef27adad29440883069B` |
| META  | eMETA  | `0x9a7413E4935EEc250d76D3D249aa182C608727e1` |

## Configuration (verified on-chain post-deploy)

| Parameter                               | Value                                                                 |
| --------------------------------------- | --------------------------------------------------------------------- |
| Payment token                           | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`                     |
| Global max utilization                  | 60%                                                                   |
| Settle band                             | ±5%                                                                   |
| Max mark age                            | 1 h                                                                   |
| Claim threshold                         | 0 (force-execution off)                                               |
| Pool LTV / LT                           | 75% / 100%                                                            |
| BorrowManager target LTV                | 70%                                                                   |
| Premium curve                           | base 6%, optimal 80%, slope1 2% (8% at optimal), slope2 72%           |
| Per-position borrow LTV / liq threshold | 70% / 80% (contract defaults)                                         |
| Treasury cut (yield shell)              | 10%                                                                   |
| PSM                                     | TSLA ← Gen-2 TSLA (`R.TSLA` ticker), ratio-jump bound 150 bps (armed) |
| Oracle configs                          | 7 tickers @ 1h staleness / 20% deviation; USDG @ 1d / 2%              |

## State at deploy

- Vault seeded: 100 USDG (VM `0x0e3d09603290f96e86Be1807AFADcd99C81e2a63`), collateral mark $100.
- Oracle signers rotated 2026-07-16: sole signer is now `0xa7C894ff35407Ef4b7e699D1AfBf35487BbdFeBF`
  (original KMS key `0x6Ff4…2A32` and bootstrap operator key removed; one-off script, since deleted).
- Maker rotated 2026-07-16: `0xefD77159Ff7eAE9DeaeC2F0D45e5171fb2fe2C1f` is sole VaultManager quote
  signer (self-linked settlement wallet) and maker on all 7 active tickers; old MM signer
  `0x7eAa…27e2` and operator test key fully deregistered (one-off script, since deleted).
- Governance: deployer EOA is PROTOCOL_ADMIN/ADMIN/OPERATOR (3h transfer delay). Migrate to Safe.

## Deploy sequence status

- [x] Step 0 — Preflight + Gen-2 TSLA custody fork tests + issuer admin-powers review
- [x] Step 1 — `DeployRobinhood.s.sol` (core + oracle + pool + router + vault + globals) — verified
- [x] Step 2 — `SetOracleConfigsRobinhood.s.sol` + `BootstrapUsdgPriceRobinhood.s.sol`
- [x] Step 3 — `AddAssetsRobinhood.s.sol` (7 eTokens) — verified
- [x] Step 4 — `EnableLendingRobinhood.s.sol` (BorrowManager + VaultYieldManager) — verified
- [x] Step 5 — `SeedDepositRobinhood.s.sol` (100 USDG)
- [x] Step 6 — `DeployPsmRobinhood.s.sol` (Gen-2 TSLA reserve, guard armed) — verified

## Oracle migration (Chainlink primary + band-limited in-house, 2026-07-20)

- [x] `DeployChainlinkOracleRobinhood.s.sol` — ChainlinkOracleVerifier at
      `0x72158ca9C5Dab08f3c470188a34c6e609fa6af9b`, Blockscout-verified. KMS signer authorised.
      Configs (verified on-chain): 14 stock tickers (7 underlying + 7 R.\*) @ 15min silence / 4h
      fresh window / 5d anchor age / 1h in-house staleness; bands 5% SPY+QQQ, 8% singles; no
      multiplierToken yet (all uiMultipliers 1.0 — set on underlying tickers before first
      dividend/split). USDG Chainlink-only (band 0, 25h fresh, 48h anchor). Parity vs old oracle
      at deploy: all 15 within ~1.7%. Design: docs/chainlink-feeds-robinhood.md; findings:
      docs/audit-report-3.md.
- [x] `SwitchOracleChainlinkRobinhood.s.sol` — CUTOVER LIVE 2026-07-20, tx `0x79dd1ce2…3eec4`.
      INHOUSE_ORACLE slot → `0x7215…af9b`; all 15 tickers preflighted and serving; mark-pull
      route simulated OK post-switch (TSLA / R.TSLA / USDG). Rollback:
      `registry.setAddress(INHOUSE_ORACLE, 0x654CFb0f871A6a22F184B9a3960BaA4fE3dAe055)`.
- [x] KMS signer service: repoint EIP-712 verifyingContract to `0x7215…af9b` (old-domain
      signatures are invalid there), 24/7 gap-filling (quote when feed >15min quiet, band
      pre-check), feed-age + aggregator-upgrade alerting. Until then, tickers whose feed is >4h quiet read as stale to freshness-checking consumers.

## Points program (2026-07-24)

- [x] `DeployOwnershipNftRobinhood.s.sol` — OwnershipNFT (soulbound points-program NFT) at
      `0x8fabA20d52Ea9CD636924Ce4083bB22E391f73e8`, Blockscout-verified. Standalone — no registry
      wiring. Name/symbol `Ownership NFT` / `OwnNFT`; ids start at 1; transfers disabled
      (soulbound) until governance flips `setTransfersEnabled`. Admin (DEFAULT_ADMIN_ROLE) =
      deployer EOA `0xD9eA00C71df5b50493fCbD1f7e8c5C8DbB525bD1` (rotate with the Safe migration);
      minter (MINTER_ROLE, mint-only) = points-service hot wallet
      `0x609C0364cEae808bD2f8988CCBD472681150dcf3`. baseURI
      `https://points.ownfinance.org/metadata/`, contractURI
      `https://points.ownfinance.org/collection.json` (both admin-updatable). Verified on-chain
      post-deploy: roles, soulbound state, URIs, `nextTokenId == 1`.

## eUSD stablecoin module (2026-09-09)

Deployed from branch `stablecoin` commit `8e0ce0e` via `DeployEusdRobinhood.s.sol` /
`DeployEusdStakingRobinhood.s.sol`. All sources Blockscout-verified (full match); proxy↔impl
links detected.

| Contract                       | Address                                      |
| ------------------------------ | -------------------------------------------- |
| EUSD (token)                   | `0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7` |
| EUSDManager (ERC-1967 proxy)   | `0x9748964d733Ff5d47F1d7E3fea620aF014dA5a9b` |
| — implementation               | `0xd05489B53973aba11d4bFaacB11bE659eb7C63d2` |
| StakedEUSD sEUSD (proxy)       | `0x4fefDd560c076CfE9EA0b8f4d21E60Af5A39fE96` |
| — implementation               | `0x74f5A0c905d22Ef2dc2CC7AE0390bBFEC99bE154` |

Launch parameters (verified on-chain): MCR 150% / liquidation 120% / bonus 5% / stability fee
2%/yr / debt ceiling 250k / minDebt 100 / mintPriceMaxAge 1h (matches the verifier's in-house
staleness window — minting works off-hours while the 24/7 gap-filler quotes, and self-halts if
price services go silent; exits never gated). sEUSD vesting period 8h (ADMIN-tunable).

Governance/roles (verified): EUSD DEFAULT_ADMIN = Safe `0x470f…78e2`, sole MINTER_ROLE =
manager proxy, deployer fully renounced. Launch collateral eSPY, listed + enabled via Safe
batch (also wrote registry keys `EUSD` / `EUSD_MANAGER`; note the registry has **no generic
getter** — the eUSD slots are event/storage-only, so consumers take addresses from this doc.
`STAKED_EUSD` slot deliberately not written). sEUSD incentives controller unset — OwnIncentives
deploys/attaches when the OWN token exists (`OWN_TOKEN_ROBINHOOD` unset skips it in the script).

State at deploy: canary CDP by deployer (0.3 eSPY, 110 eUSD debt, ~209% ratio); sEUSD seeded
with 1 eUSD of dead shares at `0xdead`; E2E pass via `TestEusdCdpRobinhood.s.sol` +
`TestEusdStakingRobinhood.s.sol` (stake/withdraw + 1 eUSD reward batch streaming).

Remaining ops: route treasury stability fees to sEUSD (`transferInRewards`, OPERATOR, cadence
≤ 8h); liquidation keeper + monitoring (alert on any eUSD `RoleGranted(MINTER_ROLE)`; periodic
`totalSupply == totalDebt` check); OWN incentives (deploy → attach → fund → setDistribution);
frontend handoff (addresses/ABIs from this table, EIP-7702 batch zap with sequential fallback,
show per-position liquidation price).

## Gen-3 OwnMarket — UUPS (2026-09-09, cutover 2026-09-10)

Deployed from branch `stablecoin` via `RedeployMarket3Robinhood.s.sol` (addresses in the core
table above). Behaviorally identical to gen-2 — the delta is upgradability only: ERC-1967/UUPS
proxy (`_authorizeUpgrade` = registry ADMIN, i.e. the Safe), proxy-safe EIP-712 domain, and the
force-execute path extracted into the external-linked `ForceExecuteLib`. Bare implementation is
un-initializable (asserted at deploy). This is the last market *swap* — all future market logic
changes go through `UpgradeOwnMarket.s.sol` as one-tx Safe upgrades; storage layout is
append-only from this deploy's commit.

Cutover: single Safe write `registry.setAddress(MARKET, proxy)` — every consumer (eToken
mint/burn, PSM ReserveVault custody, OwnVault/VaultManager/AssetRegistry hooks, BorrowManager
`convertLegacy`/`redeemHalted`) resolves `registry.market()` dynamically, and the gen-2 book was
empty (zero orders ever created), so nothing migrated. The maker/RFQ quote service re-points its
EIP-712 `verifyingContract` to the new proxy at cutover — quotes signed for the old market are
domain-invalid on the new one. Post-cutover smoke: rerun `TestMintBorrowTslaRobinhood` /
`TestPsmTslaRobinhood` round-trips.

Note: an orphan OwnMarket implementation from a nonce-raced first broadcast attempt exists at
the deployer's nonce-320 address — un-initializable, referenced by nothing, ignore it.

Cutover executed and verified on-chain 2026-09-10: `registry.market()` → gen-3 proxy;
functional probe (`psmRedeem` eth_call impersonating an eToken holder) confirmed the eToken
burn gate and ReserveVault release gate accept the new market.

## Asset support pause (2026-09-10)

Frontend + MM support temporarily withdrawn for **MU, AAPL, AMZN, AMD, META** (active set: TSLA,
SPCX, MSFT, GOOGL, SPY, QQQ, NVDA). All five had **zero eToken supply** — no holders, borrowers,
or liquidation exposure. On-chain action (Safe batch, verified): `setAssetCapUSD(ticker, 0)` on
the VaultManager for the five — blocks all new minting (RFQ **and** PSM) at the `openExposure`
gate while every exit stays structurally open. Deliberately NOT `setAssetTradingPaused` (gates
`psmRedeem`, the permissionless exit) and NOT `haltAsset` (permanent). With zero supply and zero
cap, the KMS price feed, mark keepers, and MM quoting can drop these tickers entirely.

Re-enable path (per asset): Safe `setAssetCapUSD(ticker, 1_000_000e18)` → resume KMS feed +
keeper + MM quoting → restore the ticker in the app address book.

## E2E smoke tests (2026-07-14, all passed)

Scripts: `TestSetupTslaRobinhood` / `TestMintBorrowTslaRobinhood` / `TestRepayRedeemTslaRobinhood` /
`TestPsmTslaRobinhood` (TSLA test mark $331, operator-signed quotes/prices).

| Test                              | Result                                                              |
| --------------------------------- | ------------------------------------------------------------------- |
| Mint $20 eTSLA (RFQ market order) | ✅ 0.060423 eTSLA, proceeds → maker linked wallet                   |
| Borrow $10 vs eTSLA               | ✅ debt on book+pool, utilization 14.28% of cap                     |
| Full repay + redeem               | ✅ zero debt, zero eTSLA supply, round-trip cost 1 μUSDG (rounding) |
| PSM mint/redeem 0.05 Gen-2 TSLA   | ✅ ratio exactly 1.0, zero dust, reserve fully drained              |

**Finding fixed during tests:** `DeployPsmRobinhood` registered `R.TSLA` without an
`OracleVerifier` config, so no wrapper mark could ever be pushed (`OracleConfigNotSet`). Config was
set on the live deploy (1h staleness / 20% deviation) and the script patched for future runs.

**Test artifacts cleanup** (operator key `0xa0d8…5b4B` was stand-in for both KMS services): all
done 2026-07-16 — `OracleVerifier.removeSigner(operator)`, `VaultManager.removeSigner(operator)`,
and `setMakerAllowed(TSLA, operator, false)` executed during the signer/maker rotations.

## Remaining ops (off-chain)

- [ ] KMS price service: publish `USDG`, 7 launch tickers, `R.TSLA` (token price × uiMultiplier) under chainId-4663 domain
- [ ] Keepers: `pullAssetPrice(ticker)` per asset, `pullCollateralPrice(reserve)` once R.TSLA feed live
- [ ] RFQ quote service live; linked settlement wallet funded with USDG
- [x] Remove operator from oracle signers (`removeSigner`) — done 2026-07-16; sole signer now `0xa7C8…FeBF`
- [ ] Small psmMint/psmRedeem round-trip before announcing
- [ ] Migrate PROTOCOL_ADMIN to Safe multisig

## Superseded contracts (reference only)

Gen-1 stack replaced by gen-2 on 2026-08-03 (gen-1→gen-2 market cutover has since executed);
gen-2 market replaced by the gen-3 UUPS proxy on 2026-09-10. The gen-1 vault is in wind-down
(withdrawal wait 0, deposits gated, lending grants revoked) and will be deregistered once fully
drained (halt first if dust holders remain). ~927 USDG of borrower debt on the gen-1
BorrowManager must be repaid there — positions do not migrate.

| Contract                                  | Address                                      |
| ----------------------------------------- | -------------------------------------------- |
| OwnMarket gen-2 (non-proxy)               | `0x448e0Abd706C84Fe2897DdDd597BA2b043F53178` |
| OwnMarket v1                              | `0xF17Ce62F389B5bAA9C24f448D329E898c8f8dEf7` |
| OwnVault v1 (oUSDG, wind-down)            | `0x246705F13bF56e3A572ae1407c065126230557FC` |
| BorrowManager v1 (non-proxy, repay-only)  | `0xa58738135ce8D44E746B04967590A831C7E01bF1` |
| VaultYieldManager v1                      | `0x2efb4f919302f9548d7E497503Fa92E5dd93f841` |
| LendingRouter v1                          | `0xf3f1f274bFe61544d3045321E2c0c84Aa40274f1` |
| OracleVerifier v1 (pre-Chainlink cutover) | `0x654CFb0f871A6a22F184B9a3960BaA4fE3dAe055` |
