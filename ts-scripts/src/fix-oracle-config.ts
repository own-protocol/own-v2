/**
 * Fix missing oracle config for all deployed assets.
 * Sets maxStaleness=120s, maxDeviation=500 BPS for each.
 *
 * Usage: npx tsx src/fix-oracle-config.ts
 */
import { publicClient, deployerClient } from "./config.js";
import { oracleVerifierAbi } from "./abis.js";
import { assetToBytes32 } from "./config.js";
import { readFileSync } from "fs";
import type { Address } from "viem";

const ORACLE = "0x79Fa388ddB371f36D4394128647F67A43c57f6ac" as Address;
const MAX_STALENESS = 120n;
const MAX_DEVIATION = 500n;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const assets = JSON.parse(readFileSync("output/deployed-assets.json", "utf-8")) as Array<{
    ticker: string;
  }>;

  console.log(`Setting oracle config for ${assets.length} assets...\n`);

  for (let i = 0; i < assets.length; i++) {
    const { ticker } = assets[i];
    const tickerBytes32 = assetToBytes32(ticker);

    console.log(`[${i + 1}/${assets.length}] ${ticker}`);

    const hash = await deployerClient.writeContract({
      address: ORACLE,
      abi: oracleVerifierAbi,
      functionName: "setAssetOracleConfig",
      args: [tickerBytes32, MAX_STALENESS, MAX_DEVIATION],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") throw new Error(`${ticker} reverted`);
    console.log(`  tx: ${hash}`);
    await sleep(10_000);
  }

  console.log("\n=== Done ===");
}

main().catch((err) => {
  console.error("\n*** FAILED ***", err);
  process.exit(1);
});
