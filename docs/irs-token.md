---
read_when: Importing the protocol token, deploying core contracts, integrating Minter or AirdropDistributor, or migrating legacy Aero references.
---

# IRS token naming

The protocol token is `IRS` in `contracts/IRS.sol`, implementing
`IIRS` from `contracts/interfaces/IIRS.sol`. These replace the source names
`Aero.sol`, `Aero` and `IAero`. Imports, deployment artifact names and generated bindings
must use `IRS` / `IIRS`. Regenerate Hardhat TypeChain bindings after compiling.

The ERC20 name remains `Icarus`, the symbol remains `IRS`, and decimals remain 18.
The ERC2612 permit domain remains `Icarus`, version `1`, with the current chain id and
token contract address. The rename changes no token minting, authorization, balances,
allowances or emissions calculations. Token minting APIs and selectors are unchanged.

## Integration changes

| Integration | Current API/schema |
| --- | --- |
| Token contract / interface | `IRS` / `IIRS` |
| Minter token getter | `irs() returns (IIRS)` |
| Minter initialization | `initialize(AirdropParams params, uint256 initialWeekly)`; raw IRS units |
| AirdropDistributor token getter | `irs() returns (IIRS)` |
| Deployment JSON token address | `IRS` |
| Token-paired pool input configuration | `poolsIrs` |

The two `irs()` getters replace `aero()`; no legacy getter alias is provided.
Clients must use the ABI matching their deployment. Existing immutable Minter and
AirdropDistributor deployments retain their old getter until new contracts are deployed.
Renaming source does not migrate any deployed contract, balance or token address.

New Minter deployments require the explicit starting weekly amount when initialized by
team. The one-argument initialization selector is not retained. See
[initialization and first emissions](weekly-emissions-cap.md#initialization-and-first-emissions)
for the one-time setup, first-week timing and supply-based tail behavior below `TAIL_START`.

Solidity and Hardhat deployment scripts create the `IRS` artifact and use the `IRS`
output key. Active pool input configurations and their consumers use `poolsIrs`.
Historical deployment output files and upstream provenance are retained as recorded.

## Liquidity helpers

The V2 helper lives in this repository at `contracts/LiquidityStakeHelper.sol`; see
[V2 integration](liquidity-stake-helper.md). It adds two-token liquidity and stakes LP
for the recipient in one transaction after ERC20 approvals. The separate V3 helper lives
in the sibling Slipstream repository; see its
[mint-and-stake integration](../../slipstream/docs/liquidity-stake-helper.md).

## Verification

`test/IRS.t.sol` covers metadata, permit-domain identity, authorized mint accounting and
minter authorization. Minter and AirdropDistributor suites validate the renamed getters
and existing distribution behavior. Gauge/helper suites exercise the shared renamed token
fixture and liquidity-to-stake flow.
