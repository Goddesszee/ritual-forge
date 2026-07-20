import { network } from "hardhat";

const FACTORY_ADDRESS = "0x0eeed877081103d38d3386a93ed698484f981f3d";
const WAKE_INTERVAL = 500;

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

const COMPANY_ABI = [
  { type: "function", name: "running", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "wakeCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "lastWakeBlock", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "lastHeartbeat", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "lastHeartbeatExecutor", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "scheduleId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "requestCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "treasuryBalance", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();

  const companies = await publicClient.readContract({
    address: FACTORY_ADDRESS as `0x${string}`,
    abi: FACTORY_ABI,
    functionName: "getAllCompanies",
  });
  const latest = companies[companies.length - 1];
  const addr = latest.addr as `0x${string}`;

  const [running, wakeCount, lastWakeBlock, lastHeartbeat, lastHeartbeatExecutor, scheduleId, requestCount, treasuryBalance, currentBlock] =
    await Promise.all([
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "running" }),
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "wakeCount" }),
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "lastWakeBlock" }),
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "lastHeartbeat" }),
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "lastHeartbeatExecutor" }),
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "scheduleId" }),
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "requestCount" }),
      publicClient.readContract({ address: addr, abi: COMPANY_ABI, functionName: "treasuryBalance" }),
      publicClient.getBlockNumber(),
    ]);

  const blocksSinceWake = currentBlock - lastWakeBlock;

  console.log("=== Company:", addr, "(" + latest.companyType + ") ===");
  console.log("running:", running);
  console.log("scheduleId:", scheduleId.toString(), scheduleId === 0n ? "<- 0 means no live Scheduler callback (dead unless kicked)" : "");
  console.log("wakeCount:", wakeCount.toString());
  console.log("lastWakeBlock:", lastWakeBlock.toString());
  console.log("currentBlock:", currentBlock.toString());
  console.log("blocksSinceWake:", blocksSinceWake.toString(), "(wake interval is", WAKE_INTERVAL, "blocks)");
  console.log("overdue for a wake?", wakeCount > 0n ? blocksSinceWake > BigInt(WAKE_INTERVAL) + 50n : "n/a — hasn't woken even once yet");
  console.log("lastHeartbeat:", lastHeartbeat || "(empty — no heartbeat recorded yet)");
  console.log("lastHeartbeatExecutor:", lastHeartbeatExecutor);
  console.log("requestCount:", requestCount.toString());
  console.log("treasuryBalance:", treasuryBalance.toString(), "wei");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
