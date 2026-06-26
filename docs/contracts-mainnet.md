# Own Protocol v2 — Base Mainnet Deployment

**Network:** Base mainnet (chainId `8453`)
**Deployed:** 2026-06-26 via `script/mainnet/DeployMainnet.s.sol`
**Status:** Core live + verified on Basescan. Assets / lending added in later steps.

## Core contracts

| Contract | Address | Basescan |
|----------|---------|----------|
| ProtocolRegistry | `0xAb3C9c1A5cf70fA63AF59644Dd45F82392206C04` | [↗](https://basescan.org/address/0xAb3C9c1A5cf70fA63AF59644Dd45F82392206C04) |
| AssetRegistry | `0x97e2AB404f845F5BDE3C5A7d906cf349d7a55Ee3` | [↗](https://basescan.org/address/0x97e2AB404f845F5BDE3C5A7d906cf349d7a55Ee3) |
| OwnMarket | `0x736e913a1eD16994b3f9d2BE17Cc57564188f781` | [↗](https://basescan.org/address/0x736e913a1eD16994b3f9d2BE17Cc57564188f781) |
| VaultManager | `0x4A3c284f3293250C84899A220Cf4Cb6dFCd317ba` | [↗](https://basescan.org/address/0x4A3c284f3293250C84899A220Cf4Cb6dFCd317ba) |
| ETokenFactory | `0x93e08ca467046737F75AAD4C936356c196AaA36F` | [↗](https://basescan.org/address/0x93e08ca467046737F75AAD4C936356c196AaA36F) |
| OracleVerifier (INHOUSE_ORACLE) | `0xc82f5835Fe132D34A7491961e2875941CF37aE03` | [↗](https://basescan.org/address/0xc82f5835Fe132D34A7491961e2875941CF37aE03) |
| AaveRouter (USDC→aUSDC) | `0x5744daea555ebbE2d8e093fF8b79eD7513bb20DF` | [↗](https://basescan.org/address/0x5744daea555ebbE2d8e093fF8b79eD7513bb20DF) |
| OwnVault (aUSDC) | `0xfF8d4d4D139716d32d3A3C0bD7a2cE55a916E91A` | [↗](https://basescan.org/address/0xfF8d4d4D139716d32d3A3C0bD7a2cE55a916E91A) |
| BorrowManager | _pending — set by `EnableLendingMainnet.s.sol`_ | |

## eTokens

Registered via `script/mainnet/AddAssetsMainnet.s.sol` (oracleType 1, reward token USDC, cap $1M each).
All verified on Basescan. SPCX is registered but not mintable until the signer service serves an SPCX mark.

| Ticker | eToken | Address |
|--------|--------|---------|
| MU | eMU | `0x5D2113410fD086f64cBB18117D5Ea64B6e1daeA7` |
| SPCX | eSPCX | `0xcE7a98eAB3e0aC7B5Ad686cd130f308F6bCa2f69` |
| MSFT | eMSFT | `0x0cAf1567Be08EbdBD93ae00411e1a28fBC5899fF` |
| GOOG | eGOOG | `0x46E9257BD72012F7814Ae67D95095342d5439C7A` |
| TSLA | eTSLA | `0x63e9a22Ea69698C4dDD67f63CdefBc1dbD4456Cc` |
| SPY | eSPY | `0x16589A23B56fb693e188faB9eBcB2756479E88C0` |

## Roles & signers

| Role | Address |
|------|---------|
| Deployer / bootstrap PROTOCOL_ADMIN+ADMIN+OPERATOR | `0xD9eA00C71df5b50493fCbD1f7e8c5C8DbB525bD1` |
| Vault manager (VM operator) | `0x0e3d09603290f96e86Be1807AFADcd99C81e2a63` |
| Treasury (bad-debt sink) | `0x5B199d7be394487AC7c637fd596be6f1648fD902` |
| Oracle price signer | `0x6Ff4688f3de3354eed591B737bFf5DCdD9642A32` |
| RFQ quote signer | `0x7eAa2748CF934a310B86Ae16CF4cA604809527e2` |
| Quote settlement wallet (mint sink / redeem source) | `0x7eAa2748CF934a310B86Ae16CF4cA604809527e2` |

> Governance is still on the deployer EOA. Migrate to multisig + timelock via
> `SetupGovernance.s.sol` after smoke-testing.

## External (Base mainnet) dependencies

| Token / contract | Address |
|------------------|---------|
| USDC (Circle, 6 dec) — payment token + vault underlying-in | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| aUSDC (Aave V3 aBasUSDC, 6 dec) — vault collateral asset | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| Aave V3 variableDebtUSDC | `0x59dca05b6c26dbd64b5381374aAaC5CD05644C28` |

## Global parameters (set at deploy)

| Parameter | Value |
|-----------|-------|
| Admin transfer delay | 3 hours |
| Price max age | 2 minutes |
| Global max utilization | 6500 bps (65%) |
| Settle band | 500 bps (±5%) |
| Claim threshold | unset (0) — force-execution disabled until `setClaimThreshold` |
| Max mark age | 1 hour |
| Per-asset cap (set in AddAssets) | 1,000,000e18 USD |
| Collateral oracle ticker | `USDC` (~$1) |

## Deploy sequence status

- [x] **Step 1** — `DeployMainnet.s.sol` (core + oracle + router + vault + globals) — verified
- [x] **Step 2** — `AddAssetsMainnet.s.sol` (6 eTokens) — verified, caps $1M each
- [ ] **Step 3** — keeper `pullCollateralPrice(vault)`
- [ ] **Step 4** — VM seed deposit: 100 USDC via AaveRouter
- [ ] **Step 5** — `EnableLendingMainnet.s.sol` (BorrowManager + wiring + enableAaveCollateral)
- [ ] **Step 6** — keeper `pullAssetPrice(ticker)` per asset
- [ ] Governance migration (`SetupGovernance.s.sol`)
