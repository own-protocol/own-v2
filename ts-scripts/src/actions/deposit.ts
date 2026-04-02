/**
 * LP deposits WETH into the vault.
 *
 * Usage: npx tsx src/actions/deposit.ts [amount_in_eth]
 * Default: 1 ETH
 */
import { parseEther } from "viem";
import { addresses, publicClient, vmClient, vmAccount, useMockWeth } from "../config.js";
import { erc20Abi, vaultAbi } from "../abis.js";
import { writeContract, sendTx, formatAmount } from "./utils.js";

export async function deposit(amountEth: string = "1") {
  const amount = parseEther(amountEth);
  if (amount === 0n) {
    console.log("Error: deposit amount must be > 0");
    return;
  }
  console.log(`\n=== LP Deposit: ${amountEth} WETH ===`);

  // 1. Check existing WETH balance, only wrap the shortfall
  const wethBalance = (await publicClient.readContract({
    address: addresses.weth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vmAccount.address],
  })) as bigint;
  console.log(`  Current WETH balance: ${formatAmount(wethBalance, 18)}`);

  if (wethBalance < amount) {
    const toWrap = amount - wethBalance;
    if (useMockWeth) {
      console.log(`  Minting ${formatAmount(toWrap, 18)} MockWETH (free testnet mint)...`);
      await writeContract(
        vmClient,
        {
          address: addresses.weth,
          abi: erc20Abi,
          functionName: "mint",
          args: [vmAccount.address, toWrap],
        },
        "MockWETH mint"
      );
    } else {
      console.log(`  Wrapping ${formatAmount(toWrap, 18)} ETH → WETH...`);
      await sendTx(vmClient, { to: addresses.weth, value: toWrap }, "WETH wrap");
    }
  } else {
    console.log("  Sufficient WETH balance, skipping.");
  }

  // 2. Approve vault
  console.log("Approving vault for WETH...");
  await writeContract(
    vmClient,
    {
      address: addresses.weth,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.vault, amount],
    },
    "WETH approve"
  );

  // 3. Deposit into vault
  console.log("Depositing into vault...");
  await writeContract(
    vmClient,
    {
      address: addresses.vault,
      abi: vaultAbi,
      functionName: "deposit",
      args: [amount, vmAccount.address],
    },
    "Vault deposit"
  );

  // 4. Update collateral valuation
  console.log("Updating collateral valuation...");
  await writeContract(
    vmClient,
    {
      address: addresses.vault,
      abi: vaultAbi,
      functionName: "updateCollateralValuation",
      args: [],
    },
    "Collateral valuation update"
  );

  // 5. Check vault state
  const totalAssets = await publicClient.readContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalAssets",
  });
  console.log(
    `Vault total assets: ${formatAmount(totalAssets as bigint, 18)} WETH`
  );
}

