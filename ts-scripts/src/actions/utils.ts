import {
  type Hash,
  type PublicClient,
  type WalletClient,
  type Abi,
  formatUnits,
} from "viem";
import { publicClient } from "../config.js";

// ── Local nonce tracker ──────────────────────────────────────
// Tracks the next nonce per address to avoid stale RPC responses.
const nonceCache = new Map<string, number>();

async function getNextNonce(address: `0x${string}`): Promise<number> {
  const key = address.toLowerCase();
  if (nonceCache.has(key)) {
    const next = nonceCache.get(key)!;
    nonceCache.set(key, next + 1);
    return next;
  }
  // First call: fetch from chain
  const onChain = await publicClient.getTransactionCount({ address });
  nonceCache.set(key, onChain + 1);
  return onChain;
}

/**
 * Wait for a transaction to be confirmed and log the result.
 */
export async function waitForTx(
  client: PublicClient,
  hash: Hash,
  label: string
): Promise<void> {
  console.log(`  tx: ${hash}`);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status === "reverted") {
    throw new Error(`${label} REVERTED (tx: ${hash})`);
  }
  console.log(
    `  ${label} confirmed (block ${receipt.blockNumber}, gas ${receipt.gasUsed})`
  );
}

/**
 * Write a contract call with a locally-tracked nonce.
 * Waits for confirmation before returning.
 */
export async function writeContract(
  walletClient: WalletClient,
  params: {
    address: `0x${string}`;
    abi: Abi | readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
    value?: bigint;
  },
  label: string
): Promise<Hash> {
  const account = walletClient.account!;
  const nonce = await getNextNonce(account.address);

  const hash = await walletClient.writeContract({
    ...params,
    nonce,
  } as any);

  await waitForTx(publicClient, hash, label);
  return hash;
}

/**
 * Send a raw transaction with a locally-tracked nonce.
 * Waits for confirmation before returning.
 */
export async function sendTx(
  walletClient: WalletClient,
  params: {
    to: `0x${string}`;
    value?: bigint;
    data?: `0x${string}`;
  },
  label: string
): Promise<Hash> {
  const account = walletClient.account!;
  const nonce = await getNextNonce(account.address);

  const hash = await walletClient.sendTransaction({
    ...params,
    nonce,
  } as any);

  await waitForTx(publicClient, hash, label);
  return hash;
}

/**
 * Format a bigint price (18 decimals) to a human-readable string.
 */
export function formatPrice(price: bigint): string {
  return `$${formatUnits(price, 18)}`;
}

/**
 * Format a bigint amount to human-readable with given decimals.
 */
export function formatAmount(amount: bigint, decimals: number): string {
  return formatUnits(amount, decimals);
}
