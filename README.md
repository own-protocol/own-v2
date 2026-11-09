# Own | eUSD

**eUSD** is an overcollateralized stablecoin on Robinhood Chain. Users deposit Robinhood stock tokens
or WETH into an **EUSDManager** and mint eUSD against a fresh oracle price. Each manager holds one
risk group of collateral with its own parameters, and every manager mints the same eUSD.

- **Mint** against collateral at or above the manager's minimum collateral ratio.
- **Repay / close** any time, including when markets are closed (exits use the last oracle price).
- **Liquidate** positions below the liquidation threshold; anyone can call it and earns a fixed bonus.
- **Redeem** eUSD for $1 of a chosen collateral, taken from that collateral's riskiest positions.
- A fixed annual **stability fee** accrues on debt and is minted to the treasury, keeping
  eUSD supply equal to total debt across managers.

**EUSDLiquidityManager** mints eUSD against concentrated-liquidity positions in asset/eUSD DEX pools.
Each user gets one vault per pool (a beacon proxy of a DEX adapter: `FablesAdapter` for Fables, a
Uniswap v4 fork, or `AerodromeAdapter` for Aerodrome Slipstream). The vault holds the range, and the
eUSD minted for it goes into the range, never to the user's wallet. The position is valued at the
oracle price, a lower bound for the range at any pool price. Liquidity staked in the DEX gauge earns
emissions and pays the staked fee; unstaked liquidity keeps its swap fees and pays the unstaked fee.
Positions can be liquidated in part or in full, and eUSD can be redeemed against positions whose vault
is mostly asset. One manager runs per risk group, with each group's pools inside it.

**StakingVault** is the staking layer: a fixed-APR ERC-4626 vault deployed once per asset (eUSD →
seUSD, $MONEY → sMONEY). Rewards drip in the staked asset from a pre-funded reserve at the target APR
up to a cap on total staked; above the cap the APR falls as TVL grows.

`misc/` holds **MoneyFeeCollector**, a standalone contract outside the eUSD core: it buys back $MONEY
with a share of the $MONEY trading fees and sends it to the protocol reserve.

## Contracts

```
src/
  eusd/        EUSD (token), EUSDManager (CDP engine, UUPS proxy per risk group),
               EUSDLiquidityManager (eUSD against LP positions, UUPS proxy per risk group)
  eusd/adapters/  FablesAdapter, AerodromeAdapter (per-user LP vaults behind beacons)
  libraries/   LiquidityMath (concentrated-liquidity math)
  staking/     StakingVault (seUSD, sMONEY)
  oracle/      ChainlinkOracleVerifier (Chainlink primary, band-limited in-house fallback)
  registry/    ProtocolRegistry (oracle, treasury and roles)
  interfaces/  Interfaces and shared constants
misc/          MoneyFeeCollector (UUPS proxy) and its interfaces, independent of the core
test/          unit/, invariant/, fork/, helpers/, misc/
script/        Robinhood Chain deploy and ops scripts
docs/          Deployment record, oracle feeds, eUSD Q&A, audit reports
```

The earlier protocol (OwnMarket, VaultManager, PSM, eTokens, lending, funds, OwnStakingV2, and the
registry and oracle they use) is retired and kept on the `legacy-own-v2` branch.

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (CI pins v1.3.5).

```bash
forge build
forge test -vvv
forge fmt --check
tools/storage-layout.sh   # storage-layout guard for upgradeable contracts
```

## Documentation

- [Robinhood Chain deployment](docs/contracts-robinhood.md)
- [Legacy contracts](docs/legacy-contracts-rh.md)
- [Chainlink feeds](docs/chainlink-feeds-robinhood.md)
- [eUSD Q&A](docs/eusd-qa.md)
- [Development guide](AGENTS.md)

## License

BUSL-1.1
