import { network } from "hardhat";
import { encodeFunctionData } from "viem";

const FACTORY_ADDRESS = "0x0eeed877081103d38d3386a93ed698484f981f3d";

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
    args: ["Buyer claims item never arrived. Seller provided tracking showing delivery confirmed. No photo proof."],
  });

  // Try eth_call first — cheap, and on a genuine revert (not just an async
  // LLM-precompile timing issue) it often surfaces the real revert reason
  // directly instead of costing a real tx to find out.
  try {
    console.log("Simulating via eth_call first...");
    await publicClient.call({
      to: latest.addr,
      data: requestData,
      value: latest.feePerRequest,
      account: walletClient.account,
    });
    console.log("eth_call succeeded (doesn't guarantee the real tx will, since the LLM precompile is async — but no revert at least).");
  } catch (simErr: any) {
    console.log("eth_call reverted:", simErr.shortMessage || simErr.message);
    if (simErr.cause) console.log("cause:", JSON.stringify(simErr.cause).slice(0, 1000));
  }

  try {
    console.log("\nSending REAL transaction (LLM precompile is async, eth_call can't fully simulate the commit/settle round-trip)...");
    const txHash = await walletClient.sendTransaction({
      to: latest.addr,
      data: requestData,
      value: latest.feePerRequest,
      gas: 3_000_000n,
    });
    console.log("tx sent:", txHash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash, timeout: 120_000 });
    console.log("confirmed in block:", receipt.blockNumber.toString(), "status:", receipt.status);

    if (receipt.status === "success") {
      // Pull the actual response text out of the ServiceDelivered event.
      // Includes `executor` now — the TEE node address that produced this
      // verdict, added alongside per-request proof tracking.
      const eventAbi = [{
        type: "event", name: "ServiceDelivered",
        inputs: [
          { name: "requester", type: "address", indexed: true },
          { name: "fee", type: "uint256", indexed: false },
          { name: "output", type: "string", indexed: false },
          { name: "executor", type: "address", indexed: false },
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
      console.log("\n=== ANSWERED BY (executor) ===");
      console.log(logs.length > 0 ? logs[0].args.executor : "(none)");
    } else {
      console.log("Transaction reverted on-chain. Trying debug_traceTransaction for the real execution trace...");
      try {
        const trace: any = await publicClient.request({
          method: "debug_traceTransaction" as any,
          params: [txHash, { tracer: "callTracer" }] as any,
        });
        console.log(JSON.stringify(trace, null, 2).slice(0, 3000));
      } catch (traceErr: any) {
        console.log("debug_traceTransaction not available:", traceErr.shortMessage || traceErr.message);
      }
    }
  } catch (err: any) {
    console.log("FAILED:", err.shortMessage || err.message);
    if (err.cause) console.log("cause:", JSON.stringify(err.cause).slice(0, 1000));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
