import "dotenv/config";
import { Turnkey } from "@turnkey/sdk-server";
import { createAccountWithAddress } from "@turnkey/viem";
import { createPublicClient, createWalletClient, http, type Address } from "viem";
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

export const publicClient = createPublicClient({
  chain: baseSepolia,
  transport: http(rpcUrl),
});

// ── Turnkey account ──────────────────────────────────────────

const turnkey = new Turnkey({
  apiBaseUrl: "https://api.turnkey.com",
  defaultOrganizationId: requireEnv("TURNKEY_ORGANIZATION_ID"),
  apiPublicKey: requireEnv("TURNKEY_API_PUBLIC_KEY"),
  apiPrivateKey: requireEnv("TURNKEY_API_PRIVATE_KEY"),
});

const turnkeyAccount = await createAccountWithAddress({
  client: turnkey.apiClient(),
  organizationId: requireEnv("TURNKEY_ORGANIZATION_ID"),
  signWith: requireEnv("TURNKEY_WALLET_ADDRESS"),
  ethereumAddress: requireEnv("TURNKEY_WALLET_ADDRESS"),
});

export const turnkeyClient = createWalletClient({
  account: turnkeyAccount,
  chain: baseSepolia,
  transport: http(rpcUrl),
});

// ── Contract addresses ───────────────────────────────────────

export const turnkeyAddresses = {
  eTokenFactory: envAddress("ETOKEN_FACTORY"),
  assetRegistry: envAddress("ASSET_REGISTRY"),
  inhouseOracle: envAddress("INHOUSE_ORACLE"),
  mockUsdc: envAddress("MOCK_USDC"),
} as const;
