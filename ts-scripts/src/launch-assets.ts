/**
 * Launch All Assets — Create eTokens & register in AssetRegistry
 *
 * Uses the deployer wallet to:
 * 1. Create eTokens via ETokenFactory
 * 2. Register each asset in AssetRegistry
 * 3. Configure oracle staleness/deviation per asset
 *
 * Usage: npx tsx src/launch-assets.ts
 */
import { publicClient, deployerClient, deployerAccount, addresses } from "./config.js";
import { eTokenFactoryAbi, assetRegistryAbi, oracleVerifierAbi } from "./abis.js";
import { assetToBytes32 } from "./config.js";
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "fs";
import type { Address } from "viem";

// ── Asset definitions ────────────────────────────────────────

interface AssetDef {
  ticker: string;
  name: string;
  symbol: string;
  volatility: number; // 1=low, 2=medium, 3=high
}

// US Stocks (volatility=2) — skip TSLA (already live)
const usStocks: AssetDef[] = [
  { ticker: "AAPL", name: "Apple", symbol: "eAAPL", volatility: 2 },
  { ticker: "NVDA", name: "Nvidia", symbol: "eNVDA", volatility: 2 },
  { ticker: "AMZN", name: "Amazon", symbol: "eAMZN", volatility: 2 },
  { ticker: "MSFT", name: "Microsoft", symbol: "eMSFT", volatility: 2 },
  { ticker: "META", name: "Meta", symbol: "eMETA", volatility: 2 },
  { ticker: "GOOG", name: "Alphabet", symbol: "eGOOG", volatility: 2 },
  { ticker: "COIN", name: "Coinbase", symbol: "eCOIN", volatility: 2 },
  { ticker: "MSTR", name: "MicroStrategy", symbol: "eMSTR", volatility: 2 },
  { ticker: "AMD", name: "AMD", symbol: "eAMD", volatility: 2 },
  { ticker: "PLTR", name: "Palantir", symbol: "ePLTR", volatility: 2 },
  { ticker: "TSM", name: "TSMC", symbol: "eTSM", volatility: 2 },
  { ticker: "NFLX", name: "Netflix", symbol: "eNFLX", volatility: 2 },
  { ticker: "HOOD", name: "Robinhood", symbol: "eHOOD", volatility: 2 },
  { ticker: "WMT", name: "Walmart", symbol: "eWMT", volatility: 2 },
];

// US ETFs (volatility=1)
const usETFs: AssetDef[] = [
  { ticker: "SPY", name: "S&P 500 ETF", symbol: "eSPY", volatility: 1 },
  { ticker: "QQQ", name: "Nasdaq 100 ETF", symbol: "eQQQ", volatility: 1 },
  { ticker: "TLT", name: "20+ Year Treasury ETF", symbol: "eTLT", volatility: 1 },
  { ticker: "MAGS", name: "Magnificent Seven ETF", symbol: "eMAGS", volatility: 1 },
  { ticker: "ITA", name: "Aerospace & Defense ETF", symbol: "eITA", volatility: 1 },
];

// Commodities (volatility=2) — skip GOLD (already live)
const commodities: AssetDef[] = [
  { ticker: "SILVER", name: "Silver", symbol: "eSILVER", volatility: 2 },
  { ticker: "OIL", name: "Crude Oil WTI", symbol: "eOIL", volatility: 2 },
  { ticker: "NATGAS", name: "Natural Gas", symbol: "eNATGAS", volatility: 2 },
  { ticker: "COPPER", name: "Copper", symbol: "eCOPPER", volatility: 2 },
];

// FX Pairs (volatility=1)
const fxPairs: AssetDef[] = [
  { ticker: "EURUSD", name: "EUR/USD", symbol: "eEURUSD", volatility: 1 },
  { ticker: "GBPUSD", name: "GBP/USD", symbol: "eGBPUSD", volatility: 1 },
  { ticker: "USDJPY", name: "USD/JPY", symbol: "eUSDJPY", volatility: 1 },
  { ticker: "USDKRW", name: "USD/KRW", symbol: "eUSDKRW", volatility: 1 },
  { ticker: "USDCNY", name: "USD/CNY", symbol: "eUSDCNY", volatility: 1 },
];

