# LighterPerpStrategy — spec & integration guide

A perpetuals strategy that runs a **contract-owned Lighter (zkLighter) margin account**.
USDG is pulled from the vault into an account owned by the strategy contract; a proposer-
registered **agent L2 trading key** drives trades off-chain through Lighter's API, while
every custody action (cancel, close, withdraw) stays on-chain and authed to the account
owner — the strategy itself.

This document serves two audiences:

- **Auditors** — architecture, trust model, storage, authorization, the three-step settle,
  and known risks.
- **Frontend / backend integrators** — the lifecycle, guardrail actions, state reads,
  events, and errors.

Source: `src/lighter/LighterPerpStrategy.sol`, extending the protocol's
`BaseStrategy` (`lib/sherwood-protocol/src/strategies/BaseStrategy.sol`, imported as
`@sherwood/strategies/BaseStrategy.sol`) and using `src/lighter/IZkLighter.sol`. The
protocol is pinned to **v1-deploy `2a885c53`**. File references are relative to this
repo's root and pinned to the code this document ships with — the code is
authoritative where any external description disagrees. Protocol-wide docs:
https://docs.sherwood.sh/

> **Ported from sherwood-protocol PR #3** (head `1f1ea29`, written against the
> `post-audit` protocol). The v1 port removed the `IStrategyDelivery` residue probes and
> the `sweep()` door, made `_settle` explicitly all-or-revert, re-expressed the venue
> gate on `PortfolioStrategy`'s helper, and replaced the class-certification ceremony
> with v1's. Each change is called out where it lands below; "What changed from
> post-audit" at the end lists them in one place.

## What it is

A single ERC-1167 clone per proposal. It:

1. Pulls USDG from the vault and `deposit`s it into a **strategy-owned** Lighter perp
   account (the first deposit registers the account synchronously in the same tx).
2. Registers a **trade-only** agent L2 key so an off-chain agent can trade the account via
   Lighter's API — the key can place/cancel orders but can **never** move funds out.
3. Lets the proposer **or the vault owner** run on-chain **guardrails** (cancel all,
   market-close a position, rotate the key) at any time between execute and settle.
4. Unwinds via a **three-step settle**: `initiateReturn()` closes positions,
   `queueWithdraw(ticks)` queues the (async, slow) USDG drain once the closes have
   filled, and a later `_settle` claims the matured balance and returns it to the vault.

On protocol v1 every template is priced the same way, and this one simply has no
reason to want anything else: the vault's NAV is its **idle asset balance**, deposits
and redemptions are shut while a proposal is open (`redemptionsLocked()` =
`openProposalCount() != 0`), and queued redemptions settle at the per-proposal price
`onProposalSettled` stamps after settlement. The venue exposes no on-chain mark this
template could report even if the protocol asked — positions and margin are off-chain
sequencer state and `IZkLighter` has no accessor for either.

**What this template no longer declares.** On `post-audit` it answered
`IStrategyDelivery` (`hasUndeliveredValue` / `undeliveredValue` /
`hasUnvaluedResidue`), which is how it told the vault about margin it could not value.
v1 deleted that machinery and nothing on-chain reads those answers any more. Whether
margin is still at Lighter after settlement is now **off-chain knowledge only** — the
CLI / agent read it from the Lighter API — and no protocol decision depends on it. See
"Late arrivals" for the on-chain recovery path.

## Trust model

