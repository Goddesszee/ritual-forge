# Forge

Forge is a factory contract on Ritual Chain that deploys autonomous, self-running "companies." Each one gets its own treasury, wakes itself on a Scheduler loop, and does a job you define using the Ritual LLM precompile. Once it's live, nobody has to keep it running. It funds itself, re-schedules its own next wake-up every cycle, and answers paid requests on its own.

## What's in here

```
hardhat/contracts/
  CompanyFactory.sol      deploys new AutonomousCompany instances
  AutonomousCompany.sol   self-waking company, driven by the LLM precompile
  TestToken.sol           demo ERC20 with public faucet (not used by the live UI)
  SimpleSwap.sol          demo AMM pool (not used by the live UI)
hardhat/ignition/modules/Deploy.ts   deploys the factory plus the demo tokens and pool
index.html               the whole frontend, no build step
vercel.json               static hosting config
```

The live app only uses `CompanyFactory` and `AutonomousCompany`. The token and swap contracts were part of an earlier version of the app and are no longer wired into the UI. They're harmless to leave deployed, and can be removed from the repo later if you want a smaller footprint.

## Live contract

CompanyFactory is deployed on Ritual testnet at:

```
0xE9619D9F67630B71d125b8d97D38Ca517F5CEb8A
```

## How a company works, start to finish

1. Someone calls `CompanyFactory.deployCompany(companyType, systemPrompt, feePerRequest)` with some RITUAL as `msg.value`. That becomes the new company's starting treasury.
2. The factory deploys a fresh `AutonomousCompany` and calls `start()` on it, which registers the first Scheduler wake-up 500 blocks out.
3. On every wake-up, the company calls the LLM precompile (`0x0802`) for a heartbeat status check, logs it, and re-schedules its own next wake-up. Nobody needs to call it again.
4. Anyone can call `requestService(input)` on a company and pay `feePerRequest`. The company runs `input` through the LLM precompile using its own `systemPrompt` as the system message, and the fee adds to its treasury.
5. The company owner can `withdraw()` accumulated treasury at any time.

## Redeploying the contracts yourself

```bash
cd hardhat
npm install
```

Create `hardhat/.env` (do not commit this file):

```
DEPLOYER_PRIVATE_KEY=your_ritual_testnet_private_key
```

Then deploy:

```bash
npx hardhat ignition deploy ignition/modules/Deploy.ts --network ritual
```

Copy the resulting `CompanyFactory` address into `CONFIG.factoryAddress` at the top of `index.html`, then push and redeploy on Vercel.

## Known limitations, stated plainly

- The company's `systemPrompt` is public on chain. Anyone can read it. If a company type needs a private "secret sauce" prompt, that would need the DKMS/ECIES precompile pattern instead, which isn't implemented here yet.
- No swap or bridge feature. An earlier version explored a demo swap and a real-RITUAL-to-USDC pairing, but Ritual Chain has no USDC deployed anywhere (native or bridged) as of this build, so that idea was dropped in favor of keeping Forge focused on its one job: deploying autonomous companies.
