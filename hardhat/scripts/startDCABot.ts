import { network } from "hardhat";

const DCABOT_ADDRESS = "0x8c4c4ab5021323a1edec7158a37408041f8d3c99";

const DCABOT_ABI = [
  {
    name: "start",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    name: "running",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bool" }],
  },
] as const;

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [owner] = await viem.getWalletClients();

  console.log("Starting DCABot from:", owner.account.address);

  const hash = await owner.writeContract({
    address: DCABOT_ADDRESS as `0x${string}`,
    abi: DCABOT_ABI,
    functionName: "start",
  });
  console.log("tx sent:", hash);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("tx status:", receipt.status);

  const running = await publicClient.readContract({
    address: DCABOT_ADDRESS as `0x${string}`,
    abi: DCABOT_ABI,
    functionName: "running",
  });
  console.log("running:", running);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