| Concern | Design |
|---|---|
| **Custody boundary (D1)** | The Lighter account is owned by the **strategy contract**. Every mutating venue call is authed by `msg.sender` = the account owner. Funds can only leave the account to the account owner (this contract), and this contract only ever pushes USDG to `vault()`. |
| **Agent key is trade-only** | `changePubKey(acct, apiKeyIndex, pubKey)` registers an L2 key that can place/cancel orders through the API. It **cannot** withdraw — `withdraw` / `withdrawPendingBalance` are venue-authed to the account owner, never the API key. A compromised agent key can churn/lose the position but cannot exfiltrate principal. |
| **On-chain kill switch** | The proposer can `CANCEL_ALL`, `CLOSE_MARKET`, `ROTATE_KEY` or `REGISTER_KEY` at any time via `updateParams`, `initiateReturn()` force-closes every configured market both directions, and `queueWithdraw(ticks)` drains the account — all without the agent's cooperation. **The vault owner holds the same levers** via `guardrailAction(...)`, `registerAgentKey()`, `initiateReturn()` and `queueWithdraw(...)`. That second key is not redundancy for its own sake: `onlyProposer` re-reads the vault's live agent set, so without it `SyndicateVault.removeAgent` would *kill the kill switch* — de-registering a misbehaving agent would leave nobody able to cancel its orders or close its positions until `strategyDuration` elapsed. |
| **Venue is bound to governance** | `ZK_LIGHTER` is bound on the TierRegistry **counterparty** axis at `_initialize` (`vault() → governor() → tierRegistry() → isCounterpartyAllowed`, fail-closed, including on an unresolved registry) and re-checked at `_execute` (skipped only if the registry is unresolved). The helper is `PortfolioStrategy`'s, byte for byte. `ZK_LIGHTER` is a `constant`, so this is not protection against a hostile address — it is the switch that lets an owner make the whole template inert in one call, without touching the `StrategyFactory` allowlist or waiting for a redeploy. It is deliberately **not** consulted on the exit path or the kill switch (`initiateReturn` / `queueWithdraw` / `_settle` / `recoverResiduals` / guardrails), so a demotion — or a broken registry — can never freeze capital already at the venue. |
| **The registry cannot see a venue upgrade** | `TierRegistry` snapshots the counterparty's codehash on grant and stops vouching if it changes. `ZK_LIGHTER` is a **proxy**: its runtime code does not change across an implementation upgrade, so a Lighter upgrade does **not** drop the grant. Re-reviewing the venue on every upgrade is an operator duty; `setCounterpartyAllowed(ZK_LIGHTER, false)` is how to act on it. |
| **Priced as an uncertified call, on purpose** | `execute()` and `settle()` are deliberately **not** certified in the TierRegistry, so `tierOf` resolves both to the uncertified default `(tier 2, 10_000 bps)` and a proposal's `requiredCoverage` is the **full notional** of every declared cap across both legs. `execute()` moves the whole cap into an off-chain venue whose sequencer this protocol does not control and whose margin no on-chain reader can price — there is no honest sub-`10_000` extractable bound for it. See "Tiering". |
| **Vault asset is bound** | `_initialize` reverts `AssetMismatch` unless `IERC4626(vault()).asset() == USDG`. Same bind, same reason, as `MorphoSupplyStrategy`'s `LoanAssetMismatch`: every pull and every push here is denominated in a `constant`, and a vault accounting in a different asset would never see the value move. |
| **Value is never self-reported** | Realized PnL is the USDG that actually round-trips back: the governor measures it as the vault's asset delta across the proposal (`_finishSettlement`), and nothing this template says enters that figure. |
| **Residual trust: `markets` ≠ the agent's reach** | The registered L2 key can trade **any** Lighter market — the venue enforces no per-key whitelist. `markets` is only the list `initiateReturn()` auto-closes, so a position the agent opens outside it is **not** closed by the automatic unwind and its margin stays locked. See "Residual trust" below. |
| **Residual trust: the settle gate is a *liveness* check, not a completeness check** | `_settle`'s guard compares what came back against `queuedTicks` — the amount the **proposer chose**. It proves "everything I *asked* for arrived", which is enough to stop a phantom-loss settle, but it does **not** prove the venue account is empty: `queueWithdraw(1)` plus one tick maturing satisfies it with the rest of the margin still at Lighter. It cannot be made complete on-chain — position and margin state live with the off-chain sequencer and `IZkLighter` exposes no accessor for either. **Completeness is an off-chain guarantee**: the CLI's `queue-withdraw --all` reads the true L2 balance from the Lighter API and hard-aborts on any nonzero position size. It sits in the same trust bucket as the agent key — a proposer who ignores the CLI stamps the per-proposal redeem price at a deflated NAV, which is a transfer from exiting LPs to remaining LPs (the remainder is still recoverable, but it lands *after* the stamp). |

## Lifecycle

```
propose(strategy = LighterPerp clone)
        │
        ▼
execute()                pull the coverage-scaled declaration from the vault
  (onlyVault)            → deposit into Lighter → account registered
                         synchronously (accountIndex != 0). The amount that
                         moved is recorded in deployedAmount()
        │
        ▼
registerAgentKey()       proposer OR vault owner registers the 40-byte
  (proposer/owner)       trade-only L2 key (idempotent; re-run for rotation)
        │
        ▼
  agent trades via Lighter API (off-chain)  ──  proposer trims risk on-chain via
        │                                        updateParams; owner via
        │                                        guardrailAction (same actions)
        ▼
initiateReturn()         cancel all → both-side market-close every market →
  (proposer or owner     record returnsInitiatedAt. Queues NOTHING.
   anytime; anyone once
   strategyDuration
   has elapsed)
        │
        ▼
  ⏳ closes fill          the closing trades' PnL only exists now — this is why
                          the drain amount cannot be chosen a step earlier
        │
        ▼
queueWithdraw(ticks)     queue withdraw(ticks) → queuedTicks += ticks
  (proposer OR           [ticks = observed L2 balance, read off-chain AFTER
   vault owner)           the closes filled — sized against deployedAmount(),
                          never against depositAmount]. Repeatable, and callable
                          in the Settled state so an under-withdraw is
                          correctable.
        │
        ▼
  ⏳ async maturity       Lighter's sequencer matures the withdrawal into
   (minutes → days)       getPendingBalance() — NOT same block
        │
        ▼
settle()                 requires returnsInitiatedAt != 0, a strictly later
  (onlyVault)            block, and that everything queued has arrived →
                         claim pending (re-read: must be 0) → push ALL USDG to
                         the vault → the governor checks the settle-price floor
                         and stamps the per-proposal price
        │
        ▼
  late arrivals          queueWithdraw(rest) → recoverResiduals() claims onto
  (post-settle)          the clone (permissionless) → a vault batch's
                         clone.rescueTo(USDG) takes it home
```

## Configuration (init data)

`initialize(vault, proposer, data)` where
`data = abi.encode(bytes apiKeyPubKey, uint8 apiKeyIndex, uint16[] markets, uint256 depositAmount)`.

