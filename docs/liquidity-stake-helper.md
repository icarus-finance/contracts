---
read_when: Integrating two-token V2 liquidity creation with gauge staking, or deploying LiquidityStakeHelper.
---

# Add liquidity and stake

Deploy `LiquidityStakeHelper(router)` with the trusted protocol Router. This standalone,
immutable helper works with existing Router, Voter and V2 Gauge deployments; no upgrades
or administrator configuration are required.

Approve both ERC20 input tokens to the helper, then call
`addLiquidityAndStake(AddLiquidityParams)` once. Approval transactions are separate unless
the caller already has allowances or uses a smart-account batch. Parameters:

- `tokenA`, `tokenB`, `stable`: pool identity in Router's default factory.
- `amountADesired`, `amountBDesired`: maximum inputs pulled from the caller.
- `amountAMin`, `amountBMin`: minimum inputs actually added, enforced by Router.
- `minLiquidity`: minimum LP tokens minted, in LP raw units.
- `recipient`: account credited in Gauge; cannot be zero or the helper.
- `deadline`: latest allowed block timestamp, enforced by Router.

Returns `(amountA, amountB, liquidity)` and emits `LiquidityStaked`. The helper mints LP
to itself, deposits the minted amount for `recipient`, and refunds unused inputs to the
caller. Recipient can withdraw directly from Gauge and claim rewards normally. No LP
approval from the caller is needed. All steps revert together on failure.

The pool must already have a registered, live gauge whose staking token matches the pool.
This creates LP tokens, not a new pool or gauge. Supports stable and volatile V2 pools;
concentrated-liquidity NFTs are outside this API. Inputs must be standard ERC20 tokens;
fee-on-transfer and rebasing tokens are unsupported. Wrap native assets before using this
helper. For single-input swaps plus staking, Router already exposes `zapIn(..., stake=true)`.

The helper has no owner, rescue function, arbitrary calls or permanent spender approvals.
It grants exact temporary Router/Gauge allowances, clears them after use, and refunds
only unused inputs from the current call. Preexisting donated tokens and LP remain untouched
and cannot be recovered. Calls are protected against reentrancy. Router/Voter/factory are
trusted deployment dependencies; users should verify the helper's Router before approval.

## Verification

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --match-path test/LiquidityStakeHelper.t.sol
```

Tests use local deployments; the placeholder satisfies BaseTest's environment lookup.
