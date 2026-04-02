/**
 * Push Pyth price feeds on-chain for ETH and TSLA.
 * Needed before deposit/valuation calls work.
 */
import { addresses, publicClient, vmClient, feedIds, getSessionFeedId, getCurrentSession } from "../config.js";
import { oracleAbi } from "../abis.js";
import { fetchLatestPriceUpdate, buildUpdatePriceFeedsData } from "../pyth.js";
import { writeContract, formatPrice } from "./utils.js";

const SESSION_NAMES = ["regular", "pre-market", "post-market", "overnight"];

export async function pushPrices() {
  const session = getCurrentSession();
  const tslaFeedId = getSessionFeedId("TSLA", session);

  console.log(`\n=== Push Pyth Prices On-Chain ===`);
  console.log(`  Session: ${session} (${SESSION_NAMES[session]})`);

  const [tslaUpdate, ethUpdate] = await Promise.all([
    fetchLatestPriceUpdate(tslaFeedId),
    fetchLatestPriceUpdate(feedIds.ETH),
  ]);

  console.log(`  TSLA: ${formatPrice(tslaUpdate.normalizedPrice)}`);
  console.log(`  ETH:  ${formatPrice(ethUpdate.normalizedPrice)}`);

  const updateData = buildUpdatePriceFeedsData([tslaUpdate.vaa, ethUpdate.vaa]);

  await writeContract(
    vmClient,
    {
      address: addresses.pythOracle,
      abi: oracleAbi,
      functionName: "updatePriceFeeds",
      args: [updateData],
      value: 100n,
    },
    "Pyth price feeds updated"
  );
}
