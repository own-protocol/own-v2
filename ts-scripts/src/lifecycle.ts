/**
 * Full Order Lifecycle Script
 *
 * Runs the complete flow:
 * 1. LP deposits WETH into vault
 * 2. Update Pyth price feeds on-chain
 * 3. User places a mint order for eTSLA
 * 4. VM claims the order
 * 5. VM confirms the order (with Pyth price proof)
 * 6. User places a redeem order for eTSLA
 * 7. VM claims the redeem
 * 8. VM confirms the redeem (with Pyth price proof)
 *
 * Usage: npx tsx src/lifecycle.ts
 */
import {
  addresses,
  assets,
  feedIds,
  publicClient,
  vmClient,
  vmAccount,
  userClient,
  userAccount,
  PRECISION,
} from "./config.js";
import { erc20Abi, vaultAbi, oracleAbi } from "./abis.js";
import { fetchLatestPriceUpdate, buildUpdatePriceFeedsData } from "./pyth.js";
import { deposit } from "./actions/deposit.js";
import { placeMint } from "./actions/placeMint.js";
import { claimOrder } from "./actions/claimOrder.js";
import { confirmOrder } from "./actions/confirmOrder.js";
import { placeRedeem } from "./actions/placeRedeem.js";
import { formatPrice, formatAmount, waitForTx } from "./actions/utils.js";

async function pushPythPrices() {
  console.log("\n=== Push Pyth Prices On-Chain ===");

  // Fetch VAAs for all assets
  const [tslaUpdate, ethUpdate] = await Promise.all([
    fetchLatestPriceUpdate(feedIds.TSLA),
    fetchLatestPriceUpdate(feedIds.ETH),
  ]);

  console.log(`  TSLA: ${formatPrice(tslaUpdate.normalizedPrice)}`);
  console.log(`  ETH:  ${formatPrice(ethUpdate.normalizedPrice)}`);

  // Push to Pyth oracle on-chain
  const updateData = buildUpdatePriceFeedsData([tslaUpdate.vaa, ethUpdate.vaa]);
  const hash = await vmClient.writeContract({
    address: addresses.pythOracle,
    abi: oracleAbi,
    functionName: "updatePriceFeeds",
    args: [updateData],
    value: 2n, // 1 wei per feed
    account: vmAccount,
  });
  await waitForTx(publicClient, hash, "Pyth price feeds updated");
}

async function printVaultState() {
  const [totalAssets, collateralUSD, exposureUSD, utilization] =
    await Promise.all([
      publicClient.readContract({
        address: addresses.vault,
        abi: vaultAbi,
        functionName: "totalAssets",
      }),
      publicClient.readContract({
        address: addresses.vault,
        abi: vaultAbi,
        functionName: "collateralValueUSD",
      }),
      publicClient.readContract({
        address: addresses.vault,
        abi: vaultAbi,
        functionName: "totalExposureUSD",
      }),
      publicClient.readContract({
        address: addresses.vault,
        abi: vaultAbi,
        functionName: "utilization",
      }),
    ]);

  console.log("\n--- Vault State ---");
  console.log(`  Total assets:    ${formatAmount(totalAssets as bigint, 18)} WETH`);
  console.log(`  Collateral USD:  ${formatPrice(collateralUSD as bigint)}`);
  console.log(`  Exposure USD:    ${formatPrice(exposureUSD as bigint)}`);
  console.log(`  Utilization:     ${Number(utilization as bigint) / 100}%`);
}

async function printBalances() {
  const [userUSDC, userETSLA, vmUSDC] = await Promise.all([
    publicClient.readContract({
      address: addresses.usdc,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [userAccount.address],
    }),
    publicClient.readContract({
      address: addresses.eTSLA,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [userAccount.address],
    }),
    publicClient.readContract({
      address: addresses.usdc,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [vmAccount.address],
    }),
  ]);

  console.log("\n--- Balances ---");
  console.log(`  User USDC:   ${formatAmount(userUSDC as bigint, 6)}`);
  console.log(`  User eTSLA:  ${formatAmount(userETSLA as bigint, 18)}`);
  console.log(`  VM USDC:     ${formatAmount(vmUSDC as bigint, 6)}`);
}

async function main() {
  console.log("╔══════════════════════════════════════════════╗");
  console.log("║  Own Protocol v2 — Full Lifecycle Demo       ║");
  console.log("╚══════════════════════════════════════════════╝");
  console.log(`  User:  ${userAccount.address}`);
  console.log(`  VM:    ${vmAccount.address}`);
  console.log(`  Vault: ${addresses.vault}`);

  // Step 1: LP Deposit
  await deposit("1");
  await printVaultState();

  // Step 2: Push Pyth prices on-chain (needed for getPrice / valuation)
  await pushPythPrices();

  // Step 3: Update asset + collateral valuations
  console.log("\n=== Update Valuations ===");
  const updateAssetHash = await vmClient.writeContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "updateAssetValuation",
    args: [assets.TSLA],
    account: vmAccount,
  });
  await waitForTx(publicClient, updateAssetHash, "TSLA valuation updated");

  const updateCollHash = await vmClient.writeContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "updateCollateralValuation",
    args: [],
    account: vmAccount,
  });
  await waitForTx(publicClient, updateCollHash, "Collateral valuation updated");
  await printVaultState();

  // Step 4: Place mint order
  const mintResult = await placeMint("100", "TSLA");
  if (!mintResult) throw new Error("Mint order placement failed");
  await printBalances();

  // Step 5: VM claims the mint order
  await claimOrder(mintResult.orderId);

  // Step 6: VM confirms the mint order (with Pyth proof)
  await confirmOrder(mintResult.orderId, "TSLA");
  await printBalances();
  await printVaultState();

  // Step 7: Place redeem order (all eTSLA)
  const redeemResult = await placeRedeem(undefined, "TSLA");
  if (!redeemResult) {
    console.log("\nNo eTokens to redeem — lifecycle complete (mint only).");
    return;
  }

  // Step 8: Fund VM with USDC for redeem payout (testnet only)
  console.log("\n=== Fund VM with USDC for redeem payout ===");
  // Calculate approximate payout
  const eTokenBal = (await publicClient.readContract({
    address: addresses.eTSLA,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [addresses.market], // escrowed in market
  })) as bigint;
  const approxPayout = (eTokenBal * redeemResult.orderPrice) / PRECISION / 10n ** 12n;
  const mintVmHash = await vmClient.writeContract({
    address: addresses.usdc,
    abi: erc20Abi,
    functionName: "mint",
    args: [vmAccount.address, approxPayout],
    account: vmAccount,
  });
  await waitForTx(publicClient, mintVmHash, "VM funded with USDC");
  // Approve market
  const approveVmHash = await vmClient.writeContract({
    address: addresses.usdc,
    abi: erc20Abi,
    functionName: "approve",
    args: [addresses.market, approxPayout],
    account: vmAccount,
  });
  await waitForTx(publicClient, approveVmHash, "VM USDC approve");

  // Step 9: VM claims the redeem
  await claimOrder(redeemResult.orderId);

  // Step 10: VM confirms the redeem
  await confirmOrder(redeemResult.orderId, "TSLA");
  await printBalances();
  await printVaultState();

  console.log("\n╔══════════════════════════════════════════════╗");
  console.log("║  Lifecycle Complete!                          ║");
  console.log("╚══════════════════════════════════════════════╝");
}

main().catch((err) => {
  console.error("\n*** LIFECYCLE FAILED ***");
  console.error(err);
  process.exit(1);
});
