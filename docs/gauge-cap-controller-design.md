---
read_when: Designing fee-based emissions caps, modifying Voter accounting, or planning deployment migration.
---

# Fee-only gauge caps: proposed Icarus design

Status: design only; no Solidity implementation or deployment authorization implied.
Priority: small contract surface, explicit epoch expiry, no cap bypass on alternate entrypoints.
Recommended simplification: one irreversible activation; all subsequent funding uses the same
expiring accounting lifecycle. No observe/disabled modes or uncapped permanent accrual bucket.
Scope: new IRS transferred by Voter to gauges. Existing streamed rewards, direct team top-ups,
and Slipstream rollover remain outside this cap. An absolute cap on total LP rewards requires
gauge/CLPool changes and is a separate, larger project.

## Recommended policy

- Funding epoch `E = epochStart(timestamp)`; fee measurement interval `[E-WEEK, E)`.
- Vote share: weights at the actual Minter notification; preserve existing lazy-index semantics.
- Cap: previous-epoch eligible trading fees, valued in WETH, times multiplier, divided by IRS price.
- Report deadline: proposed `E + 1 hour`, aligned with existing distribution window.
  This deadline is a product choice; late publication postpones rewards and compresses streaming.
- Reports finalize at the deadline; payouts start only after it. No retroactive correction after finalization.
- Missing/invalid report: hold before deadline; zero budget after deadline. Never automatic uncapped fallback.
- Payout window: `[deadline, E+WEEK)`. Unpaid funding burns at epoch expiry. No catch-up payout.
- New gauge grace: exemption through its first complete epoch after creation, scheduled at creation;
  `firstCappedEpoch = epochStart(createdAt) + 2*WEEK` (7–14 days depending on creation time).
  Exemption still expires with its funding epoch.
- Controller/config replacements and cap exemption changes: future epochs only.
- Emergency response: council can explicitly bypass caps for a named live funded epoch, evented with
  a reason hash. Same allocations, reserves, expiry and release counters; no uncapped accrual bucket.
  Bypass is irreversible for that epoch and cannot revive expired funding.
- Optional payout halt is separate: stops payouts while expiry/burns stay permissionless. A halt
  through epoch end burns unpaid funding; use explicit bypass for oracle/report outages instead.
- Governance exceptions: explicit, evented, future-epoch uncapped status; no report-status-based exemption.
- Existing Minter behavior retained: skipped weeks do not retroactively mint multiple weeks.

Example: 100 WETH fees, multiplier 1.2, IRS price 0.001 WETH/token => 120,000 IRS budget.
If vote allocation is 200,000 IRS, maximum release is 120,000; at least 80,000 burns.
If only 90,000 releases before expiry, remaining 110,000 burns. No redistribution.

## Minimal controller

Controller stores budgets and report provenance; holds no tokens and cannot send rewards.
Voter owns allocation, expiry, burn, allowance, and actual transfer accounting.
Use OpenZeppelin full-precision `Math.mulDiv`; do not introduce bespoke oracle math.

```solidity
enum Status { Pending, Ready, Expired }
struct EpochConfig {
    uint32 multiplierBps;        // e.g. 12000; bounded by governance policy
    uint32 reportDelay;          // immutable for this epoch
    address reporter;            // snapshot; rotation applies prospectively
}
struct FeeReport {
    uint256 feeValueWeth;        // 18-decimal WETH value
    uint256 irsPriceWeth;        // 18-decimal WETH price per whole IRS
    uint256 capIrs;              // raw 18-decimal IRS units, computed at publication
    bytes32 evidenceHash;        // fee breakdown, finalized block range, oracle samples
    bool submitted;             // distinguishes genuine zero fees from absent report
}

// Proposed interface.
registerGauge(address gauge, uint256 createdAt); // onlyVoter; immutable registration
publishReport(address gauge, uint256 epoch, uint256 feeValueWeth,
              uint256 irsPriceWeth, bytes32 evidenceHash);
quote(address gauge, uint256 epoch)
    returns (Status status, bool exempt, uint256 capIrs);
scheduleConfig(uint256 effectiveEpoch, EpochConfig config);
scheduleExemption(address gauge, uint256 effectiveEpoch, bool exempt);
setPayoutPaused(bool paused); // council; does not disable expiry
// Voter API, independently callable even when controller is unavailable:
bypassEpoch(uint256 fundedEpoch, bytes32 reasonHash); // council; once, before expiry
```

