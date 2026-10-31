# Own — eUSD

**eUSD** is an overcollateralized stablecoin on Robinhood Chain. Users deposit Robinhood stock tokens
or WETH into an **EUSDManager** and mint eUSD against a fresh oracle price. Each manager holds one
risk group of collateral with its own parameters, and every manager mints the same eUSD.

- **Mint** against collateral at or above the manager's minimum collateral ratio.
- **Repay / close** any time, including when markets are closed (exits use the last oracle price).
- **Liquidate** positions below the liquidation threshold; anyone can call it and earns a fixed bonus.
- **Redeem** eUSD for $1 of a chosen collateral, taken from that collateral's riskiest positions.
- A fixed annual **stability fee** accrues on debt and is minted to the treasury, keeping
  eUSD supply equal to total debt across managers.

**StakingVault** is the staking layer: a fixed-APR ERC-4626 vault deployed once per asset (eUSD →
seUSD, $MONEY → sMONEY). Rewards drip in the staked asset from a pre-funded reserve at the target APR
up to a cap on total staked; above the cap the APR falls as TVL grows. **MoneyFeeCollector** buys
back $MONEY with a share of the $MONEY trading fees and sends it to the protocol reserve.

## Contracts

```
src/
  eusd/        EUSD (token), EUSDManager (CDP engine, UUPS proxy per risk group)
  staking/     StakingVault (seUSD, sMONEY), MoneyFeeCollector (UUPS proxy)
  oracle/      ChainlinkOracleVerifier (Chainlink primary, band-limited in-house fallback)
  registry/    ProtocolRegistry (addresses and roles)
  interfaces/  Interfaces and shared constants
test/          unit/, invariant/, fork/, helpers/
script/        Robinhood Chain deploy and ops scripts
docs/          Deployment record, oracle feeds, eUSD Q&A, audit reports
```

The earlier protocol (OwnMarket, VaultManager, PSM, eTokens, lending, funds, OwnStakingV2) is
retired and kept on the `legacy-own-v2` branch.

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
- [Chainlink feeds](docs/chainlink-feeds-robinhood.md)
- [eUSD Q&A](docs/eusd-qa.md)
- [Development guide](AGENTS.md)

## License

BUSL-1.1