// Korean Stocks & ETFs (volatility=2)
const koreanAssets: AssetDef[] = [
  { ticker: "SMSNG", name: "Samsung Electronics", symbol: "eSMSNG", volatility: 2 },
  { ticker: "SKHYNX", name: "SK Hynix", symbol: "eSKHYNX", volatility: 2 },
  { ticker: "LGES", name: "LG Energy Solution", symbol: "eLGES", volatility: 2 },
  { ticker: "KOSPI", name: "KOSPI 200 ETF", symbol: "eKOSPI", volatility: 2 },
  { ticker: "CELTRN", name: "Celltrion", symbol: "eCELTRN", volatility: 2 },
];

// Japanese Stocks & ETFs (volatility=2)
const japaneseAssets: AssetDef[] = [
  { ticker: "TOYOTA", name: "Toyota Motor", symbol: "eTOYOTA", volatility: 2 },
  { ticker: "SONY", name: "Sony Group", symbol: "eSONY", volatility: 2 },
  { ticker: "NIKKEI", name: "Nikkei 225 ETF", symbol: "eNIKKEI", volatility: 2 },
];

// Indian ETFs (volatility=1)
const indianAssets: AssetDef[] = [
  { ticker: "NIFTY", name: "Nifty 50 ETF", symbol: "eNIFTY", volatility: 1 },
  { ticker: "SENSEX", name: "Sensex ETF", symbol: "eSENSEX", volatility: 1 },
];

// HK / Chinese Stocks & ETFs (volatility=2)
const hkAssets: AssetDef[] = [
  { ticker: "BABA", name: "Alibaba", symbol: "eBABA", volatility: 2 },
  { ticker: "TCEHY", name: "Tencent", symbol: "eTCEHY", volatility: 2 },
  { ticker: "JD", name: "JD.com", symbol: "eJD", volatility: 2 },
  { ticker: "BIDU", name: "Baidu", symbol: "eBIDU", volatility: 2 },
  { ticker: "HSI", name: "Hang Seng Index ETF", symbol: "eHSI", volatility: 2 },
];

const ALL_ASSETS: AssetDef[] = [
  ...usStocks,
  ...usETFs,
  ...commodities,
  ...fxPairs,
  ...koreanAssets,
  ...japaneseAssets,
  ...indianAssets,
  ...hkAssets,
];

// ── Oracle defaults ──────────────────────────────────────────

const MAX_STALENESS = 120n; // 120 seconds
const MAX_DEVIATION = 500n; // 500 BPS = 5%

// ── Helpers ──────────────────────────────────────────────────

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function waitForTx(hash: `0x${string}`, label: string) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === "reverted") {
    throw new Error(`${label} — tx reverted: ${hash}`);
  }
  console.log(`  ${label} — tx: ${hash}`);
  await sleep(15_000);
  return receipt;
}

// ── Main ─────────────────────────────────────────────────────

