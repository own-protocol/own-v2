## Testnet — Base Sepolia (v2, 2026-06-12)

Deployer / admin: `0xa3374B34A855b0bF6b96401D8c367608d9c8a048`
Manager: `0xb914b344D8a2C88598A9C5905C9342a9678a67db`

### Core contracts (all verified on BaseScan)

PROTOCOL_REGISTRY=0xb42a2ed47f31d044b0db4391beb5f678b6cd00d1
ASSET_REGISTRY=0x104a8871a06448ce610612ea81d0202372054d80
INHOUSE_ORACLE=0x6d4d4f1c561ba6dfa2ff64a8485b0ec1a6a62ffb
OWN_MARKET=0x15d79cd37302957e07123096f0c800e27418b09a
VAULT_MANAGER=0xb55fafeb479ed9f8c7fea9653b85cc6b2c1498ee
ETOKEN_FACTORY=0xb8ce24ffa09a226a26d3035354bcb18fc1e8ff02
WETH_ROUTER=0x11f60aaf7b05e8c53181ecd963698ec93a01a3fc

# Pyth is not used — all assets price via INHOUSE_ORACLE. A PythOracleVerifier

# (0x719d6b282a27b926be9886693aeec5e2c927a7f4) remains in the registry's PYTH_ORACLE slot from the

# initial deploy but is orphaned/unused (the slot cannot be cleared) and is referenced by no asset.

### ETH vault

VAULT_ADDRESS=0x48793b9843bbd18dfec3f45bd5c41c0561da887a # collateral = MockWETH, manager = VM above

### Reused testnet tokens (not redeployed)

MOCK_USDC=0x6f5BB5824C8D572966a1DED0470AF3E72C527613 # payment token, 6 decimals, open mint
MockWETH=0xfbd78Da8aDbc322084eE7F80C10F914B92CEb6FE # ETH vault collateral, 18 decimals, open mint
WETH=0x4200000000000000000000000000000000000006 # canonical Base Sepolia WETH (unused — vault uses MockWETH)

### Signers

ORACLE_SIGNER=0x6Ff4688f3de3354eed591B737bFf5DCdD9642A32 # price attestation signer on INHOUSE_ORACLE
MM_QUOTE_SIGNER=0x7eAa2748CF934a310B86Ae16CF4cA604809527e2 # RFQ quote signer on VaultManager; linked settlement address = same

## Assets — all in-house oracle (oracleType 1)

ETH collateral asset -> MockWETH (0xfbd78Da8aDbc322084eE7F80C10F914B92CEb6FE)

US stocks:
ETOKEN_AAPL=0x0ff7cf5ee99ff5bc2bA955F6A1C4965A76Afe535
ETOKEN_NVDA=0x32a442F9376A5B0146c2bbFdcBa386F61aea1eEE
ETOKEN_AMZN=0x9C6e9883971b1012544C0E3898fa55CBf0D96EDe
ETOKEN_MSFT=0x46DA09bfaF35B322B9731F254Ca9F4Fd9256a843
ETOKEN_META=0xE6eF9d6591D5F57d2a675d5F234Fd559dC7d96d2
ETOKEN_GOOG=0x002CAA47731A93d8881812922932cd0DCecce22a
ETOKEN_COIN=0xD8ED0998c79DE46a07ADD3f6A474148C60d944bd
ETOKEN_MSTR=0xE00Dd77bef74876B1F8D38A096921258355aFda0
ETOKEN_AMD=0x507f8848f5978E8995e18183dDC1C3E238D5Bb0A
ETOKEN_PLTR=0xAC9C16fFDcc7197524861BD9C24C975Ad81b8dbb
ETOKEN_TSM=0x53d678550A800e9cB3C38f800ABd0602F88CB74C
ETOKEN_NFLX=0x53dC9b4477F2BE54fe2c635C42109C7dAd94E1F5
ETOKEN_HOOD=0xb64bA64808C4Bb95488B0e2822662c287DF1ada3
ETOKEN_WMT=0x1f6194b3d069175D3AA173363329E6dc6C212ac5

US ETFs:
ETOKEN_SPY=0x530506534a75212994cA5d6EDFBAB1016465bF2C
ETOKEN_QQQ=0x7E33ebF73D4dA8AD433Ad95af81D6Fbac4D1E6e2
ETOKEN_TLT=0xa42c581b6A28D035b6Ce664a1A7431AEec3d8A3e
ETOKEN_MAGS=0x69b09E983E72B6704a1be9e084758e212E1bB5a0
ETOKEN_ITA=0x42df6cc9B88487ED1C32d6ADdB4F5dbC47D272f6

## Notes

- All assets price via the in-house oracle (oracleType 1) — there is no Pyth.
- 19 active eToken assets (14 US stocks + 5 US ETFs) + the ETH collateral asset, each with a
  per-asset cap of 10,000,000 USD (1e25) on the VaultManager.
- The original Pyth eTokens eTSLA (`0x3307b2…`) and eGOLD (`0xd33AB1…`) were deactivated on-chain and
  their caps zeroed (migration `RemovePythAssets.s.sol`); they are no longer tradeable.
- Global max utilization: 8000 BPS (80%).
- Before any asset can be minted, a keeper must pull each asset's mark (`VaultManager.pullAssetPrice`)
  and the vault's collateral mark (`VaultManager.pullCollateralPrice`) so marks are non-zero.
- MM quote signer `0x7eAa2748…` is registered on the VaultManager (linked settlement address = same),
  so `OwnMarket` will accept its signed quotes.