| Field | Validation | Meaning |
|---|---|---|
| `apiKeyPubKey` | length **exactly 40** (`InvalidPubKey`) | Goldilocks-canonical L2 trading key |
| `apiKeyIndex` | `2..254` (`InvalidApiKeyIndex`) | API key slot (0/1 reserved by the web app, 255 out of range) |
| `markets` | nonempty (`NoMarkets`), at most **16** (`TooManyMarkets`), each `≤ 254` (`InvalidMarket`), no duplicates (`DuplicateMarket`) | perp markets `initiateReturn()` auto-closes. **Not** a venue-enforced trading whitelist — see "Residual trust" |
| `depositAmount` | `≥ MIN_DEPOSIT = 1e6` (`DepositTooSmall`) and `≤ type(uint64).max` (`DepositTooLarge`) | the USDG **ceiling** `execute()` pulls. Mandatory — there is no dynamic mode. The amount actually deployed is this figure scaled by the proposal's approve coverage; read `deployedAmount()` after execute, never this |

`initialize` additionally reverts `AssetMismatch` unless `IERC4626(vault()).asset() == USDG`,
and `TierRegistryUnresolved` / `CounterpartyNotAllowed` unless the vault's governor resolves
a TierRegistry that vouches for `ZK_LIGHTER` on the counterparty axis (see "Trust model").

**There is no `depositAmount == 0` "dynamic-all" mode.** It pulled whatever USDG the vault
happened to hold at execute time, which cannot survive the v1 governor: the execute batch is
checked against a **per-call cap**, and `SyndicateVault.executeGovernorBatch` refuses a pull
that would breach `QueueReserveBreached` or `BufferBreached`. All three are decided against a
*size*, and a size only knowable at execute time is a size nobody could vote on. Size the
deposit explicitly in the proposal; surplus float stays in the vault.

`MAX_MARKETS = 16` and the duplicate rejection exist because `initiateReturn()` makes
**2 venue calls per market in one transaction**. An unbounded or padded list could push
that past the block gas limit, which would make `returnsInitiatedAt` unreachable and
therefore `_settle` permanently unreachable.

`depositAmount` is bounded by `type(uint64).max` at init because `IZkLighter.withdraw` takes
`uint64` ticks: a larger deposit could never be drained in a single request. Both bounds are
enforced once, at init, and `_execute` never re-reads the vault's balance — the declaration is
the ceiling and nothing about the vault's live float can enlarge it.

### The declaration is a ceiling, not a promise: coverage scaling

`execute()` deploys **`depositAmount × effectiveMaxCapital / maxCapital`**, floored, and
records it in `deployedAmount()`.

When the bond-encumbered approve quorum comes in short, the v1 governor does not fail
closed. `SyndicateGovernor._deriveAndStoreEffectiveCapital` takes the coverage actually
raised and scales the whole proposal by `raised / required` — the batch-level net-outflow
meter (`effectiveMaxCapital`) **and** every per-call cap (`_scaleCaps`). Pulling the pinned
declaration into a scaled batch would revert `CallCapExceeded` at the execute leg: a
governance cycle spent, the vault untouched, nothing deployed.

**Re-verified on v1.** `executeProposal` writes `effectiveMaxCapital` *before* handing the
batch to the vault, so `getEffectiveMaxCapital(activePid)` read from inside `execute()` is
this execution's figure, and `getRiskEnvelope` still returns the declared `maxCapital`.
v1's `_scaleCaps` has one step `post-audit` did not — it trims the largest scaled cap when
the scaled caps sum past `effectiveMaxCapital` — but that trim cannot fire on the execute
leg: `propose` rejects `sum(executeCallCaps) > maxCapital` (`CallCapsExceedMaxCapital`), and
a sum of floors is at most the floor of the sum.

**Why the ratio and not `min(depositAmount, effectiveMaxCapital)`.** There are two caps and
the binding one is not the batch's. `BatchExecutorLib` meters this call's own gross outflow
against `floor(cap_i × raised / required)`, and a proposal normally declares `maxCapital` as
the vault's whole TVL while `cap_i` is just the deploy size — so the `min` form resolves to
the unscaled `depositAmount` and still breaks the per-call meter. The ratio form cannot:
`floor(dep × floor(max × r/q) / max) ≤ floor(dep × r/q)` for any `dep ≤ cap_i`, because the
inner floor only moves the numerator down.

**A scaled amount below `MIN_DEPOSIT` reverts `DepositTooSmall` — from `_execute`, not just
from `initialize`.** Deploying dust is worse than deploying nothing: the unwind is two venue
round-trips per market regardless of size. The proposal expires with the vault untouched.

Reads degrade to the pinned amount whenever the governor cannot be asked — no resolvable
`governor()`, no active proposal, a governor that answers neither getter, a zero declared
envelope, or an effective capital at or above the declared one. Every v1 governor answers
both getters; the fallback costs nothing and the alternative is an undecodable `execute()`
revert, since every hop is a length-checked raw staticcall.

**Size the drain off `deployedAmount()`, not off `depositAmount`.** `queueWithdraw(ticks)`
asks the venue for a balance that has to be there; the declaration may name a balance that
never was.

### Chain and venue

The **template** constructor pins `block.chainid` to `4663` (Robinhood mainnet) or
`9994663` (the Tenderly fork), reverting `UnsupportedChain` otherwise — the venue and asset
addresses are `constant`, so a template deployed on any other chain would point at whatever
code happens to live there. ERC-1167 clones skip constructors, so this guards the template
deploy only, which is exactly the right place.

Venue constants (also recorded in `script/lighter/addresses-4663.json`; the fork replays
mainnet state, so both chains share them):

- ZkLighter proxy `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d`
- USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6 dp), asset index `3`, route `Perps = 0`

USDG tick size is 1, so any 6-dp amount is trivially a valid tick multiple.

## Tiering and the v1 ceremony

v1 has **one** registry axis this template touches and **one** factory switch:

