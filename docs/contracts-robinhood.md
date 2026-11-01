# eUSD | Robinhood Chain Deployment

**Network:** Robinhood Chain (chainId `4663`). All contracts below are verified on
[robin.etherscan.io](https://robin.etherscan.io).

Deployed 2026-11-01 from branch `deploy-contracts` commit `54e39f1` (forge 1.3.5, solc 0.8.28,
optimizer 200, cancun) with `DeployCoreRobinhood.s.sol`, `DeployEusdManagerRobinhood.s.sol` and
`DeployStakingVaultRobinhood.s.sol`. Older contracts are listed in
[legacy-contracts-rh.md](legacy-contracts-rh.md); their code is on the `legacy-own-v2` branch.

## Contracts

| Contract                                 | Address                                      |
| ---------------------------------------- | -------------------------------------------- |
| EUSD (token, deployed 2026-09-09)        | `0x8B84D644CECaeE6d21373F37E1bA00f85eD7CdB7` |
| ProtocolRegistry                         | `0x348C42672FEf9dEcd678B631bf1D3BaEf5fD0085` |
| ChainlinkOracleVerifier                  | `0x985bd81406341956411BE122ea64Fa1Cc0839F24` |
| EUSDManager A (ERC-1967 proxy)           | `0xF9c9a09ef44B9003f4E9CD76C30431389848cbF5` |
| EUSDManager B (ERC-1967 proxy)           | `0xbd0A8dea2964C61dBC225dB3C1b4cE341A0c32C2` |
| EUSDManager C (ERC-1967 proxy)           | `0x6d491928BBEc0c508A939b103753A3472b63Cc8C` |
| EUSDManager D (ERC-1967 proxy)           | `0x948df8d22c8025f587697D02b4888fE432758d0e` |
| EUSDManager implementation (shared)      | `0x3B0bb2203aFe55AD088362279c6a34b609AB9150` |
| StakingVault seUSD (stakes eUSD)         | `0xa13A08828A78577D39e253a30E64b354D813Ade5` |
| StakingVault sMONEY (stakes $MONEY)      | `0xB6B87Ff4BA072851d1E7E69D39eEb7341b3A5F11` |
| MoneyFeeCollector (ERC-1967/UUPS proxy)  | `0xB6BCAfB905CE0648A71F6d43155d5D53a2B08154` |
| MoneyFeeCollector implementation (new)   | `0x0b427Ed2ba730d721D1f06e122fe4367aF43014F` |
| $MONEY (token)                           | `0x0a8B4763C71aC39101b3B8a97e62Da0B81549a4f` |

## Managers A–D

Each EUSDManager holds one collateral risk group with its own risk params, and all four mint the
same eUSD. Riskier collateral needs a higher collateral ratio. Read a manager's params with
`riskParams()`.

| Manager | Risk group       | Collateral (Robinhood stock tokens, WETH)            |
| ------- | ---------------- | ---------------------------------------------------- |
| A       | Index and gold   | SPY, QQQ, GLD                                        |
| B       | ETH              | WETH                                                 |
| C       | Big tech         | NVDA, META, GOOGL, AAPL, TSLA, AMZN                  |
| D       | High volatility  | SPCX, MSTR, CRCL, MU, PLTR                           |

## Roles

The deployer holds no role. The registry's default admin is the governance Safe
`0x470f35a7e5d4Cd490D74799AC01E7bEea7F478e2` (3h transfer delay). Every other contract is gated
through the registry's roles:

- **ADMIN** (governance Safe): collateral listing, risk params, APR and cap, upgrades.
- **OPERATOR** (governance Safe and the keeper): pause minting, top up the staking vaults with
  `pullFromTreasury`.
- **Treasury** (`registry.treasury()`): the treasury Safe
  `0x8f974d82EEaa9725ecC40600f12093B14080dA54`. It receives stability fees and funds staking
  rewards.
- **eUSD `MINTER_ROLE`**: the four managers only.

## Oracle

The verifier prices every collateral ticker from Chainlink and accepts a signed in-house price
from the oracle signer within a band around the Chainlink anchor, so mints keep working outside
market hours. The keeper pushes the signed prices. Feed list:
[chainlink-feeds-robinhood.md](chainlink-feeds-robinhood.md).

## Staking

One fixed-APR `StakingVault` per asset: seUSD (eUSD) and sMONEY ($MONEY). Each has an admin-set
APR (`setApr`) and a cap on the staked amount that earns the full APR (`setCap`); above the cap the
APR is shared. The treasury Safe approves each vault once, and the keeper tops up the reward
reserve weekly with `pullFromTreasury(amount)`. Anyone can add rewards with `fund(amount)`, and
unspent rewards come back with `withdrawReserve` (ADMIN).

## $MONEY fee collector

Routes the Pons V2 trading fees of the $MONEY pair. The keeper's `buyBack` buys $MONEY with the
admin-set share of the fees (`setBurnShareBps`) and sends it to `reserve`. The rest is paid to the
payees in SPY. Swaps go through the Pons V2 venue `0x65050A9b7E5075A2bA5cED7b1b64EE66262c40Dc`.
