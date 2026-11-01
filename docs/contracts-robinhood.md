# eUSD — Robinhood Chain Deployment

**Network:** Robinhood Chain (chainId `4663`). All contracts verified on
[Blockscout](https://robinhoodchain.blockscout.com).

The retired stack (OwnMarket, VaultManager, PSM ReserveVaults, eTokens, AssetRegistry, lending,
OwnStakeZap) and its deployment record live on the `legacy-own-v2` branch. OwnStakingV2,
TieredBoostCalculator and MoneyPriceFeed below are being replaced by fixed-APR StakingVaults (see
the eUSD core and last sections); their code also lives on `legacy-own-v2`. The eSPY EUSDManager
below still runs on that stack (it reads the AssetRegistry and VaultManager) until its positions
wind down.

## Legacy registry and oracle

The lending vaults, the eSPY manager and the PSM read these. They stay live and unchanged until
the last legacy position closes; their code (generic address slots, `verifyPrice`, `priceMaxAge`)
lives on `legacy-own-v2`. The keeper and the oracle signer keep serving this verifier until then.

| Contract                          | Address                                      |
| --------------------------------- | -------------------------------------------- |
| ProtocolRegistry (legacy)         | `0x93e08ca467046737F75AAD4C936356c196AaA36F` |
| ChainlinkOracleVerifier (legacy)  | `0x72158ca9C5Dab08f3c470188a34c6e609fa6af9b` |

Live oracle configs (verified on-chain): 14 stock tickers (7 underlying + 7 R.\*) @ 15 min silence /
4h fresh window / 5d anchor age / 1h in-house staleness; USDG Chainlink-only (band 0, 25h fresh,
48h anchor). Design: docs/chainlink-feeds-robinhood.md; findings: audits/09-09-2026_Own_V2.pdf.

## eUSD core (2026-11-01)

Deployed from branch `deploy-contracts` commit `54e39f1` (forge 1.3.5, solc 0.8.28, optimizer 200,
cancun) via `DeployCoreRobinhood.s.sol`, `DeployEusdManagerRobinhood.s.sol` and
`DeployStakingVaultRobinhood.s.sol`. All sources verified on robin.etherscan.io (bytecode matches
the build byte for byte); the manager proxies are linked to their implementation. The deployer
holds no role: the registry's default admin is the governance Safe `0x470f…78e2` (3h transfer
delay), and every other contract is gated through the registry's ADMIN / OPERATOR roles.

| Contract                          | Address                                      |
| --------------------------------- | -------------------------------------------- |
| ProtocolRegistry                  | `0x348C42672FEf9dEcd678B631bf1D3BaEf5fD0085` |
| ChainlinkOracleVerifier           | `0x985bd81406341956411BE122ea64Fa1Cc0839F24` |
| EUSDManager implementation        | `0x3B0bb2203aFe55AD088362279c6a34b609AB9150` |
| EUSDManager A (ERC-1967 proxy)    | `0xF9c9a09ef44B9003f4E9CD76C30431389848cbF5` |
| EUSDManager B (ERC-1967 proxy)    | `0xbd0A8dea2964C61dBC225dB3C1b4cE341A0c32C2` |
| EUSDManager C (ERC-1967 proxy)    | `0x6d491928BBEc0c508A939b103753A3472b63Cc8C` |
| EUSDManager D (ERC-1967 proxy)    | `0x948df8d22c8025f587697D02b4888fE432758d0e` |
| StakingVault seUSD (eUSD)         | `0xa13A08828A78577D39e253a30E64b354D813Ade5` |
| StakingVault sMONEY ($MONEY)      | `0xB6B87Ff4BA072851d1E7E69D39eEb7341b3A5F11` |
| MoneyFeeCollector implementation  | `0x0b427Ed2ba730d721D1f06e122fe4367aF43014F` |

Each manager is one collateral risk profile minting the same eUSD. A manager is inert until the
Safe grants it eUSD `MINTER_ROLE` and adds its collateral. The Safe also sets the registry's
`oracle` and `treasury`, grants ADMIN/OPERATOR, and on the verifier calls `addSigner` and
`setChainlinkConfig` for every collateral ticker. The oracle signer signs for the new verifier's
EIP-712 domain, and the keeper pushes to both verifiers while the legacy stack lives.

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

## Fixed-APR staking (2026-11-01)

Replaces OwnStakingV2. One `StakingVault` per asset via `DeployStakingVaultRobinhood.s.sol`: seUSD
(eUSD) and sMONEY ($MONEY); addresses in the eUSD core table above. Each has an admin-set APR
(`setApr`) and cap on the staked amount that earns the full APR (`setCap`). The treasury Safe
(`registry.treasury()`) approves each vault once and the keeper (OPERATOR) tops up the reserve
weekly with `pullFromTreasury(amount)`; anyone can also add to it with `fund(amount)`. Unspent
reserve comes back with `withdrawReserve` (ADMIN). OwnStakingV2 winds down: no new
`notifyRewardAmount` batches, stakers unstake.

The fee collector is upgraded (new implementation in the eUSD core table) so the keeper's `buyBack`
sends bought $MONEY to `reserve` instead of burning it. Safe steps after deploying the new
implementation: `upgradeToAndCall(impl, "")`, `setReserve(reserve)`, and the admin-set buy-back
share (`setBurnShareBps`; the rest is paid to the payees in SPY). The keeper must call `buyBack`
instead of `buyAndBurn`.
