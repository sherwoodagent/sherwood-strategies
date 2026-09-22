# LaunchpadStrategy and launch adapters

Design notes for `src/launchpad/`, on Sherwood protocol v1 (`v1-deploy`,
pinned in `lib/sherwood-protocol`). This document started as the design for
sherwood-protocol PR #277 (SHE-153), written against the protocol's older
`post-audit` tree. The venue facts and custody reasoning carry over as they
were. Settlement and gating are rewritten for v1; the sections below say where.

## Why

A Sherwood fund's only liquidity is the vault's own deposit/redeem queue,
priced once per proposal cycle. The product direction is that every agentic
fund can have its own market: agents in a fund can choose to "IPO" on-chain.

A `LaunchpadStrategy` proposal does exactly that. It launches a fund token on a
launchpad with vault capital, holds back a reserve, and lets the fund's share
holders claim a pro-rata slice of that reserve. The venue plugs in through
`ILaunchAdapter`, the way `PortfolioStrategy` is venue-agnostic through
`ISwapAdapter`.

## What lives here

| Path | What |
|---|---|
| `src/launchpad/ILaunchAdapter.sol` | The venue abstraction: lifecycle verbs plus the custody invariant |
| `src/launchpad/LaunchpadStrategy.sol` | The `BaseStrategy` clone template |
| `src/launchpad/adapters/StonkLaunchAdapter.sol` | StonkBrokers Smart Launch V2 adapter: implementation plus one ERC-1167 clone per launch |
| `src/launchpad/vendor/stonkbrokers/` | Reduced venue interfaces transcribed from verified source |
| `script/launchpad/DeployLaunchpadStrategy.s.sol` | Deploy and v1 registry steps for Robinhood 4663 |
| `script/launchpad/addresses-4663.json` | Stonk pad set and lens, with identity evidence |

The Sushi adapter is being rewritten for Sushi Launchpad V2 on a separate
branch and is not in this tree. The Sushi facts below describe Launchpad V1
and stay here because they are what shaped the interface. The deploy script
has a `// SUSHI V2:` seam where the new adapter slots in.

## The venues, side by side

All facts verified against Robinhood mainnet 4663 (verified explorer source and
`cast` reads, 2026-08-22 to 2026-08-31).

| | Sushi Launchpad V1 | StonkBrokers Smart Launch V2/V3 |
|---|---|---|
| Deployment | `0x104f1ab4…a7ed`, 4663 only | 16 pads (8 V2 mint-launch, 8 V3 bring-your-own-token), one per quote lane; lens `0x25b5…15B3`; 4663 only |
| Supply | fixed 1B × 1e18, minted to the launchpad | creator-chosen; `createLaunch(token=0)` mints **to the creator**; `arm(id, supplyWei)` loads the curve portion |
| Creator allocation | **zero**: the reserve must be a same-tx dev buy (`launchAndBuy`) | supply minus loaded supply stays with the creator: the reserve is a free allocation |
| Launch price | fixed $5,000 FDV via a quote-token Chainlink feed | creator-chosen `startMcapUsd8` in [$1k, $1M], `gradMcapUsd8` in [$50k, $10M] (live bounds) |
| Liquidity | immediate: 97% of supply in a one-sided Sushi-V3 1% position owned by the launchpad | curve phase first; at graduation, permissionless `bond()` mints a **locked** LP; unsold supply burned or single-sided-LP'd (`unsoldMode`) |
| Quote assets | feed-gated allowlist: WETH, USDG, SUSHI, GME, TSLA, SPCX, COIN, DELL, AAPL, NVDA. **WOOD absent**; owner-only to add | fixed lane per pad: WETH, STONK, USDG, GME, NVDA, AAPL, SPCX, USO. **WOOD impossible** |
| Creator role | transferable (`transferCreator`) | pinned at `createLaunch`, **no transfer** |
| Fee stream | 70% of LP fees to the creator, permissionless `distributeFees` | 16.5% of the per-trade tax to the creator (`creatorFeeBps` 1650), paid at trade time; `flushCreatorQuote` only for failed pushes |
| Launch fee | 0.0005 native ETH | 0 on every pad (`launchFeeWei() == 0`) |
| Contract callers | fine (`nonReentrant` only) | fine unless the launch sets `eoaOnly`, which the adapter never does |
| Venue hazards | quote feed staleness (3d max) at launch | stock lanes revert `StalePrice` on oracle gaps (weekends); tax changes per minute, so all quoting goes through the lens |

