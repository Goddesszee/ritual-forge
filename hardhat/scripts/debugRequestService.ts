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
    console.log("Sending REAL transaction (LLM precompile is async, eth_call can't simulate the commit/settle round-trip)...");
    const txHash = await walletClient.sendTransaction({
      to: latest.addr,
      data: requestData,
      value: latest.feePerRequest,
    });
    console.log("tx sent:", txHash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash, timeout: 120_000 });
    console.log("confirmed in block:", receipt.blockNumber.toString(), "status:", receipt.status);

    if (receipt.status === "success") {
      // Pull the actual response text out of the ServiceDelivered event.
      const eventAbi = [{
        type: "event", name: "ServiceDelivered",
        inputs: [
          { name: "requester", type: "address", indexed: true },
          { name: "fee", type: "uint256", indexed: false },
          { name: "output", type: "string", indexed: false },
        ],
      }] as const;
      const logs = await publicClient.getContractEvents({
        address: latest.addr,
        abi: eventAbi,
        eventName: "ServiceDelivered",
        fromBlock: receipt.blockNumber,
        toBlock: receipt.blockNumber,
      });
      console.log("\n=== LLM RESPONSE ===");
      console.log(logs.length > 0 ? logs[0].args.output : "(no ServiceDelivered event found in this block)");
    } else {
      console.log("Transaction reverted on-chain.");
    }
  } catch (err: any) {
    console.log("FAILED:", err.shortMessage || err.message);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