Publication constraints: registered gauge, aligned funded epoch, authorized reporter for `E`,
deadline not passed, positive bounded price, bounded fee value, supported decimals.
Governor schedules configuration/exemptions only for unstarted epochs; effective epochs must be
week-aligned. Bound multiplier and report delay, with `0 < reportDelay < WEEK`. Resolve configuration
by the funded epoch rather than today's defaults; freeze the complete report and evidence at deadline.
Corrections allowed only before deadline; emit old/new report hash. Readiness depends on time,
not permissionless callers freezing reports early. Published cap freezes the epoch's multiplier.
Budget calculation with IRS decimals 18:
`capIrs = mulDiv(mulDiv(feeValueWeth, multiplierBps, 10000), 1e18, irsPriceWeth)`.
Round down. Reporter-derived values remain trusted; bounds are sanity checks, not truth proofs.
Avoid generic low-level calls, arbitrary return-data decoding, and per-gauge oracle calls during payout.

Voter stores canonical `gaugeCreatedAt[gauge]` and calls controller `registerGauge` during
`createGauge`. Controller checks the supplied timestamp against Voter and disallows resetting it.
Before delayed activation, backfill existing gauges in bounded batches with documented canonical
creation timestamps; complete registration is an activation prerequisite. Do not invent fresh
timestamps which grant old gauges another grace period.
Controller replacement needs the same bounded registration backfill before its effective epoch.
Grace always derives from Voter's canonical timestamp; a replacement cannot restart it. An absent
registration or zero/unknown timestamp produces no implicit exemption: treat it as missing configuration,
hold funding, and require correct registration or explicit epoch emergency bypass.

This proposal provides an explicit epoch-scoped council bypass during oracle failures.
Missing, invalidated or reverting reports do not automatically bypass caps.
Operator action is required before the epoch expires; otherwise unpaid subsidies burn.
Place bypass storage/authorization in Voter, so a broken controller cannot prevent recovery.
Emit epoch, caller, timestamp and reason hash; monitoring must alert on both report failures and bypass.
One-way bypass avoids lowering eligibility after a nominal payout has already exceeded the cap.

## Fee report producer

Separate keeper/indexer required; onchain controller alone cannot establish historical fee value.
Publish auditable reports pinned to finalized start/end blocks with deterministic measurement code.

- V2: derive actual swap fee amounts using the factory fee active at each swap, or validated
  fee events plus unstaked-fee transfers. `Pool.Fees` excludes the separate gauge-fee component;
  a report based only on that event undercounts total fees.
- CL: derive eligible trading fees from CLPool accounting/events and its active fee parameters.
  Establish exact LP/protocol fee inclusion policy before implementation.
- Choose gross trading fees or voter-directed fees consistently across V2 and CL. Proposed baseline:
  gross trading fees paid by swaps; exclude non-trading donations, bribes, reward top-ups, rebates.
- Do not use FeeVotingReward balances/notifications as evidence of epoch trading fees.
  Claims can batch multiple epochs; balances can include donations and unsent amounts.
- Value fee tokens through approved sources. Low-liquidity token without reliable quote: unsupported,
  zero valued contribution; no optimistic arbitrary spot price.
- WETH/IRS price: approved deep market TWAP, pinned measurement interval and staleness rules.
  Proposed conservative price statistic must be specified and reproduced by report tooling.
- Fee-on-transfer/rebasing/exotic-token policies explicit; unsupported until measured reliably.
- Wash trades still generate real fees; cap economics and price manipulation need economic review.

One reporter multisig initially; documented operational dependency. Fully autonomous onchain fee
measurement/oracles would expand pool, oracle, and governance scope substantially.

## Voter integration: preserve accrual, separate eligibility

Local `claimable[gauge]` is timeless. A `min(claimable, currentCap)` distribution patch incorrectly
applies one epoch's fee budget to multiple epochs and can leak via future mode changes.
Local `_updateFor` runs before vote weight changes and is publicly callable; all paths must use
the same epoch attribution. Checkpointing never decides exemption from a mutable global mode.

Proposed state:

```solidity
struct FundingEpoch {
    uint256 startIndex;
    uint256 endIndex;
    uint256 received;
    uint256 released;
    uint256 burned;
    address controller;         // fixed for funded epoch
    bool expired;
}
mapping(uint256 => FundingEpoch) funding;
mapping(address => mapping(uint256 => uint256)) allocated;
mapping(address => mapping(uint256 => uint256)) released;
mapping(address => mapping(uint256 => bool)) forfeited;
mapping(uint256 => bool) capBypassed;
mapping(address => uint256) gaugeCreatedAt; // canonical; no replacement-controller grace reset
uint256 activeFundingEpoch;
// Optional legacyClaimable only for a separately designed activation/migration.
```

At `notifyRewardAmount`, transfer from Minter, create epoch receipt, advance index exactly as today,
and record index interval under `E`. Snapshot controller/config, not live controller settings later.
Zero totalWeight: burn funding immediately; do not leave orphan tokens for future voters.
Reject multiple notifications in one epoch; normal Minter sends once. Expire the previous funding
receipt before opening a new one. There is at most one live capped epoch, so no history loop is needed.

