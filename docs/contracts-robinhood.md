# Own Protocol v2 — Robinhood Chain Deployment

**Network:** Robinhood Chain (chainId `4663`)
**Deployed:** 2026-07-14 via `script/robinhood/` suite (branch `robinhood`, commit `12b8467`)
**Status:** Core + assets + lending + yield automation + PSM live. All contracts verified on
[Blockscout](https://robinhoodchain.blockscout.com).

## Core contracts

| Contract                          | Address                                      |
| --------------------------------- | -------------------------------------------- |
| ProtocolRegistry                  | `0x93E08Ca467046737f75aAd4C936356c196AAa36f` |
| AssetRegistry                     | `0xDfEFfe8C385A28351Cc07a249A3B2C15Fe7b928A` |
| OwnMarket                         | `0xF17Ce62F389B5bAA9C24f448D329E898c8f8dEf7` |
| VaultManager                      | `0xfA2981bA6F5E955f3FF4c9DBd9a79Ff29015d352` |
| ETokenFactory                     | `0x21C8Ab24844101eE7A2625a7f281F7cED679782a` |
| OracleVerifier (in-house)         | `0x654CFb0f871A6a22F184B9a3960BaA4fE3dAe055` |
| OwnLendingPool                    | `0xADa84DAeBD59053CDbC49740E1F06F039Bb4FbbA` |
| — oUSDG (aToken)                  | `0x8673efc9f9a561625b9B560a28127bCa42290143` |
| — odUSDG (debt token)             | `0xB722B898897e3221eE09C51f03935D437FfbC85e` |
| LendingRouter                     | `0xF3f1f274bFe61544d3045321E2c0c84Aa40274f1` |
| OwnVault (oUSDG, shares `ovUSDG`) | `0x246705F13bF56e3A572ae1407c065126230557FC` |
| BorrowManager                     | `0xa58738135ce8D44E746B04967590A831C7E01bF1` |
| VaultYieldManager                 | `0x2efb4f919302f9548d7E497503Fa92E5dd93f841` |

## PSM ReserveVaults (batch 2026-07-14, `DeployPsmAssetsRobinhood.s.sol`)

All 7 launch assets are PSM-backed by Gen-2 tokens. Every wrapper address was validated on-chain
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

## eTokens (7 launch assets, $1M cap each, all grants armed)

| Asset | eToken | Address                                      |
| ----- | ------ | -------------------------------------------- |
| MU    | eMU    | `0xBd9cD65B2E323c2E19E2814079E429f8c581747f` |
| SPCX  | eSPCX  | `0x1712272D906cf2C69141C01F7655F096ED829c7D` |
| MSFT  | eMSFT  | `0x2BFC548AB80dE31a7134BAf1D0b1b9e309d99E1B` |
| GOOGL | eGOOGL | `0xec054872FcDc5F2bAC4E5c393198B8B952792445` |
| TSLA  | eTSLA  | `0x82D2F4e0649Fc77C2dF7fcF3b6c7e50a1F2F50f4` |
| SPY   | eSPY   | `0xb9D2F8A79F59b84269Adf7d82Fe44ad41139FcF5` |
| QQQ   | eQQQ   | `0xA49938669141fEb6FD55D240bED06cCb1784Bbd4` |

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
- Operator key temporarily added as oracle signer for the USDG bootstrap — **remove once KMS is sole signer**.
- Governance: deployer EOA is PROTOCOL_ADMIN/ADMIN/OPERATOR (3h transfer delay). Migrate to Safe.

## Deploy sequence status

- [x] Step 0 — Preflight + Gen-2 TSLA custody fork tests + issuer admin-powers review
- [x] Step 1 — `DeployRobinhood.s.sol` (core + oracle + pool + router + vault + globals) — verified
- [x] Step 2 — `SetOracleConfigsRobinhood.s.sol` + `BootstrapUsdgPriceRobinhood.s.sol`
- [x] Step 3 — `AddAssetsRobinhood.s.sol` (7 eTokens) — verified
- [x] Step 4 — `EnableLendingRobinhood.s.sol` (BorrowManager + VaultYieldManager) — verified
- [x] Step 5 — `SeedDepositRobinhood.s.sol` (100 USDG)
- [x] Step 6 — `DeployPsmRobinhood.s.sol` (Gen-2 TSLA reserve, guard armed) — verified

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

**Test artifacts to clean up before public launch** (operator key `0xa0d8…5b4B` was stand-in for
both KMS services): `VaultManager.removeSigner(operator)` + `setMakerAllowed(TSLA, operator, false)`

- `OracleVerifier.removeSigner(operator)` once the real KMS quote + price signers are live.

## Remaining ops (off-chain)

- [ ] KMS price service: publish `USDG`, 7 launch tickers, `R.TSLA` (token price × uiMultiplier) under chainId-4663 domain
- [ ] Keepers: `pullAssetPrice(ticker)` per asset, `pullCollateralPrice(reserve)` once R.TSLA feed live
- [ ] RFQ quote service live; linked settlement wallet funded with USDG
- [ ] Remove operator from oracle signers (`removeSigner`) once KMS is sole signer
- [ ] Small psmMint/psmRedeem round-trip before announcing
- [ ] Migrate PROTOCOL_ADMIN to Safe multisig
