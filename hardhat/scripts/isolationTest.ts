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

async function rawCall(publicClient: any, account: any, to: `0x${string}`, data: `0x${string}`, label: string) {
  console.log(`\n>>> Testing: ${label}`);
  try {
    const result = await publicClient.call({ account, to, data });
    console.log(`    SUCCESS. Return data:`, result.data);
    return true;
  } catch (err: any) {
    let current = err;
    let rawData = null;
    while (current) {
      if (current.data && typeof current.data === "string" && current.data.startsWith("0x") && current.data.length >= 10) {
        rawData = current.data;
      }
      current = current.cause;
    }
    console.log(`    FAILED. Raw error data:`, rawData || "(none found)");
    console.log(`    Short message:`, err.shortMessage || err.message);
    return false;
  }
}

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();
  const account = walletClient.account;

  console.log("Deploying a fresh test company...");
  const deployData = encodeFunctionData({
    abi: FACTORY_ABI,
    functionName: "deployCompany",
    args: ["Isolation Test", "You are a test agent.", parseEther("0.001")],
  });

  const deployHash = await walletClient.sendTransaction({
    to: FACTORY_ADDRESS as `0x${string}`,
    data: deployData,
    value: parseEther("0.05"),
  });
  console.log("Deploy tx sent:", deployHash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash: deployHash });
  console.log("Deploy confirmed in block:", receipt.blockNumber.toString());

  // Get the deployed company address from the CompanyDeployed event
  const logs = await publicClient.getLogs({
    address: FACTORY_ADDRESS as `0x${string}`,
    fromBlock: receipt.blockNumber,
    toBlock: receipt.blockNumber,
  });
  console.log("Logs found:", logs.length);
  // The company address is the first indexed topic after the event signature
  const companyAddress = logs.length > 0 ? ("0x" + logs[0].topics[1]?.slice(26)) as `0x${string}` : null;
  console.log("New company address:", companyAddress);

  if (!companyAddress) {
    console.log("Could not extract company address from logs, aborting isolation tests.");
    return;
  }

  const fundData = encodeFunctionData({
    abi: [{ type: "function", name: "fundWalletOnly", stateMutability: "nonpayable", inputs: [], outputs: [] }],
    functionName: "fundWalletOnly",
  });
  const fundOk = await rawCall(publicClient, account, companyAddress, fundData, "fundWalletOnly()");

  // Sanity check: call a function that should DEFINITELY fail with a KNOWN,
  // computable error (InsufficientFee, since feePerRequest > 0 and we send 0),
  // to verify our error-extraction logic actually works correctly.
  const requestServiceData = encodeFunctionData({
    abi: [{ type: "function", name: "requestService", stateMutability: "payable", inputs: [{ name: "input", type: "string" }], outputs: [{ type: "string" }] }],
    functionName: "requestService",
    args: ["test"],
  });
  console.log("\n--- Sanity check: calling requestService() with 0 value, expect InsufficientFee ---");
  await rawCall(publicClient, account, companyAddress, requestServiceData, "requestService() [expect InsufficientFee selector, NOT 0x13a6fe64]");

  const scheduleData = encodeFunctionData({
    abi: [{ type: "function", name: "scheduleOnly", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint256" }] }],
    functionName: "scheduleOnly",
  });
  const scheduleOk = await rawCall(publicClient, account, companyAddress, scheduleData, "scheduleOnly()");

  console.log("\n=== RESULT ===");
  console.log("fundWalletOnly:", fundOk ? "WORKS" : "FAILS");
  console.log("scheduleOnly:", scheduleOk ? "WORKS" : "FAILS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
