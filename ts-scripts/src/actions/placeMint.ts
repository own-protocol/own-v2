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
  publicClient,
  userClient,
  userAccount,
  getCurrentSession,
  getSessionFeedId,
} from "../config.js";
import { erc20Abi, marketAbi } from "../abis.js";
import { fetchLatestPriceUpdate } from "../pyth.js";
import { writeContract, formatPrice } from "./utils.js";

const SESSION_NAMES = ["regular", "pre-market", "post-market", "overnight"];

export async function placeMint(
  usdcAmount: string = "100",
  asset: "TSLA" | "GOLD" = "TSLA"
) {
  const amount = parseUnits(usdcAmount, 6); // USDC has 6 decimals
  const assetBytes = assets[asset];

  // Use session-aware feed ID for current price
  const session = getCurrentSession();
  const feedId = getSessionFeedId(asset, session);

  console.log(`\n=== Place Mint Order: ${usdcAmount} USDC -> e${asset} ===`);
  console.log(`  Session: ${session} (${SESSION_NAMES[session]})`);

  // 1. Fetch current price from Pyth (session-aware feed)
  console.log("Fetching current price from Pyth...");
  const priceUpdate = await fetchLatestPriceUpdate(feedId);
  // Add 0.1% buffer above current price to allow for minor price movement
  const currentPrice = priceUpdate.normalizedPrice;
  const orderPrice = currentPrice + currentPrice / 1000n;
  console.log(`  Current ${asset} price: ${formatPrice(currentPrice)}`);
  console.log(`  Order price (+0.1% buffer): ${formatPrice(orderPrice)}`);

  // 2. Mint mock USDC to user (testnet only)
  console.log("Minting mock USDC...");
  await writeContract(
    userClient,
    {
      address: addresses.usdc,
      abi: erc20Abi,
      functionName: "mint",
      args: [userAccount.address, amount],
    },
    "USDC mint"
  );

  // 3. Approve market for USDC
  console.log("Approving market for USDC...");
  await writeContract(
    userClient,
    {
      address: addresses.usdc,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.market, amount],
    },
    "USDC approve"
  );

  // 4. Place mint order (expiry = 1 day from now)
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 86400);
  console.log("Placing mint order...");
  const placeHash = await writeContract(
    userClient,
    {
      address: addresses.market,
      abi: marketAbi,
      functionName: "placeMintOrder",
      args: [addresses.vault, assetBytes, amount, orderPrice, expiry],
    },
    "Mint order placed"
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

