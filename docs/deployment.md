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

Deploys all protocol contracts, registers them in ProtocolRegistry, configures Pyth oracle feeds, adds TSLA + GOLD assets, and sets fee levels.

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
| VaultFactory | Creates OwnVault instances |
| OwnMarket | Order escrow + execution marketplace |
| EToken (TSLA) | eTSLA synthetic token |
| EToken (GOLD) | eGOLD synthetic token |
| WETHRouter | Native ETH deposit/redeem wrapper |

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
| Max utilization | 80% (8000 BPS) | Cap on exposure / collateral ratio |
| VM fee share | 20% (2000 BPS) | VM's portion of the non-protocol fee |
| Grace period | 1 day | Delay after claim before force execution |
| Claim threshold | 6 hours | Delay for unclaimed orders before force execution |
| Collateral oracle | ETH/USD Pyth feed | Used for utilization and force execution calculations |

## Step 3: Configure Vault (as VM)

Run with the vault manager key. Sets the payment token and enables assets for trading.

```bash
forge script script/ConfigureVault.s.sol --rpc-url base_sepolia --broadcast
```

**Configuration applied:**
- Payment token: MockUSDC
- Enabled assets: TSLA, GOLD

## Post-Deployment Verification

### Mint testnet USDC

The MockUSDC has an open `mint(address, uint256)` function:

```bash
cast send $MOCK_USDC "mint(address,uint256)" <YOUR_ADDRESS> 1000000000000 \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY
```

This mints 1,000,000 USDC (6 decimals).

### Place a mint order

```bash
# 1. Approve market to spend USDC
cast send $MOCK_USDC "approve(address,uint256)" $OWN_MARKET 10000000000 \
  --rpc-url base_sepolia --private-key <USER_KEY>

# 2. Place mint order (10,000 USDC for TSLA at $250)
cast send $OWN_MARKET "placeMintOrder(address,bytes32,uint256,uint256,uint256)" \
  $VAULT_ADDRESS \
  $(cast --format-bytes32-string "TSLA") \
  10000000000 \
  250000000000000000000 \
  $(( $(date +%s) + 86400 )) \
  --rpc-url base_sepolia --private-key <USER_KEY>
```

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
