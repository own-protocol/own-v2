/**
 * User places a mint order (buy eTokens with USDC).
 *
 * Usage: npx tsx src/actions/placeMint.ts [usdc_amount] [asset]
 * Default: 100 USDC, TSLA
 */
import { parseUnits } from "viem";
import {
  addresses,
  assets,
  feedIds,
  publicClient,
  userClient,
  userAccount,
  PRECISION,
} from "../config.js";
import { erc20Abi, marketAbi } from "../abis.js";
import { fetchLatestPriceUpdate } from "../pyth.js";
import { waitForTx, formatPrice } from "./utils.js";

export async function placeMint(
  usdcAmount: string = "100",
  asset: "TSLA" | "GOLD" = "TSLA"
) {
  const amount = parseUnits(usdcAmount, 6); // USDC has 6 decimals
  const assetBytes = assets[asset];
  const feedId = feedIds[asset];

  console.log(`\n=== Place Mint Order: ${usdcAmount} USDC -> e${asset} ===`);

  // 1. Fetch current price from Pyth
  console.log("Fetching current price from Pyth...");
  const priceUpdate = await fetchLatestPriceUpdate(feedId);
  const orderPrice = priceUpdate.normalizedPrice;
  console.log(`  Current ${asset} price: ${formatPrice(orderPrice)}`);

  // 2. Mint mock USDC to user (testnet only)
  console.log("Minting mock USDC...");
  const mintHash = await userClient.writeContract({
    address: addresses.usdc,
    abi: erc20Abi,
    functionName: "mint",
    args: [userAccount.address, amount],
    account: userAccount,
  });
  await waitForTx(publicClient, mintHash, "USDC mint");

  // 3. Approve market for USDC
  console.log("Approving market for USDC...");
  const approveHash = await userClient.writeContract({
    address: addresses.usdc,
    abi: erc20Abi,
    functionName: "approve",
    args: [addresses.market, amount],
    account: userAccount,
  });
  await waitForTx(publicClient, approveHash, "USDC approve");

  // 4. Place mint order (expiry = 1 day from now)
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 86400);
  console.log("Placing mint order...");
  const placeHash = await userClient.writeContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "placeMintOrder",
    args: [addresses.vault, assetBytes, amount, orderPrice, expiry],
    account: userAccount,
  });
  await waitForTx(publicClient, placeHash, "Mint order placed");

  // 5. Get order ID from logs
  const receipt = await publicClient.getTransactionReceipt({ hash: placeHash });
  // OrderPlaced event topic
  const orderPlacedLog = receipt.logs[receipt.logs.length - 1];
  const orderId = BigInt(orderPlacedLog.topics[1]!);
  console.log(`  Order ID: ${orderId}`);

  return { orderId, orderPrice };
}

// CLI entry point
const amount = process.argv[2] || "100";
const asset = (process.argv[3] as "TSLA" | "GOLD") || "TSLA";
placeMint(amount, asset).catch(console.error);
