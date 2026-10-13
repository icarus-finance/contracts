---
read_when: Integrating IRS gauge claims, configuring claim hooks, or deploying updated gauges and Voter.
---

# IRS gauge claim-and-lock

LP gauge emissions can be claimed liquid or locked in one transaction. This feature applies to
new deployments of the V2 `Gauge` source here and the compatible CLGauge in the sibling
[Slipstream repository](../../slipstream/docs/claim-and-lock.md). Existing gauges and Voter are
immutable; deploying a new factory does not change existing instances.
Rebase claims already compound active locks; bribe and fee claims retain their separate APIs.

## User APIs

- `Gauge.getReward(account)` retains liquid claims. Only account or its configured Voter can call.
- `Gauge.getRewardAndLock(account, tokenId, lockDuration)` locks the full accrued claim and returns
  the target id. Same caller authorization as liquid claims; supports the trusted forwarder.
- Existing target: `tokenId != 0`, `lockDuration == 0`, and account must own the NFT. NFT operator
  approval does not authorize redirecting another user's emissions. Calls escrow `depositFor`;
  retains lock end and permanent status. Expired, managed and deposited-managed
  targets remain subject to escrow restrictions. Team locks accept additions under their existing
  team vesting schedule, including proportional clawback of the added balance.
- New target: `tokenId == 0`; calls `createLockFor(amount, lockDuration, account)`.
  Duration is seconds, rounded down to a weekly unlock boundary, within escrow's four-year maximum.
  New NFTs have ordinary timed locks. No user IRS approval is needed: gauge funds escrow directly.
- `Voter.claimRewardsAndLock(gauges, tokenId, lockDuration)` batches supported gauges into one NFT.
  Compatible V2 and CL gauges can be included in the same batch.
  First positive claim creates the NFT when the input id is zero; subsequent claims add to it.
  Empty claims create no NFT. Returns zero if no new lock was funded.
- Zero rewards do not transfer, lock, or call the hook. Invalid existing ownership/duration still
  fails validation. Claims work after gauge deactivation so users can collect accrued rewards.

Accounting is cleared before external settlement. Gauge grants escrow the exact claim allowance,
then clears it before the hook. Any transfer, escrow or hook failure rolls back the entire claim
(and all prior gauges in a batch).

## Team callback

Current `VotingEscrow.team()` calls `Voter.setClaimHook(hook)` once to configure all compatible
gauges linked to that Voter, including gauges created later. Each gauge reads `Voter.claimHook()`
on every positive claim; there is no per-gauge override or configuration loop. Hook must be a
contract, or zero to disable for all gauges. Replacement/removal emits `ClaimHookSet` on Voter.
Hook defaults to zero; there is no bonus policy or reward funding in this change.

```solidity
function onClaim(uint256 tokenId, uint256 amountLocked, address user, address gauge) external;
```

Hook is called once after each positive gauge claim:

| Claim | tokenId | amountLocked | user |
| --- | --- | --- | --- |
| Liquid | 0 | 0 | Reward recipient |
| Existing lock | Target id | Full IRS claim, raw units | Reward recipient and NFT owner |
| New lock | Created id | Full IRS claim, raw units | New NFT owner |

The `gauge` argument is always the calling gauge (`msg.sender`). Use it for gauge-specific logic,
or resolve the pool through `Voter.poolForGauge(gauge)` for pool-specific logic. Caller is the
gauge, not Voter or the user. Hook implementations must check `msg.sender == gauge` and
authenticate supported gauges
(e.g. against the protocol Voter's gauge registry and an explicit deployment/version allowlist),
and prevent forged callbacks from awarding rewards. The callback intentionally supplies no
liquid claim amount. A future bonus policy can inspect escrow state to apply lock-duration rules.
Batches produce one callback per positive gauge claim, including repeated claims against one NFT.

Hook calls are atomic: a reverting hook blocks claims on its gauge until team repairs or disables
it via the shared Voter setting. A global reverting hook can block claims across all compatible gauges.
Gauge reentrancy protection covers claims, deposit/withdraw and notifications; Voter protects its
setter and claim-and-lock batch against reentrancy.
No token allowance is granted to hooks. Future hooks need their own funding, accounting and audit.

## Verification

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --match-path 'test/{Gauge*,Voter*,VotingEscrow*,RewardsDistributor*}.t.sol' --summary
```

Local deployment tests do not use that placeholder RPC; the variable satisfies BaseTest setup.
