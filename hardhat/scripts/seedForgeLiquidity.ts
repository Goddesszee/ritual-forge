import { network } from "hardhat";

// Fill these in after running the Ignition deploy.
const FORGE_TOKEN_ADDRESS = "0xYOUR_FORGE_TOKEN_ADDRESS";
const SWAP_ADDRESS = "0xYOUR_SWAP_ADDRESS";

// How much of each side to seed. This sets the initial FORGE/RITUAL
// price for the pool — 1,000 FORGE : 1 RITUAL below just means "1 RITUAL
// buys ~1,000 FORGE at the start"; pick whatever ratio makes sense to you.
const RITUAL_TO_SEED = 10n ** 18n / 10n; // 0.1 RITUAL
const FORGE_TO_SEED = 100n * 10n ** 18n; // 100 FORGE

const ERC20_ABI = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

const SWAP_ABI = [
  {
    name: "addLiquidity",
    type: "function",
    stateMutability: "payable",
    inputs: [{ name: "forgeAmount", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();

  console.log("Seeding from:", walletClient.account.address);

  const forgeBalance = await publicClient.readContract({
    address: FORGE_TOKEN_ADDRESS as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [walletClient.account.address],
  });
  console.log("Deployer FORGE balance:", forgeBalance.toString());
  if (forgeBalance < FORGE_TO_SEED) {
    throw new Error("Deployer doesn't hold enough FORGE to seed. Did you deploy ForgeToken to this account?");
  }

  console.log("\nApproving swap contract for", FORGE_TO_SEED.toString(), "FORGE...");
  const approveHash = await walletClient.writeContract({
    address: FORGE_TOKEN_ADDRESS as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [SWAP_ADDRESS as `0x${string}`, FORGE_TO_SEED],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });
  console.log("Approved.");

  console.log("\nSeeding liquidity:", RITUAL_TO_SEED.toString(), "wei RITUAL +", FORGE_TO_SEED.toString(), "FORGE...");
  const seedHash = await walletClient.writeContract({
    address: SWAP_ADDRESS as `0x${string}`,
    abi: SWAP_ABI,
    functionName: "addLiquidity",
    args: [FORGE_TO_SEED],
    value: RITUAL_TO_SEED,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: seedHash });
  console.log("Seeded. tx status:", receipt.status);
  console.log("\nUpdate CONFIG.forgeTokenAddress and CONFIG.swapAddress in index.html.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
