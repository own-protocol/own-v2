# eUSD — Robinhood Chain Deployment

**Network:** Robinhood Chain (chainId `4663`). All contracts verified on
[Blockscout](https://robinhoodchain.blockscout.com).

The retired stack (OwnMarket, VaultManager, PSM ReserveVaults, eTokens, AssetRegistry, lending,
OwnStakeZap) and its deployment record live on the `legacy-own-v2` branch. The eSPY EUSDManager
below still runs on that stack (it reads the AssetRegistry and VaultManager) until its positions
wind down.

## Shared contracts

| Contract                           | Address                                      |
| ---------------------------------- | -------------------------------------------- |
| ProtocolRegistry                   | `0x93e08ca467046737F75AAD4C936356c196AaA36F` |
| ChainlinkOracleVerifier (in-house) | `0x72158ca9C5Dab08f3c470188a34c6e609fa6af9b` |

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

## eUSD stablecoin module (2026-09-09)

Deployed from branch `stablecoin` commit `8e0ce0e` via `DeployEusdRobinhood.s.sol` /
`DeployEusdStakingRobinhood.s.sol`. All sources Blockscout-verified (full match); proxy↔impl
links detected.

| Contract                          | Address                                      |
| --------------------------------- | -------------------------------------------- |
| EUSD (token)                      | `0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7` |
| EUSDManager (ERC-1967 proxy)      | `0x9748964d733Ff5d47F1d7E3fea620aF014dA5a9b` |
| — implementation (v3, 2026-09-18) | `0x8f0EB3331Da1ba72A7451601fc9e197D6551674e` |
| OwnStakingV2 (ERC-1967 proxy)     | `0xfD1CC0751D5d9C0D5f9eAd6b8525FdEe22423b76` |
| — implementation                  | `0xF524E4855F36592d10D6c869f10Ecd652a6C7801` |
| OwnStakeZap (ERC-1967 proxy)      | `0xE28423b4CA87cB9e822E99325A09A9457291e8fa` |
| — implementation                  | `0xf98D894Dc4A0C01B59eb30CF4B7750111cc5FF52` |
| TieredBoostCalculator (live)      | `0x00434cfc44e5f30295c14d9f98b8763787db2613` |
| LinearBoostCalculator (retired)   | `0xc23E6e6EaE9551014c479123E2cc6e4B1c9233D2` |
| MoneyPriceFeed                    | `0x31283f38ec6e63AC9A5b2C37563eD31F708411EE` |

TieredBoostCalculator (2026-09-25, `DeployTieredBoostCalculatorRobinhood.s.sol`): tiers <$10k 3.0,
$10k 2.0, $25k 1.0, $50k 0.2, $100k+ 0.1 full-boost coverage; 0.1× floor, 3.6× max. Swapped in via
governance Safe batch `setBoostCalculator` + `refreshBoost(all 39 stakers)`. Etherscan-verified
(robin.etherscan.io) along with the EUSD, EUSDManager and OwnStakingV2 proxies and implementations.

MoneyPriceFeed: keeper-pushed $MONEY TWAP mark behind the AggregatorV3 surface, for OwnStakingV2 boost pricing. Pending Safe call wires it as the
MONEY aggregator: `setChainlinkConfig(MONEY, feed, 0, 900, 5400, 86400, 0, 0)` — `bandBps = 0`
keeps the signer leg off (pushed mark is the only source); `clFreshWindow` 90 min tracks the
cadence; alert if no push lands for > 90 min. Staking's `priceMaxAge` is 24h (initialize
default), coinciding with `maxAnchorAge`.

Launch parameters (verified on-chain): MCR 150% / liquidation 120% / bonus 5% / stability fee
2%/yr / debt ceiling 250k / minDebt 100 / mintPriceMaxAge 1h (matches the verifier's in-house
staleness window — minting works off-hours while the 24/7 gap-filler quotes, and self-halts if
price services go silent; exits never gated).

Governance/roles (verified): EUSD DEFAULT_ADMIN = Safe `0x470f…78e2`, sole MINTER_ROLE =
manager proxy, deployer fully renounced. Launch collateral eSPY, listed + enabled via Safe
batch (also wrote registry keys `EUSD` / `EUSD_MANAGER`; note the registry has **no generic
getter** — the eUSD slots are event/storage-only, so consumers take addresses from this doc.
`STAKED_EUSD` slot deliberately not written).

