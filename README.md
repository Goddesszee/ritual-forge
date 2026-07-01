# Forge

A factory contract that spins up autonomous, self-funding, self-scheduling
"companies" on Ritual Chain — plus a minimal on-chain swap for two demo
tokens (RTA / RTB), since Ritual testnet has no deep native liquidity yet.

## What's in here

```
hardhat/contracts/
  CompanyFactory.sol      — deploys new AutonomousCompany instances
  AutonomousCompany.sol   — self-waking (Scheduler), LLM-precompile-driven company
  TestToken.sol           — minimal ERC20 with public faucet (RTA / RTB)
  SimpleSwap.sol           — constant-product AMM pool for RTA/RTB
hardhat/ignition/modules/Deploy.ts   — deploys factory + both tokens + swap pool
index.html               — the whole frontend (no build step)
vercel.json               — static hosting config
```

Contracts compile clean against solc 0.8.24 (verified locally). They were
not broadcast to Ritual testnet from this environment — I don't have
network access to `rpc.ritualfoundation.org` from my sandbox, and I never
handle your private key directly. You'll run the actual deploy yourself,
one time, with your own funded wallet.

## Step 1 — Deploy the contracts

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

This deploys, in order: `CompanyFactory`, `TokenA` (RTA), `TokenB` (RTB),
`SimpleSwap`. Copy the four resulting addresses.

## Step 2 — Seed the swap pool (optional but needed for swap to work)

From the deployer wallet, mint yourself tokens via each token's `faucet()`
function (1000 per call, 1hr cooldown), then call `SimpleSwap.addLiquidity()`
with matched amounts of RTA and RTB — you'll need to `approve()` the swap
contract for both tokens first. This can be done via Remix, a small script,
or directly from the deployed frontend once it's live (add an "add liquidity"
call via console, or I can add a liquidity UI in a follow-up pass).

## Step 3 — Wire up the frontend

Open `index.html` and fill in the four addresses at the top of the
`<script>` block:

```js
const CONFIG = {
  ...
  factoryAddress: "0xYourFactoryAddress",
  tokenAAddress:  "0xYourTokenAAddress",
  tokenBAddress:  "0xYourTokenBAddress",
  swapAddress:    "0xYourSwapAddress",
};
```

## Step 4 — Deploy to Vercel

Push this repo to GitHub, then import it into Vercel as a static site
(Framework preset: **Other**). No build command needed — `index.html` is
served as-is, same pattern as your `ritual-chain-workshop` deploy.

## How a company works, end to end

1. Someone calls `CompanyFactory.deployCompany(companyType, systemPrompt, feePerRequest)`
   with some RITUAL as `msg.value` — that becomes the new company's starting treasury.
2. The factory deploys a fresh `AutonomousCompany` and calls `start()` on it,
   which registers the first Scheduler wake-up 500 blocks out.
3. Every wake-up, the company calls the LLM precompile (`0x0802`) for a
   heartbeat status check, logs it, and re-schedules its own next wake-up —
   nobody needs to call it again.
4. Anyone can call `requestService(input)` on a company and pay `feePerRequest`;
   the company runs `input` through the LLM precompile using its own
   `systemPrompt` as the system message, and the fee adds to its treasury.
5. The company owner can `withdraw()` accumulated treasury at any time.

## Known limitations, stated plainly

- **Swap liquidity is testnet-scale**, seeded by whoever adds liquidity first.
  This is a real on-chain AMM, not a mock — but don't expect deep liquidity
  or tight pricing.
- **No CCTP bridge.** Ritual Chain is not a Circle CCTP-supported domain as
  of this build, so there's no way to bridge USDC or any Circle asset
  directly into Ritual. If you want cross-chain funding later, the realistic
  path is CCTP into Arc (already supported, already used by NAN) plus a
  custom relayer contract into a company's treasury — a separate build.
- **Company `systemPrompt` is public** on-chain (anyone can read it). If a
  company type needs a private "secret sauce" prompt, that would need the
  DKMS/ECIES precompile pattern instead — not implemented here yet.
