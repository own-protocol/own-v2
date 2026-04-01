/**
 * VM confirms a claimed order with Pyth price proof.
 *
 * Usage: npx tsx src/actions/confirmOrder.ts <orderId> [asset]
 * Default asset: TSLA
 */
import { addresses, feedIds, publicClient, vmClient, vmAccount } from "../config.js";
import { marketAbi, oracleAbi } from "../abis.js";
import { buildPriceProofFromHermes } from "../pyth.js";
import { waitForTx, formatPrice } from "./utils.js";

export async function confirmOrder(
  orderId: bigint,
  asset: "TSLA" | "GOLD" = "TSLA"
) {
  const feedId = feedIds[asset];

  console.log(`\n=== VM Confirm Order #${orderId} (${asset}) ===`);

  // 1. Build price proof from Pyth Hermes
  console.log("Fetching Pyth price proof...");
  const { priceProofData, price } = await buildPriceProofFromHermes(feedId, 0);
  console.log(`  Pyth price: ${formatPrice(price.normalizedPrice)}`);
  console.log(`  Publish time: ${new Date(price.publishTime * 1000).toISOString()}`);

  // 2. Estimate Pyth verification fee
  // For confirmOrder, the market calls verifyPriceForSession twice (low + high)
  // Each call goes through _callVerifyPriceForSession which calls verifyFee first
  // On Base, Pyth fees are typically 1 wei per VAA
  const value = 2n; // 2 wei for 2 verifyPrice calls (1 wei each)

  // 3. Confirm order
  console.log("Confirming order...");
  const hash = await vmClient.writeContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "confirmOrder",
    args: [orderId, priceProofData],
    value,
    account: vmAccount,
  });
  await waitForTx(publicClient, hash, "Order confirmed");

  // 4. Check order status
  const order = await publicClient.readContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "getOrder",
    args: [orderId],
  });
  console.log(`  Order status: ${(order as any).status} (2 = Confirmed)`);
}

// CLI entry point
const orderId = process.argv[2];
if (!orderId) {
  console.error("Usage: npx tsx src/actions/confirmOrder.ts <orderId> [asset]");
  process.exit(1);
}
const asset = (process.argv[3] as "TSLA" | "GOLD") || "TSLA";
confirmOrder(BigInt(orderId), asset).catch(console.error);
