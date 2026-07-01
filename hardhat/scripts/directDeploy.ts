import { network } from "hardhat";
import { parseEther } from "viem";

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();

  console.log("Deploying from:", walletClient.account.address);
  const nonce = await publicClient.getTransactionCount({ address: walletClient.account.address });
  console.log("Current nonce:", nonce);

  console.log("\nDeploying CompanyFactory...");
  const factory = await viem.deployContract("CompanyFactory", []);
  console.log("CompanyFactory deployed at:", factory.address);

  console.log("\nDeploying TokenA...");
  const tokenA = await viem.deployContract("TestToken", ["Ritual Token A", "RTA", parseEther("1000000")]);
  console.log("TokenA deployed at:", tokenA.address);

  console.log("\nDeploying TokenB...");
  const tokenB = await viem.deployContract("TestToken", ["Ritual Token B", "RTB", parseEther("1000000")]);
  console.log("TokenB deployed at:", tokenB.address);

  console.log("\nDeploying SimpleSwap...");
  const swap = await viem.deployContract("SimpleSwap", [tokenA.address, tokenB.address]);
  console.log("SimpleSwap deployed at:", swap.address);

  console.log("\n=== ALL DEPLOYED ===");
  console.log("CompanyFactory:", factory.address);
  console.log("TokenA:", tokenA.address);
  console.log("TokenB:", tokenB.address);
  console.log("SimpleSwap:", swap.address);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
