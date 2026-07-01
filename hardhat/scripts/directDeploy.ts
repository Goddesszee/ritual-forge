import { network } from "hardhat";

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

  console.log("\n=== DEPLOYED ===");
  console.log("CompanyFactory:", factory.address);
  console.log("\nUpdate CONFIG.factoryAddress in index.html to this address.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

