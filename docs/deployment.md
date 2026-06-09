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
| `TREASURY_ADDRESS` | Address that receives protocol fee share |
| `BASESCAN_API_KEY` | (Optional) For contract verification on BaseScan |

## Step 1: Deploy Core Contracts

Deploys all protocol contracts, registers them in ProtocolRegistry, configures Pyth oracle feeds, adds TSLA + GOLD assets, and configures global parameters on the VaultManager: max utilization, per-asset USD issuance ceilings, and the single global payment token (MockUSDC).

```bash
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
```

The script logs all deployed addresses. Copy them into your `.env`:

```
PROTOCOL_REGISTRY=0x...
ASSET_REGISTRY=0x...
FEE_CALCULATOR=0x...
PYTH_ORACLE=0x...
VAULT_FACTORY=0x...
OWN_MARKET=0x...
VAULT_MANAGER=0x...
MOCK_USDC=0x...
ETOKEN_TSLA=0x...
ETOKEN_GOLD=0x...
WETH_ROUTER=0x...
```

**What gets deployed:**

| Contract | Purpose |
|----------|---------|
| MockERC20 | Testnet USDC (6 decimals, open mint) |
| ProtocolRegistry | Central address registry with 2-day timelock |
| AssetRegistry | Asset configs + oracle mappings |
| FeeCalculator | Mint/redeem fees by volatility level |
| PythOracleVerifier | Pyth oracle wrapper (120s max price age) |
| VaultFactory | Creates OwnVault instances + registers them with the VaultManager |
| OwnMarket | RFQ order execution marketplace |
| VaultManager | Global pooled risk accounting + control hub (exposure, marks, utilization, per-asset caps, signer registry, payment token, pause, halt, claim threshold) |
| EToken (TSLA) | eTSLA synthetic token |
| EToken (GOLD) | eGOLD synthetic token |
| WETHRouter | Native ETH deposit/redeem wrapper |

The script also sets the **global max utilization** (80% / 8000 BPS), a **per-asset USD ceiling**
(`assetCapUSD`) for each launched asset, and the **global payment token** (MockUSDC). A per-asset cap
of `0` blocks minting that asset, so this step is required before any mint can succeed.

## Step 2: Create Vault

Creates a WETH-collateral vault and configures admin parameters. Run with the deployer key.

```bash
forge script script/CreateVault.s.sol --rpc-url base_sepolia --broadcast
```

Copy the vault address into `.env`:

```
VAULT_ADDRESS=0x...
```

**Configuration applied:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| Collateral asset | `ETH` ticker | Passed to `createVault`; the VaultManager prices the vault's collateral via this oracle ticker. |
| `manager` | `VM_ADDRESS` | The vault's operator (accepts LP deposits, distributes yield, can pause the vault). |

> Order-execution parameters (payment token, signers, claim threshold) are **global** on the
> VaultManager, not per vault. Max utilization is likewise set once in Step 1. `createVault`
> auto-registers the vault with the VaultManager.

## Step 3: Configure Global Order Settlement (as admin)

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

# 2. Place a limit mint order (10,000 USDC for TSLA, max $250)
#    orderType: 0 = Mint, 1 = Redeem
cast send $OWN_MARKET "placeOrder(bytes32,uint8,uint256,uint256,uint256)" \
  $(cast --format-bytes32-string "TSLA") \
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
| WETH | `0x4200000000000000000000000000000000000006` |
| Pyth | `0xA2aa501b19aff244D90cc15a4Cf739D2725B5729` |

## Pyth Feed IDs

| Asset | Feed ID |
|-------|---------|
| TSLA/USD | `0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1` |
| XAU/USD | `0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2` |
| ETH/USD | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |

## Fee Schedule (Testnet Defaults)

| Volatility Level | Mint Fee | Redeem Fee | Assets |
|-------------------|----------|------------|--------|
| 1 (Low) | 0.50% | 0.25% | GOLD |
| 2 (Medium) | 1.00% | 0.50% | TSLA |
| 3 (High) | 2.00% | 1.00% | -- |
