import "dotenv/config";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

// ── Env helpers ──────────────────────────────────────────────

function requireEnv(key: string): string {
  const val = process.env[key];
  if (!val) throw new Error(`Missing env var: ${key}`);
  return val;
}

function envAddress(key: string): Address {
  return requireEnv(key) as Address;
}

// ── Chain config ─────────────────────────────────────────────

const rpcUrl = requireEnv("RPC_URL");

// Auto-detect chain from RPC or default to Base Sepolia
export const chain: Chain = baseSepolia;

// ── Accounts ─────────────────────────────────────────────────

export const deployerAccount = privateKeyToAccount(
  requireEnv("DEPLOYER_PRIVATE_KEY") as `0x${string}`
);
export const vmAccount = privateKeyToAccount(
  requireEnv("VM_PRIVATE_KEY") as `0x${string}`
);
export const userAccount = privateKeyToAccount(
  requireEnv("USER_PRIVATE_KEY") as `0x${string}`
);

// ── Clients ──────────────────────────────────────────────────

export const publicClient = createPublicClient({
  chain,
  transport: http(rpcUrl),
});

export const deployerClient = createWalletClient({
  account: deployerAccount,
  chain,
  transport: http(rpcUrl),
});

export const vmClient = createWalletClient({
  account: vmAccount,
  chain,
  transport: http(rpcUrl),
});

export const userClient = createWalletClient({
  account: userAccount,
  chain,
  transport: http(rpcUrl),
});

// ── Contract addresses ───────────────────────────────────────

export const addresses = {
  market: envAddress("OWN_MARKET"),
  vault: envAddress("OWN_VAULT"),
  usdc: envAddress("MOCK_USDC"),
  eTSLA: envAddress("ETOKEN_TSLA"),
  eGOLD: envAddress("ETOKEN_GOLD"),
  pythOracle: envAddress("PYTH_ORACLE"),
  weth: envAddress("WETH"),
} as const;

// ── Pyth feed IDs ────────────────────────────────────────────

export const feedIds = {
  TSLA: requireEnv("TSLA_FEED_ID") as `0x${string}`,
  GOLD: requireEnv("GOLD_FEED_ID") as `0x${string}`,
  ETH: requireEnv("ETH_FEED_ID") as `0x${string}`,
} as const;

// ── Asset tickers (bytes32) ──────────────────────────────────

export function assetToBytes32(asset: string): `0x${string}` {
  const hex = Buffer.from(asset).toString("hex").padEnd(64, "0");
  return `0x${hex}`;
}

export const assets = {
  TSLA: assetToBytes32("TSLA"),
  GOLD: assetToBytes32("GOLD"),
  ETH: assetToBytes32("ETH"),
} as const;

// ── Constants ────────────────────────────────────────────────

export const PRECISION = 10n ** 18n;
export const BPS = 10_000n;