| Switch | Question | Set by | This template |
|---|---|---|---|
| `StrategyFactory.approvedTemplate` | may clones of this template be minted and registered? | `setTemplateApproval(template, true)` | **yes** — `cloneAndInit` refuses an unapproved template and registers every clone it mints; the vault's batch guard admits a non-asset target only if the factory reports it registered |
| `TierRegistry.isCounterpartyAllowed` | may a reviewed template hand this venue funds from its own code? | `setCounterpartyAllowed(ZK_LIGHTER, true)` | **yes** — otherwise every clone-init reverts `CounterpartyNotAllowed` |
| `TierRegistry.tierOf` / class certification | how much of a declared cap is extractable, and at what tier? | `proposeClassCertification` → `certifyClass` | **no**, for `execute()` and `settle()` — they stay at the `(2, 10_000)` default |

The registry cannot express "tier 2 / full notional" as a *certification*:
`proposeClassCertification` reverts `InvalidTier` on `tier >= 2` and `BoundRequired` on a
bound of `0` or `>= 10_000`. Tier 2 / 10_000 is what `tierOf` **returns when nothing is
certified**, so the correct encoding of the decision is to certify neither money-moving
selector.

**What the v1 ceremony dropped.** On `post-audit` a per-proposal clone was only a legal
batch callee if its *class* was allowed (`setClassAllowed`), which required a class
*anchor*, which only `certifyClass` could write. The old script therefore certified the
inert `name()` selector at tier 0 / bound 1 purely to mint the anchor, waited out
`certifyDelay`, and ran a second `finalize()` entrypoint. v1 deleted the class-allow axis —
clones are admitted structurally because the factory registered them — so there is nothing
for an anchor to unlock. `script/lighter/DeployLighterTemplate.s.sol` is now one broadcast
and certifies nothing. It still **requires** `classTierOf(template, execute) ==
classTierOf(template, settle) == (2, 10_000)` as a post-flight.

**What follows from tier 2**, all of it the safe direction:

- The bond-encumbered approve quorum can never be escaped by an owner raising
  `ExposureLedger.quorumTierThreshold` to 2. A template that moves the whole cap
  off-chain always has an identified, stake-backed approver on the hook.
- The per-call tier-2 ceiling (`tier2CallCapBps`) binds this template if an owner ever
  tightens it.
- `executeProposal`'s `TierRegressed` / `CoverageRegressed` guards become unreachable
  here: the tier cannot rise above 2 and coverage cannot rise above the full bound, so a
  certification change landing between propose and execute cannot brick an in-flight
  proposal.
- `requiredCoverage` is `sum(execCaps) + sum(settleCaps)` — for the canonical
  one-mover-per-leg proposal, `2 × maxCapital`. Size the guardian cohort against that: an
  under-covered proposal does not revert, it **deploys less** (see "coverage scaling").

## Guardrail actions (`updateParams` / `guardrailAction`)

`Executed` state only. Encoding: `abi.encode(uint8 action, bytes args)`. Two doors onto the
same dispatch:

