/**
 * User cancels an open order.
 *
 * Usage: npx tsx src/actions/cancelOrder.ts <orderId>
 */
import { addresses, userClient } from "../config.js";
import { marketAbi } from "../abis.js";
import { writeContract } from "./utils.js";

export async function cancelOrder(orderId: bigint) {
  console.log(`\n=== Cancel Order #${orderId} ===`);

  await writeContract(
    userClient,
    {
      address: addresses.market,
      abi: marketAbi,
      functionName: "cancelOrder",
      args: [orderId],
    },
    "Order cancelled"
  );
}

