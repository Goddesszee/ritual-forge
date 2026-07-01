import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("RitualAgentFactoryModule", (m) => {
  const factory = m.contract("CompanyFactory");

  const tokenA = m.contract("TestToken", ["Ritual Token A", "RTA", 1_000_000n * 10n ** 18n], {
    id: "TokenA",
  });
  const tokenB = m.contract("TestToken", ["Ritual Token B", "RTB", 1_000_000n * 10n ** 18n], {
    id: "TokenB",
  });

  const swap = m.contract("SimpleSwap", [tokenA, tokenB]);

  return { factory, tokenA, tokenB, swap };
});
