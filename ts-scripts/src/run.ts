/**
 * CLI runner for all actions.
 *
 * Usage:
 *   npx tsx src/run.ts deposit [amount_eth]
 *   npx tsx src/run.ts place-mint [usdc_amount] [asset]
 *   npx tsx src/run.ts claim <orderId>
 *   npx tsx src/run.ts confirm <orderId> [asset] [sessionId]
 *   npx tsx src/run.ts place-redeem [etoken_amount] [asset]
 *   npx tsx src/run.ts cancel <orderId>
 *   npx tsx src/run.ts balances
 */
import { deposit } from "./actions/deposit.js";
import { placeMint } from "./actions/placeMint.js";
import { claimOrder } from "./actions/claimOrder.js";
import { confirmOrder } from "./actions/confirmOrder.js";
import { placeRedeem } from "./actions/placeRedeem.js";
import { cancelOrder } from "./actions/cancelOrder.js";
import { addresses, publicClient, userAccount, vmAccount } from "./config.js";
import { erc20Abi } from "./abis.js";
import { formatUnits } from "viem";

const COMMANDS: Record<string, string> = {
  deposit: "deposit [amount_eth]         — LP deposits WETH into vault",
  "place-mint": "place-mint [usdc] [asset]    — User places a mint order",
  claim: "claim <orderId>              — VM claims an order",
  confirm: "confirm <orderId> [asset] [session] — VM confirms with price proof",
  "place-redeem": "place-redeem [amount] [asset] — User places a redeem order",
  cancel: "cancel <orderId>             — User cancels an open order",
  balances: "balances                     — Show user/VM balances",
};

function usage() {
  console.log("\nUsage: npx tsx src/run.ts <command> [args...]\n");
  console.log("Commands:");
  for (const [, desc] of Object.entries(COMMANDS)) {
    console.log(`  ${desc}`);
  }
  process.exit(1);
}

async function balances() {
  const [userETSLA, userUSDC, vmUSDC] = await Promise.all([
    publicClient.readContract({ address: addresses.eTSLA, abi: erc20Abi, functionName: "balanceOf", args: [userAccount.address] }) as Promise<bigint>,
    publicClient.readContract({ address: addresses.usdc, abi: erc20Abi, functionName: "balanceOf", args: [userAccount.address] }) as Promise<bigint>,
    publicClient.readContract({ address: addresses.usdc, abi: erc20Abi, functionName: "balanceOf", args: [vmAccount.address] }) as Promise<bigint>,
  ]);
  console.log("\n--- Balances ---");
  console.log(`  User eTSLA:  ${formatUnits(userETSLA, 18)}`);
  console.log(`  User USDC:   ${formatUnits(userUSDC, 6)}`);
  console.log(`  VM USDC:     ${formatUnits(vmUSDC, 6)}`);
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (!command) usage();

  switch (command) {
    case "deposit":
      await deposit(args[0] || "1");
      break;

    case "place-mint":
      await placeMint(args[0] || "100", (args[1] as "TSLA" | "GOLD") || "TSLA");
      break;

    case "claim":
      if (!args[0]) { console.error("Error: orderId required"); usage(); }
      await claimOrder(BigInt(args[0]));
      break;

    case "confirm":
      if (!args[0]) { console.error("Error: orderId required"); usage(); }
      await confirmOrder(
        BigInt(args[0]),
        (args[1] as "TSLA" | "GOLD") || "TSLA",
        args[2] ? parseInt(args[2]) : undefined
      );
      break;

    case "place-redeem":
      await placeRedeem(args[0], (args[1] as "TSLA" | "GOLD") || "TSLA");
      break;

    case "cancel":
      if (!args[0]) { console.error("Error: orderId required"); usage(); }
      await cancelOrder(BigInt(args[0]));
      break;

    case "balances":
      await balances();
      break;

    default:
      console.error(`Unknown command: ${command}`);
      usage();
  }
}

main().catch((err) => {
  console.error("\n*** FAILED ***");
  console.error(err.shortMessage || err.message);
  process.exit(1);
});
