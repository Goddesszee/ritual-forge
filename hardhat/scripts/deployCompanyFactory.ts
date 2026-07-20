import { network } from "hardhat";

async function main() {
  const { viem } = await network.connect();
  const [deployer] = await viem.getWalletClients();

  console.log("Deploying CompanyFactory from:", deployer.account.address);
  console.log("(This deploys the updated AutonomousCompany bytecode too — every");
  console.log(" company created through this new factory will log/emit the TEE");
  console.log(" executor address that answered each request.)");

  const factory = await viem.deployContract("CompanyFactory");

  console.log("\nCompanyFactory deployed at:", factory.address);
  console.log("\nUpdate CONFIG.factoryAddress in index.html with this address.");
  console.log("Note: companies deployed under the OLD factory keep the old");
  console.log("behavior (no executor tracking) — only new deploys through this");
  console.log("factory get per-verdict proof.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
