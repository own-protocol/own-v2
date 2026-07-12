# Own Protocol v2 — Deployment Guide

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Base Sepolia ETH for gas (use [Base Sepolia Faucet](https://www.alchemy.com/faucets/base-sepolia))
- Two wallets: one for deployer/admin, one for vault manager (VM)
- (Optional) BaseScan API key for contract verification

## Environment Setup

```bash
cp .env.example .env
```

Fill in the required values:

| Variable | Description |
|----------|-------------|
| `BASE_SEPOLIA_RPC` | RPC endpoint (default: `https://sepolia.base.org`) |
| `DEPLOYER_PRIVATE_KEY` | Deployer wallet private key (becomes protocol admin) |
| `VM_PRIVATE_KEY` | Vault manager wallet private key |
| `VM_ADDRESS` | Vault manager address (must match `VM_PRIVATE_KEY`) |
| `TREASURY_ADDRESS` | Address that receives bad-debt collateral released during lending wind-down |
| `BASESCAN_API_KEY` | (Optional) For contract verification on BaseScan |

## Step 1: Deploy Core Contracts

Deploys all core protocol contracts, registers them in ProtocolRegistry, registers the ETH collateral asset (in-house oracle), and configures global parameters on the VaultManager: max utilization, per-asset USD issuance ceilings, and the single global payment token. There is no Pyth — all assets price via the in-house OracleVerifier (Step 2).

> **Token reuse.** `Deploy.s.sol` does **not** deploy fresh tokens — it reuses the existing testnet
> USDC (`TESTNET_USDC`) as payment token and testnet MockWETH (`TESTNET_WETH`) as the ETH vault
> collateral. Both are wired in as constants at the top of the script (and aligned with the
> collateral address in `CreateVault.s.sol`). Update those constants if the testnet tokens change.

```bash
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
```

The script logs all deployed addresses. Copy them into your `.env`:

```
PROTOCOL_REGISTRY=0x...
ASSET_REGISTRY=0x...
OWN_MARKET=0x...
VAULT_MANAGER=0x...
ETOKEN_FACTORY=0x...
MOCK_USDC=0x...
WETH_ROUTER=0x...
```

**What gets deployed:**

| Contract | Purpose |
|----------|---------|
| ProtocolRegistry | Central address registry with 2-day timelock |
| AssetRegistry | Asset configs + oracle mappings |
| OwnMarket | RFQ order execution marketplace |
| VaultManager | Global pooled risk accounting + control hub (exposure, marks, utilization, per-asset caps, signer registry, payment token, pause, halt, claim threshold) |
| ETokenFactory | Deploys eTokens (assets are registered separately via AddAssets.s.sol) |
| WETHRouter | Native ETH deposit/redeem wrapper |

The script also sets the **global max utilization** (80% / 8000 BPS), a **per-asset USD ceiling**
(`assetCapUSD`) for each launched asset, and the **global payment token** (testnet USDC). A per-asset
cap of `0` blocks minting that asset, so this step is required before any mint can succeed.

## Step 2: Deploy In-House Oracle (required — all assets use it)

Every asset (the ETH collateral from Step 1 and the stocks/ETFs from Step 3) prices via the in-house
`OracleVerifier` (oracleType 1). Deploy it, register it as `INHOUSE_ORACLE` in the ProtocolRegistry,
and add the price-attestation signer:

```bash
forge script script/DeployOracleSigner.s.sol --rpc-url base_sepolia --broadcast --verify
```

Copy the address into `.env`:

```
INHOUSE_ORACLE=0x...
```

## Step 3: Register the Asset Set (US stocks + ETFs)

Batch-registers 14 US stocks + 5 US ETFs: for each it creates the EToken, registers it in the
AssetRegistry with oracleType 1, and sets the per-asset USD cap on the VaultManager. Dependencies are
resolved from the ProtocolRegistry, so only `PROTOCOL_REGISTRY` needs to be set in `.env`.

```bash
forge script script/AddAssets.s.sol --rpc-url base_sepolia --broadcast --verify
```

> Single-asset additions still use `AddAsset.s.sol` (edit its constants per asset). Note that
> `AddAsset.s.sol` does **not** set the per-asset cap — call `VaultManager.setAssetCapUSD` afterwards,
> or minting that asset reverts with `AssetCapBreached`.

Before any in-house asset can be minted, a keeper must pull its mark
(`VaultManager.pullAssetPrice`) and the vault's collateral mark (`VaultManager.pullCollateralPrice`)
so marks are non-zero.

> **Per-asset grants (v2, default-deny).** Quote settlement, borrowing, and force-execution are
> all inert per asset until the AssetRegistry grants are armed:
> `setMakerAllowed(ticker, signer, true)`, `setLendingVaultAllowed(ticker, vault, true)`,
> `setForceExecuteVaultAllowed(ticker, vault, true)`. The mainnet asset script
> (`script/mainnet/AddAssetsMainnet.s.sol`) arms them alongside each `addAsset`; when adding
> assets by hand, arm them explicitly or the corresponding paths revert
> (`MakerNotAllowed` / `LendingVaultNotAllowed` / `ForceExecuteVaultNotAllowed`).

## Step 4: Create Vault

Deploys a MockWETH-collateral `OwnVault` directly and registers it on the VaultManager (admin-only).
Run with the deployer key. There is no vault factory. The collateral address (MockWETH) is hardcoded
in the script and must match `TESTNET_WETH` in `Deploy.s.sol`.

```bash
forge script script/CreateVault.s.sol --rpc-url base_sepolia --broadcast --verify
```

Copy the vault address into `.env`:

```
VAULT_ADDRESS=0x...
```

**Configuration applied:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| Collateral asset | `ETH` ticker | Passed to `VaultManager.registerVault(vault, collateralAsset)`; the VaultManager prices the vault's collateral via this oracle ticker. |
| `manager` | `VM_ADDRESS` | The vault's operator (accepts LP deposits, distributes yield, can pause the vault). |

> Order-execution parameters (payment token, signers, claim threshold) are **global** on the
> VaultManager, not per vault. Max utilization is likewise set once in Step 1. The script deploys the
> vault and calls `registerVault` on the VaultManager, which holds the vault allowlist + risk pool.

## Step 5: Configure Global Order Settlement (as admin)

The global payment token is already set in Step 1. The remaining global setup — registering a quote
signer and setting the claim threshold — is admin-run on the VaultManager. (The
`ConfigureVault.s.sol` script re-sets the global payment token if you need to change it.)

> Per-vault asset enablement does not exist — the global AssetRegistry governs which assets are
> tradeable, and the VaultManager's per-asset cap governs issuance. Before an asset can be minted, a
> keeper must pull its price (`VaultManager.pullAssetPrice`) and the vault's collateral price
> (`VaultManager.pullCollateralPrice`) so the marks are non-zero.

### Register a quote signer (required)

No quote signer is seeded at deployment, so the market will reject all quotes until one is
registered. Signers are **global** and admin-managed on the VaultManager. Each signer carries a
**linked settlement address** (mint proceeds flow to it; redeem payouts come from it). Register the
signing key (e.g. an HSM/KMS key) with its linked funding wallet:

```bash
cast send $VAULT_MANAGER "registerSigner(address,address)" <SIGNER_ADDRESS> <LINKED_ADDRESS> \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY
```

### Set the claim threshold (optional)

```bash
cast send $VAULT_MANAGER "setClaimThreshold(uint256)" 21600 \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY
```

## Step 6: Configure the PSM (optional at launch)

The PSM (wrapper-token mint/redeem — `docs/protocol.md` §14) ships fail-closed: it stays inert
until a wrapper is configured **and** the global ratio-jump bound is set. Configure with
`script/mainnet/DeployPsmMainnet.s.sol` (set the real wrapper token / ticker / backed asset —
the checked-in constants are placeholders), which:

1. registers the wrapper ticker (so its oracle feed resolves),
2. deploys the `ReserveVault` (env `RESERVE_MANAGER_MAINNET` = the operating VM),
3. registers it as the backed asset's RWA reserve (`registerVault(reserve, wrapperTicker, asset)`),
4. wires `setPsmConfig` and arms `setRatioJumpBoundBps` (100–200 bps recommended; the on-switch).

Pre-verify the wrapper token with `test/fork/WrapperBaseFork.t.sol` (`BASE_RPC` +
`WRAPPER_TOKEN_BASE` env): metadata, transfer restrictions, custody round-trip. The oracle
service must publish the wrapper **token** price under the wrapper ticker, and a keeper must
`pullCollateralPrice(reserve)` before the first mint.

## Post-Deployment Verification

### Mint testnet USDC

The MockUSDC has an open `mint(address, uint256)` function:

```bash
cast send $MOCK_USDC "mint(address,uint256)" <YOUR_ADDRESS> 1000000000000 \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY
```

This mints 1,000,000 USDC (6 decimals).

### Place a mint order

A **market order** settles a signer-issued quote in one transaction via
`executeOrder(Quote,bytes)` — the quote and signature come from a maker's quoter service, so it is
driven by the app/SDK rather than a bare `cast` call. The single-user path you can run directly is a
**limit order** (`placeOrder`), which escrows funds on-chain for a maker to fill later. Orders are
vault-less — no vault argument:

```bash
# 1. Approve market to spend USDC
cast send $MOCK_USDC "approve(address,uint256)" $OWN_MARKET 10000000000 \
  --rpc-url base_sepolia --private-key <USER_KEY>

# 2. Place a limit mint order (10,000 USDC for AAPL, max $250)
#    orderType: 0 = Mint, 1 = Redeem
cast send $OWN_MARKET "placeOrder(bytes32,uint8,uint256,uint256,uint256)" \
  $(cast --format-bytes32-string "AAPL") \
  0 \
  10000000000 \
  250000000000000000000 \
  $(( $(date +%s) + 86400 )) \
  --rpc-url base_sepolia --private-key <USER_KEY>
```

A maker then fills it by submitting a signed quote to `fillOrder`. If a redeem order goes unfilled,
the owner can call `forceExecuteOrder(orderId, vault, ...)` after the claim threshold — naming the
registered vault to draw collateral from — to settle at the oracle price.

### LP deposit via WETHRouter (native ETH)

```bash
cast send $WETH_ROUTER "depositETH(address,address,uint256)" \
  $VAULT_ADDRESS <RECEIVER> 0 \
  --value 1ether \
  --rpc-url base_sepolia --private-key <USER_KEY>
```

## External Addresses (Base Sepolia)

| Contract | Address |
|----------|---------|
| Canonical WETH | `0x4200000000000000000000000000000000000006` (unused — vault collateral is MockWETH) |
| MockWETH (testnet ETH) | `0xfbd78Da8aDbc322084eE7F80C10F914B92CEb6FE` |
| MockUSDC (testnet USDC) | `0x6f5BB5824C8D572966a1DED0470AF3E72C527613` |

Oracle prices are supplied by the in-house signer service (https://twelvedata.com/ &
https://eodhd.com/) and attested on-chain via the `OracleVerifier`. There are no Pyth feeds.

## Fees

The protocol charges **no on-chain mint or redeem fee** — orders settle at the maker's signed
quote price and the maker captures its spread off-chain. Lending revenue (the premium above Aave's
borrow rate) and dividends earned on borrowed collateral are swept to the vault manager. See `docs/protocol.md`
§7 for the full revenue model.
