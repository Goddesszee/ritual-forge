import { network } from "hardhat";
import { encodeFunctionData } from "viem";

const COMPANY_ADDRESS = "0xcA587628c3730C95B9810DdF013Fb0131aE3e711";

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();

  console.log("Raw eth_call simulation of start() on:", COMPANY_ADDRESS);
  console.log("From:", walletClient.account.address);

  const startAbi = [
    { type: "function", name: "start", stateMutability: "nonpayable", inputs: [], outputs: [] },
  ] as const;

  const data = encodeFunctionData({ abi: startAbi, functionName: "start" });

  try {
    const result = await publicClient.call({
      account: walletClient.account,
      to: COMPANY_ADDRESS as `0x${string}`,
      data,
    });
    console.log("SUCCEEDED, return data:", result);
  } catch (err: any) {
    console.log("\n=== RAW CALL FAILED ===");
    console.log("Full error object keys:", Object.keys(err));
    console.log("err.details:", err.details);
    console.log("err.shortMessage:", err.shortMessage);
    console.log("err.metaMessages:", err.metaMessages);

    // Walk the cause chain and print every layer's data field
    let current = err;
    let depth = 0;
    while (current && depth < 6) {
      console.log(`\n--- depth ${depth} ---`);
      console.log("name:", current.name);
      console.log("message:", (current.message || "").slice(0, 300));
      if (current.data) console.log("RAW DATA:", current.data);
      if (current.signature) console.log("signature:", current.signature);
      if (current.errorName) console.log("errorName:", current.errorName);
      current = current.cause;
      depth++;
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
