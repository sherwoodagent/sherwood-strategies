# GenericCallStrategy design

Design notes and normative requirements for `src/generic-call/`, on Sherwood protocol v1 (`v1-deploy` `2a885c53`, pinned in `lib/sherwood-protocol`). This document started as the openspec change `generic-call-strategy` in sherwood-protocol PR #414 (SHE-510; proposal, design and spec, merged as `d5452dc6` on the `post-audit-v2` tree). The decisions carry over as they were. Where the v1-deploy pin or this repo differs, the text says so. The integration guide is [`GenericCallStrategy.md`](GenericCallStrategy.md).

## Why

Since `structural-batch-rules` (SHE-271, protocol PR #315) a proposal batch reaches a third-party protocol only through a strategy registered in `StrategyFactory`: `SyndicateVault._guardBatchCalls` reverts `NotARegisteredStrategy(target)` for every other non-asset target, and `SyndicateGovernor._mirrorBatchLeg` mirrors it at propose. That rule closes NM-0999 6.8 by construction and stays. Its cost is that an agent wanting a venue the shipped templates do not cover (a Seaport order, a DEX router swap, a lending deposit) must write, compile, deploy and register Solidity. For Sherwood Arena, where agents propose on their own, that is a blocker (SHE-510).

`registerStrategy` is already permissionless, so a hand-written forwarder is admitted today. What is missing is a Sherwood-shipped forwarder: one reviewed code shape that guardians can recognise by provenance (`StrategyFactory.cloneTemplate`), read through fixed getters, and that agents use by encoding call lists instead of writing a contract.

The protocol's open change `permissionless-tier2-sandbox` was the prior attempt at the same goal: a vault-minted, per-proposal sandbox clone running proposer-supplied calls, with new vault and governor entry points. It predates SHE-271 and reasons about `isAdapterAllowed`, which the registered-strategy rule replaced. The template route needs no core change because SHE-271 already admits any registered strategy as a batch target: a factory-minted clone of an approved template is registered at clone time, and the clone gives the same isolation the sandbox sought (it holds only what it pulled).

### Why it lives in this repo, and why it breaks README rule 2

This repo holds the templates outside the audited core, and its README asks every template to gate each venue it calls through `TierRegistry.isCounterpartyAllowed` (rule 2). Generic-call is the deliberate exception: having no venue of its own is the whole point, so it has no allowlist to consult. What stands in its place is the loss bound (D3: the clone can only ever lose `pullAmount`), the init-time denylist of protocol contracts (D2), tier 2 forever with full-notional coverage (D11), the guardian review (D10), and the `StrategyFactory` owner's template approval, which is the gate for the template as a whole.

## What lives here

| Path | What |
|---|---|
| `src/generic-call/GenericCallStrategy.sol` | The `BaseStrategy` clone template |
| `script/generic-call/DeployGenericCallTemplate.s.sol` | Deploy and v1 template approval, one broadcast |
| `test/generic-call/` | Unit suite (mocks), governor lifecycle suite (local v1 stack), deploy-script suite, `fork/` rehearsal against live 4663 |
| `test/mocks/GenericCallMocks.sol` | Venues, hostile tokens, NFT market and the protocol stubs the unit suite binds to |

## Context

Batches run under `delegatecall`, so every sub-call reaches its target with `msg.sender == vault`. `structural-batch-rules` made the batch guard four structural rules: a non-asset target must be a registered strategy; an asset call is a metered transfer or an approve-family call whose spender is reset after the batch; the meters run last. Its design (D3) recorded the intent this change serves: anyone can write a strategy, and a proposal may call any contract with any calldata, but only through strategy code. A `vault() == this` callee predicate was rejected there and is not revived here.

This change ships one such forwarder as a Sherwood template. It adds no protocol surface: the vault, governor, factory and registry are unchanged. It adds a recognisable shape (`StrategyFactory.cloneTemplate(clone) == GENERIC_CALL_TEMPLATE`), fixed getters for guardians, and removes the Solidity step for agents.

## Goals / Non-Goals

- Goals: an agent reaches any venue by encoding call lists; the clone's maximum loss is `pullAmount` by construction; everything a guardian votes on is fixed at `initialize` and readable on-chain; the clone fits the existing batch shape `[asset.approve(clone, cap), clone.execute()]` / `[clone.settle()]`.
- Non-Goals: no change to `_guardBatchCalls`, `_mirrorBatchLeg`, `StrategyFactory`, `TierRegistry`, `BaseStrategy` or the governor; no tier 0/1 certification, ever; no native value; no dynamic calldata beyond the settle-leg balance patch (D13); no ERC-1155 custody; no residue interface (`IStrategyDelivery` / `hasUnvaluedResidue` / `collectResidue` exist on neither `post-audit-v2` nor v1-deploy, so a non-asset balance at settle is handled by the sweep list and `rescueTo`, D6/D9). Nothing here runs on chain by itself: the deploy and the approval are this repo's script, run on an owner GO.

## Decisions

### D1: Init data, fixed for the clone's life

`abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls, BalancePatch[] settlePatches, address[] sweepTokens)`, with `Call` the existing `BatchExecutorLib.Call` `(address target, bytes data, uint256 value)`. Reusing the batch struct means the SDK's `BatchCall` type and the CLI's batch encoders/decoders apply unchanged.

- `value` must be zero (`NativeValueUnsupported`). The vault holds USDG, never native; the clone has no `receive`/`fallback`, so a venue cannot refund native to it either.
- `pullAmount` may be zero: `_execute` then skips `_pullFromVault` (some tokens revert a zero `transferFrom`). A zero-pull clone sells tokens the owner moved onto it with `SyndicateVault.rescueERC20`. **v1-deploy difference:** on `post-audit-v2` that call pays only a factory-made clone bound to that vault; on v1-deploy, which 4663 runs, it pays any non-zero recipient (owner-only, refused while a proposal is active). The template does not depend on the restriction, but on 4663 the owner checks the recipient: `StrategyFactory.cloneTemplate(to) == GENERIC_CALL_TEMPLATE` and `to.vault() == vault`.
- Legs may be empty. An empty settle leg still pushes the asset and sweep tokens home.
- `_updateParams` always reverts `NoTunableParams`. Calls, targets, the pull and the sweep list are what guardians approve; a proposer who could edit them after the vote would void the review. No non-call parameter is tunable either: the only candidate, a minimum asset return, is dropped (D6).
- `configHash = keccak256(abi.encode(pullAmount, executeCalls, settleCalls, settlePatches, sweepTokens))` over the decoded values, so a non-canonical encoding of the same config hashes the same. A proposer can cite it in `metadataURI`; a guardian recomputes it from the getters.

Caps, to bound the template's own overhead (storage reads per call, loop length): at most 16 calls per leg, at most 16,384 bytes of calldata summed per leg, at most 16 sweep tokens. These do not bound a venue's own gas (D8).

### D2: Target rules, checked at `initialize`

For every call in both legs:

1. `target` is not zero, not `address(this)`, not the vault, not the governor (`vault.governor()`), not the SyndicateFactory (`vault.factory()`), not the TierRegistry (`governor.tierRegistry()`), not the StrategyFactory (`tierRegistry.strategyFactory()`), not the GuardianRegistry (`governor.guardianRegistry()`), not sWOOD (`guardianRegistry.swood()`). Each hop is a raw length-checked staticcall; a hop that does not resolve reverts `ProtocolAddressUnresolved` (fail-closed: a clone that cannot name the protocol around it refuses to exist, and `execute()` needs the governor anyway). The withdrawal queue (`vault.withdrawalQueue()`), the ExposureLedger (`governor.exposureLedger()`) and the ChallengeGame (`exposureLedger.coverageFreezer()`) are denied when set; each may legitimately be unset, so a zero read denies nothing. The queue, ledger, registry and sWOOD entries follow `permissionless-tier2-sandbox`'s list, which this one extends: a clone holding vault capital must not queue vault shares or stake mid-proposal. The ChallengeGame is added so a clone holding WOOD cannot file a challenge and burn the bond. WOOD itself is NOT denied: refusing it as a direct target would not stop a clone buying WOOD through a venue, only stop it approving or transferring WOOD it holds, stranding the position; the staking risk sits in sWOOD and the registry, which are denied.
2. `target.code.length != 0` (`TargetHasNoCode`): a call to a codeless address succeeds and does nothing, so a typo'd router would "execute" with the capital idle on the clone.
3. On the vault asset, the selector is `approve(address,uint256)` or `transfer(address,uint256)` and nothing else (`AssetCallNotAllowed`).
4. `pinnedCodehash[target] = target.codehash` is recorded (D4).

None of the denied contracts grants the clone a privilege: the clone is not an agent, not the vault and not the governor, and the lifecycle entry points are reentrancy-locked while a batch runs (see Threats). The denylist exists so a guardian never has to reason about the clone touching the lifecycle directly. A venue can still call those contracts with its own identity; that confers nothing a stranger lacks. The list is read once at `initialize`: a later re-pointing of these addresses is an owner action, not an adversary.

Every getter the walk reads exists at the v1-deploy pin, and on 4663 every hop resolves for the live vaults (`test/generic-call/fork/DeployGenericCallTemplateFork.t.sol` resolves them and checks each is refused).

### D3: The asset rule is the load-bearing control

Inside the execute batch the vault's allowance to the clone (`asset.approve(clone, cap)`) is live until `executeGovernorBatch` resets it after the delegatecall. The clone pulls `pullAmount` itself. If the clone could call `asset.transferFrom(vault, x, n)` or any token-specific extension (Paxos `transferFromBatch`, the V1-01 shape), it could spend the rest of that allowance. Rule D2.3 forbids every asset selector except `approve` and `transfer`, both bounded by the clone's own balance. The vault approves only its asset (`AssetCallRules`), so the clone reaches no other vault-held token. Together: the most the clone can lose is `pullAmount`, whatever its calls do.

The per-call cap bounds the vault's net outflow of `execute()`; `pullAmount` is tied to nothing on chain. The meter is a net delta, so a plan with approve 1,000,000, cap 1,000 and pull 1,000,000 that sends 999,000 back inside the execute leg passes, while the clone commands the whole pull for the transaction; the vault's net loss is still cap-bounded. Guardians must require approve amount == `pullAmount` <= cap (D10). An on-chain check against `getCallCaps` was considered and not taken: it would add a governor read to every clone and every governor test stub for a property the review already checks.

### D4: Codehash pinning, and what it covers

Each target's codehash is pinned at `initialize` and re-checked for every call of BOTH legs at the start of `execute()` (`TargetCodeChanged`). A refused execute is recoverable (the proposal expires, the agent re-proposes). `settle()` does not re-check: a code change between execute and settle would otherwise wedge the proposal in `Executed`, and settle is where capital comes home.

Covered: code at a target address changing between review and execute (redeploy at the same address, an EIP-7702 delegation change). Not covered: a proxy whose implementation is swapped (the proxy's own code is unchanged), owner-settable venue parameters, venue state. Same position as `structural-batch-rules` D2: proxy swaps are a review-time judgement, not an on-chain check. Pinning is per target; the clone's own registration pin is per strategy (`StrategyFactory.registeredCodehash`) and covers only the clone.

### D5: Execute

```
_execute():
  require every pinned codehash (both legs)
  if pullAmount != 0: _pullFromVault(asset, pullAmount)
  run execute leg      // call only, never delegatecall
  revoke grants (D7)
```

A failed call reverts `CallFailed(uint8 leg, uint256 index, bytes reason)` carrying the venue's revert data verbatim: the index tells an agent which call broke, the data keeps the venue error decodable. `BaseStrategy.execute` has already set `Executed` and checked the active-proposal binding before `_execute` runs.

### D6: Settle and value accounting

```
_settle():
  run settle leg
  revoke grants (D7)
  _pushAllToVault(asset)               // strict
  for t in sweepTokens: try push(t)    // best-effort, SweepFailed on failure
```

Settlement counts only the vault asset: `_finishSettlement` measures `asset.balanceOf(vault)` against the execute snapshot. Anything the clone returns in another token, and anything left on the clone, is a realised loss in the proposal's P&L. Sweep tokens land in the vault, outside the share price; the owner can move them to a clone of that vault with `rescueERC20` (see D1 on checking the recipient) for a later proposal to sell. ERC-721s returned to the vault are NAV-zero the same way.

No template-level minimum return. `settleProposal` already refuses a settle whose price per share is below the proposer-declared `maxDrawdownBps` floor (`_requireSettlePriceAboveFloorHook`); a second, USDG-denominated floor on the clone would be a duplicate knob guardians must reconcile, with the same wedge-on-miss behaviour. Venue-level bounds (a router's `amountOutMin`) live in the settle calldata.

Sweep tokens must have code and must not be denied contracts (`InvalidSweepToken`). At settle the asset push is strict and each sweep is best-effort: a balance that cannot be read (no code, a revert, a read over `HYGIENE_GAS`) counts as zero and is skipped, and a failed transfer emits `SweepFailed` and leaves the token on the clone for `rescueTo`. A sweep token can never block the asset's return. Sweep transfers get full gas: a legitimate token with transfer hooks should not fail for want of gas.

This is also where the template departs from this repo's README rule 3 (after `settle()` the clone holds nothing): the asset leg is all-or-revert, the sweeps are not, and an undeclared token stays on the clone for `rescueTo`. A strict sweep would let one broken token wedge the return of the asset.

### D7: Approval revocation is best-effort and names two selectors

At `initialize` the template records a grant for every call (either leg) whose selector is `approve(address,uint256)` (`0x095ea7b3`, data ≥ 68 bytes) as `(target, spender)`, and every call whose selector is `setApprovalForAll(address,bool)` (`0xa22cb465`) as `(target, operator)`. After each leg it revokes each grant whose live read says it is open: `allowance(this, spender) != 0` → `approve(spender, 0)`; `isApprovedForAll(this, operator)` → `setApprovalForAll(operator, false)`. A read that does not answer one word (an ERC-721 `approve(to, tokenId)` shares the selector but has no `allowance`) skips the grant; a revoke call that fails is ignored. Each read and each revoke runs under `HYGIENE_GAS` (100,000), so a token that burns gas cannot starve the rest of the settle. Revocation must never wedge settle.

Consequence: an approval the settle leg needs must be granted in the settle leg. Not recognised: Permit2 approvals, `increaseAllowance`, ERC-777 operators, any other grant shape. This is the enumeration pattern the core moved away from, so it is hygiene, not a bound. The bounds are D3 (the clone only ever holds what it pulled) and D6 (settle empties the clone of the asset and every declared token, so a lingering approval has nothing left to pull). The guardian reads the legs.

### D8: Gas

The caps in D1 bound the template's own work. A venue's gas is not bounded by the template. A leg too expensive to execute fails the execute (the proposal expires). A settle leg too expensive to run leaves the proposal `Executed`; the owner's emergency path recovers what the clone holds (D9). The template's own hygiene calls are bounded (D6, D7). The returndata of each call is copied into memory; a venue returning a huge payload costs the caller of the batch gas, and the proposer chose that venue.

### D9: Recovery

- `BaseStrategy.rescueTo(token)` (vault-only, any state) pushes any ERC-20 straggler home, from a later proposal's batch or the owner's `emergencySettleWithCalls`.
- `rescueERC721To(token, tokenId)` (vault-only, any state) does `IERC721(token).transferFrom(address(this), vault, tokenId)`. Plain `transferFrom`: the recipient is always the vault, an `ERC721Holder`, so the receiver callback would add nothing. The vault owner's `rescueERC721` takes it from there.
- `onERC721Received` returns its selector so a venue that delivers with `safeTransferFrom` succeeds. No ERC-1155 hooks: the vault cannot receive an ERC-1155 (no receiver hook and no non-safe transfer), so a 1155 the clone held could never come home; refusing receipt keeps that failure at execute.

Limit: recovery reaches only what the clone holds. The emergency batch can call registered strategies and the asset (`SyndicateVault._guardBatchCalls`), and the clone's vault entries are `execute`, `settle`, `rescueTo` and `rescueERC721To`. A position recorded inside a venue (a lending balance keyed to the clone, an open order, a stake) whose settle leg can never succeed is a realised loss: `settleProposal` and `unstick` replay the same leg. Guardians should prefer venues that issue the clone a token (D10).

### D10: Guardian reviewability

Getters: `name() == "Generic Call"`, `asset()`, `pullAmount()`, `executeCalls() returns (Call[])`, `settleCalls() returns (Call[])`, `settlePatches() returns (BalancePatch[])`, `sweepTokens() returns (address[])`, `grants() returns (Grant[])`, `pinnedCodehash(address)`, `configHash()`, plus `BaseStrategy`'s `vault()`, `proposer()`, `state()`, `executed()`.

What a guardian checks before approving:

1. Provenance: `StrategyFactory.cloneTemplate(clone)` equals `GENERIC_CALL_TEMPLATE` in this repo's `deployments/<chainid>.json`, and `vault()` is the proposal's vault. The protocol's `chains/<chainid>.json` never names the template.
2. The batches, none of it checked on chain (D3): shape `[asset.approve(clone, A), clone.execute()]` and `[clone.settle()]`; approve amount `A == pullAmount`; cap: `pullAmount` at most the cap on `clone.execute()` after any coverage scaling.
3. Every call in both legs: target identity, decoded calldata, where tokens can go. `transfer` of the asset to an arbitrary address, or a venue call paying an arbitrary recipient, is allowed by the template and is exactly what the review must catch. Whether each venue leaves the clone holding a token or only a venue-internal record, which is lost if the settle leg cannot run (D9).
4. Simulation: the execute batch as the governor calling `vault.executeGovernorBatch` (the Arena runner already does this with `eth_simulateV1`), then the settle batch, and the vault's asset delta.

The CLI's guardian walk reads every zero-argument getter whose output holds an address, including tuple fields, so `executeCalls()` / `settleCalls()` expose every inner target once the CLI adds a `TEMPLATE_ABIS` entry for this template (follow-up in `sherwood`).

### D11: Tier and coverage

`tierOf(clone, execute.selector)` is `(2, 10_000)`: the clone is uncertified, so coverage is the full declared cap on `clone.execute()`. The template SHALL never be certified, by address or by class: it is the surface the protocol's adapter-onboarding checklist §2.1 refuses at tier 0/1 (`lib/sherwood-protocol/docs/adapter-onboarding-checklist.md`; an arbitrary-call forwarder whose destinations are fixed by calldata, not code). The deploy script's post-flight and `verify()` require `classTierOf(template, execute/settle) == (2, 10_000)`. The template is outside the protocol's audit scope and offered at the syndicate's own risk, like every template in this repo.

`_scanCalls` refuses a tier-2 call whose cap exceeds `tier2CallCapBps` of TVL (`Tier2CallCapExceedsCeiling`). Arena vaults must keep `tier2CallCapBps` at or above the Arena size cap (8,000 bps) or a generic-call proposal at that size reverts at propose (SHE-407). Nothing here changes that parameter.

### D12: The destination gate does not cover it

The protocol's SHE-209 gate (`script/check-template-destinations.sh` on `post-audit-v2`; absent at the v1-deploy pin) scans the protocol's own `src/strategies/` for token movements whose destination is not the vault or the clone. This repo has no equivalent gate. The template's own movements (`_pullFromVault`, `_pushAllToVault`, `rescueERC721To`) pay the vault or the clone. Its forwarded calls are opaque `call`s no such gate can see, which is why D11 forbids certification: the gate is a backstop for certified templates, and this one is never certified.

### D13: Settle-leg balance patches

`BalancePatch(uint256 callIndex, uint256 wordIndex, address token)`: before settle call `callIndex` runs, the 32 bytes at calldata offset `4 + 32 * wordIndex` are overwritten with `IERC20(token).balanceOf(address(this))`, read at that moment (after the earlier settle calls). This is what lets a settle leg unwind a position whose size is unknown at init: lending shares, LP tokens, a token bought at a market price. Without it the position is stranded and settlement, which counts only the asset, books it as a total loss.

Scope, checked at `initialize` (`InvalidPatch(patchIndex)` otherwise):

- settle leg only (the execute pull is already known); `callIndex` inside the settle leg; at most one patch per call;
- the word lies inside the calldata (`wordIndex < (data.length - 4) / 32`), word-aligned by construction;
- `token` is already in the plan: the asset, a target of either leg (`pinnedCodehash[token] != 0`) or a sweep token. Each of those has passed D2.1 and is in front of the guardian, so a patch adds no new contract to review;
- the word is not an address word of an approve or transfer selector: word 0 of `approve`, `setApprovalForAll` and `transfer`, words 0 and 1 of `transferFrom` and both `safeTransferFrom` overloads. A balance written there would aim the call at whatever address the number spells, and anyone can move a token balance after the vote. Word 0 of an approve is also the grant D7 recorded. Other selectors are not decoded; the guardian checks that each patch hits an amount.

Bound: the written amount is the clone's own balance, so a patch can never move more than the clone holds, and the clone holds only what it pulled plus what its venues returned. A patch does not loosen D3: the asset selector rule is checked on the selector, which a patch never touches. A token whose `balanceOf` reverts reverts the settle; the emergency path recovers what the clone holds (D9). Patches are part of `configHash` and read from `settlePatches()`.

## Threats

| Threat | Closed by |
| --- | --- |
| Reentrancy into the vault or governor during a leg | Direct calls refused (D2.1). Indirect: `executeGovernorBatch`, `_deposit`, `_withdraw`, `requestRedeem`, `requestDeposit`, `settleRedeem` share the vault's `nonReentrant`; `executeProposal`, `settleProposal`, `unstick`, `finalizeEmergencySettle` share the governor's lock. Every leg runs inside one of those. |
| A venue calls back into the clone | `execute`, `settle`, `rescueTo`, `rescueERC721To` are `onlyVault`; `updateParams` always reverts; `initialize` is one-shot; `onERC721Received` is stateless. |
| A venue multicall targeting the clone's `rescueTo`/`settle` | `msg.sender` is the multicall contract, not the vault: `NotVault`. A direct self-call is refused at init (D2.1). |
| The clone spends more than it pulled | D3: no `transferFrom` or extension selector on the asset; no allowance to the clone on any other vault token. |
| Proposer edits the plan after the vote | Nothing is tunable (D1). |
| Proposer times settle against a moved market | Same as every template: the governor's drawdown floor and venue-level bounds in the settle calldata. The proposer can settle early; that is the existing governor rule. |
| Target self-destructs, is redeployed or re-delegated between propose and execute | D4 at execute. Proxy upgrades not covered; stated. |
| Gas griefing with long lists | D1 caps; venue gas unbounded (D8). |
| A token burns gas in the revoke or wedges a sweep | Revoke reads and writes under `HYGIENE_GAS` (D7); sweeps best-effort, asset push strict (D6). |
| A patch aims a call at an address chosen after the vote | Patch token must be in the plan; address words of the approve and transfer selectors refused (D13). |
| A venue-held position whose settle leg can never run | Not closed: a realised loss (D9). Guardians prefer token receipts (D10). |
| Lingering approvals | D7 best-effort revoke; D6 pushes leave nothing to pull. |
| Dust in non-asset tokens | Declared sweep tokens pushed at settle; anything else via `rescueTo`; all of it is a realised loss in the P&L (D6). |
| Native value or `delegatecall` tricks | `value == 0` enforced; `call` only; no `receive`/`fallback`. |
| A look-alike contract posing as this template | Provenance check (D10.1); a hand-registered contract has no `cloneTemplate` entry. |

## Risks / Trade-offs

- The template does not bound where funds go. A leg may `transfer` the pulled asset to any address. That is the definition of the template; tier-2 full-notional coverage and the guardian vote are the controls, as for any hand-written strategy.
- Calldata is fixed at init except for settle-leg balance patches (D13). An execute-leg amount, or a settle amount that is not a balance the clone holds, stays fixed.
- Revocation recognises two selectors only (D7).
- Storing call data costs proposer gas at clone time (about 20k gas per 32 bytes); the 16 KB per-leg cap bounds it.

## Deployment

The template requires NO venue address at deploy time: its call lists, pull amount and sweep tokens arrive per clone through `_initialize(bytes)`, and it binds no counterparty, so it needs no `TierRegistry` seeding. It reaches the allowlist only through the `StrategyFactory` owner's `setTemplateApproval(template, true)`.

`script/generic-call/DeployGenericCallTemplate.s.sol` does both in one broadcast: plain `new GenericCallStrategy()`, then the approval if the broadcaster owns `StrategyFactory`, else `RUNBOOK` lines and `ownerStepsComplete == false`. On a real broadcast it records `GENERIC_CALL_TEMPLATE` and `_meta.genericCall` in `deployments/<chainid>.json`; `--sig 'verify()'` re-checks the entry. On 4663 it is an owner GO item, and `STRATEGY_FACTORY` and `TIER_REGISTRY` must be exported because the pinned protocol book names neither. Steps and commands: [`GenericCallStrategy.md`](GenericCallStrategy.md#deployment).

**Changed from PR #414.** The protocol PR minted the template through the protocol's `DeployAll` ceremony and, for 4663, a standalone `DeployGenericCallTemplate` script, both through the protocol's Create3Factory under a `GENERIC_CALL_TEMPLATE` salt, and booked the address in the protocol's `chains/4663.json`. None of that moved. The deploy here is plain CREATE, so the address that PR predicted is void, and the book is this repo's.

## Requirements

Normative, from the PR's `specs/generic-call-strategy/spec.md`. The scenarios are covered by `test/generic-call/GenericCallStrategy.t.sol` (mocks) and `test/generic-call/GenericCallStrategy_lifecycle.t.sol` (local v1 stack).

### The generic-call plan is fixed at initialize

`GenericCallStrategy._initialize` SHALL decode `abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls, BalancePatch[] settlePatches, address[] sweepTokens)`, where `Call` is `BatchExecutorLib.Call (address target, bytes data, uint256 value)` and `BalancePatch` is `(uint256 callIndex, uint256 wordIndex, address token)`, and store it for the clone's life. `_updateParams` SHALL always revert `NoTunableParams()`. The clone SHALL expose `configHash()` equal to `keccak256(abi.encode(pullAmount, executeCalls, settleCalls, settlePatches, sweepTokens))` over the decoded values.

ADVERSARY: a proposer who could change targets, calldata, the pull, the patches or the sweep list after the guardian vote would execute a plan nobody reviewed.

`_initialize` SHALL revert `TooManyCalls(leg)` when a leg holds more than 16 calls, `CalldataTooLarge(leg)` when a leg's summed calldata exceeds 16,384 bytes, `TooManySweepTokens()` above 16 sweep tokens, and `InvalidSweepToken(index)` for a sweep token that has no code or is a denied contract (the target denylist, including zero). Empty legs and `pullAmount == 0` SHALL be accepted.

- **Proposer tries to retune after execute.** GIVEN an executed clone, WHEN its proposer calls `updateParams` with any data, THEN the call reverts `NoTunableParams()` and every getter returns what it returned before.
- **Oversized leg refused.** WHEN a clone is initialized with 17 execute calls, or with settle calldata summing to more than 16,384 bytes, THEN initialization reverts `TooManyCalls(leg)` or `CalldataTooLarge(leg)` and no clone state is written.
- **Unusable sweep token refused.** WHEN a sweep token is zero, has no code, or is the vault, THEN initialization reverts `InvalidSweepToken(index)`.
- **Config hash is canonical.** WHEN a guardian re-encodes the values the getters return and hashes them, THEN the result equals `configHash()`.

### Every call target is checked at initialize

For every call in both legs `_initialize` SHALL revert:

- `NativeValueUnsupported(leg, index)` when `value != 0`;
- `ForbiddenTarget(leg, index, target)` when `target` is zero, the clone, the vault, the vault's governor, the vault's SyndicateFactory (`vault.factory()`), the governor's TierRegistry, that registry's StrategyFactory, the governor's GuardianRegistry, that registry's sWOOD, or (when set) the vault's withdrawal queue, the governor's ExposureLedger or that ledger's ChallengeGame (`coverageFreezer()`);
- `TargetHasNoCode(leg, index, target)` when `target` has no code;
- `AssetCallNotAllowed(leg, index, selector)` when `target` is the vault asset and the selector is not `approve(address,uint256)` or `transfer(address,uint256)`, or the calldata is shorter than 68 bytes.

The protocol addresses SHALL be resolved through raw length-checked staticcalls (`vault.governor()`, `vault.factory()`, `governor.tierRegistry()`, `tierRegistry.strategyFactory()`, `governor.guardianRegistry()`, `guardianRegistry.swood()`), and any of those hops that does not answer a clean address SHALL revert `ProtocolAddressUnresolved()`. `vault.withdrawalQueue()`, `governor.exposureLedger()` and `exposureLedger.coverageFreezer()` MAY be unset; a zero read denies nothing extra. WOOD SHALL NOT be denied: denying it would only strand WOOD a clone bought through a venue. The clone SHALL make every forwarded call with `call`, never `delegatecall`, and SHALL have no `receive` or `fallback`.

ADVERSARY (asset rule): inside the execute batch the vault's allowance to the clone is live until the batch ends. A clone allowed `transferFrom(vault, …)` or a token extension such as `transferFromBatch` on the asset could spend that allowance beyond `pullAmount`. With only `approve` and `transfer`, both bounded by the clone's own balance, the most the clone can lose is `pullAmount`.

ADVERSARY (denylist): the clone touching the lifecycle contracts directly, queueing vault shares through the withdrawal queue, staking through sWOOD or the GuardianRegistry with vault capital mid-proposal, or filing a ChallengeGame challenge with WOOD it holds and burning the bond. None grants the clone a privilege today, but the list keeps a guardian from having to prove it per proposal.

- **Vault allowance cannot be widened.** WHEN a clone is initialized with an execute call `asset.transferFrom(vault, attacker, n)`, THEN initialization reverts `AssetCallNotAllowed(0, index, transferFrom.selector)`.
- **Lifecycle contract as a target.** WHEN a call in either leg targets the vault, the governor, the SyndicateFactory, the TierRegistry, the StrategyFactory, the GuardianRegistry, sWOOD, the withdrawal queue, the ExposureLedger, the ChallengeGame, the clone itself or the zero address, THEN initialization reverts `ForbiddenTarget(leg, index, target)`.
- **Native value refused.** WHEN a call carries `value = 1`, THEN initialization reverts `NativeValueUnsupported(leg, index)`.
- **Codeless target refused.** WHEN a call targets an address with no code, THEN initialization reverts `TargetHasNoCode(leg, index, target)`.

### Target code is pinned at initialize and re-checked at execute only

`_initialize` SHALL record `pinnedCodehash(target) = target.codehash` for every target. `_execute` SHALL, before pulling any capital, revert `TargetCodeChanged(target)` when any target of either leg no longer has its pinned codehash. `_settle` SHALL NOT re-check codehashes.

ADVERSARY: a target whose code changes between the guardian review and execution (a redeploy at the same address, a changed EIP-7702 delegation) runs code nobody reviewed. A refused execute is recoverable; a refused settle would wedge the proposal in `Executed`, so settle does not check. A proxy whose implementation is swapped keeps its codehash and is NOT covered; that is a review-time judgement.

- **Target code changed before execute.** GIVEN a clone whose settle-leg target's code was replaced after initialize, WHEN the proposal's execute batch calls `execute()`, THEN the call reverts `TargetCodeChanged(target)` and no asset leaves the vault.
- **Target code changed between execute and settle.** GIVEN an executed clone whose settle-leg target's code was then replaced, WHEN the settle batch calls `settle()`, THEN no codehash check runs and the settle leg executes against the current code.

### Execute pulls, runs the execute leg and revokes grants

`_execute` SHALL, after the codehash check, pull `pullAmount` of the vault asset with `_pullFromVault` (skipped when zero), run the execute leg in order, and then revoke grants. A call that fails SHALL revert `CallFailed(leg, index, reason)` with the callee's revert data as `reason`.

- **Happy path through a real vault and governor.** WHEN a proposal with execute batch `[asset.approve(clone, pullAmount), clone.execute()]` executes, THEN the clone holds the venue position, the vault's asset dropped by `pullAmount`, and no allowance granted in the execute leg is still open.
- **Failed inner call bubbles.** WHEN an execute-leg call reverts with error data `E`, THEN `execute()` reverts `CallFailed(0, index, E)` and the whole batch reverts.

### Settle runs the settle leg, revokes grants and returns custody

`_settle` SHALL run the settle leg in order (a failing call reverts `CallFailed(1, index, reason)`), revoke grants, push the clone's whole asset balance to the vault (a failure reverts), and then try to push the clone's whole balance of each declared sweep token to the vault. A sweep SHALL be best-effort: a balance read that fails or does not return one word counts as zero and is skipped, and a transfer that fails SHALL emit `SweepFailed(token)` and leave the token on the clone. The template SHALL NOT impose its own minimum-return floor: the governor's `maxDrawdownBps` floor in `settleProposal` is the price check.

Settlement P&L counts only the vault asset. Sweep tokens and ERC-721s returned to the vault, and anything left on the clone, SHALL be documented as a realised loss for that proposal.

ADVERSARY (sweeps): a sweep token that reverts, burns gas or loses its code after the vote. A strict sweep would wedge the asset's return behind it.

- **Settle returns the asset and sweep tokens.** GIVEN an executed clone holding asset `A` and sweep token `T`, WHEN the settle batch `[clone.settle()]` runs, THEN the vault receives all of `A` and all of `T`, the clone holds neither, and the clone's state is `Settled`.
- **A broken sweep token does not block the asset.** GIVEN an executed clone whose sweep token's `transfer` reverts, and another sweep token whose code is gone, WHEN the settle batch runs, THEN the vault receives the asset, `SweepFailed(token)` is emitted for the reverting token, the codeless one is skipped, and the clone is `Settled`.
- **Empty settle leg.** WHEN a clone with no settle calls is settled, THEN it pushes its asset balance and sweep balances to the vault and settles.

### Settle calls may take the clone's live balance as an argument

A `BalancePatch(callIndex, wordIndex, token)` SHALL make `_settle`, immediately before settle call `callIndex` runs, overwrite the 32-byte word at calldata offset `4 + 32 * wordIndex` with `IERC20(token).balanceOf(address(this))` read at that moment. Patches SHALL apply to the settle leg only. `_initialize` SHALL revert `InvalidPatch(patchIndex)` when `callIndex` is outside the settle leg, when a second patch names the same call, when the word does not lie wholly inside that call's calldata, when `token` is not already in the plan (the vault asset, a target of either leg, or a sweep token), or when the patch targets an address word: word 0 of `approve(address,uint256)`, `setApprovalForAll(address,bool)` or `transfer(address,uint256)`, or word 0 or 1 of `transferFrom(address,address,uint256)`, `safeTransferFrom(address,address,uint256)` or `safeTransferFrom(address,address,uint256,bytes)`. `settlePatches()` SHALL return the stored patches.

ADVERSARY: a settle leg sized at init cannot unwind a position whose size is only known after execute (shares, LP tokens, a market-price buy). The position is stranded and settlement, which counts only the vault asset, books it as a total loss. The patched amount is the clone's own balance, so it can never move more than the clone holds. A balance written into an address word aims the call at whatever address the number spells, and anyone can move a token balance after the vote; word 0 of an approve is also the spender the revocation step recorded. Restricting the token to the plan means a patch adds no contract the guardian has not already reviewed.

- **Market-price buy is sold whole at settle.** GIVEN an execute leg that buys a token at a price unknown at init, and a settle sell call patched with that token's balance, WHEN the settle batch runs, THEN the sell call receives the clone's whole balance of the token and the clone holds none of it afterwards.
- **Patch outside the calldata refused.** WHEN a patch names a word past the end of its call's calldata, a call index outside the settle leg, or a second patch on the same call, THEN initialization reverts `InvalidPatch(patchIndex)`.
- **Address words cannot be patched.** WHEN a patch names word 0 of a settle-leg `approve`, `setApprovalForAll` or `transfer`, or word 0 or 1 of a `transferFrom` or `safeTransferFrom`, THEN initialization reverts `InvalidPatch(patchIndex)`.
- **Patch token outside the plan refused.** WHEN a patch names a token that is not the asset, a leg target or a sweep token, THEN initialization reverts `InvalidPatch(patchIndex)`.

### Approval revocation is best-effort over two named selectors

`_initialize` SHALL record a grant for every call in either leg whose selector is `approve(address,uint256)` with at least 68 bytes of calldata, as `(target, spender)`, and for every call whose selector is `setApprovalForAll(address,bool)` with at least 68 bytes, as `(target, operator)`. After each leg the clone SHALL revoke each recorded grant that a live read reports open: `allowance(this, spender) != 0` leads to `approve(spender, 0)`, and `isApprovedForAll(this, operator) == true` leads to `setApprovalForAll(operator, false)`. A read that does not return exactly one word SHALL skip the grant, and a failed revoke call SHALL emit `RevokeFailed(token, spender)` and be ignored. Each read and each revoke call SHALL be made with at most 100,000 gas. `grants()` SHALL return the recorded list.

ADVERSARY: a venue keeping an approval over tokens the clone holds between execute and settle. Revocation is hygiene, not the bound: the clone only holds what it pulled, and settle pushes the asset and every declared token home. Other grant shapes (Permit2, `increaseAllowance`, ERC-777 operators) are NOT revoked and are left to the guardian review.

- **Execute-leg approval revoked before settle.** WHEN the execute leg calls `asset.approve(venue, x)` and the venue pulls less than `x`, THEN after `execute()` returns, `asset.allowance(clone, venue) == 0`.
- **Operator approval revoked.** WHEN a leg calls `nft.setApprovalForAll(market, true)`, THEN after that leg `nft.isApprovedForAll(clone, market)` is false.
- **A gas-burning token cannot starve the settle.** WHEN a granted token burns all gas it is given on the `allowance` read or on the revoke, THEN that read or revoke fails after 100,000 gas and the settle completes.
- **Selector collision does not wedge.** WHEN a leg calls an ERC-721's `approve(to, tokenId)`, which shares the ERC-20 selector, THEN the revoke step's `allowance` read fails, the grant is skipped and the leg completes.

### Recovery hooks reach every asset the clone can hold

The clone SHALL keep `BaseStrategy.rescueTo(token)` for ERC-20s and SHALL add `rescueERC721To(address token, uint256 tokenId)`, `onlyVault`, callable in any state, which moves the token with `transferFrom(address(this), vault, tokenId)`. The clone SHALL implement `onERC721Received` returning its selector and SHALL NOT implement ERC-1155 receiver hooks.

ADVERSARY: an execute that lands an NFT, followed by a settle leg that can no longer sell it. Without a vault-only NFT exit the NFT is stranded on the clone forever, because the emergency path can only call registered strategies and the asset. An ERC-1155 the clone held could never reach the vault (no receiver hook there, no non-safe transfer), so refusing receipt keeps that failure at execute.

These hooks reach only what the clone holds. The documentation SHALL state that a position recorded inside a venue whose settle leg can never succeed is a realised loss, and SHALL tell guardians to prefer venues that issue the clone a token.

- **NFT rescued by an emergency batch.** GIVEN an executed clone holding an ERC-721 whose settle leg reverts, WHEN the owner's emergency batch calls `clone.rescueERC721To(nft, id)`, THEN the vault owns the NFT.
- **A venue-held position is lost when the settle leg cannot run.** GIVEN an executed clone that holds part of its pull and deposited the rest into a venue that now refuses every withdrawal, WHEN `settleProposal` and `unstick` run, and then the owner's emergency batch calls `clone.rescueTo(asset)`, THEN both replays revert `CallFailed(1, 0, reason)`, the emergency batch returns only the part the clone held, the venue still holds the rest, and the proposal ends `Settled`.
- **Only the vault rescues.** WHEN any address other than the vault calls `rescueERC721To`, THEN the call reverts `NotVault()`.

### The template is tier 2 and never certified

The generic-call template and its clones SHALL NOT be certified at tier 0 or 1, by address or by class: it is an arbitrary-call forwarder whose destinations are set by calldata, the surface the protocol's adapter-onboarding checklist §2.1 refuses. Its calls SHALL therefore price at `(2, 10_000)` and need full-notional coverage. Its documentation SHALL state that it is outside the audit scope and offered at the syndicate's own risk, and SHALL list what a guardian checks: provenance (`StrategyFactory.cloneTemplate(clone)` equals `GENERIC_CALL_TEMPLATE` in this repo's deployments book), the two batch shapes, that the approve amount equals `pullAmount` and `pullAmount` is at most the cap on `clone.execute()` (nothing on chain ties them), every inner call, and a simulation of both batches.

- **A clone prices at full notional.** WHEN a proposal's execute batch calls a generic-call clone's `execute()` with cap `c`, THEN `tierOf(clone, execute.selector)` is `(2, 10_000)` and the call contributes `c` to required coverage.

## Not ported from PR #414

- The protocol deploy ceremony: the `DeployGenericCallStrategy` phase in `DeployAll`, the `GENERIC_CALL_TEMPLATE` CREATE3 salt in `DeploySalts`, the `Stack` field in `DeployTypes`, the key in `DeployStrategyFactory._templateKeys()` and the deploy tests that pin that set, and the `deployment-docs` spec delta describing them. This repo deploys with its own script (above).
- The protocol's `verify-blockscout.py`, `verify-robinhood.sh` and `check-template-destinations.sh` edits, the deployment-runbook steps and the audit-scope entry. Verification here is `--sig 'verify()'` plus Sourcify; the audit-scope position is stated at the top of `GenericCallStrategy.md`.
- `tasks.md`, the PR's implementation checklist.
