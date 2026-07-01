import { network } from "hardhat";

const COMPANY_ADDRESS = "0xA9BD7E178D05961d5b7194dE353dEbc43905244D";
const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";

async function main() {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();

  const walletAbi = [
    {
      name: "balanceOf",
      type: "function",
      stateMutability: "view",
      inputs: [{ name: "account", type: "address" }],
      outputs: [{ type: "uint256" }],
    },
  ] as const;

  const balance = await publicClient.readContract({
    address: RITUAL_WALLET as `0x${string}`,
    abi: walletAbi,
    functionName: "balanceOf",
    args: [COMPANY_ADDRESS as `0x${string}`],
  });
  console.log("Company RitualWallet balance:", balance.toString(), "wei");

  const plainBalance = await publicClient.getBalance({ address: COMPANY_ADDRESS as `0x${string}` });
  console.log("Company plain native balance:", plainBalance.toString(), "wei");

  const block = await publicClient.getBlock();
  console.log("Current block number:", block.number.toString());
  console.log("Current basefee:", block.baseFeePerGas?.toString(), "wei");

  const gasPrice = await publicClient.getGasPrice();
  console.log("Current gas price:", gasPrice.toString(), "wei");

  const estimatedCost = 300000n * (block.baseFeePerGas ? block.baseFeePerGas + 1000000000n : gasPrice);
  console.log("Estimated cost for one execution (gas=300000):", estimatedCost.toString(), "wei");
  console.log("Deposit sufficient?", balance >= estimatedCost);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
