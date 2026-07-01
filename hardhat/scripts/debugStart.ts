import { network } from "hardhat";

const COMPANY_ADDRESS = "0x35217ab76f51f0C36b2fEE8b7a072EEd931b6e3A";

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();

  console.log("Simulating start() on company:", COMPANY_ADDRESS);
  console.log("From:", walletClient.account.address);

  try {
    const { request } = await publicClient.simulateContract({
      address: COMPANY_ADDRESS as `0x${string}`,
      abi: [
        {
          type: "function",
          name: "start",
          stateMutability: "nonpayable",
          inputs: [],
          outputs: [],
        },
      ],
      functionName: "start",
      account: walletClient.account,
    });
    console.log("Simulation SUCCEEDED:", request);
  } catch (err: any) {
    console.log("\n=== SIMULATION FAILED ===");
    console.log("Short message:", err.shortMessage || err.message);
    if (err.cause) {
      console.log("Cause name:", err.cause.name);
      console.log("Cause short message:", err.cause.shortMessage || err.cause.message);
      if (err.cause.data) console.log("Revert data:", err.cause.data);
      if (err.cause.reason) console.log("Decoded reason:", err.cause.reason);
      if (err.cause.cause) {
        console.log("Nested cause:", err.cause.cause.shortMessage || err.cause.cause.message);
      }
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
