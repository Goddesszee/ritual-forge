import { network } from "hardhat";

// Fill these in with your current live RitualForgeSwap + ForgeToken addresses
// (same ones already in CONFIG at the top of index.html).
const SWAP_ADDRESS = "0xYOUR_SWAP_ADDRESS";
const FORGE_TOKEN_ADDRESS = "0xYOUR_FORGE_TOKEN_ADDRESS";

// How much RITUAL the bot spends on FORGE every single wake cycle.
const SWAP_AMOUNT_PER_CYCLE = 10n ** 16n; // 0.01 RITUAL per cycle

// Initial funding sent with deployment. Needs to comfortably cover the
// 0.06 RITUAL Scheduler escrow deposit plus a few swap cycles on top,
// or start() will only be able to deposit whatever it actually has.
const INITIAL_FUNDING = 10n ** 17n; // 0.1 RITUAL

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [deployer] = await viem.getWalletClients();

  console.log("Deploying DCABot from:", deployer.account.address);
  console.log("Swap address:", SWAP_ADDRESS);
  console.log("Forge token:", FORGE_TOKEN_ADDRESS);
  console.log("Per-cycle swap amount:", SWAP_AMOUNT_PER_CYCLE.toString(), "wei");
  console.log("Initial funding:", INITIAL_FUNDING.toString(), "wei");

  const bot = await viem.deployContract(
    "DCABot",
    [SWAP_ADDRESS, FORGE_TOKEN_ADDRESS, SWAP_AMOUNT_PER_CYCLE],
    { value: INITIAL_FUNDING }
  );

  console.log("\nDCABot deployed at:", bot.address);
  console.log("\nNext step: call start() on it to register the first wake-up.");
  console.log("You can do this via a small script, or through a block explorer's 'Write Contract' tab once verified.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
