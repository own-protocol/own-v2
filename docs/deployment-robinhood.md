# Own Protocol v2 — Robinhood Chain Deployment Guide

**Network:** Robinhood Chain (chainId `4663`) — Arbitrum Orbit L2 on Ethereum, ETH gas.
**Explorer:** [Blockscout](https://robinhoodchain.blockscout.com) — there is no Etherscan; contract
verification goes through Blockscout (no API key required).
**Docs:** <https://docs.robinhood.com/chain> (RPC, token contracts, deploy guide).

## What's different from the Base deploy

| | Base mainnet | Robinhood Chain |
|---|---|---|
| Lending venue | Aave V3 (aBasUSDC) | **OwnLendingPool** (in-house, zero-rate; premium curve is the full rate) |
| Payment token / collateral underlying | USDC (Circle) | **USDG** (Paxos Global Dollar, 6 dec) `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Vault collateral | aBasUSDC | **oUSDG** (OwnLendingPool aToken, deployed by us) |
| PSM backing | (issuer TBD, never launched) | **Gen-2 Robinhood Stock Tokens** (Jersey issuer, ERC-20 18 dec, ERC-8056 `uiMultiplier`) |
| External oracles | none (in-house) | none at launch (Chainlink is the only 3rd-party option; no Pyth) |
| Verification | Basescan (`--verify`) | Blockscout (`--verify --verifier blockscout --verifier-url …`) |
| LP yield | manual VM sweep | **VaultYieldManager** installed as vault.manager (10% treasury cut) |
| enableAaveCollateral timing | after first deposit (Aave constraint) | any time (no-op flag on OwnLendingPool) |

## Environment

Add to `.env` (see `.env.example`, Robinhood section):

`ROBINHOOD_RPC`, `DEPLOYER_PRIVATE_KEY_ROBINHOOD`, `VM_PRIVATE_KEY_ROBINHOOD`,
`VM_ADDRESS_ROBINHOOD`, `TREASURY_ADDRESS_ROBINHOOD`, `ORACLE_SIGNER_ROBINHOOD` (KMS price key),
`OPERATOR_PRIVATE_KEY_ROBINHOOD` (bootstrap signer), `QUOTE_SIGNER_ROBINHOOD`,
`QUOTE_SIGNER_LINKED_ROBINHOOD`, `RESERVE_MANAGER_ROBINHOOD`.

The deployer needs ETH on Robinhood Chain for gas (bridge via the canonical Arbitrum Orbit bridge;
7-day exit). Public RPC: `https://rpc.mainnet.chain.robinhood.com` (rate-limited — Alchemy
recommended for the deploy itself).

### Blockscout verification flags

Every broadcast that creates contracts takes:

```bash
--verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

To verify a single contract after the fact:

```bash
forge verify-contract <ADDR> src/core/OwnVault.sol:OwnVault --chain-id 4663 \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ \
  --constructor-args $(cast abi-encode "constructor(address,string,string,address,address)" ...)
```

## Step 0 — Preflight (read-only, no broadcast)

```bash
forge script script/robinhood/CheckChainRobinhood.s.sol --rpc-url robinhood
```

Asserts chainId 4663, USDG metadata (6 dec), and symbol/decimals/`uiMultiplier` of the Gen-2
launch tokens. Then, for each PSM backing candidate:

```bash
WRAPPER_TOKEN_ROBINHOOD=0x322F0929c4625eD5bAd873c95208D54E1c003b2d \
  forge test --match-contract WrapperRobinhoodForkTest -vvv
```

⚠️ **Blocking review:** Gen-2 token admin powers (pause / freeze / upgradeability) are unverified.
Read the verified token source on Blockscout before running Step 6.

## Step 1 — Core deploy

```bash
forge script script/robinhood/DeployRobinhood.s.sol --rpc-url robinhood --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

Deploys ProtocolRegistry (3h admin-transfer delay), AssetRegistry, OwnMarket, VaultManager,
ETokenFactory, OracleVerifier (+ KMS signer), **OwnLendingPool** (USDG reserve, LTV 75% / LT 100%,
oUSDG + odUSDG tokens), LendingRouter (only allowed supplier), the oUSDG collateral asset
(ticker `USDG`), and the single **oUSDG OwnVault**; sets globals (60% max util, ±5% settle band,
1h max mark age, payment token USDG) and registers the RFQ quote signer. Claim threshold stays 0
(force-execution off).

Copy the logged addresses into `.env` (`PROTOCOL_REGISTRY_ROBINHOOD`, `VAULT_ADDRESS_ROBINHOOD`,
`LENDING_POOL_ROBINHOOD`, `LENDING_ROUTER_ROBINHOOD`).

