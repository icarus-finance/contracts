---
read_when: Initializing Minter emissions, configuring weekly emissions caps, operating a cap reporter, or reviewing Minter accounting.
---

# Global weekly emissions cap

Implemented in `Minter`; no external controller or Voter changes required. This replaces the
per-gauge proposal for this implementation. Applies to fresh deployments of the updated Minter;
it does not make an existing immutable Minter upgradeable.

## Administration and reports

- `team` calls `setCapReporter(account, allowed)` to whitelist/revoke reporters. Zero address rejected.
- No reporter is authorized automatically, including team. Multiple reporters may be authorized.
- A reporter calls `setWeeklyCap(epoch, amount)` in raw IRS units (18 decimals).
- Epoch is its UTC Unix timestamp rounded down to a multiple of `1 weeks` (Thursday boundary).
- Current and future aligned epochs accepted; past or already processed epochs rejected.
- Reports can be overwritten until processing. `setWeeklyCap(epoch, 0)` removes a report; there is no separate clear function.
- `weeklyCaps(epoch)` returns `(amount, reported)`. A zero submission stores `(0, false)`, exactly like an absent report.
- Missing or cleared report means normal scheduled emissions. Caps never carry into another epoch.
- Revoking a reporter prevents new writes but does not remove its existing reports. An authorized
  reporter can clear those reports before processing. Team can authorize itself for this purpose.
- Report changes, reporter permissions, and the budget selected at processing emit events.

Publish before the epoch boundary where possible. `updatePeriod()` is permissionless: the first
successful processing transaction freezes that epoch's outcome. A report submitted after the boundary
can lose a transaction-ordering race to uncapped processing; it cannot change an already processed
week. Missing reports deliberately fail open, so reporter outages restore nominal emissions.

## Initialization and first emissions

Team calls `initialize(AirdropParams params, uint256 initialWeekly)` once. `initialWeekly`
sets `weekly` in raw IRS units (18 decimals); `weekly` is zero before initialization.
For example, `10_000_000 * 1e18` selects the former 10 million IRS starting schedule.
Initialization sets `activePeriod` to the current week. It performs the configured airdrop but
emits no weekly rewards; the first weekly emission is available at the next weekly boundary.
Initialization remains atomic: a failed airdrop also rolls back the initial weekly amount,
initialization flag and schedule. Reinitialization cannot change that amount.

At or above `TAIL_START` (`8_969_150 * 1e18`), the first nominal gauge funding equals
`initialWeekly`, before any weekly cap; the existing growth/decay schedule follows.
Below `TAIL_START`, including zero, the first emission immediately uses the supply-based
tail formula instead: `totalSupply * tailEmissionRate / 10_000`. Thus a lower initial
amount is not an exact first-emission budget, and zero does not pause emissions.
Rebase and team rewards are additional to gauge funding. Tail funding depends on the
token supply when the emission is processed, including the initialization airdrop.
Caps affect weekly emissions, not the initialization airdrop. An empty airdrop is supported:
when token supply is zero, the first emission has zero rebase (there are no existing holders).

This initialization ABI applies to fresh Minter deployments. Update deployment scripts,
bindings and initialization calldata to pass the explicit amount; no one-argument overload
is provided. Existing immutable deployments retain their original ABI and schedule.

`script/hardhat/DeployCore.ts` requires `INITIAL_WEEKLY` in the environment, with no
default, and checks that it fits `uint256` before deploying contracts. Supply an integer
in raw IRS units, for example `INITIAL_WEEKLY=10000000000000000000000000` for 10 million
IRS; do not supply a decimal token amount or a Solidity expression. The commented
initialization example in `script/DeployCore.s.sol` reads the same variable using
`vm.envUint("INITIAL_WEEKLY")`.

To cap the first emission:

1. Team whitelists the reporter (allowed before initialization).
2. Initialize, or determine the week in which initialization will occur.
3. Reporter submits `setWeeklyCap(firstEmissionEpoch, amount)`, where
   `firstEmissionEpoch = floor(initializationTimestamp / WEEK) * WEEK + WEEK`.
4. At that boundary, `updatePeriod()` uses the report. Reports may be submitted before or after
   initialization, but must precede processing of the target emission epoch.

A report for the initialization week does not cap the following week. If initialization is delayed
into a different week, submit a report for the new first emission epoch. Initialization does not
shift or clear existing reports. Pre-initialization `updatePeriod()` remains a no-op, even with reports.
An already initialized current epoch cannot be edited, including by submitting zero. Failed or
repeated initialization cannot reset the schedule or reopen processed epochs.

## Accounting

1. Compute nominal gauge funding using the existing growth/decay/tail schedule.
2. Advance nominal `weekly` and epoch counters as before, independently of the cap.
3. Use `min(nominal, reportedCap)` if reported; otherwise use nominal funding.
4. Calculate rebase from this actual funding and the existing supply snapshots.
5. Calculate team reward as `teamRate * (actualFunding + rebase) / (10000 - teamRate)`.
6. Mint only the shortfall against Minter's existing token balance, transfer rewards and fund Voter.

The team formula intentionally changes even without a cap: it now uses actual gauge funding,
rather than the next scheduled `weekly` amount (or stale `weekly` in tail mode).
A zero submission restores normal gauge funding, rebase and team rewards; it cannot pause emissions.
Rejected emissions under a positive binding cap are never minted; no burn API or delayed burn
reserve is introduced.

The cap covers new gauge funding only; rebase and team rewards are additional. Existing gauge
claimable balances, CL rollover and direct top-ups are outside it. Normal Voter carryover remains.
Lower resulting token supply also reduces future supply-based tail emissions. Skipped weeks retain
existing semantics: only the current epoch is processed, with no retroactive minting or cap replay.

No changes to RewardsDistributor claims, VotingEscrow, pools or gauges. Report calculation and
submission are external operational responsibilities; this contract accepts the reporter's token
budget and does not validate trading fees or token prices.

## Verification

Focused regressions:

```sh
forge test --match-path 'test/{Minter*.t.sol,RewardsDistributor.t.sol,Voter.t.sol,e2e/MinterTestFlow.t.sol}' --summary
```

Cap tests cover authority and revocation,
zero/missing/high budgets, report finalization, schedule/tail continuity, skipped epochs, repeated
updates, rebase checkpointing and fuzzed funding conservation with prefunded Minter balances.
The real deployment initialization suite covers reports before/after initialization, first-epoch
funding, empty airdrops, delayed initialization, failed airdrop rollback, repeated initialization,
airdrop independence, first rebase claims and fuzzed initialization times within the week.
Existing rebase/tail regression expectations now derive from pre-mint supply and epoch allocation
instead of historical totals tied to the old team formula.
