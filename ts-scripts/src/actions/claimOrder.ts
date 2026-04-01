/**
 * VM claims an open order.
 *
 * Usage: npx tsx src/actions/claimOrder.ts <orderId>
 */
import { addresses, publicClient, vmClient } from "../config.js";
import { marketAbi } from "../abis.js";
import { writeContract } from "./utils.js";

export async function claimOrder(orderId: bigint) {
  console.log(`\n=== VM Claim Order #${orderId} ===`);

  await writeContract(
    vmClient,
    {
      address: addresses.market,
      abi: marketAbi,
      functionName: "claimOrder",
      args: [orderId],
    },
    "Order claimed"
  );

  // Read order status
  const order = await publicClient.readContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "getOrder",
    args: [orderId],
  });
  console.log(`  Order status: ${(order as any).status} (1 = Claimed)`);
}

