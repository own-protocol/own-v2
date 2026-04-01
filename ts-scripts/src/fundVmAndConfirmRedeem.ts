import { addresses, publicClient, vmClient, vmAccount, userAccount, PRECISION } from "./config.js";
import { erc20Abi, marketAbi } from "./abis.js";
import { writeContract, formatPrice, formatAmount } from "./actions/utils.js";
import { confirmOrder } from "./actions/confirmOrder.js";

async function main() {
  const orderId = 4n;

  // Read the order
  const order = (await publicClient.readContract({
    address: addresses.market,
    abi: marketAbi,
    functionName: "getOrder",
    args: [orderId],
  })) as any;

  const eTokenAmount = order.amount as bigint;
  const orderPrice = order.price as bigint;
  const grossPayout = (eTokenAmount * orderPrice) / (PRECISION * 10n ** 12n);

  console.log(`  eToken amount: ${formatAmount(eTokenAmount, 18)}`);
  console.log(`  Order price: ${formatPrice(orderPrice)}`);
  console.log(`  Gross payout needed: ${formatAmount(grossPayout, 6)} USDC`);

  // Check VM USDC balance
  const vmUSDC = (await publicClient.readContract({
    address: addresses.usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vmAccount.address],
  })) as bigint;
  console.log(`  VM USDC balance: ${formatAmount(vmUSDC, 6)}`);

  // Approve market for USDC
  console.log("\nVM approving market for USDC...");
  await writeContract(
    vmClient,
    {
      address: addresses.usdc,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.market, grossPayout],
    },
    "VM USDC approve"
  );

  // Check user USDC before
  const userUSDCBefore = (await publicClient.readContract({
    address: addresses.usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [userAccount.address],
  })) as bigint;
  console.log(`\nUser USDC before: ${formatAmount(userUSDCBefore, 6)}`);

  // Confirm the redeem
  await confirmOrder(orderId, "TSLA");

  // Check user USDC after
  const userUSDCAfter = (await publicClient.readContract({
    address: addresses.usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [userAccount.address],
  })) as bigint;
  console.log(`\nUser USDC after: ${formatAmount(userUSDCAfter, 6)}`);
  console.log(`USDC received: ${formatAmount(userUSDCAfter - userUSDCBefore, 6)}`);
}

main().catch(console.error);