- `updateParams(data)` — **proposer only** (`BaseStrategy.onlyProposer`, which re-reads the
  vault's live agent set). This is the `IStrategy` surface the governor and the CLI already
  speak.
- `guardrailAction(data)` — **proposer or vault owner**. Same actions, same state gate.

| Action | Value | `args` | Effect |
|---|:---:|---|---|
| `CANCEL_ALL` | 1 | `""` | `cancelAllOrders(acct)` |
| `CLOSE_MARKET` | 2 | `(uint16 market, uint32 price, uint8 isAsk)` | `createOrder(acct, market, 0, price, isAsk, Market)` — single-side full-position close; side chosen off-chain (cheaper than the both-side close) |
| `ROTATE_KEY` | 3 | `(bytes newPubKey40)` | update the **stored** key, then `changePubKey` — reverts `InvalidPubKey` if not 40 bytes |
| ~~`WITHDRAW`~~ | ~~4~~ | — | **RETIRED.** Superseded by the top-level `queueWithdraw(ticks)`, which must also work in the `Settled` state and therefore cannot route through `updateParams` (Executed-only). Action `4` reverts `InvalidAction`; `1`/`2`/`3`/`5` keep their meaning |
| `REGISTER_KEY` | 5 | `""` | (re)register the stored key — reverts `AccountNotRegistered` before the first deposit |

`baseAmount = 0` on a close order closes the **full** position on whichever side opposes it.
Any unrecognized action reverts `InvalidAction`.

`CLOSE_MARKET` deliberately does **not** validate `market` against the configured `markets`
list: the agent key can trade any Lighter market, so this is the operator's only remedy for
a position opened outside the list (see "Residual trust"). Impact is bounded —
`baseAmount = 0` can only *close* a position, never open one.

## Roles & authorization matrix

`proposer` = the agent that cloned/initialized the strategy (`BaseStrategy._proposer`).

"proposer" below always means a **live** proposer: `_isLiveProposer` re-reads
`vault().isAgent(proposer)` on every one of these paths, exactly as
`BaseStrategy.onlyProposer` does. A de-registered agent fails every ✅ in that column.

| Function | vault | proposer | vault owner | anyone | State gate |
|---|:---:|:---:|:---:|:---:|---|
| `execute()` / `settle()` | ✅ | | | | `onlyVault` + state (`execute` also requires the governor's active proposal to name this clone) |
| `rescueTo(token)` (inherited) | ✅ | | | | none — any state |
| `registerAgentKey()` | | ✅ | ✅ | | account must exist |
| `updateParams(...)` | | ✅ | | | `onlyProposer`, `Executed` |
| `guardrailAction(...)` | | ✅ | ✅ | | `Executed` |
| `initiateReturn()` | | ✅ (anytime) | ✅ (anytime) | ✅ (once `strategyDuration` has elapsed) | `Executed` |
| `queueWithdraw(ticks)` | | ✅ | ✅ | | `Executed` **or** `Settled` |
| `acknowledgeShortfall()` | | ✅ | ✅ | | `returnsInitiatedAt != 0` **and** `queuedTicks != 0` **and** a shortfall is currently observable |
| `recoverResiduals()` | | | | ✅ | any |

`recoverResiduals()` is safe permissionless because it moves value in only one direction and
to only one place — the venue pays the account owner, which is this contract (and
`withdrawPendingBalance` is permissionless at Lighter anyway). It does **not** push to the
vault; only the vault can do that, via `rescueTo`, and only from a governor batch.

Six auth details are load-bearing:

- **`queueWithdraw` is NOT permissionless**, even after `strategyDuration`, and not after
  settlement either. The amount is un-correctable once the request is queued, so letting an
  anonymous caller choose it would let them book the entire principal as an LP loss for the
  price of two transactions. Only the drain *trigger* (`initiateReturn`) is permissionless;
  the drain *amount* never is.
- **`initiateReturn()`'s permissionless branch validates the proposal identity, not just
  the clock.** `getActiveProposal()` returns `0` when nothing is active and
  `getProposal(0)` returns a **zeroed struct rather than reverting**, so a bare
  `block.timestamp < p.executedAt + p.strategyDuration` check is fail-**open** for
  everyone. That state is reachable: the emergency-settle paths clear `_activeProposal`
  while the strategy may still be `Executed`. The gate therefore rejects `pid == 0` and
  `p.strategy != address(this)` first.
- **The permissionless branch may only *kick off* the unwind.** The proposer can
  re-invoke `initiateReturn()` freely (e.g. the agent re-opened after the first close),
  but a repeat from an anonymous caller reverts `AlreadyInitiated` so a griefer cannot
  spam venue priority requests block after block. `returnsInitiatedAt` latches on the
  first call only — re-latching would reset the async-maturity clock and hold `_settle`
  in `SettleTooSoon` indefinitely.
- **`acknowledgeShortfall()` is state-gated, not a free waiver.** It waives the two
  settle guards that stand between `settle()` and booking the principal as a loss, so an
  ungated version was a one-call bypass of both. It requires an *initiated* return, a
  *nonzero* `queuedTicks`, and a shortfall that is **actually observable right now**
  (`returnedAssets + pending + bal < queuedTicks`). Kept on the proposer as well as the
  vault owner deliberately: post-gate the waiver grants the proposer nothing they do not
  already hold via the denominator, and the proposer is the party that observes the
  under-fill operationally.
- **After an emergency settle, the permissionless `initiateReturn()` branch is closed.**
  Rejecting `pid == 0` means that once `_activeProposal` is cleared the only remaining
  unwind drivers are the **proposer** and the **vault owner**, with `recoverResiduals()`
  still open to anyone. This is deliberate: the emergency-settle path is itself
  vault-owner-driven, so the owner is by construction present.
- **The vault owner is a first-class unwind driver, not a fallback.** `initiateReturn()`,
  `queueWithdraw()`, `guardrailAction()` and `registerAgentKey()` all admit
  `ISyndicateVault(vault()).owner()`. Without that, the owner's own revocation lever
  (`removeAgent`) was self-defeating: it stripped the only party who could cancel orders,
  close positions, rotate the compromised key, or *start* the unwind. The owner can move no
  funds anywhere new — every withdrawal is venue-authed to this contract, which only ever
  pushes to `vault()` — so the second key adds liveness and no exfiltration surface.

## Three-step settle

Lighter withdrawals are **async priority requests**. A `withdraw` only becomes claimable
once the off-chain sequencer's batch executes — proven to take **minutes to days**, never the
same block. Settling naively (drain + push in one call) would push ~0 and book a **phantom
total loss**.

**Why close and withdraw are separate steps.** Both legs used to live in one
`initiateReturn(ticks)` call, which meant `ticks` was read off-chain *before* the closing
trades executed — so it structurally could not include those trades' PnL. Under-stating
stranded the remainder permanently, because the only route to `ZK_LIGHTER.withdraw` was
`Executed`-gated. The two legs are split, and the withdraw leg is reachable **after**
settlement.

**Step 1 — `initiateReturn()`**:
- `cancelAllOrders`, then for **every** configured market emit **both** a market SELL-close
  (`price = 1`, `isAsk = 1`) and a market BUY-close (`price = 2^32-1`, `isAsk = 0`). The
  contract can't read a position's sign on-chain, so it closes both directions — the side
  opposing the open position fills, the other no-ops against a flat/absent position. Proven
  on 4663 in both directions (`test/lighter/harness/LighterH2Canary.md`).
- Queues **nothing**. Records `returnsInitiatedAt = block.number` on the first call.

> **MEV surface.** Those price bounds (`1` for a SELL, `2^32-1` for a BUY) are the widest
> legal values — i.e. the unwind carries **zero slippage protection**. This is deliberate:
> an unwind that silently no-fills is strictly worse than a bad fill, because the margin
> then never leaves the venue and the whole settlement stalls. If tighter bounds are wanted
> for a given position, use `CLOSE_MARKET` (which takes an explicit `price`) *before*
> `initiateReturn()`; the both-side sweep then no-ops on a flat book.

**Step 2 — `queueWithdraw(uint64 ticks)`**, proposer or vault owner:
- `withdraw(acct, 3, Perps, ticks)`, accumulating into `queuedTicks`. `ticks` is the
  **observed L2 balance** read off-chain from the API *after* the closes filled. A
  too-large value reverts venue-side.
- Repeatable, and callable in **both** `Executed` and `Settled`.

**Step 3 — `_settle()`**, governor-called, **all-or-revert**:
- Reverts `ReturnsNotInitiated` if step 1 never ran.
- Reverts `SettleTooSoon` unless `block.number > returnsInitiatedAt`.
- Reverts `NothingQueued` if `queuedTicks == 0` — no drain was ever requested, so settling
  would book the whole principal as a loss while it still sits on the venue.
- Reverts `WithdrawalInFlight(queued, accounted)` if
  `returnedAssets + getPendingBalance() + USDG.balanceOf(this) < queuedTicks` — what was
  asked for has not fully arrived. This replaced a `pending == 0 && bal == 0` check that
  anyone could satisfy by donating 1 wei of USDG.
- Otherwise: claim the matured pending balance (skipped if a third party already claimed it
  here — `withdrawPendingBalance` is permissionless), **re-read it and revert
  `SettleIncomplete` if anything is still claimable**, then push the **entire** USDG balance
  to the vault.

**The all-or-revert invariant.** After a successful `settle()` the clone holds nothing it
could have delivered: no USDG, nothing claimable at Lighter. USDG is the only token the
template takes custody of; anything else was sent by someone outside the template and is the
vault's to take with `rescueTo(token)`. What settlement cannot deliver is value that is not
yet this contract's to claim — ticks queued but not matured, and L2 margin never queued —
and the guards above exist so that it is not booked as a loss by accident. The
`SettleIncomplete` re-read is new in the v1 port: the venue is third-party code behind a
proxy, and a claim that ever pays out less than asked would otherwise leave deliverable
value behind that the governor's P&L has already booked as lost.

### What the settle gate does and does not prove

- **It is a liveness / anti-phantom-loss check.** It proves *"everything I asked for has
  come back"*.
- **It is NOT a completeness check.** The denominator is `queuedTicks`, which the proposer
  chooses. `queueWithdraw(1)` followed by 1 tick maturing satisfies the guard with **no
  waiver at all**.
- **It cannot be made complete on-chain.** The account's true balance and open positions are
  off-chain sequencer state; `IZkLighter` exposes `getPendingBalance` (matured withdrawals
  only) and nothing else.
- **Completeness is enforced off-chain**, by the CLI: `queue-withdraw --all` reads the true
  L2 balance from the Lighter API and hard-aborts if any market still has a nonzero position
  size.
- **The residual risk is a NAV *transfer*, not a loss.** A proposer who under-queues stamps
  the per-proposal redeem price low; the remainder is still recoverable (see "Late
  arrivals"), but it lands after the stamp, so the value moves from exiting LPs to remaining
  LPs. The vault owner's `emergencySettleWithCalls` path is the backstop if the proposer will
  not complete the drain.

### `returnedAssets` and `rescueTo`

`returnedAssets` counts what **this contract** pushed to the vault — on v1 that is the
`_settle` push and nothing else (post-audit also counted every `sweep()`). The inherited
`BaseStrategy.rescueTo(token)` is `onlyVault`, not `virtual`, and moves a balance without a
hook this template could observe, so it is **not** counted. The consequence: a vault batch
that rescues USDG off the clone **before** `settle()` shrinks `accounted` by what it moved,
and the settle guard then reads that as a shortfall. That is not a brick —
`acknowledgeShortfall()` lets settlement through, and nothing is lost because the rescued
USDG is already in the vault. `test_v1_rescueBeforeSettle_readsAsShortfall_waiverUnblocks`
pins it.

### The settle guard cannot brick the vault

The contract can never *know* the account is empty — it can only verify that what it
**asked** for has come back. When the venue under-fills (partial batch, forced liquidation,
a write-off), `accounted` can never reach `queuedTicks` and the guard would hold `_settle`
shut. Three independent releases exist, in increasing order of cost:

1. **`acknowledgeShortfall()`** — proposer *or* vault owner asserts the shortfall is real.
   It only relaxes a timing gate: it cannot redirect funds, and anything that matures later
   is still recoverable **after** settle. This is the normal path. It is **state-gated**:
   - `returnsInitiatedAt != 0` (`ReturnsNotInitiated`) — the positions were actually closed;
   - `queuedTicks != 0` (`NothingQueued`) — a drain was actually requested;
   - `returnedAssets + pending + bal < queuedTicks` (`NoShortfall(queued, accounted)`) — the
     shortfall is observable *now*. Arming while `accounted == 0` (nothing matured yet)
     stays legal — that is the normal case.
2. **`SyndicateGovernor.unstick(pid)`** — vault owner re-runs the pre-committed settlement
   calls once `strategyDuration` has elapsed. (Only helps if those calls don't revert inside
   `strategy.settle()`.)
3. **`emergencySettleWithCalls` → `finalizeEmergencySettle`** — the vault owner supplies
   unwind calls, guardians review them, and `_finishSettlementHook` completes the proposal
   in the *governor* whether or not `strategy.settle()` was ever called.

> **The waiver does not waive the governor.** v1's `settleProposal` refuses to finish below
> a price-per-share floor derived from the proposal's `maxDrawdownBps`, capped at
> `MAX_STAMP_DRAWDOWN_BPS = 9_000` (`SettlePriceBelowFloor`). An acknowledged shortfall
> deeper than the declared drawdown makes the whole settlement revert; `unstick` applies the
> 90% cap instead of the declared bps, and `finalizeEmergencySettle` applies no floor.
> Declare `maxDrawdownBps` for a leveraged perp venue with that in mind.

Because (3) resolves a proposal without touching the strategy, neither `recoverResiduals()`
nor `rescueTo()` is gated on the lifecycle state — an emergency-settled Lighter clone sits in
`Executed` forever holding, or still owed, USDG. A **later** proposal's batch can also call
`clone.settle()` on it (BaseStrategy deliberately leaves `settle()` unbound to the active
proposal for this reason).

### Residual trust: `markets` is not a trading whitelist

The registered L2 key can trade **any** Lighter market. The venue enforces no per-key market
restriction, and the contract has no way to impose one. `markets` is only the list that
`initiateReturn()` automatically closes.

**Consequence:** if the agent opens a position in a market outside `markets`, the automatic
unwind never closes it. Its margin stays locked on the venue, so the post-close L2 balance
is lower than expected and `queueWithdraw` under-fills — the loss shows up as a settlement
shortfall, not as a revert.

**Operator remedy:** `CLOSE_MARKET` (action `2`) on the unlisted market, then
`queueWithdraw(ticks)` for the freed margin.

**Ordering constraint:** `CLOSE_MARKET` routes through `updateParams` / `guardrailAction`,
both `Executed`-only. `queueWithdraw` survives into `Settled`, but *closing* does not. Discover
and close stray positions **before** settlement; monitoring the account's open positions
off-chain is an operational requirement.

## The LP-lock window

Because the withdrawal leg is asynchronous and slow, the proposal does **not** settle the
instant the unwind starts, and on v1 deposits and instant redemptions stay shut for as long
as the proposal is open. LPs who queued a redeem are paid at the per-proposal price only
**after** `_settle` returns the USDG — which cannot happen until the sequencer matures the
withdrawal (minutes to days). An in-flight Lighter proposal ties up the vault until maturity
+ settle.

## Late arrivals (post-settle recovery)

Late-maturing tranches — a `withdraw` that matured after settle, an under-queued drain, an
acknowledged shortfall that later pays — are recovered in three steps:

1. **`queueWithdraw(ticks)`** — proposer/owner queues the remainder. Works in the `Settled`
   state.
2. **`recoverResiduals()`** — permissionless, any state. **Claims** any matured pending
   balance **onto the clone**. It does *not* push to the vault.
3. **`clone.rescueTo(USDG)`** from a **vault batch** — typically a later proposal's
   settlement calls, or an owner emergency batch — pushes the clone's USDG home. A batch can
   carry `[clone.recoverResiduals(), clone.rescueTo(USDG)]` to do 2 and 3 together; the clone
   is a registered strategy, so the vault's batch guard admits it.

**Why the door stays open after settle (a v1 decision, not an inheritance).** On `post-audit`
the post-settle drain fed a vault consumer (`hasUnvaluedResidue`, `collectResidue`). v1 has
neither, and nothing on-chain reads `queuedTicks` once the clone is `Settled`. The reason to
keep it is custody: the Lighter account is venue-authed to this contract, so `queueWithdraw`
is the only way anyone will ever be able to request that margin. Closing it at settle would
make the remainder unrecoverable by construction; keeping it costs nothing, since a post-settle
call only moves value toward the clone.

**Why the push is the vault's alone.** On v1 the only thing that turns USDG in the vault into
share value is the vault's idle balance, and deposits are open whenever no proposal is. A
permissionless push would let anyone choose the block a late tranche lands in NAV — deposit
in front of it and take a slice of principal that belonged to the LPs who carried the loss.
Governor batches only run while a proposal is open, when deposits are shut. **The cost:** the
governor measures P&L as the vault's asset delta across a proposal, so a tranche rescued inside
a *later* proposal's batch is booked as that proposal's profit and pays its performance fee.
Queue the true balance before settling whenever possible.

## Events & errors

**Events:** `Deposited(amount, accountIndex)` (`amount` is what was *deployed* — the
coverage-scaled figure, not the declaration), `AgentKeyRegistered(accountIndex, apiKeyIndex)`,
`OrdersCancelled(accountIndex)`, `MarketClosed(market, isAsk)`,
`WithdrawQueued(ticks, cumulativeTicks)`, `ReturnsInitiated(address indexed caller)`,
`ShortfallAcknowledged(address indexed caller, uint256 queuedTicks, uint256 accounted)`,
`Settled()`, `FundsSwept(amount)` (emitted by the settle push only; the name is kept from
`post-audit` for indexer continuity).

**Errors:** `InvalidPubKey`, `InvalidApiKeyIndex`, `NoMarkets`, `InvalidMarket`,
`DuplicateMarket`, `TooManyMarkets`, `DepositTooSmall`, `DepositTooLarge`,
`AccountNotRegistered`, `InvalidAction`, `NotAuthorized`, `ReturnsNotInitiated`,
`AlreadyInitiated`, `SettleTooSoon`, `ZeroTicks`, `NothingQueued`,
`WithdrawalInFlight(queued, accounted)`, `NoShortfall(queued, accounted)`,
`SettleIncomplete(stillPending)`, `UnsupportedChain`, `AssetMismatch`,
`CounterpartyNotAllowed(counterparty, registry)`, `TierRegistryUnresolved` (plus
`BaseStrategy`'s `NotProposer` / `ProposerNoLongerAgent` / `NotVault` / `NotExecuted` /
`AlreadyExecuted` / `AlreadyInitialized` / `ZeroAddress` / `NotActiveProposalStrategy`).

`AssetMismatch`, `TierRegistryUnresolved` and `CounterpartyNotAllowed` are raised by
`_initialize`; `CounterpartyNotAllowed` also by `_execute`. A registry that answers
`isCounterpartyAllowed` with a word outside `{0, 1}` fails init / execute with **empty**
revert data (`abi.decode`), matching `PortfolioStrategy`; `post-audit` read such a word as a
grant. `NotAuthorized` covers the de-registered-agent case on `queueWithdraw` /
`acknowledgeShortfall` / `registerAgentKey` / `guardrailAction`, since those paths admit the
vault owner too and therefore cannot report `ProposerNoLongerAgent`.

`DepositTooSmall` is raised from **two** places: `initialize` rejects a declaration below
`MIN_DEPOSIT`, and `_execute` rejects a coverage-*scaled* amount below it.

`AccountNotRegistered` is raised by a single shared `_acct()` helper that every
venue-calling path goes through — including `_execute`, which fails the whole deposit
rather than custodying capital in an account this contract cannot address. Account index
`0` is a *different* account, not "no account", so no path may pass it through.

## State reads (frontend data needs)

| Read | Source |
|---|---|
| USDG actually deployed at execute (0 before) — **the figure to size a drain against** | `strategy.deployedAmount()` |
| USDG the proposal DECLARED (the ceiling) | `strategy.depositAmount()` |
| Lighter account index (0 until first deposit) | `strategy.accountIndex()` |
| USDG ticks matured & awaiting claim | `strategy.pendingBalance()` |
| Configured markets | `strategy.markets(i)` |
| Stored agent key / key slot | `strategy.apiKeyPubKey()` / `strategy.apiKeyIndex()` |
| Unwind progress | `strategy.returnsInitiatedAt()` (block; 0 = not initiated), `strategy.settled()` |
| Ticks requested from the venue (cumulative) | `strategy.queuedTicks()` |
| USDG this clone pushed to the vault itself (the settle push; not `rescueTo`) | `strategy.returnedAssets()` |
| Shortfall waived by proposer/owner | `strategy.shortfallAcknowledged()` |
| Margin still at Lighter | **off-chain only** — the Lighter API. `queuedTicks - returnedAssets` is a lower bound on what was asked for and not delivered by the settle push, not a balance |

## Testing

Unit suites: `test/lighter/LighterPerpStrategy.t.sol` (mocks: `test/mocks/MockZkLighter.sol`,
which models the venue's `l2Balance → queued → pending → ERC20` lifecycle) and
`test/lighter/DeployLighterTemplate.t.sol` (the ceremony against the real v1
`StrategyFactory` and `TierRegistry`). Fork testing and the not-yet-ported lifecycle bench:
[`lighter-fork-testing.md`](./lighter-fork-testing.md).

## Canary provenance

The contract-owned-account lifecycle was proven **live on Robinhood mainnet (chain 4663)** by
the `LighterAccountOwner` canary harness (`test/lighter/harness/LighterAccountOwner.sol`),
which ran the full loop — deposit USDG → contract-owned account **623** → register agent key
→ trade → force-close → withdraw USDG back to the contract. The both-side close was proven on
real filled positions in both directions (`test/lighter/harness/LighterH2Canary.md`). None of
that depends on the protocol version.

The **full strategy lifecycle** was proven on the Robinhood-mainnet fork (chain 9994663) on
2026-08-22, against the then-deployed **post-audit** Sherwood stack and the real ZkLighter.
That run exercised the post-audit residue surface (`hasUnvaluedResidue`, `collectResidue` →
`sweep()`) that v1 removed. **The v1 port has not been run end to end against a deployed v1
stack.** See the fork-testing doc for what that run needs.

## What changed from post-audit

| Change | Reason |
|---|---|
| `IStrategyDelivery` (`hasUndeliveredValue` / `undeliveredValue` / `hasUnvaluedResidue`) removed | v1 has no residue machinery; nothing reads them. The unvalued-margin declaration is now off-chain knowledge only. |
| `sweep()` removed | v1 has no `collectResidue` dispatcher. `[recoverResiduals(), rescueTo(USDG)]` in a vault batch replaces it. |
| `_settle` re-reads the venue's pending balance after the claim and reverts `SettleIncomplete` if nonzero | makes the all-or-revert invariant self-enforcing against a short-paying venue |
| `returnedAssets` counts only the settle push | `sweep()` is gone; `rescueTo` cannot be hooked |
| `queueWithdraw` stays open after settle, with a custody reason instead of an accounting one | the account answers only to the clone; no v1 consumer reads `queuedTicks` post-settle |
| venue gate moved onto `PortfolioStrategy`'s helper; a malformed registry word now refuses instead of granting | instruction to match v1's reference template; stricter on garbage |
| deploy ceremony: dropped the `name()` anchor certification, `finalize()`, and `setClassAllowed` | v1 deleted the class-allow axis; clones are admitted via factory registration |