### Measured economics

- Sushi's launch pool is the 1% tier (`fee == 10000`).
- A 1,000 USDG Sushi dev buy takes about 164.56M tokens (16.46% of the float),
  a starting market cap near $6.1k. That is the sizing reference for
  `reserveAmount` and `minTokensOut`, and it shows why a `minTokensOut` of 1 wei
  makes the reserve floor meaningless.
- Sushi's 70/30 creator split floors: measured `quoteToSushi / quoteCollected`
  is 2999 bps. The exact invariant is `creatorLeg == collected - toSushi`.
- `quoteTokenPriceFeed(WOOD)` was still zero on 2026-08-31.
- Stonk's `bufferSecs` is an opening anti-snipe shield (99.99% tax while it
  runs), folded into the deadline: `deadline = armTime + bufferSecs +
  windowSecs`. It is not a grace period after the window.
- A bring-your-own token is accepted on both V2 and V3 pads. Using only the V2
  pads is a deliberate choice (the mint path hands the fund its whole supply as
  a free allocation), not a safety constraint.
- Block time on 4663 is about 0.1s and the public RPC keeps roughly 5k to 50k
  blocks, so fork tests take their block from `ROBINHOOD_FORK_BLOCK` (0 means
  latest) instead of pinning one in source.

## Decision 1: `ILaunchAdapter` is a lifecycle, not a function

A single `launch() -> tokensOut` call fits Sushi, where the pool exists and the
dev buy settles in the launch transaction. It cannot express StonkBrokers,
where a launch is a process: create, arm, a curve phase of minutes to
indefinitely, graduate, bond. So the interface carries `launch`, `phase`,
`finalize` and `collectFees`, plus `quoteSupported`, `nativeFeeSource` and
`launchTarget`.

`nativeFeeSource` exists because the pair is the agent's choice. The obvious
way to fund a native launch fee, unwrapping some of the launch quote, assumes
the quote is wrapped native. An agent pairing against a stable, a stock token
or WOOD would revert at execute on exactly the pairings this template exists
for. The adapter names its fee token and amount, read live because the venue
owner can reprice between propose and execute, and the strategy acquires that
token through its own allowlisted swap adapter.

Rules every implementation must meet (normative in `ILaunchAdapter`):

- **Custody invariant.** When `launch` returns, the calling strategy holds
  `reserveHeld >= reserveAmount` launch tokens and the venue's creator
  economics, directly or through an adapter instance it alone owns. The adapter
  keeps no balance and no role usable for any strategy except through that
  strategy's own calls.
- `phase` and `quoteSupported` must not revert.
- `collectFees` pays the launch's `feeRecipient` only, is permissionless, and
  returns `(0, 0)` when nothing accrued.

`Failed` means the venue cancelled the launch. On StonkBrokers, timer expiry is
itself a graduation trigger (`timerClose = !openEnded && now >= deadline`), so a
closed window is one permissionless `graduate()` plus `bond()` away from a
locked LP. That is `Closing`, not `Failed`. `Failed` is reachable only through
`abort`, which the pad refuses once `buyCount != 0`. Verified on the live pads
by `test/launchpad/fork/StonkLaunchRobinhoodFork.t.sol`.

## Decision 2: two custody shapes, one interface

**Sushi (V1): a stateless singleton.** The creator role is transferable, so the
adapter can be creator for a few opcodes and hand the role on in the same
transaction. After the launch it holds nothing and no role.

**StonkBrokers: an ERC-1167 clone per launch.** There is no `transferCreator`.
Whoever calls `createLaunch` is the creator forever: fee recipient and the only
`arm`/`abort` caller. A shared singleton would become the creator of every
fund's launch, one contract holding every fee stream and every recovery lever.
Prior audit rounds kept removing that kind of shared mutable custody. So
`StonkLaunchAdapter.launch` mints a fresh clone owned by the calling strategy,
and the clone:

1. calls `createLaunch` (clone = creator) and receives the whole supply;
2. transfers `reserveAmount` to the owning strategy before arming anything;
3. arms the remainder, and delivers any dev buy straight to the strategy
   (`buy(..., recipient = owner)`);
4. forwards the creator fee the pad pushes back during that dev buy to the
   `feeRecipient`, returns any unrelated resting quote to the owner, and asserts
   it ends holding zero launch token.

