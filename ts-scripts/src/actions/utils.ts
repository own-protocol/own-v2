import { type Hash, type PublicClient, formatUnits } from "viem";

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