`_updateFor(gauge)` clips its old `supplyIndex` upward to the current epoch's `startIndex`.
The clipped interval excludes expired funding intentionally. Credit `allocated[gauge][E]` using
the existing weight before that gauge's weight mutation, then advance `supplyIndex` to `index`.
If no live funded epoch exists, checkpoint without creating an allocation.
Gauge creation starts at current index; no previous funding entitlement.
All vote/reset/managed-vote paths checkpoint before changing weights. No uncapped accrual side channel.
Historic exemption/config status comes from epoch snapshot; calling `updateFor` early changes no outcome.

This is constant work per gauge and retains existing vote/reset checkpoint ordering. It depends on
the explicit policy that historic capped allocations expire. Neither payout halt nor emergency bypass
switches accrual into another accounting bucket. Exempt gauges use the same expiry lifecycle with a larger
budget; future exemption cannot reclassify past withheld funds. Explicit emergency epoch bypass
can release that live epoch's remaining nominal allocation; accounting and lifetime do not change.

Fresh deployment needs no legacy bucket. Optional delayed activation on new compatible contracts:
freeze weight mutations, checkpoint all registered gauges at one fixed index in bounded batches,
move those preactivation entitlements into `legacyClaimable`, then activate at a future epoch.
Reserve/burn bookkeeping excludes that fixed legacy liability forever. Require complete checkpointing
before activation; do not infer legacy entitlement from unprocessed indexes after activation.
This activation machinery is unnecessary if caps start at first emission; avoid it initially.

Distribution pseudocode:

```text
updatePeriod(); expire funded epochs whose end <= now; checkpoint(gauge)
if paused: return                       # expiry already performed
E = current funded epoch
if E.expired: return
if capBypassed[E]: budget = allocation[E]     # skip controller call; outage recovery
else:
    quote = controller.quote(gauge, E)
    if quote.Pending or quote unavailable: return
    budget = exempt ? allocation[E] : min(allocation[E], cap[E])
remaining = budget - released[gauge][E]
if remaining == 0: return
if gauge not alive or forfeited[gauge][E]: return
if remaining <= gauge.left() or remaining <= WEEK: return  # existing thresholds
update released and epoch.released before external call
approve exact remaining; notifyRewardAmount(remaining); clear approval
```

Keep a preview exposing allocation, cap, released, bypass status/reason, pending reason, expected burn,
and deadline. A bypass does not bypass killed-gauge forfeiture or optional payout halt.
`claimable` compatibility needs a documented decision: retain as current eligible/pending amount
for integrations, or add explicit getters and update callers. Do not silently change its meaning.

At expiry, atomically mark epoch expired and burn `received - released - burned` once.
This includes withheld amounts, uncheckpointed gauges, small unstreamable budgets, and rounding dust.
Later checkpointing sees expired status and cannot resurrect liability. Expiry needs no gauge loop.
Expire the single previous live receipt on notification, plus permissionless `expireEpoch(E)`.
Sweeping one epoch never zeroes another epoch's balances or legacy entitlement.

Missed distributions are deliberately forfeited under this policy. This is not equivalent to
current Icarus indefinite `claimable` carryover. If product requires eventual historical payouts,
retain epoch-specific budgets and reserves indefinitely, process backlogs, and define their streaming;
that alternative costs more and must replace the expiry policy explicitly.

## Killed gauges, top-ups, rollover, and dust

Killed gauges: simplest new policy marks the current epoch entitlement `forfeited` and leaves its
unpaid subsidy in the reserve for expiry burn; already-streamed rewards stay claimable. Checkpoint
before marking killed; skip credit while dead. Revival cannot clear current-epoch forfeiture; eligible
again from a future epoch. Existing code sends killed-gauge funds to Minter; retaining that behavior needs separate
`returned` accounting and changes conservation to include returns. Funds returned to Minter can
offset later minting, so they are not token burns. Select one policy before coding.
Kill/revive must checkpoint consistently; revival never revives an expired epoch entitlement.

V2 and CL gauges reject zero reward rates; existing Voter requires amount greater than `left()`
and `WEEK`. Keep these conservative gates initially; expire any unpaid dust instead of rolling
subsidy into a later epoch's cap. Cap excess need not burn immediately; aggregate expiry burn is simpler.
Reported circulating supply includes held excess until expiry; document this timing.

Both gauges expose team-only `notifyRewardWithoutClaim`; Voter cap cannot control those payments.
CL `notifyRewardAmount` adds `pool.rollover()` from prior rewards. A zero Voter transfer also does
not trigger CL rollover, potentially delaying its release. No gauge changes proposed here; UI must
describe fresh Voter subsidy rather than promising a cap on aggregate LP APR.

## Burn and migration

