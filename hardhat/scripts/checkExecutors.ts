import { network } from "hardhat";

const TEE_REGISTRY = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();

  const abi = [{
    name: "getServicesByCapability",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "capability", type: "uint8" }, { name: "checkValidity", type: "bool" }],
    outputs: [{
      name: "services",
      type: "tuple[]",
      components: [
        { name: "node", type: "tuple", components: [
          { name: "paymentAddress", type: "address" },
          { name: "teeAddress", type: "address" },
          { name: "teeType", type: "uint8" },
          { name: "publicKey", type: "bytes" },
          { name: "endpoint", type: "string" },
          { name: "certPubKeyHash", type: "bytes32" },
          { name: "capability", type: "uint8" },
        ]},
        { name: "isValid", type: "bool" },
        { name: "workloadId", type: "bytes32" },
      ],
    }],
  }] as const;

  console.log("Checking LLM executors (capability=1, checkValidity=true)...");
  const services = await publicClient.readContract({
    address: TEE_REGISTRY as `0x${string}`,
    abi,
    functionName: "getServicesByCapability",
    args: [1, true],
  });

  console.log("Number of valid LLM executors found:", services.length);
  for (const s of services) {
    console.log("  teeAddress:", s.node.teeAddress, "isValid:", s.isValid, "capability:", s.node.capability);
  }

  if (services.length === 0) {
    console.log("\n*** NO VALID EXECUTORS — this alone would cause every LLM call to revert. ***");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
