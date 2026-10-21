---
read_when: Integrating vote submission, calculating frontend vote allocations, or reviewing rebase claim ordering.
---

# Automatic rebases when voting

`Voter.vote(tokenId, pools, weights)` validates the caller and vote window, updates the Minter
period, claims the NFT's rebases from the escrow's RewardsDistributor, then reads the increased
voting power and allocates votes. Claim, rollover and vote are atomic: any failure reverts all three.
No separate claim transaction or token approval is required, including for active team locks.

The existing arguments remain relative weights. Each pool receives
`weights[i] * postRebaseVotingPower / sum(weights)`, rounded down. Frontends can pass allocations
calculated using post-rebase power directly. If their sum matches the actual power at execution,
each allocation matches its input exactly. If power changes between preview and execution,
the contract scales allocations proportionally to the actual post-rebase power.

Use a simulation of `vote` to preview execution, especially before the week's Minter rollover:
`claimable(tokenId)` alone does not include rebase checkpoints from an unprocessed rollover.
For timed locks, use the escrow's voting-power math, including slope rounding and remaining time;
IRS lock amount alone is not voting power. Permanent locks use their full locked amount.

Existing approval, epoch, pool, team blacklist and same-block ownership-change checks remain.
An empty claim does not prevent a valid vote. Managed NFTs can claim; NFTs deposited into a managed
NFT cannot claim directly. `poke`, reset and managed deposit/withdraw retain their existing behavior.
Managed rebases enter the existing locked-reward accounting: rewards added in the current epoch
are not yet claimable on immediate constituent withdrawal, so a residual managed balance can remain.

The claim loop processes at most 50 weeks per call; long backlogs can require additional claims.
Automatic claiming adds gas and makes voting depend on successful Minter/distributor execution.
The first vote after an unprocessed epoch also pays the rollover gas. Existing immutable Voters
require replacement deployment for this behavior.

Verification:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --match-path 'test/{Voter*,TeamLock,RewardsDistributor}.t.sol' --summary
```
