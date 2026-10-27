---
read_when: Funding team veNFTs, merging into team locks, claiming rebases, or reviewing clawback accounting.
---

# Team lock additions

Team restrictions apply to the full `VotingEscrow.locked(tokenId).amount`; there is no separate
principal-only team amount. `teamLocks(tokenId)` stores the vesting start, end and clawback flag.

- `increaseAmount` accepts IRS from an owner or approved caller. The team needs NFT approval
  when it is not the owner; its automatic voting permission does not authorize balance operations.
- `depositFor` accepts IRS from any payer, including RewardsDistributor rebase claims and gauge
  claim-and-lock. The payer funds the addition; NFT approval is unnecessary for this entrypoint.
- `merge(from, to)` accepts an ordinary timed source into a team-locked destination when the caller
  is approved for both NFTs. The source is burned and its full balance becomes team locked.
  Existing normal-NFT, source vote/permanent-lock and destination expiry checks still apply.
- A team-locked source cannot merge out, including into another team lock.

All additions increase the same locked balance used for voting power and proportional clawback.
They retain the original team vesting start/end and clawback flag; no fresh vesting schedule starts.
Before the one permitted clawback, its amount is:

`lockedAmount * (teamEnd - now) / (teamEnd - teamStart)` (rounded down).

Thus newly deposited, merged and rebased IRS also participates in the existing vesting schedule.
After clawback, additions to the owner's remaining restricted NFT grow that balance but cannot
enable a second clawback. The team's clawback NFT has no team restriction.

Timed locks must remain unexpired to receive additions; permanent destinations remain supported.
RewardsDistributor retains its existing liquid payout for expired nonpermanent escrow locks;
only rebases deposited into an active lock grow its team-locked balance.
Deposits retain the escrow lock end. Incoming merges retain permanence or use the later escrow
lock end. Neither changes team vesting dates. Team expiry alone does not remove restrictions:
anyone must call `unlockTeamLock` after expiry, then the NFT follows ordinary escrow rules.

These source changes require a new deployment; existing immutable escrows retain their code.

Verification:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --match-path 'test/{TeamLock,VotingEscrow,RewardsDistributor,GaugeClaimAndLock}.t.sol' --summary
```
