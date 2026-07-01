# Scheduler.schedule() reverts with unexplained selector 0x13a6fe64 despite matching documented ABI and confirmed sufficient RitualWallet funding

## Summary

Calling `Scheduler.schedule()` (0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B) from a deployed contract consistently reverts with a bare custom error selector `0x13a6fe64`. This selector does not match any error name I could find documented in `ritual-dapp-skills`, and does not change even after correcting two real bugs found along the way (wrong single-shot convention, missing 11th `predicate` parameter). The call is made from a contract (not an EOA), with confirmed sufficient RitualWallet balance, using the exact 11-parameter signature shown in the skill doc's own examples.

## Environment

- Network: Ritual testnet (chain ID 1979)
- Scheduler: `0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B`
- RitualWallet: `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948`

## Steps to reproduce

1. Deploy a simple contract that funds its own RitualWallet balance via `deposit(uint256 lockDuration)`, confirmed on-chain (not simulated).
2. From that same contract, call `Scheduler.schedule(...)` with:
   - `data`: `abi.encodeWithSelector(this.wakeUp.selector, uint256(0))`
   - `gas`: `300000`
   - `startBlock`: `block.number + 500`
   - `numCalls`: `1`
   - `frequency`: `1` (per the single-shot convention documented in the skill's quick reference table)
   - `ttl`: `100`
   - `maxFeePerGas`: `block.basefee + 1 gwei`
   - `maxPriorityFeePerGas`: `0`
   - `value`: `0`
   - `payer`: `address(this)`
   - `predicate`: `address(0)` (unconditional)

## Expected behavior

`schedule()` succeeds and returns a `callId`, per the worked examples in `skills/ritual-dapp-scheduler/SKILL.md`.

## Actual behavior

The call reverts. Raw revert data captured via `eth_call` (bypassing any custom error wrapping on my end) is exactly `0x13a6fe64`, a 4-byte selector. I was unable to match this against any error name in the public skill docs, including the wallet skill's `Common Errors` table (`InsufficientBalance`, `FundsLocked`, `TransferFailed`) or the scheduler skill's documented errors (`ScheduleLifespanExceeded`, `CallSkippedTTLExpired`), nor roughly 100 other candidate names I brute-forced via keccak256 comparison.

## What I've ruled out

- **Wrong function signature**: confirmed the 10-param vs 11-param selectors are genuinely different (`0x1328c7c4` vs `0x07b665e2`), and neither matches the observed revert selector `0x13a6fe64` — so the revert data is not simply "function not found."
- **Insufficient RitualWallet balance**: confirmed via `balanceOf()` read after a real, confirmed `deposit()` transaction that the calling contract's balance was `5000000000000000` wei (0.005 RITUAL) at the time `schedule()` was called, well above the estimated per-execution cost at current basefee.
- **numCalls × frequency exceeding MAX_LIFESPAN**: `1 × 1 = 1`, far under the documented `10,000` cap.
- **Simulation vs real state artifact**: confirmed by sending the funding deposit as a real, mined transaction (not `eth_call`) before testing `schedule()`, and re-verifying the balance on-chain immediately before the scheduling attempt.
- **My own error-decoding logic being unreliable**: verified against a known, self-defined custom error (`InsufficientFee()`, selector `0x025dbdd4`) in the same test harness, which decoded correctly, confirming the harness itself is trustworthy and `0x13a6fe64` is a genuine on-chain revert.

## Question

Is there a validation rule, minimum value, or additional setup step (e.g. `approveScheduler`, a minimum `ttl`/`ganAmount` relationship, or a `startBlock` bound) not covered in the current `ritual-dapp-scheduler` skill doc that would produce this specific revert? Happy to share full contract source and transaction hashes on request.
