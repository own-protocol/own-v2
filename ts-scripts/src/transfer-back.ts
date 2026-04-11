/**
 * Transfer ownership of AssetRegistry, ETokenFactory & OracleVerifier
 * back from Turnkey wallet to the registry admin (deployer).
 *
 * Usage: npx tsx src/transfer-back.ts
 */
import { publicClient, turnkeyClient, turnkeyAddresses } from "./turnkey-config.js";
import type { Address } from "viem";

const ownableAbi = [
  {
    name: "transferOwnership",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "newOwner", type: "address" }],
    outputs: [],
  },
  {
    name: "owner",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

// Registry admin — original deployer
const NEW_OWNER: Address = "0xa3374B34A855b0bF6b96401D8c367608d9c8a048";

const contracts = [
  { name: "AssetRegistry", address: turnkeyAddresses.assetRegistry },
  { name: "ETokenFactory", address: turnkeyAddresses.eTokenFactory },
  { name: "OracleVerifier", address: turnkeyAddresses.inhouseOracle },
];

async function main() {
  console.log("=== Transfer Ownership Back to Registry Admin ===");
  console.log(`New owner: ${NEW_OWNER}\n`);

  for (const c of contracts) {
    const currentOwner = await publicClient.readContract({
      address: c.address,
      abi: ownableAbi,
      functionName: "owner",
    });
    console.log(`${c.name} (${c.address})`);
    console.log(`  Current owner: ${currentOwner}`);

    if ((currentOwner as string).toLowerCase() === NEW_OWNER.toLowerCase()) {
      console.log(`  Already owned by target, skipping`);
      continue;
    }

    const hash = await turnkeyClient.writeContract({
      address: c.address,
      abi: ownableAbi,
      functionName: "transferOwnership",
      args: [NEW_OWNER],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") throw new Error(`${c.name} transfer reverted`);
    console.log(`  Transferred — tx: ${hash}`);
  }

  console.log("\n=== Done ===");
}

main().catch((err) => {
  console.error("\n*** FAILED ***", err);
  process.exit(1);
});