Later clone verbs: `cloneFinalize` and `cloneCollectFees` are permissionless.
Neither pays the caller, and the venue's own `graduate`/`bond`/
`flushCreatorQuote` are permissionless too. `abort` is owner-only, because a
permissionless abort would let anyone cancel a fund's launch in the seconds
before its first trade. `LaunchpadStrategy` never calls `abort`.

The registry gate binds the **implementation**. Callers resolve a ref to a
clone by ERC-1167 runtime introspection (prefix, embedded implementation,
suffix), so per-launch clones need no registry writes, and de-listing the
implementation refuses every new launch through it. The lane map is
constructor-written storage with no setter; `padSetHash =
keccak256(abi.encode(quotes, pads))` is the on-chain witness of the
configuration the grant covered, since a codehash cannot see storage.

## Decision 3: fees are named at launch and never touch the strategy

`LaunchParams.feeRecipient` is always the fund's vault. `_execute` fills it
from `vault()`, and `InitParams` has no such member, so a proposer cannot
point the fee stream anywhere else. The venues bind the payee for the life of
the launch.

Routing fees through the strategy would give the fee stream a destination that
has to change at settlement. On v1 a fee that reaches a strategy after it
settled has no way home except a later governance batch naming it to
`rescueTo`. Naming the vault at launch removes that problem: fees never enter
strategy custody, settlement makes no venue call, and anyone may push accrued
fees with the adapter's permissionless `collectFees(launchRef)`. Fees arrive at
the vault in kind and unpriced; a later proposal disposes of them.

On StonkBrokers the clone stays the creator (it needs `arm`/`abort`), so the
clone forwards to its pinned `feeRecipient` rather than the venue paying the
vault directly. The recipient is written once at `initialize`, with no setter.
One consequence: the destination cannot follow a vault migration.

## Decision 4: the claim is a dividend in kind

Holders keep their shares and claim launch tokens from the reserve. Burning
shares to redeem is out for now: share supply is the governor's voting base and
the queue's pricing base, and burning mid-proposal would interact with the
withdrawal queue's single-realized-price invariant and the checkpointed votes.

`claimable(h) = reserve × getPastVotes(h, snap) / getPastTotalSupply(snap)`, at
most once per holder, inside the window. No new snapshot machinery is needed:
`SyndicateVault` is `ERC20VotesUpgradeable` with `clock() == block.timestamp`,
self-delegates every receiver in `_update`, and on v1 refuses `delegate`
outright, so past votes equal past balance for every holder. v1 also mints and
burns no shares while a proposal is open, so the snapshot denominator cannot
move under the claim.

- **Snapshot at execute**, the moment capital leaves the vault. An init-time
  snapshot would let the proposer freeze the claimant set before depositors can
  react to the public proposal.
- **Queue-escrowed shares** at the snapshot belong to the withdrawal queue,
  which never claims. That weight stays unclaimed and reaches the vault with the
  rest of the unclaimed reserve at settlement. It is not redistributed.
- A claim in the execute block reverts with the template's own
  `SnapshotNotFinal`, not OZ's `ERC5805FutureLookup` from inside the vault.
- `claimFor(holder)` is permissionless and pays the holder, never the caller.

## Decision 5: settlement on v1 is all-or-revert

This is where the port changes the design. On `post-audit`, settlement left
the unclaimed reserve and any unsellable quote on the clone, declared them
through `IStrategyDelivery` views (`hasUnvaluedResidue`, `undeliveredValue`,
with a residue latch), and let the vault recover them with `sweep()`. v1 has
none of that machinery. A balance left on a clone after `settle()` can only come
back through a later vault batch calling `BaseStrategy.rescueTo`. So:

**After `settle()`, the clone holds nothing.** `_settle`:

1. converts leftover quote to the vault asset through the allowlisted swap
   adapter, with a floor at the adapter's own forward quote less
   `settleSlippageBps`, using raw calls so the adapter cannot abort settlement;
2. pushes the vault asset;
3. pushes whatever quote is left **raw**: no quote, a zero quote, a reverting
   swap, or a partial fill's remainder. A failed conversion is not a revert,
   because an unquotable pair must not wedge settlement and with it
   `openProposalCount() != 0`, which locks the vault;
4. pushes whatever launch token is left (the unclaimed reserve) **in kind**.

Each push is a typed `safeTransfer` of the live balance. A token that will not
move fails the whole settlement instead of staying behind, and a retry works
once it moves. The fee-swap overshoot (an exact-input swap cannot land on an
exact fee amount) is pushed to the vault during `_execute`, since `feeToken` is
never stored and settlement could not name it.

