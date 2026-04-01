/**
 * User places a redeem order (sell eTokens for USDC).
 *
 * Usage: npx tsx src/actions/placeRedeem.ts [etoken_amount] [asset]
 * Default: all eTokens, TSLA
 */
import {
  addresses,
  assets,
  feedIds,
  publicClient,
  userClient,
  userAccount,
} from "../config.js";
import { erc20Abi, marketAbi } from "../abis.js";
import { fetchLatestPriceUpdate } from "../pyth.js";
import { waitForTx, formatPrice, formatAmount } from "./utils.js";

export async function placeRedeem(
  eTokenAmount?: string,
  asset: "TSLA" | "GOLD" = "TSLA"
) {
  const assetBytes = assets[asset];
  const feedId = feedIds[asset];
  const eTokenAddr = asset === "TSLA" ? addresses.eTSLA : addresses.eGOLD;

  console.log(`\n=== Place Redeem Order: e${asset} -> USDC ===`);

  // 1. Get eToken balance if amount not specified
  let amount: bigint;
  if (eTokenAmount) {
    amount = BigInt(eTokenAmount);
  } else {
    amount = (await publicClient.readContract({
      address: eTokenAddr,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [userAccount.address],
    })) as bigint;
  }
  console.log(`  Redeeming: ${formatAmount(amount, 18)} e${asset}`);

  if (amount === 0n) {
    console.log("  No eTokens to redeem. Skipping.");
    return;
  }

  // 2. Fetch current price from Pyth
  console.log("Fetching current price from Pyth...");
  const priceUpdate = await fetchLatestPriceUpdate(feedId);
  const orderPrice = priceUpdate.normalizedPrice;
  console.log(`  Current ${asset} price: ${formatPrice(orderPrice)}`);

  // 3. Approve market for eTokens
  console.log("Approving market for eTokens...");
  const approveHash = await userClient.writeContract({
    address: eTokenAddr,
    abi: erc20Abi,
    functionName: "approve",
    args: [addresses.market, amount],
    account: userAccount,
  });
  await waitForTx(publicClient, approveHash, "eToken approve");

  // 4. Place redeem order (expiry = 1 day from now)
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 86400);
  console.log("Placing redeem order...");
  const placeHash = await userClient.writeContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "placeRedeemOrder",
    args: [addresses.vault, assetBytes, amount, orderPrice, expiry],
    account: userAccount,
  });
  await waitForTx(publicClient, placeHash, "Redeem order placed");

  // 5. Get order ID from logs
  const receipt = await publicClient.getTransactionReceipt({ hash: placeHash });
  const orderPlacedLog = receipt.logs[receipt.logs.length - 1];
  const orderId = BigInt(orderPlacedLog.topics[1]!);
  console.log(`  Order ID: ${orderId}`);

  return { orderId, orderPrice };
}

// CLI entry point
const amount = process.argv[2];
const asset = (process.argv[3] as "TSLA" | "GOLD") || "TSLA";
placeRedeem(amount, asset).catch(console.error);
