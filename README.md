# Own Protocol

Own is a permissionless protocol for bringing tokenized real-world assets (RWAs) onchain. Users mint ERC-20 tokens called **eTokens** (e.g. eTSLA, eGOLD) by using stablecoins. Each eToken tracks the price of its underlying asset through onchain oracles. The tokens are backed by on-chain collateral deposited by LPs in Own Vaults.

**Core contracts**: ProtocolRegistry, OwnMarket, OwnVault, VaultFactory, AssetRegistry, FeeCalculator, OracleVerifier, PythOracleVerifier, EToken

**Peripheral contracts**: WETHRouter, WstETHRouter

See [docs/protocol.md](docs/protocol.md) for comprehensive protocol documentation.

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
  core/           Core protocol contracts (OwnVault, OwnMarket, registries)
  interfaces/     Interface definitions and shared types
  tokens/         EToken (synthetic asset token)
  periphery/      Router contracts (WETHRouter, WstETHRouter)
test/
  unit/           Unit tests with mocked dependencies
  integration/    End-to-end flow tests
  invariant/      Stateful property tests
script/           Deployment scripts
docs/             Protocol and deployment documentation
```

## Documentation

- [Protocol Documentation](docs/protocol.md) — how the protocol works, contract architecture, order lifecycle, fee model, oracle system
- [Deployment Guide](docs/deployment.md) — step-by-step deployment instructions for Base Sepolia
- [Development Guide](AGENTS.md) — coding conventions, security patterns, testing standards

## License

BUSL-1.1