**No claim can follow settlement.** `_claim` requires `Executed`, and
`BaseStrategy.settle` sets `Settled` before calling `_settle`. On the normal
path the window closed before the settle gate opened. On the backstop path
(below), settlement is what ends the window.

**The fund token is never sold.** Not into its own pool, not anywhere: that
price can be moved by an attacker inside the settlement transaction.

### P&L: a launch settles as a loss, and that is accepted

v1's governor measures settle P&L as the vault-asset balance delta,
`balanceOf(vault)` after settlement minus the snapshot before execute. Nothing
credits the reserve. Only step 2 above counts; the quote the launch spent, any
raw quote from step 3 and the reserve from step 4 all read as loss.

On `post-audit`, PR #277 fixed this with an `unpricedCostBasis()` credit on the
governor (the `unpriced-cost-basis` change). **That credit is not on v1 and is
not being re-added.** The product decision is to accept that a launch settles
as a loss equal to the quote it spent. The reserve is a dividend in kind to the
holders, not an asset the vault books.

Voters therefore size the proposal's `maxDrawdownBps` to the spend. v1 refuses
a settlement whose price per share falls below `ppsAtExecute × (1 −
maxDrawdownBps)`, with the declared drawdown capped at `MAX_STAMP_DRAWDOWN_BPS`
(90%). As a rule of thumb, `maxDrawdownBps` should be at least
`assetIn / totalAssets` at execute, plus headroom for management-fee accrual
and swap slippage. A proposal sized below that cannot settle through
`settleProposal`. The vault owner can still finish it with `unstick` (the same
settlement calls, floored at the 90% cap) once `strategyDuration` has passed,
or through the emergency path.

### Why the claim window is clamped at execute

`initialize` runs before the proposal that will carry the clone exists, so the
strategy cannot know the `strategyDuration` at init. The window is clamped at
execute instead:

    windowEnd = min(executedAt + claimWindow,
                    executedAt + strategyDuration − CLAIM_SETTLE_BUFFER)

`CLAIM_SETTLE_BUFFER` (5 minutes) is below the governor's 1-hour
`ABSOLUTE_MIN_STRATEGY_DURATION`, and a `strategyDuration` at or below the
buffer reverts execute instead of producing an empty window.

The proposal id and `anyoneSettleAt = executedAt + strategyDuration` are cached
at execute, because `getActiveProposal()` reads 0 after settlement. The settle
gate is a disjunction: settlement opens after `windowEnd` **or** at
`anyoneSettleAt`. A window that outlasted the proposal would keep `settle()`
reverting, with no permissionless exit (`settleProposal` bubbles the revert;
`unstick` and `emergencySettleWithCalls` are owner-gated), and deposits and
redemptions would stay locked vault-wide.

The clamp and the backstop share one `getProposal` struct decode, which is
upgrade-fragile. v1 changed `StrategyProposal` (it dropped `votesFor` and
`votesAbstain`); the template decodes through the v1 interface and reads only
`executedAt` and `strategyDuration`, so it is unaffected. A governor that
reordered the struct later would poison both clamp and backstop, and the bound
still standing then is the init-time ceiling `claimWindow <= MAX_CLAIM_WINDOW`
(14 days), which caps such a wedge at 14 days rather than forever.

## Decision 6: quote routing stays in the strategy, venue rules in the adapter

The vault asset (WETH or USDG in practice) is rarely the launch quote. The
strategy owns the swap: pull the vault asset, swap into the quote through the
allowlisted `ISwapAdapter` with the voted `minQuoteOut`, hand the quote to the
launch adapter. The adapter owns which quotes its venue accepts
(`quoteSupported`), which is where the WOOD asymmetry lives: Sushi may gain WOOD
by an owner action, StonkBrokers structurally cannot.

When the native fee is denominated in the vault asset, the strategy holds it
back before the quote leg, so the pair is crossed once instead of twice. On a
thin lane that is the difference between a launch and a failed one.

Tunables (`minTokensOut`, `minQuoteOut`, `settleSlippageBps`, `deadline`) may
change only before execute, and each value bound may only tighten.
`minTokensOut` is visible to voters, and a proposer who could lower it after
the vote would have been handed a sandwich budget by the vote itself.

## Decision 7: registry gates on v1