State at deploy: canary CDP by deployer (0.3 eSPY, 110 eUSD debt, ~209% ratio); sEUSD seeded
with 1 eUSD of dead shares at `0xdead`; E2E pass via `TestEusdCdpRobinhood.s.sol` +
`TestEusdStakingRobinhood.s.sol` (stake/withdraw + 1 eUSD reward batch streaming).

Remaining ops: liquidation keeper + monitoring (alert on any eUSD `RoleGranted(MINTER_ROLE)`;
periodic `totalSupply == totalDebt` check); frontend handoff (addresses/ABIs from this table,
EIP-7702 batch zap with sequential fallback, show per-position liquidation price).

## EUSDManager v3 — closePositionPrincipalOnly (2026-09-18)

Deployed from branch `update-eusdmanager` via `UpgradeEusdManagerRobinhood.s.sol`; proxy switched
via governance Safe `upgradeToAndCall(v3, "")`. Adds `closePositionPrincipalOnly` (accrued fees
settled in collateral at the anchor price, treasury's fee eUSD burned in the same amount) and the
append-only `Position.feesAccrued` field. Post-upgrade checks passed: implementation slot,
`totalDebt == eusd.totalSupply()`, `stakeZap`, risk params, and the eSPY head position intact
with `feesAccrued == 0`.

Operational notes: fee tracking starts at this upgrade — fees folded into debt before it settle
in eUSD like principal. The treasury must retain an eUSD float covering outstanding
`feesAccrued` (and migrate its balance before any treasury address rotation) or the
principal-only path reverts; `closePosition` remains the fallback.

## $MONEY staking (2026-09-16)

Deployed from branch `OwnStakingV2` via `UpgradeEusdManagerRobinhood.s.sol` +
`DeployMoneyStakingRobinhood.s.sol`. Wiring (manager upgrade, `setStakeZap`, `setZap`) executes
via a governance Safe batch (executed 2026-09-16, incl. a Safe signer rotation); SPY reward
allowance via a treasury Safe approval. Addresses live in the eUSD stablecoin module table
above. sEUSD staking is deprecated by this deploy — withdraw-only, no new reward batches.

An accidental duplicate broadcast (same block-window, nonces 0x156–0x15a) deployed a second,
unused set — staking proxy `0x7fe0…1df2`, zap proxy `0x187d…60c2`, calculator `0xea73…aba7`.
Never wire or fund these; the table above is canonical.

## $MONEY fee collector (2026-09-14)

Deployed from branch `FeeCollector` via `DeployMoneyFeeCollectorRobinhood.s.sol`. Routes Pons
V2 trading fees of the $MONEY pair: 70% to payees, 30% held as burn reserve; keepers
buy-and-burn $MONEY through allow-listed venues, capped at `burnSpendBps` (10%) of held
balance per `burnInterval` (1h). $MONEY pair fees accrue in SPY — collection is
`collectFees([SPY])`.

| Contract                                | Address                                      |
| --------------------------------------- | -------------------------------------------- |
| MoneyFeeCollector (ERC-1967/UUPS proxy) | `0xB6BCAfB905CE0648A71F6d43155d5D53a2B08154` |
| — implementation                        | `0x918D34E4Cc32363267b034c32e01Eb495f009A2c` |
| $MONEY token (own.money)                | `0x0a8B4763C71aC39101b3B8a97e62Da0B81549a4f` |
| Pons V2 swap venue (SPY↔$MONEY)         | `0x65050A9b7E5075A2bA5cED7b1b64EE66262c40Dc` |

The Pons V2 swap venue is the canonical SPY↔$MONEY router for protocol integrations: the fee
collector's allow-listed `buyAndBurn` target (verified on-chain 2026-09-16 from its hourly
keeper txs) and the `OwnStakeZap` swap router (`SWAP_ROUTER` in
`DeployMoneyStakingRobinhood.s.sol`). It is a TransparentUpgradeableProxy controlled by Pons,
not the protocol — integrations must confine it (exact JIT allowance + min-out delta check, as
both existing consumers do) and any future consumer should reuse this address rather than
introducing a second venue.
