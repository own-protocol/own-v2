import { fetchLatestPriceUpdate, buildUpdatePriceFeedsData } from "./pyth.js";
import { addresses, publicClient, vmClient, getSessionFeedId } from "./config.js";
import { oracleAbi } from "./abis.js";

async function main() {
  const feedId = getSessionFeedId("TSLA", 1); // pre-market
  const update = await fetchLatestPriceUpdate(feedId);
  console.log("VAA length:", update.vaa.length);
  console.log("Price:", update.normalizedPrice);

  // Try pushing to Pyth oracle
  const updateData = buildUpdatePriceFeedsData([update.vaa]);
  console.log("Calling updatePriceFeeds...");
  const hash = await vmClient.writeContract({
    address: addresses.pythOracle,
    abi: oracleAbi,
    functionName: "updatePriceFeeds",
    args: [updateData],
    value: 100n, // More ETH for Pyth fee
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("updatePriceFeeds status:", receipt.status);
}

main().catch(console.error);
