import { network } from "hardhat";
import { encodeFunctionData } from "viem";

const FACTORY_ADDRESS = "0x84eb65fff1d8418ca3b625a0b4a7b39b6c335688";

const FACTORY_ABI = [
  {
    type: "function", name: "getAllCompanies", stateMutability: "view",
    inputs: [],
    outputs: [{
      type: "tuple[]", components: [
        { name: "addr", type: "address" },
        { name: "owner", type: "address" },
        { name: "companyType", type: "string" },
        { name: "feePerRequest", type: "uint256" },
        { name: "createdAt", type: "uint256" },
      ],
    }],
  },
] as const;

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();
  const account = walletClient.account;

  const companies = await publicClient.readContract({
    address: FACTORY_ADDRESS as `0x${string}`,
    abi: FACTORY_ABI,
    functionName: "getAllCompanies",
  });
  const latest = companies[companies.length - 1];
  console.log("Testing latest company:", latest.addr, "fee:", latest.feePerRequest.toString());

  const requestData = encodeFunctionData({
    abi: [{ type: "function", name: "requestService", stateMutability: "payable", inputs: [{ name: "input", type: "string" }], outputs: [{ type: "string" }] }],
    functionName: "requestService",
    args: ["0x86b245d0b48bbdc58f08caea971a24ba377c366a"],
  });

  try {
    const result = await publicClient.call({
      account,
      to: latest.addr,
      data: requestData,
      value: latest.feePerRequest,
    });
    console.log("SUCCEEDED:", result);
  } catch (err: any) {
    let current = err;
    let rawData = null;
    let depth = 0;
    while (current && depth < 8) {
      console.log(`--- depth ${depth}: ${current.name} ---`);
      if (current.message) console.log("  message:", current.message.slice(0, 200));
      if (current.data && typeof current.data === "string" && current.data.startsWith("0x")) {
        console.log("  DATA:", current.data);
        rawData = current.data;
      }
      current = current.cause;
      depth++;
    }
    console.log("\nFinal raw data found:", rawData);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