async function main() {
  console.log("╔══════════════════════════════════════════════╗");
  console.log("║  Own Protocol — Launch All Assets             ║");
  console.log("╚══════════════════════════════════════════════╝");
  console.log(`  Wallet: ${deployerAccount.address}`);
  console.log(`  Factory: ${addresses.eTokenFactory}`);
  console.log(`  Registry: ${addresses.assetRegistry}`);
  console.log(`  Oracle: ${addresses.inhouseOracle}`);
  console.log(`  Assets to deploy: ${ALL_ASSETS.length}`);
  console.log("");

  // Load previously deployed assets (for resume support)
  const outputPath = "output/deployed-assets.json";
  let results: Array<{ ticker: string; symbol: string; eToken: Address }> = [];
  if (existsSync(outputPath)) {
    results = JSON.parse(readFileSync(outputPath, "utf-8"));
    console.log(`  Resuming — ${results.length} assets already deployed`);
  }
  const deployed = new Set(results.map((r) => r.ticker));

  for (let i = 0; i < ALL_ASSETS.length; i++) {
    const asset = ALL_ASSETS[i];
    const tickerBytes32 = assetToBytes32(asset.ticker);

    if (deployed.has(asset.ticker)) {
      console.log(`\n[${i + 1}/${ALL_ASSETS.length}] ${asset.ticker} — already deployed, skipping`);
      continue;
    }

    console.log(`\n[${i + 1}/${ALL_ASSETS.length}] ${asset.ticker} (${asset.symbol})`);

    // 1. Check if eToken already exists (from a previous partial run)
    const currentBlock = await publicClient.getBlockNumber();
    const existingLogs = await publicClient.getLogs({
      address: addresses.eTokenFactory,
      event: {
        type: "event",
        name: "ETokenCreated",
        inputs: [
          { name: "token", type: "address", indexed: true },
          { name: "ticker", type: "bytes32", indexed: true },
          { name: "symbol", type: "string", indexed: false },
        ],
      },
      args: { ticker: tickerBytes32 },
      fromBlock: currentBlock - 9000n,
      toBlock: "latest",
    });

    let eTokenAddress: Address;
    if (existingLogs.length > 0) {
      eTokenAddress = existingLogs[0].args.token as Address;
      console.log(`  eToken already exists: ${eTokenAddress}`);
    } else {
      const createHash = await deployerClient.writeContract({
        address: addresses.eTokenFactory,
        abi: eTokenFactoryAbi,
        functionName: "createEToken",
        args: [asset.name, asset.symbol, tickerBytes32, addresses.usdc],
      });
      const createReceipt = await waitForTx(createHash, "createEToken");

      // Parse ETokenCreated event to get deployed address
      const createdLog = createReceipt.logs.find(
        (log) => log.address.toLowerCase() === addresses.eTokenFactory.toLowerCase()
      );
      if (!createdLog || !createdLog.topics[1]) {
        throw new Error(`Failed to parse ETokenCreated event for ${asset.ticker}`);
      }
      eTokenAddress = ("0x" + createdLog.topics[1].slice(26)) as Address;
      console.log(`  eToken: ${eTokenAddress}`);
    }

    // 2. Register asset in AssetRegistry (skip if already registered)
    try {
      const addHash = await deployerClient.writeContract({
        address: addresses.assetRegistry,
        abi: assetRegistryAbi,
        functionName: "addAsset",
        args: [
          tickerBytes32,
          eTokenAddress,
          {
            activeToken: eTokenAddress,
            legacyTokens: [],
            active: true,
            volatilityLevel: asset.volatility,
            oracleType: 1, // in-house oracle
          },
        ],
      });
      await waitForTx(addHash, "addAsset");
    } catch (e: any) {
      if (e.message?.includes("0xcdf86285") || e.message?.includes("AssetAlreadyExists")) {
        console.log(`  addAsset — already registered, skipping`);
      } else {
        throw e;
      }
    }

    // 3. Configure oracle (skip if already configured)
    try {
      const oracleHash = await deployerClient.writeContract({
        address: addresses.inhouseOracle,
        abi: oracleVerifierAbi,
        functionName: "setAssetOracleConfig",
        args: [tickerBytes32, MAX_STALENESS, MAX_DEVIATION],
      });
      await waitForTx(oracleHash, "setAssetOracleConfig");
    } catch (e: any) {
      if (e.message?.includes("already") || e.message?.includes("configured")) {
        console.log(`  setAssetOracleConfig — already set, skipping`);
      } else {
        throw e;
      }
    }

    results.push({ ticker: asset.ticker, symbol: asset.symbol, eToken: eTokenAddress });

    // Save progress after each asset (for resume)
    mkdirSync("output", { recursive: true });
    writeFileSync(outputPath, JSON.stringify(results, null, 2));
  }

  // Write results to JSON
  mkdirSync("output", { recursive: true });
  writeFileSync("output/deployed-assets.json", JSON.stringify(results, null, 2));

  // Print summary for contracts.md
  console.log("\n╔══════════════════════════════════════════════╗");
  console.log("║  All Assets Deployed                          ║");
  console.log("╚══════════════════════════════════════════════╝\n");
  console.log("Add to docs/contracts.md:\n");
  for (const r of results) {
    console.log(`ETOKEN_${r.ticker}=${r.eToken}`);
  }
}

main().catch((err) => {
  console.error("\n*** LAUNCH FAILED ***");
  console.error(err);
  process.exit(1);
});