## Step 2 — Oracle configs + USDG mark bootstrap

```bash
forge script script/robinhood/SetOracleConfigsRobinhood.s.sol --rpc-url robinhood --broadcast
forge script script/robinhood/BootstrapUsdgPriceRobinhood.s.sol --rpc-url robinhood --broadcast
```

First sets per-asset oracle configs (1h staleness, 20% deviation) for the 7 launch tickers; second
adds the operator as a temporary oracle signer, attests USDG at $1, and pulls the vault collateral
mark. **Remove the operator signer once the KMS service is the sole signer.**

## Step 3 — Launch assets

```bash
forge script script/robinhood/AddAssetsRobinhood.s.sol --rpc-url robinhood --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

Creates the 7 eTokens (MU, SPCX, MSFT, GOOG, TSLA, SPY, QQQ — USDG reward token), registers them
(in-house oracle, $1M cap each), and arms the per-asset fail-closed grants (maker / lending-vault /
force-execute). Keepers must `pullAssetPrice(ticker)` before any mint.

## Step 4 — Lending + yield automation

```bash
forge script script/robinhood/EnableLendingRobinhood.s.sol --rpc-url robinhood --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

Deploys the vault's permanent BorrowManager (target LTV 70%; premium curve base 6%, optimal util
80%, slope1 2% (→8% at optimal), slope2 72% — the pool rate is 0, so this is the entire lending
rate), binds it, grants credit delegation, sets the collateral flag, then deploys the
**VaultYieldManager** (10% treasury cut), installs it as `vault.manager`, and allowlists it as a
pool supplier. From here the
VM drives the deposit queue through the shell's `acceptDeposit`/`rejectDeposit` passthroughs and
anyone can crank `distribute()`.

Unlike Base, this does **not** need to wait for the first deposit.

## Step 5 — Seed deposit (VM)

```bash
forge script script/robinhood/SeedDepositRobinhood.s.sol --rpc-url robinhood --broadcast
```

VM deposits 100 USDG via the LendingRouter (USDG → oUSDG → vault shares) and refreshes the
collateral mark. Requires the VM wallet to hold USDG on Robinhood Chain.

## Step 6 — PSM (Gen-2 Stock Token backing)

Gates: Step 0 wrapper fork test passed **and** issuer admin-powers review done **and** the oracle
service publishes the wrapper token price (share price × `uiMultiplier`) under the wrapper ticker.

```bash
forge script script/robinhood/DeployPsmRobinhood.s.sol --rpc-url robinhood --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

Registers the wrapper ticker (`R.TSLA` → Gen-2 TSLA), deploys the ReserveVault, registers it as
TSLA's RWA reserve, wires `setPsmConfig`, and arms the 150 bps ratio-jump bound (the PSM
on-switch). Keeper: `pullCollateralPrice(reserve)` once the feed is live; verify with a small
psmMint/psmRedeem round-trip.

> **Split runbook:** a stock split jumps `uiMultiplier` far beyond the ratio-jump bound by design.
> Halt, re-mark under the new multiplier, resume — do not widen the bound.

## Off-chain services checklist

- **Price signer (KMS):** publish marks for `USDG` ($1), the 7 launch tickers, and each wrapper
  ticker (Gen-2 token price **including** `uiMultiplier`). Sequence numbers + EIP-712 domain are
  chain-scoped — new chainId 4663 domain.
- **RFQ quote signer (KMS):** new domain for chainId 4663; linked settlement wallet funded with
  USDG for redeem payouts.
- **Keepers:** `pullAssetPrice` / `pullCollateralPrice` crank; `VaultYieldManager.distribute()`
  crank (permissionless).
- **Governance:** deployer EOA is bootstrap admin. Safe v1.4.1 + CREATE2 factories are live at
  canonical addresses on 4663 — move PROTOCOL_ADMIN to the multisig/timelock post-launch (3h
  transfer delay applies).

## External addresses (Robinhood Chain, verified on-chain 2026-07-14)

| Contract | Address |
|---|---|
| USDG (Paxos, 6 dec) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Gen-2 MU | `0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD` |
| Gen-2 SPCX | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` |
| Gen-2 MSFT | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` |
| Gen-2 GOOGL (not GOOG) | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` |
| Gen-2 TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` |
| Gen-2 SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` |
| Gen-2 QQQ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` |

Full Gen-2 registry: <https://docs.robinhood.com/chain/contracts>. All Gen-2 tokens are 18
decimals; issuer is Robinhood Assets (Jersey) Ltd (Reg S — no US persons).
