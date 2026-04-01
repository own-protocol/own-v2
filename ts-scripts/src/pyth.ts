import { encodeAbiParameters, parseAbiParameters } from "viem";

const HERMES_BASE_URL = "https://hermes.pyth.network";

export interface PythPriceUpdate {
  vaa: `0x${string}`;
  price: bigint;
  expo: number;
  publishTime: number;
  normalizedPrice: bigint; // 18-decimal normalized
}

/**
 * Fetch the latest price update (with VAA) from Pyth Hermes.
 */
export async function fetchLatestPriceUpdate(
  feedId: string
): Promise<PythPriceUpdate> {
  const url = `${HERMES_BASE_URL}/v2/updates/price/latest?ids[]=${feedId}&encoding=hex&parsed=true`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Hermes API error: ${res.status}`);

  const data = await res.json();
  const vaaHex = data.binary.data[0] as string;
  const parsed = data.parsed[0];

  const rawPrice = BigInt(parsed.price.price);
  const expo = parsed.price.expo as number;
  const publishTime = parsed.price.publish_time as number;

  // Normalize to 18 decimals
  const normalizedPrice = normalizePythPrice(rawPrice, expo);

  return {
    vaa: `0x${vaaHex}`,
    price: rawPrice,
    expo,
    publishTime,
    normalizedPrice,
  };
}

/**
 * Fetch a price update at a specific timestamp from Pyth Hermes.
 * Uses the /v2/updates/price/:publish_time endpoint.
 */
export async function fetchPriceUpdateAtTimestamp(
  feedId: string,
  publishTime: number
): Promise<PythPriceUpdate> {
  const url = `${HERMES_BASE_URL}/v2/updates/price/${publishTime}?ids[]=${feedId}&encoding=hex&parsed=true`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Hermes API error: ${res.status} for timestamp ${publishTime}`);

  const data = await res.json();
  const vaaHex = data.binary.data[0] as string;
  const parsed = data.parsed[0];

  const rawPrice = BigInt(parsed.price.price);
  const expo = parsed.price.expo as number;
  const actualPublishTime = parsed.price.publish_time as number;

  const normalizedPrice = normalizePythPrice(rawPrice, expo);

  return {
    vaa: `0x${vaaHex}`,
    price: rawPrice,
    expo,
    publishTime: actualPublishTime,
    normalizedPrice,
  };
}

/**
 * Normalize a Pyth price (raw + exponent) to 18 decimals.
 */
function normalizePythPrice(rawPrice: bigint, expo: number): bigint {
  if (expo >= 0) {
    return rawPrice * 10n ** BigInt(18 + expo);
  } else {
    const absExpo = -expo;
    if (absExpo <= 18) {
      return rawPrice * 10n ** BigInt(18 - absExpo);
    } else {
      return rawPrice / 10n ** BigInt(absExpo - 18);
    }
  }
}

/**
 * Build the inner priceData bytes for Pyth's verifyPrice / verifyPriceForSession.
 * Format: abi.encode(bytes[] updateData, uint64 minPublishTime, uint64 maxPublishTime)
 */
export function buildPythPriceData(
  vaa: `0x${string}`,
  publishTime: number
): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("bytes[], uint64, uint64"),
    [[vaa], BigInt(publishTime), BigInt(publishTime)]
  );
}

/**
 * Build the full priceProofData for confirmOrder.
 * Format: abi.encode(bytes lowPriceData, bytes highPriceData, uint8 sessionId)
 *
 * For simple cases where order.price == current price, use the same VAA for both low and high.
 */
export function buildConfirmPriceProof(
  lowPriceData: `0x${string}`,
  highPriceData: `0x${string}`,
  sessionId: number = 0
): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("bytes, bytes, uint8"),
    [lowPriceData, highPriceData, sessionId]
  );
}

/**
 * Convenience: fetch VAA and build complete price proof for confirmOrder.
 */
export async function buildPriceProofFromHermes(
  feedId: string,
  sessionId: number = 0
): Promise<{ priceProofData: `0x${string}`; price: PythPriceUpdate }> {
  const update = await fetchLatestPriceUpdate(feedId);
  const priceData = buildPythPriceData(update.vaa, update.publishTime);
  const priceProofData = buildConfirmPriceProof(priceData, priceData, sessionId);
  return { priceProofData, price: update };
}

/**
 * Build the updateData bytes for PythOracleVerifier.updatePriceFeeds().
 * Format: abi.encode(bytes[])
 */
export function buildUpdatePriceFeedsData(
  vaas: `0x${string}`[]
): `0x${string}` {
  return encodeAbiParameters(parseAbiParameters("bytes[]"), [vaas]);
}
