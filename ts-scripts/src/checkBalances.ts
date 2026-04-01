import { addresses, publicClient, userAccount, vmAccount } from "./config.js";
import { erc20Abi } from "./abis.js";
import { formatUnits } from "viem";

async function main() {
  const eTSLA = (await publicClient.readContract({ address: addresses.eTSLA, abi: erc20Abi, functionName: "balanceOf", args: [userAccount.address] })) as bigint;
  const userUSDC = (await publicClient.readContract({ address: addresses.usdc, abi: erc20Abi, functionName: "balanceOf", args: [userAccount.address] })) as bigint;
  const vmUSDC = (await publicClient.readContract({ address: addresses.usdc, abi: erc20Abi, functionName: "balanceOf", args: [vmAccount.address] })) as bigint;

  console.log("User eTSLA:", formatUnits(eTSLA, 18));
  console.log("User USDC:", formatUnits(userUSDC, 6));
  console.log("VM USDC:", formatUnits(vmUSDC, 6));
  console.log("\n25% eTSLA:", formatUnits(eTSLA / 4n, 18));
  console.log("25% raw:", (eTSLA / 4n).toString());
}

main().catch(console.error);
