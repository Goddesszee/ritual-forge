import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("RitualAgentFactoryModule", (m) => {
  const factory = m.contract("CompanyFactory");

  // FORGE token + native RITUAL <-> FORGE swap pool. Deployed with an
  // empty pool — no liquidity is seeded here, since that requires
  // sending real testnet RITUAL as msg.value, which Ignition modules
  // don't do well for a value-bearing call like this. Run
  // `scripts/seedForgeLiquidity.ts` after this deploy to seed it.
  const forgeToken = m.contract("ForgeToken", [1_000_000n * 10n ** 18n]);
  const swap = m.contract("RitualForgeSwap", [forgeToken]);

  return { factory, forgeToken, swap };
});
