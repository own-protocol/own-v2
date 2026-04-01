/**
 * User places a redeem order (sell eTokens for USDC).
 *
 * Usage: npx tsx src/actions/placeRedeem.ts [etoken_amount] [asset]
 * Default: all eTokens, TSLA
 */
import {
  addresses,
  assets,
  publicClient,
  userClient,
  userAccount,
  getCurrentSession,
  getSessionFeedId,
} from "../config.js";
import { erc20Abi, marketAbi } from "../abis.js";
import { fetchLatestPriceUpdate } from "../pyth.js";
import { writeContract, formatPrice, formatAmount } from "./utils.js";

const SESSION_NAMES = ["regular", "pre-market", "post-market", "overnight"];

export async function placeRedeem(
  eTokenAmount?: string,
  asset: "TSLA" | "GOLD" = "TSLA"
) {
  const assetBytes = assets[asset];
  const eTokenAddr = asset === "TSLA" ? addresses.eTSLA : addresses.eGOLD;

  const session = getCurrentSession();
  const feedId = getSessionFeedId(asset, session);

  console.log(`\n=== Place Redeem Order: e${asset} -> USDC ===`);
  console.log(`  Session: ${session} (${SESSION_NAMES[session]})`);

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

  // 2. Fetch current price from Pyth (session-aware)
  console.log("Fetching current price from Pyth...");
  const priceUpdate = await fetchLatestPriceUpdate(feedId);
  // Subtract 0.1% buffer below current price for redeem
  const currentPrice = priceUpdate.normalizedPrice;
  const orderPrice = currentPrice - currentPrice / 1000n;
  console.log(`  Current ${asset} price: ${formatPrice(currentPrice)}`);
  console.log(`  Order price (-0.1% buffer): ${formatPrice(orderPrice)}`);

  // 3. Approve market for eTokens
  console.log("Approving market for eTokens...");
  await writeContract(
    userClient,
    {
      address: eTokenAddr,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.market, amount],
    },
    "eToken approve"
  );

  // 4. Place redeem order (expiry = 1 day from now)
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 86400);
  console.log("Placing redeem order...");
  const placeHash = await writeContract(
    userClient,
    {
      address: addresses.market,
      abi: marketAbi,
      functionName: "placeRedeemOrder",
      args: [addresses.vault, assetBytes, amount, orderPrice, expiry],
    },
    "Redeem order placed"
  );

  // 5. Get order ID from logs
  const receipt = await publicClient.getTransactionReceipt({
    hash: placeHash,
  });
  const orderPlacedLog = receipt.logs[receipt.logs.length - 1];
  const orderId = BigInt(orderPlacedLog.topics[1]!);
  console.log(`  Order ID: ${orderId}`);

  return { orderId, orderPrice };
}

