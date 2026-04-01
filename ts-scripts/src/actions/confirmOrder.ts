/**
 * VM confirms a claimed order with Pyth price proof.
 *
 * Usage: npx tsx src/actions/confirmOrder.ts <orderId> [asset] [sessionId]
 * Default asset: TSLA, sessionId: auto-detected from current time
 */
import {
  addresses,
  publicClient,
  vmClient,
  getCurrentSession,
  getSessionFeedId,
} from "../config.js";
import { marketAbi } from "../abis.js";
import {
  fetchPriceUpdateAtTimestamp,
  buildPythPriceData,
  buildConfirmPriceProof,
} from "../pyth.js";
import { writeContract, formatPrice } from "./utils.js";

const SESSION_NAMES = ["regular", "pre-market", "post-market", "overnight"];

export async function confirmOrder(
  orderId: bigint,
  asset: "TSLA" | "GOLD" = "TSLA",
  sessionId?: number
) {
  const session = sessionId ?? getCurrentSession();
  const feedId = getSessionFeedId(asset, session);

  console.log(`\n=== VM Confirm Order #${orderId} (${asset}) ===`);
  console.log(`  Session: ${session} (${SESSION_NAMES[session]})`);

  // 1. Read the order to get claimedAt timestamp
  const order = (await publicClient.readContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "getOrder",
    args: [orderId],
  })) as any;

  const claimedAt = Number(order.claimedAt);
  console.log(
    `  Claimed at: ${new Date(claimedAt * 1000).toISOString()} (${claimedAt})`
  );
  console.log(`  Order price: ${formatPrice(order.price)}`);

  // 2. Fetch VAA at the claim timestamp (proves price was reachable at claim time)
  console.log("Fetching Pyth price proof at claim time...");
  const priceUpdate = await fetchPriceUpdateAtTimestamp(feedId, claimedAt);
  console.log(`  Proof price: ${formatPrice(priceUpdate.normalizedPrice)}`);
  console.log(
    `  Proof publish time: ${new Date(priceUpdate.publishTime * 1000).toISOString()}`
  );

  // 3. Build price proof — use the same VAA for both low and high
  const priceData = buildPythPriceData(
    priceUpdate.vaa,
    priceUpdate.publishTime
  );
  const priceProofData = buildConfirmPriceProof(priceData, priceData, session);

  // 4. Confirm order with enough ETH for Pyth fees (unused is refunded)
  console.log("Confirming order...");
  await writeContract(
    vmClient,
    {
      address: addresses.market,
      abi: marketAbi,
      functionName: "confirmOrder",
      args: [orderId, priceProofData],
      value: 100n,
    },
    "Order confirmed"
  );

  // 5. Check order status
  const updatedOrder = (await publicClient.readContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "getOrder",
    args: [orderId],
  })) as any;
  console.log(`  Order status: ${updatedOrder.status} (2 = Confirmed)`);
}

