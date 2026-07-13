import { network } from "hardhat";

const SWAP_ADDRESS = "0xE77408fA0292a164AC270d54C1d669314AA6EC50";
const FORGE_TOKEN_ADDRESS = "0xD138Db50B091a0Fa639114CF37757551fbdAFa90";

async function main() {
  const { viem } = await network.connect();
  const [deployer] = await viem.getWalletClients();

  console.log("Deploying DCABotFactory from:", deployer.account.address);
  console.log("Swap address:", SWAP_ADDRESS);
  console.log("Forge token:", FORGE_TOKEN_ADDRESS);

  const factory = await viem.deployContract("DCABotFactory", [SWAP_ADDRESS, FORGE_TOKEN_ADDRESS]);

  console.log("\nDCABotFactory deployed at:", factory.address);
  console.log("\nUpdate CONFIG.dcaBotFactoryAddress in index.html with this address.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
