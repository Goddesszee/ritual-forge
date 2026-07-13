# Forge

Forge is a factory contract on Ritual Chain that deploys autonomous, self-running "companies." Each one gets its own treasury, wakes itself on a Scheduler loop, and does a job you define using Ritual's TEE-attested LLM precompile. Once it's live, nobody has to keep it running — it funds itself, re-schedules its own next wake-up every cycle, and answers paid requests on its own.

## Why this matters, not just how it works

Most "AI oracle" patterns on other chains are really just a centralized script with an API key, wrapped in a contract that trusts it blindly. Ritual's LLM precompile runs the actual model call inside a TEE and cryptographically ties the result to the exact request that produced it — so the judgment a Forge company gives back is *verifiable*, not just claimed. That's the real difference from a normal backend service: nobody, including the company's own owner, can quietly swap in a different answer.

The default example shipped in the deploy form — an **airdrop / allowlist risk scorer** — is a real, sellable use case. Every token launch or allowlist today either pays an off-chain analytics vendor for sybil-risk judgment calls, or skips the check entirely and eats the fraud. A Forge company doing that job is: pay-per-call (no subscription), always on (Scheduler-driven, no ops team), and its verdicts are independently checkable rather than a black box.

## What's in here

```
hardhat/contracts/
  CompanyFactory.sol       deploys new AutonomousCompany instances
  AutonomousCompany.sol    self-waking company, driven by the LLM precompile + Scheduler
  ForgeToken.sol            demo ERC20 (FORGE) with a public 1hr faucet
  RitualForgeSwap.sol       constant-product AMM pairing native RITUAL against FORGE
hardhat/ignition/modules/Deploy.ts     deploys the factory, ForgeToken, and the swap pool
hardhat/scripts/seedForgeLiquidity.ts  seeds initial RITUAL/FORGE liquidity after deploy
api/help.js                serverless function proxying the in-app help assistant to an LLM
index.html                 the whole frontend, no build step (deploy form, swap modal, help widget)
vercel.json                 static hosting config
```

## Live contracts (Ritual testnet, chain ID 1979)

Check `CONFIG` at the top of `index.html` for the current live addresses — they get redeployed periodically during active development, so that's the source of truth rather than duplicating them here.

## How a company works, start to finish

1. Someone calls `CompanyFactory.deployCompany(companyType, systemPrompt, feePerRequest)` with some RITUAL as `msg.value`. That becomes the new company's starting treasury.
2. The owner calls `start()`, which deposits into the company's RitualWallet and registers the first Scheduler wake-up.
3. On every wake-up, the company calls the LLM precompile (`0x0802`) for a heartbeat check, logs it, tops up its RitualWallet balance, and re-schedules its own next wake-up. Nobody needs to call it again. If a reschedule ever fails, the owner can call `kick()` to recover it without needing to stop and redeploy.
4. Anyone can call `requestService(input)` on a company and pay `feePerRequest`. The company runs `input` through the LLM precompile using its own `systemPrompt` as the system message, and the fee adds to its treasury. For the risk-scorer template, `input` is the wallet address plus whatever on-chain context the caller already has (age, tx count, funding source) — the company doesn't fetch data itself, it gives a verifiable, TEE-attested judgment over data the caller supplies.
5. The company owner can `withdraw()` accumulated treasury at any time.

## Also in the app

- **Swap** (top nav) — RITUAL ⇄ FORGE via `RitualForgeSwap`, a simple constant-product AMM with a FORGE faucet built in.
- **Ask Forge** (bottom-right chat bubble) — a help assistant for navigating the app. Backed by `api/help.js` if `OPENAI_API_KEY` is set as a Vercel environment variable; falls back to a small scripted FAQ automatically if that's unavailable.

## Redeploying the contracts yourself

```bash
cd hardhat
npm install
```

Set your deployer key (stored encrypted locally, not in a plaintext file):

```bash
npx hardhat keystore set DEPLOYER_PRIVATE_KEY
```

Then deploy:

```bash
npx hardhat ignition deploy ignition/modules/Deploy.ts --network ritual
```

(add `--reset` if resuming a stuck/interrupted deployment journal)

Copy the resulting `CompanyFactory`, `ForgeToken`, and `RitualForgeSwap` addresses into `CONFIG` at the top of `index.html`, seed the swap pool with `scripts/seedForgeLiquidity.ts`, then push and let Vercel redeploy.

## Known limitations, stated plainly

- The company's `systemPrompt` is public on chain. Anyone can read it. If a company type needs a private "secret sauce" prompt, that would need the DKMS/ECIES secrets precompile pattern instead, which isn't implemented here yet.
- Companies don't autonomously fetch on-chain data about the wallet they're scoring (no HTTP precompile integration yet) — the caller supplies context in `input`. The value today is verifiable reasoning over supplied data, not autonomous data collection.
- `numCalls`/gas/fee parameters for `Scheduler.schedule()` are matched to Ritual's own official reference example rather than independently tuned — if Ritual's recommended values change, this needs updating too.
