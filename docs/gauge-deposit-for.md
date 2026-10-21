---
read_when: Integrating V2 Gauge deposits for recipients, helper staking, or trusted-forwarder calls.
---

# Gauge recipient deposits

V2 Gauge retains both existing entrypoints: `deposit(amount)` credits the effective caller;
`deposit(amount, recipient)` credits the specified recipient. Both use the same internal
accounting and pull LP tokens from the effective caller, resolved through the trusted
ERC2771 forwarder. Approve Gauge before depositing. Deposits require a live gauge and a
positive amount.

The recipient owns the stake's withdrawal and emissions rights. Funding a different
recipient gives the donor no withdrawal authority. `LiquidityStakeHelper` uses this
existing recipient API to mint LP and stake for its user atomically; see
[helper integration](liquidity-stake-helper.md).

Recipient zero is now rejected with `InvalidParams()` before transferring LP tokens.
Previously, positive deposits to zero could strand their staking credit. No selector or
reward-accounting changes accompany this guard. Existing deployed gauges are immutable;
the new rejection applies to newly deployed Gauge code only.

Slipstream's NFT gauge provides a matching recipient deposit overload in its own repository;
its position custody and token-id API differ from these fungible LP deposits.
