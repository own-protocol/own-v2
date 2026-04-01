/**
 * LP deposits WETH into the vault.
 *
 * Usage: npx tsx src/actions/deposit.ts [amount_in_eth]
 * Default: 1 ETH
 */
import { parseEther } from "viem";
import { addresses, publicClient, vmClient, vmAccount } from "../config.js";
import { erc20Abi, vaultAbi } from "../abis.js";
import { waitForTx, formatAmount } from "./utils.js";

export async function deposit(amountEth: string = "1") {
  const amount = parseEther(amountEth);
  console.log(`\n=== LP Deposit: ${amountEth} WETH ===`);

  // 1. Wrap ETH to WETH (Base WETH accepts deposit() with ETH value)
  console.log("Wrapping ETH to WETH...");
  const wrapHash = await vmClient.sendTransaction({
    to: addresses.weth,
    value: amount,
    account: vmAccount,
  });
  await waitForTx(publicClient, wrapHash, "WETH wrap");

  // 2. Approve vault
  console.log("Approving vault for WETH...");
  const approveHash = await vmClient.writeContract({
    address: addresses.weth,
    abi: erc20Abi,
    functionName: "approve",
    args: [addresses.vault, amount],
    account: vmAccount,
  });
  await waitForTx(publicClient, approveHash, "WETH approve");

  // 3. Deposit into vault
  console.log("Depositing into vault...");
  const depositHash = await vmClient.writeContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "deposit",
    args: [amount, vmAccount.address],
    account: vmAccount,
  });
  await waitForTx(publicClient, depositHash, "Vault deposit");

  // 4. Update collateral valuation
  console.log("Updating collateral valuation...");
  const updateHash = await vmClient.writeContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "updateCollateralValuation",
    args: [],
    account: vmAccount,
  });
  await waitForTx(publicClient, updateHash, "Collateral valuation update");

  // 5. Check vault state
  const totalAssets = await publicClient.readContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalAssets",
  });
  console.log(`Vault total assets: ${formatAmount(totalAssets as bigint, 18)} WETH`);
}

// CLI entry point
const amount = process.argv[2] || "1";
deposit(amount).catch(console.error);
