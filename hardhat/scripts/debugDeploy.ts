import hre from "hardhat";
import { parseEther } from "viem";

const FACTORY_ADDRESS = "0xE9619D9F67630B71d125b8d97D38Ca517F5CEb8A";

async function main() {
  const publicClient = await hre.viem.getPublicClient();
  const [walletClient] = await hre.viem.getWalletClients();

  console.log("Simulating deployCompany() from:", walletClient.account.address);

  try {
    const { request } = await publicClient.simulateContract({
      address: FACTORY_ADDRESS,
      abi: [
        {
          type: "function",
          name: "deployCompany",
          stateMutability: "payable",
          inputs: [
            { name: "companyType", type: "string" },
            { name: "systemPrompt", type: "string" },
            { name: "feePerRequest", type: "uint256" },
          ],
          outputs: [{ name: "companyAddress", type: "address" }],
        },
      ],
      functionName: "deployCompany",
      args: ["Test Scorer", "You are a test agent. Respond briefly to confirm you are operating.", parseEther("0.001")],
      value: parseEther("0.01"),
      account: walletClient.account,
    });
    console.log("Simulation SUCCEEDED. This would have worked:", request);
  } catch (err: any) {
    console.log("\n=== SIMULATION FAILED ===");
    console.log("Short message:", err.shortMessage || err.message);
    if (err.cause) {
      console.log("Cause:", err.cause.shortMessage || err.cause.message);
      if (err.cause.data) console.log("Revert data:", err.cause.data);
      if (err.cause.reason) console.log("Decoded reason:", err.cause.reason);
    }
    console.log("\nFull error:", JSON.stringify(err, Object.getOwnPropertyNames(err), 2).slice(0, 3000));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
