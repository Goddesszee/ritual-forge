import { network } from "hardhat";
import { parseEther, encodeFunctionData } from "viem";

const FACTORY_ADDRESS = "0xfa4e8999075a68f33f055d91415bcd41720a4304";

const FACTORY_ABI = [
  {
    type: "function", name: "deployCompany", stateMutability: "payable",
    inputs: [
      { name: "companyType", type: "string" },
      { name: "systemPrompt", type: "string" },
      { name: "feePerRequest", type: "uint256" },
    ],
    outputs: [{ name: "companyAddress", type: "address" }],
  },
] as const;

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();

  console.log("Deploying a fresh test company...");
  const deployData = encodeFunctionData({
    abi: FACTORY_ABI,
    functionName: "deployCompany",
    args: ["Isolation Test 2", "You are a test agent.", parseEther("0.001")],
  });

  const deployHash = await walletClient.sendTransaction({
    to: FACTORY_ADDRESS as `0x${string}`,
    data: deployData,
    value: parseEther("0.05"),
  });
  console.log("Deploy tx sent:", deployHash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash: deployHash });
  console.log("Deploy confirmed in block:", receipt.blockNumber.toString());

  const logs = await publicClient.getLogs({
    address: FACTORY_ADDRESS as `0x${string}`,
    fromBlock: receipt.blockNumber,
    toBlock: receipt.blockNumber,
  });
  const companyAddress = ("0x" + logs[0].topics[1]?.slice(26)) as `0x${string}`;
  console.log("New company address:", companyAddress);

  // STEP 1: send fundWalletOnly() as a REAL transaction, not a simulation.
  console.log("\n>>> Sending fundWalletOnly() for REAL...");
  const fundData = encodeFunctionData({
    abi: [{ type: "function", name: "fundWalletOnly", stateMutability: "nonpayable", inputs: [], outputs: [] }],
    functionName: "fundWalletOnly",
  });
  const fundHash = await walletClient.sendTransaction({ to: companyAddress, data: fundData });
  console.log("    fund tx sent:", fundHash);
  const fundReceipt = await publicClient.waitForTransactionReceipt({ hash: fundHash });
  console.log("    fund confirmed in block:", fundReceipt.blockNumber.toString(), "status:", fundReceipt.status);

  // Verify the RitualWallet balance actually changed on-chain.
  const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";
  const balance = await publicClient.readContract({
    address: RITUAL_WALLET as `0x${string}`,
    abi: [{ name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] }],
    functionName: "balanceOf",
    args: [companyAddress],
  });
  console.log("    Company RitualWallet balance NOW:", balance.toString(), "wei");

  // STEP 2: now test scheduleOnly() for real, against the genuinely funded state.
  console.log("\n>>> Sending scheduleOnly() for REAL...");
  const scheduleData = encodeFunctionData({
    abi: [{ type: "function", name: "scheduleOnly", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] }],
    functionName: "scheduleOnly",
  });
  try {
    const scheduleHash = await walletClient.sendTransaction({ to: companyAddress, data: scheduleData });
    console.log("    schedule tx sent:", scheduleHash);
    const scheduleReceipt = await publicClient.waitForTransactionReceipt({ hash: scheduleHash });
    console.log("    schedule confirmed in block:", scheduleReceipt.blockNumber.toString(), "status:", scheduleReceipt.status);
    if (scheduleReceipt.status === "success") {
      console.log("\n=== scheduleOnly() WORKED FOR REAL ===");
    } else {
      console.log("\n=== scheduleOnly() transaction REVERTED ===");
    }
  } catch (err: any) {
    console.log("    FAILED to send:", err.shortMessage || err.message);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
