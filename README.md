# Own Protocol v2

Own is a permissionless protocol for bringing tokenized real-world assets (RWAs) onchain as **Collateral-Secured Tokens (CSTs)** — ERC-20 **eTokens** (e.g. eTSLA, eGOLD) that track the price of a real-world asset and are backed by a diversified collateral portfolio instead of a single custodian.

The backing stack has two layers:

- **Reserve Vaults** — protocol-owned, share-less custody of an existing wrapper token (a regulated issuer's tokenized stock) held 1:1 by value against issued supply. A fully reserved eToken is delta-one backed and consumes no LP capital.
- **Multi-Purpose Vaults (MPVs / Own Vaults)** — overcollateralized crypto collateral posted by LPs that insures any exposure not matched by reserves, and simultaneously underwrites the lending market while earning yield.

Issuance runs through two paths: an **RFQ marketplace** where market makers quote mints and redeems against signed oracle-priced quotes, and a **PSM (peg-stability module)** for permissionless two-way 1:1 conversion between wrapper tokens and eTokens (`psmMint` / `psmRedeem`, plus permissionless DvP fills of resting orders against the reserve via `psmFillOrder`). Every holder has a code-property exit: a maker fill, an in-kind PSM redemption against the reserve, or a forced redemption against vault collateral at the oracle price.

**Core contracts**: ProtocolRegistry, OwnMarket, OwnVault, ReserveVault, VaultManager, AssetRegistry, BorrowManager, OwnLendingPool, OracleVerifier, PythOracleVerifier

**Tokens**: EToken, ETokenFactory, OwnAToken, OwnDebtToken

**Peripheral contracts**: LendingRouter, VaultYieldManager, WETHRouter, WstETHRouter

See [docs/protocol.md](docs/protocol.md) for comprehensive protocol documentation and [docs/psm-design.md](docs/psm-design.md) for the PSM & reserve-vault design.

See [docs/Own Protocol Whitepaper.pdf](docs/Own%20Protocol%20Whitepaper.pdf) for the whitepaper — _CST: A Decentralized Real-World Asset Standard_.

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
forge install
forge build
```

### Test

```bash
forge test
```

Run with verbosity:

```bash
forge test -vvv
```

### Deploy

See [docs/deployment.md](docs/deployment.md) for full deployment instructions.

```bash
# Deploy core contracts to Base Sepolia
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
```

## Project Structure

```
src/
  core/           Core protocol contracts (OwnMarket, OwnVault, ReserveVault,
                  OwnLendingPool, registries)
  interfaces/     Interface definitions and shared types
  libraries/      Interest-rate model and lending math
  tokens/         EToken (CST), lending pool receipt/debt tokens
  periphery/      Routers and vault yield manager
test/
  unit/           Unit tests with mocked dependencies
  integration/    End-to-end flow tests
  invariant/      Stateful property tests
  fork/           Mainnet-fork tests
script/           Deployment scripts (testnet + mainnet)
docs/             Protocol, PSM design, and deployment documentation
```

## Documentation

- [Protocol Documentation](docs/protocol.md) — how the protocol works, contract architecture, order lifecycle, oracle system, PSM & reserve vaults
- [PSM Design](docs/psm-design.md) — peg-stability module and RWA reserve-vault design and decision log
- [Deployment Guide](docs/deployment.md) — step-by-step deployment instructions
- [Development Guide](AGENTS.md) — coding conventions, security patterns, testing standards

## License

BUSL-1.1