v1 deleted `TierRegistry.isAdapterAllowed` and the tier certification it came
with. Gating is now the counterparty allowlist:

- **Both** the launch adapter and the swap adapter must satisfy
  `isCounterpartyAllowed` on the registry found by walking `vault() ->
  governor() -> tierRegistry()`, the same length-checked raw-staticcall walk
  `PortfolioStrategy._requireAllowedAdapter` uses. Only an exact `1` counts as
  allowed; a revert, a short return or a dirty word is a no.
- `_initialize` fails closed on an unresolved registry and checks both
  adapters before asking the launch adapter anything, since an
  attacker-authored adapter answers `quoteSupported` with "yes" for free.
- `_execute` re-checks both, skipping only if the walk no longer resolves
  (`PortfolioStrategy` parity). The grant snapshots the adapter's codehash, so
  an adapter whose code changes after the grant reads as not allowed with no
  registry write at all.
- `_settle` and `claim` never consult the registry. Gating the exits would give
  a de-listing the power to freeze deployed capital and strand the claim.
- The quote token and the launch token are not counterparties. The strategy
  holds them as inventory and never calls them beyond ERC-20.

The deploy ceremony (`script/launchpad/DeployLaunchpadStrategy.s.sol`) grants
the Stonk adapter, its eight V2 pads and the lens with `setCounterpartyAllowed`,
and approves the template with `StrategyFactory.setTemplateApproval`. It
performs those writes when the broadcaster owns the registry and factory and
prints them as Safe transactions otherwise. The protocol's own swap adapter is
granted by the core ceremony. The pad and lens grants are read by no code
today; they record which venues the protocol vouched for, as `ILaunchAdapter`
asks.

## Trust notes

- `BaseStrategy.rescueTo(token)` is vault-only and works in any state, so a
  vault batch (a settlement or emergency call the proposal's governance
  allowed) could move the reserve out of a clone during the claim window. That
  is v1's emergency exit, not something this template can narrow.
- Launch tokens, raw quote and fees delivered to the vault sit outside
  `totalAssets()`. The vault owner's `rescueERC20` can move non-asset tokens
  whenever no proposal is open; disposing of them otherwise takes a proposal.
- `StonkLaunchAdapter` holds the lens and never calls it. `minTokensOut` is
  quoted off-chain through the lens and voted on; re-quoting at execute would
  enforce a floor nobody approved, read off a price movable in the same
  transaction.

## Open questions

1. **WOOD on Sushi.** Needs the Sushi owner (`0x6fA4…4657`) to register a
   WOOD/USD aggregator. Until then Sushi launches pair against WETH or another
   feed-registered quote. Re-check against Sushi Launchpad V2 on the sushi-v2
   branch.
2. **Default economics.** The default reserve fraction below the 20%
   `MAX_RESERVE_BPS` ceiling, and on Stonk the default `startMcapUsd8` /
   `gradMcapUsd8` / tax schedule the CLI will offer.
3. **`maxDrawdownBps` guidance.** The CLI should compute and suggest the
   drawdown a launch needs (Decision 5) rather than leave voters to derive it.

Resolved during PR #277: the Stonk never-graduates path does not exist
(Decision 1), and the fee-stream endgame is the vault, named at launch
(Decision 3).

## Venue 3: Pons (separate PR, #282)

Researched and built separately because the venue is closed to us.
`PonsLaunchFactory` (`0xA5aA…1feB`) gates `launchToken` on `launchEnabled`
(false) or a per-address whitelist, which only the Pons owner can grant. The
whitelist being per address rules out per-launch clones, so a Pons adapter must
be a singleton. Its `TokenParams.feeWallet` names the payee at launch, so a
singleton is also correct under the custody invariant. The creator receives
zero tokens, the initial buy is funded in native ETH, and the only live launch
config pairs against WETH.

## Not ported from PR #277

- The protocol-side changes: governor, `CallSandbox`, `BaseStrategy`,
  `ConcentratedLiquidityStrategy`, `ISyndicateGovernor`, `IStrategyDelivery`,
  the storage-layout golden, CI and `foundry.toml` edits, and the
  `unpriced-cost-basis` change. v1 does not carry them.
- `SushiLaunchAdapter`, its vendor interface, mocks and tests: being rewritten
  for Sushi Launchpad V2 on the sushi-v2 branch.
- `script/fork/launchpad-e2e.sh`: tied to a specific Tenderly vnet.
