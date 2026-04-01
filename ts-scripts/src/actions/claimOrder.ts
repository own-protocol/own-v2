/**
 * VM claims an open order.
 *
 * Usage: npx tsx src/actions/claimOrder.ts <orderId>
 */
import { addresses, publicClient, vmClient, vmAccount } from "../config.js";
import { marketAbi } from "../abis.js";
import { waitForTx } from "./utils.js";

export async function claimOrder(orderId: bigint) {
  console.log(`\n=== VM Claim Order #${orderId} ===`);

  const hash = await vmClient.writeContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "claimOrder",
    args: [orderId],
    account: vmAccount,
  });
  await waitForTx(publicClient, hash, "Order claimed");

  // Read order status
  const order = await publicClient.readContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "getOrder",
    args: [orderId],
  });
  console.log(`  Order status: ${(order as any).status} (1 = Claimed)`);
}

// CLI entry point
const orderId = process.argv[2];
if (!orderId) {
  console.error("Usage: npx tsx src/actions/claimOrder.ts <orderId>");
  process.exit(1);
}
claimOrder(BigInt(orderId)).catch(console.error);