`contracts/Aero.sol` has no burn API. For fresh deployment add `burn(uint256)` burning caller-owned
IRS and matching interface; Voter burns its own reserves. Avoid `burnFrom` allowance complexity.
A dead-address transfer does not reduce totalSupply; tail emission and rebase calculations differ.
Burn tests must cover supply-based Minter economics after expiry, not merely emitted burn events.

Existing source deploys immutable Minter.voter and Gauge.voter. A standalone new controller cannot
intercept their payout path. Governance has no general pointer replacement in those contracts.
Existing token mint authority can transfer via its current Minter only if that Minter exposes the
necessary path; source Minter does not expose such a migration setter. Do not assume deployer control.
VotingEscrow Voter permissions and reward/factory references also need migration analysis.
Fresh deployment: small component count. Live replacement: coordinated token/Minter/Voter/gauge
migration or a separately reviewed alternative; not priced as this design's implementation.

## Required invariants and regression matrix

For every epoch: `received = released + burned + held` (plus explicit returns if retained).
`held >= 0`; total reserves never exceed Voter token balance.
For every gauge/epoch: `released <= allocation` and, unless exempt or explicitly bypassed,
`released <= cap`. Expired funding never pays. Report failure alone never increases eligible budget.
One entrypoint cannot alter the result obtainable through another entrypoint.

| Case | Required assertion |
| --- | --- |
| `updateFor` before/after report deadline, vote/reset, repeated distribute | Identical total allocation, cap, paid, burned |
| Allocation > cap, allocation < cap, zero fees | Exact max budget, excess conserved/burned |
| Missing report, invalid/zero price, reporter rotation | Hold then zero; no implicit uncapped payout |
| Correct report before deadline, attempted edit afterward | Correction observable; finalized value immutable |
| Two funded epochs with one distribution missed | Prior reserve burns once; current allocation preserved |
| Repeated expiry, notification after skipped Minter weeks | No double burn; no retro mint invented |
| Weight change before/after funding, missed old checkpoints | Current allocation preserved; expired funds cannot revive |
| Zero totalWeight, rounding, tiny reward amount | No orphan/future claim; deterministic expiry |
| Grace creation boundary, scheduled exemption/controller replacement | Fixed per-epoch policy; no retro bypass |
| Emergency pause/resume across expiry | Payout blocked; burn remains possible; no revival |
| Missing/reverting controller, then explicit live-epoch bypass | Nominal payout resumes without controller; reserve conserved |
| Bypass twice, attempted bypass reversal/expired bypass | One-way epoch flag; no double release or historic revival |
| Bypass after capped partial payout, halted/killed gauge | Only remaining nominal allocation; halt/forfeiture still enforced |
| Kill/revive at every checkpoint phase | No double return/burn, no resurrected funding |
| Malicious/reverting controller or gauge | Failed call cannot unlock uncapped funds; other gauges usable |
| V2 team top-up, CL rollover, empty CL liquidity | Scope explicit; existing reward accounting preserved |
| Burn then Minter tail/rebase calculations | totalSupply and future mint calculations consistent |

Use Foundry unit/fuzz invariants plus V2 and CL integration tests. Include real existing
Voter/Minter voting flows and deliberately unordered keeper calls; mocks alone miss index issues.

## Complexity estimate

Estimates, not commitments; assumes fresh deployment, trusted report producer, no new onchain oracle.

| Work | Estimated effort | Main risk |
| --- | --- | --- |
| Controller + interface + permissions | 2–4 engineering days | Report units, fixed epoch config |
| Voter epoch allocation/expiry integration | 3–6 days | Lazy index, ordering, liveness |
| Token burn API + deployment wiring | 1–2 days | Token economics, immutable references |
| Fee/price report keeper and reproducibility | 4–8 days | V2/CL fee definitions, trustworthy pricing |
| Tests, fuzz/integration, operator docs | 4–7 days | Missed epochs and adversarial ordering |
| Independent security review/remediation | Separate scope | Accounting and oracle economics |

Combined engineering estimate: roughly 3–6 weeks for one engineer; parallel tooling/tests can reduce
elapsed time. Live deployment migration and a fully onchain controller require separate estimates.
Contract-only prototype, excluding keeper and independent review: roughly 1–2 weeks. Planning surface:
about 150–250 net Voter lines, a 200–300-line controller, a small interface and token burn addition.
These are approximate implementation estimates, not a measured patch; tests/tooling are additional.
Most changes stay in Voter/interface/controller/token/deployment/tests; pools, escrow, and gauges
can remain unchanged for the restricted fresh-subsidy definition. Medium/high accounting complexity,
despite a small number of contracts.

Unresolved product choices: gross vs voter-directed fees; multiplier; report deadline; price source;
grace length; missed epoch forfeiture; killed-gauge return vs burn; whether direct top-ups/rollover
must be capped; fresh deployment vs migration of existing immutable deployments.
