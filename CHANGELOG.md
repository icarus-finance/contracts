# Changelog

All notable changes to the initial Aerodrome codebase will be documented in this file.

Initial code was forked from [aerodrome-finance/contracts@a5fae2e](https://github.com/aerodrome-finance/contracts/tree/a5fae2e87e490d6b10f133e28cc11bcc58c5346a).

All code under expired BUSL-1.1 license was changed to GPL-2.0.

## Updated

- Updated Forge-std to v1.10.0
- Updated Solidity to 0.8.30
- Updated OpenZeppelin contracts to v5.4.0 (except for `contracts/governance`).
- Updated OpenZeppeling contracts to v4.9.6 for `contracts/governance`.
- Updated licenses to GPL-2.0

## Added

- Added `teamLocks` to the `VotingEscrow`, which enable restricting veNFTs functions until specified timestamp.
    - Transfer, Merge, Split, DepositManaged functions are disabled.
    - Voting, claiming rewards, lockPermanent, unlockPermanent, increaseAmount, increaseLockTime are enabled. 
    - Team locked veNFT can be "clawbacked" by the team, but only once, which splits veNFT into two locks:
        - Lock that stays with the owner, with proportional amount of vested IRS, still locked until end of team lock.
        - Lock with rest of unvested IRS, that is transferred to the team address.
- Added `acceptTeam` function to the VotingEscrow.
- Added `earnedUntilTs` and `getRewardUntilTs` functions to claim rewards up to specified timestamp.
- Added `contracts/candy`, Sugar contracts rewritten in Solidity, used to simplify querying onchain data.
- Added modifiers for authorization checks for `Voter` and `VotingEscrow`.

## Fixed

- Fixed loosing rewards due to rounding errors, especially for small locks.
- Fixed potential out of gas errors for claiming rewards very rarely. 
