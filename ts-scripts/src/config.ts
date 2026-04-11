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
  eTokenFactory: envAddress("ETOKEN_FACTORY"),
  assetRegistry: envAddress("ASSET_REGISTRY"),
  inhouseOracle: envAddress("INHOUSE_ORACLE"),
} as const;

// When MOCK_WETH_COLLATERAL=true, the WETH address points to a MockWETH
// contract that supports free minting (no real ETH needed). When false/unset,
// WETH is the canonical 0x4200...0006 and must be obtained by wrapping ETH.
export const useMockWeth: boolean =
  process.env.MOCK_WETH_COLLATERAL === "true";

// ── Pyth feed IDs ────────────────────────────────────────────
// Session 0 = regular, 1 = pre-market, 2 = post-market, 3 = overnight

export const feedIds = {
  TSLA: requireEnv("TSLA_FEED_ID") as `0x${string}`,
  GOLD: requireEnv("GOLD_FEED_ID") as `0x${string}`,
  ETH: requireEnv("ETH_FEED_ID") as `0x${string}`,
} as const;

// Session-specific feed IDs for equity assets (Pyth has separate feeds per session)
export const sessionFeedIds: Record<string, Record<number, `0x${string}`>> = {
  TSLA: {
    0: "0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1", // regular
    1: "0x42676a595d0099c381687124805c8bb22c75424dffcaa55e3dc6549854ebe20a", // pre-market
    2: "0x2a797e196973b72447e0ab8e841d9f5706c37dc581fe66a0bd21bcd256cdb9b9", // post-market
    3: "0x713631e41c06db404e6a5d029f3eebfd5b885c59dce4a19f337c024e26584e26", // overnight
  },
};

/**
 * Detect the current US equity trading session based on ET time.
 * Returns: 0 = regular, 1 = pre-market, 2 = post-market, 3 = overnight
 */
export function getCurrentSession(): number {
  const now = new Date();
  // Convert to ET (approximate: UTC-4 for EDT, UTC-5 for EST)
  // Using America/New_York for proper DST handling
  const etStr = now.toLocaleString("en-US", { timeZone: "America/New_York" });
  const et = new Date(etStr);
  const hour = et.getHours();
  const min = et.getMinutes();
  const time = hour * 60 + min;
  const day = et.getDay(); // 0=Sun, 6=Sat

  // Weekend: overnight on Sunday, no trading Sat
  if (day === 0) return 3; // Sunday = overnight
  if (day === 6) return 3; // Saturday = technically no session, use overnight

  // Weekday sessions (in minutes from midnight ET):
  // Overnight: 20:00 (prev day) - 04:00 → 0-240
  // Pre-market: 04:00 - 09:30 → 240-570
  // Regular:    09:30 - 16:00 → 570-960
  // Post-market: 16:00 - 20:00 → 960-1200
  // Overnight: 20:00 - 24:00 → 1200-1440

  if (time < 240) return 3;       // midnight - 4am ET: overnight
  if (time < 570) return 1;       // 4am - 9:30am ET: pre-market
  if (time < 960) return 0;       // 9:30am - 4pm ET: regular
  if (time < 1200) return 2;      // 4pm - 8pm ET: post-market
  return 3;                        // 8pm - midnight ET: overnight
}

/**
 * Get the Pyth feed ID for an asset and session.
 * Falls back to the default feed ID if no session-specific feed exists.
 */
export function getSessionFeedId(asset: string, sessionId: number): `0x${string}` {
  const sessionFeeds = sessionFeedIds[asset];
  if (sessionFeeds && sessionFeeds[sessionId]) {
    return sessionFeeds[sessionId];
  }
  // Fallback to default (regular session) feed
  return feedIds[asset as keyof typeof feedIds];
}

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
