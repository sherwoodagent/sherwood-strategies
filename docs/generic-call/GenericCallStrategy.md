# Generic-call strategy template

`src/generic-call/GenericCallStrategy.sol` lets an agent run a list of calls against any protocol (a Seaport order, a DEX router swap, a lending deposit) without writing Solidity. The agent encodes two call lists; a clone of the template runs them as the proposal's strategy.

Source: `src/generic-call/GenericCallStrategy.sol`, extending the protocol's `BaseStrategy` (`lib/sherwood-protocol/src/strategies/BaseStrategy.sol`, imported as `@sherwood/strategies/BaseStrategy.sol`) and reusing its `BatchExecutorLib.Call` struct. The protocol is pinned to **v1-deploy `a91fae2f`**, the tree 4663 runs. File references are relative to this repo's root. Protocol-wide docs: https://docs.sherwood.sh/

> **Ported from sherwood-protocol PR #414** (merge `d5452dc6`, written against the `post-audit-v2` tree). The template, its unit suite and its lifecycle suite moved unchanged apart from import paths: `BaseStrategy` and `BatchExecutorLib` are byte-identical between that tree and the pin, and every getter the denylist reads exists at the pin. What changed is around it: the deploy is this repo's script with plain CREATE instead of the protocol's CREATE3 ceremony, and the address lives in this repo's `deployments/<chainid>.json`. The fixes from the [readiness review](audit-2026-11-06-generic-call-readiness.md) were made here after the port: scaled balance patches (one per word), capped one-word hygiene reads, and `SweepFailed` on an unreadable sweep balance. `SyndicateVault.rescueERC20` only pays a factory-made clone bound to that vault, on 4663 as on `post-audit-v2`. Section 1 of the review records what 4663 runs and how the earlier pin differed from it.

> **Unaudited, at the syndicate's own risk.** The template is outside the protocol's audit scope, like every template in this repo. It is tier 2 for good: it must never be certified at tier 0 or 1, by address or by class ([adapter-onboarding checklist §2.1](../../lib/sherwood-protocol/docs/adapter-onboarding-checklist.md)). The template does not limit where funds go. The guardian review does.

Design and normative requirements: [`design.md`](design.md).

## What it does

The clone holds a fixed plan, set once at `initialize`:

| Field | Meaning |
| --- | --- |
| `pullAmount` | Vault asset (USDG) pulled at execute. Zero pulls nothing. |
| `executeCalls` | Calls run, in order, after the pull. |
| `settleCalls` | Calls run, in order, at settle, before custody returns to the vault. |
| `settlePatches` | Optional: settle-call arguments filled with the clone's live token balance at settle time. |
| `sweepTokens` | ERC-20s pushed to the vault at settle, in addition to the asset, best-effort. |

`execute()`:

1. Re-checks each target's code against the codehash pinned at init, for both legs.
2. Pulls `pullAmount`.
3. Runs the execute leg.
4. Revokes the grants.

`settle()`:

1. Runs the settle leg.
2. Revokes the grants.
3. Pushes the clone's whole USDG balance to the vault, then each sweep token. A sweep that fails emits `SweepFailed` and leaves that token on the clone; it never blocks the USDG.

If any leg call fails, the step reverts `CallFailed(leg, index, reason)`, where `leg` is 0 for execute and 1 for settle, and `reason` is the venue's own revert data.

Nothing can be changed after `initialize`: `updateParams` always reverts `NoTunableParams`.

## What an agent supplies

Clone through `StrategyFactory.cloneAndInit(template, vault, proposer, data)` (or the deterministic variant), with:

```solidity
data = abi.encode(
    uint256 pullAmount,
    BatchExecutorLib.Call[] executeCalls,   // (address target, bytes data, uint256 value)
    BatchExecutorLib.Call[] settleCalls,
    GenericCallStrategy.BalancePatch[] settlePatches,
        // (uint256 callIndex, uint256 wordIndex, address token, uint256 mulNum, uint256 mulDen)
    address[] sweepTokens
);
```

> **The init ABI changed with the scaled patch.** `BalancePatch` gained `mulNum` and `mulDen`, so each `settlePatches` element is five words. An encoder written against the three-field struct (the `generic-call` encoder in `@sherwoodagent/sdk` 0.15.0 and CLI 0.103.0, and the Arena mirror) must be updated before anyone proposes. Its output is not always refused: with a non-empty `sweepTokens` it decodes, the next two words are read as `mulNum` and `mulDen` (the sweep count and the first sweep token's address), and the patched word becomes zero.

`template` is `GENERIC_CALL_TEMPLATE` from this repo's `deployments/<chainid>.json`. `Call` is the same struct as a proposal batch call, so the SDK's `BatchCall` type encodes it.

Then propose with the standard batches:

| Leg | Calls | Caps |
| --- | --- | --- |
| Execute | `[USDG.approve(clone, pullAmount), clone.execute()]` | `[0, pullAmount]` |
| Settle | `[clone.settle()]` | `[0]` |

Nothing on chain ties these numbers together. The cap on `clone.execute()` meters the vault's net outflow during that call, and `pullAmount` appears nowhere in the governor or vault. A plan that pulls more than its cap and sends the excess back inside the execute leg passes the meter, while the clone holds the whole pull for the length of the transaction. Keep the approve amount equal to `pullAmount`, and `pullAmount` at most the cap.

### Rules checked at `initialize`

| Rule | Error |
| --- | --- |
| `value` must be 0. The vault holds no native token and the clone has no `receive`. | `NativeValueUnsupported` |
| A target may not be zero, the clone, the vault, the governor, the SyndicateFactory, the TierRegistry, the StrategyFactory, the GuardianRegistry or sWOOD. It also may not be the withdrawal queue, the ExposureLedger or the ChallengeGame, when those are set. WOOD itself is allowed, so a clone can sell WOOD it bought. | `ForbiddenTarget` |
| A target must have code. | `TargetHasNoCode` |
| On the vault asset, only `approve(address,uint256)` and `transfer(address,uint256)` are allowed. | `AssetCallNotAllowed` |
| At most 16 calls per leg. | `TooManyCalls` |
| At most 16,384 bytes of calldata per leg. | `CalldataTooLarge` |
| At most 16 sweep tokens. | `TooManySweepTokens` |
| Each sweep token has code and is not a denied contract. | `InvalidSweepToken` |
| At most 32 settle patches. | `TooManyPatches` |
| Each settle patch names a settle call, and no word is patched twice (two patches on one call must target different words). The patched word lies inside that call's calldata. The token is already in the plan: the asset, a target of either leg, or a sweep token. The patched word is not an address: not word 0 of `approve`, `setApprovalForAll` or `transfer`, and not words 0 or 1 of `transferFrom` or either `safeTransferFrom`. The scale is both zero (identity) or both non-zero. | `InvalidPatch` |

The protocol contracts are resolved from the vault at `initialize` (`vault.governor()`, `vault.factory()`, `governor.tierRegistry()`, `tierRegistry.strategyFactory()`, `governor.guardianRegistry()`, `guardianRegistry.swood()`, then `vault.withdrawalQueue()`, `governor.exposureLedger()` and `exposureLedger.coverageFreezer()`). The first six must resolve or the clone refuses to exist (`ProtocolAddressUnresolved`). On 4663 every hop resolves for the live vaults; `test/generic-call/fork/DeployGenericCallTemplateFork.t.sol` checks it.

The asset rule is what bounds the loss. During the execute batch the vault's allowance to the clone stays live until the batch ends. Without the rule, a `transferFrom(vault, …)` could spend more than the pull. With it, the clone can only ever lose `pullAmount`.

### Writing legs that work

- **Calldata is fixed when you clone, except for balance patches.** To exit a position whose size you cannot know in advance (lending shares, LP tokens, a token bought at a market price), add a `BalancePatch`.
  - **What it does:** just before settle call `callIndex` runs, argument word `wordIndex` (byte offset `4 + 32 * wordIndex`) is overwritten with the clone's `token` balance at that moment. It counts what the earlier settle calls returned. With a scale (`mulNum`, `mulDen` both non-zero) the word is `balance * mulNum / mulDen`, rounded down; `(0, 0)` writes the balance itself.
  - **Example:** to sell everything bought at execute through `adapter.swap(tokenIn, tokenOut, amountIn, amountOutMin, extraData)`, patch word 2 with `(tokenIn, 0, 0)` and word 3 with `(tokenIn, mulNum, mulDen)`. `test/generic-call/fork/GenericCallUniswapFork.t.sol` does this through the live `UniswapSwapAdapter`.
  - **Which word to patch:** any 32-byte word after the selector can be patched, at most once, and at most 32 words in all. For a value inside a dynamic struct or array, count its position in the ABI encoding: in `f((address,address,uint256,uint256,bytes))` word 0 is the tuple's offset, so the third field is word 3.
  - **Which token:** one the plan already names. A receipt token the settle leg never calls (an aToken that `withdraw` burns) must be listed in `sweepTokens` to be patchable, which also sweeps any leftover.
  - **The limit:** an identity patch writes what the clone holds, never more. A scaled patch can write any number, but the clone still moves only what it holds.
  - **Without a patch:** use a venue's "max" sentinel (for example, withdraw `type(uint256).max`), or make execute exact-output so the settle amounts are known.
- **A patched sell carries a scaled minimum.** A sell whose amount is patched cannot have a sensible fixed `amountOutMin`: set low, the sell can be sandwiched at a block a third party chooses (anyone can settle once `strategyDuration` has passed), and the governor's drawdown floor bounds that only to the declared drawdown of the whole vault; set at the propose-time quote, it reverts once the market moves. Patch the minimum with a scale instead: `mulNum / mulDen` is the floor price in output units per unit of the token sold, taken from a quote at propose time less a bounded slippage (for example `mulNum = quotedOut * (10_000 - slippageBps)`, `mulDen = quotedIn * 10_000`, both in raw units). Never leave a patched sell's minimum at zero. Keep `strategyDuration` short enough for that quote to hold: a floor the market has moved through reverts the sell, `settleProposal` and `unstick` replay the same leg, and the owner's emergency path returns the token to the vault in kind, which settlement books as a loss.
- **Approvals are revoked after each leg.** If the settle leg needs a venue approval, grant it in the settle leg.
- **Prefer venues that give the clone a token.** Anything the clone holds can be recovered by the owner's emergency batch. A position recorded only inside a venue (a lending balance keyed to the clone, an open order, a stake) comes home only through the settle leg. If that leg can never run, the position is lost.
- **Settlement counts only USDG.** Anything returned in another token, and anything left on the clone, is a realised loss in the proposal's P&L. Sell back to USDG in the settle leg. List any token you expect to be left over in `sweepTokens`.
- **Selling swept tokens later.** The vault owner can move a swept token onto a generic-call clone of the same vault with `SyndicateVault.rescueERC20` (owner-only, refused while a proposal is active), where a later proposal sells it with `pullAmount = 0`. `rescueERC20` only pays a factory-made clone bound to that vault, on 4663 as on `post-audit-v2`; any other recipient reverts `RescueRecipientNotStrategy`.
- **The only template-wide price floor is the envelope's.** `settleProposal` refuses a settle below the `maxDrawdownBps` floor. Put venue-level minimums, such as a router's `amountOutMin`, in the calldata, scaled by a patch when the amount is patched (above).
- **ERC-721s:** a venue may deliver one with `safeTransferFrom`. An NFT the settle leg cannot sell can be pulled to the vault through `rescueERC721To` in an emergency batch. The NFT is then outside the share price. The clone refuses ERC-1155s, because the vault cannot receive them.

## How a guardian reads it

Before you vote:

1. **Provenance.** `StrategyFactory.cloneTemplate(clone)` must equal `GENERIC_CALL_TEMPLATE` in this repo's `deployments/<chainid>.json` (not the protocol's `chains/<chainid>.json`, which never names it), and `clone.vault()` must be the proposal's vault. A hand-registered look-alike has no `cloneTemplate` entry.
2. **Batches.** None of these is checked on chain:
   - shape: the execute batch is exactly `[USDG.approve(clone, A), clone.execute()]` and the settle batch `[clone.settle()]`;
   - approve amount: `A == pullAmount()`;
   - cap: `pullAmount()` is at most the cap on `clone.execute()`. The cap meters net outflow, so a larger pull that is sent back inside the execute leg would pass the meter.
3. **The plan.** Read these getters:
   - `executeCalls()`, `settleCalls()`, `settlePatches()`, `sweepTokens()`, `pullAmount()`;
   - `grants()`: the approvals the template will revoke;
   - `pinnedCodehash(target)`;
   - `configHash()`, which is `keccak256(abi.encode(pullAmount, executeCalls, settleCalls, settlePatches, sweepTokens))` and can be compared against the proposal's metadata.

   For each patch, decode which argument it overwrites. It should be an amount, not an address or a deadline. The template refuses the address words of the approve and transfer selectors only.

   For a scaled patch, `mulNum / mulDen` is the implied floor price in output units per unit of `token`. Convert it with both decimals and compare it with the market price at review and with the slippage the proposer declared. A floor far below market is an allowance for a sandwich; one above market is a settle that will revert. A patched sell whose minimum is unpatched and fixed at zero has no floor at all.

   For each venue, ask whether the clone ends up holding a token or only a record inside the venue. A venue-held position is lost if its settle leg can never run (see Risks).

   Decode every inner call and ask where funds can go. Both of these pass every template check and are what the review exists to catch:
   - `USDG.transfer(anyone, …)`;
   - a router call that pays an arbitrary address.
4. **Simulate.** Run the execute batch as the governor calling `vault.executeGovernorBatch`, then the settle batch, and read the vault's USDG delta. The simulation is same-block, so it shows no market move between the two legs.

## Tier and coverage

- **Tier.** `tierOf(clone, execute.selector)` is `(2, 10_000)`, so the proposal needs coverage equal to the full cap on `clone.execute()`. The deploy script's post-flight and `verify()` require `classTierOf(template, execute/settle) == (2, 10_000)`.
- **Per-call ceiling.** A tier-2 call's cap must also fit under `tier2CallCapBps` of the vault's TVL. Arena vaults need `tier2CallCapBps` of at least 8,000 bps, or a proposal at the Arena size cap reverts `Tier2CallCapExceedsCeiling` at propose (SHE-407).

## Risks

- **No destination limit.** The template does not restrict where funds go. Tier-2 coverage and the guardian vote are the controls.
- **Proxy upgrades are not caught.** A codehash change at a target is caught at execute only. A proxy keeps its codehash when its implementation is swapped, so that swap is not detected. The same holds for an EIP-7702-delegated EOA: the pinned hash is of its 23-byte delegation designator, so a changed delegation is caught, but a delegate that is itself a proxy, or is redeployed, is not. Settle never checks code, so a change can never wedge the return of capital.
- **A balance patch overwrites one argument word with the clone's balance of one token, or that balance scaled.** The clone still moves at most what it holds. A patch can be aimed at the wrong argument, and a scale can name a floor far from the market; guardians check both.
- **Approval revocation is best-effort.** It covers ERC-20 `approve` and `setApprovalForAll` only, and each revoke read and write gets 100,000 gas:
  - Permit2, `increaseAllowance` and ERC-777 operators are not revoked;
  - an ERC-721 `approve(to, id)` shares the ERC-20 selector and is skipped.

  The real bound is that the clone only holds what it pulled, and settle empties it.
- **Sweeps are best-effort.** A sweep token whose balance cannot be read, or whose transfer fails, emits `SweepFailed` and stays on the clone, where `rescueTo` can try again. Sweep transfers run with full gas, unlike the capped revokes, so a sweep token that burns gas on `transfer` can push the settle out of gas; such a token could wedge the settle leg directly too, and sweep tokens are in the reviewed plan.
- **A venue-held position can be lost.** If the settle leg can never succeed (the venue is paused, closed or broken), `settleProposal` and `unstick` replay the same leg and fail. The owner's emergency batch can reach only registered strategies and the asset, and the clone's only vault entries are `execute`, `settle`, `rescueTo` and `rescueERC721To`. The emergency path recovers what the clone holds. A position recorded inside the venue is a realised loss. On 4663 `finalizeEmergencySettle` runs the owner's batch with zero net egress, so a position that needs a repay or a margin top-up cannot be freed with vault float: an outside donor must fund the clone first (for example by transferring the asset to it before the batch, which `rescueTo(asset)` then returns). The settle batch itself must call `clone.settle()`: `settleProposal` and `unstick` revert `StrategyNotSettled` while the strategy still answers `executed() == true`.
- **Venue gas is not bounded.** A settle leg too expensive to run leaves the proposal `Executed`. The owner's emergency path then recovers what the clone holds, with `rescueTo` / `rescueERC721To`.
- **Timing is not only the proposer's.** `executeProposal` is permissionless inside the execution window, and `settleProposal` is permissionless once `strategyDuration` has passed (the proposer may also settle early). Calldata is fixed, so a router deadline or any other time-bound argument in the execute leg must cover the vote, the review and the execution window, and one in the settle leg must cover `strategyDuration` plus however long a settle takes to be sent. A stale deadline at execute is recoverable: the proposal expires. At settle it wedges the leg, as a stale floor does.

## Deployment

`script/generic-call/DeployGenericCallTemplate.s.sol:DeployGenericCallTemplate` is the whole v1 ceremony, one broadcast. The template needs no venue address and no `TierRegistry` seeding: its call lists, pull amount and sweep tokens arrive per clone through `initialize`, and it binds no counterparty.

1. **Deploy.** Plain `new GenericCallStrategy()` from the broadcaster. The protocol PR minted it through the protocol's Create3Factory under a `GENERIC_CALL_TEMPLATE` salt; that path did not move, so the address it predicted is void. The address is whatever this broadcast lands on.
2. **Approve.** `StrategyFactory.setTemplateApproval(template, true)`, performed in-run when the broadcaster owns `StrategyFactory`. Otherwise the script prints the call and its calldata as `RUNBOOK` lines, records `_meta.genericCall.ownerStepsComplete == false`, and the owner sends it afterwards. Confirm `StrategyFactory.owner()` on chain before sending.
3. **Post-flight.** The script asserts the template fits Robinhood's 98,304-byte MaxCodeSize and that `execute()` and `settle()` price at `(2, 10_000)`.
4. **Book.** On a real broadcast only, the script writes `GENERIC_CALL_TEMPLATE` and `_meta.genericCall` into `deployments/<chainid>.json`. Commit that file with the `broadcast/` log, as `deployments/README.md` describes. Nothing is pre-booked: the key appears only once a broadcast has put code at it.
5. **Verify.** `--sig 'verify()'` re-reads `GENERIC_CALL_TEMPLATE` and checks it against the chain: code, the template rather than a clone, `name()`, the registry/factory wiring, the approval as a fact, and the uncertified pricing. Verify the source on Sourcify, as for the other templates in the book.

`STRATEGY_FACTORY` and `TIER_REGISTRY` come from the env, else from the pinned protocol book. Since the `a91fae2f` pin, `chains/4663.json` names both; an exported value still wins over the book (values in `deployments/README.md`):

```bash
STRATEGY_FACTORY=0xb06788F027268a9A06c3AD41a88559530D2E54b1 \
TIER_REGISTRY=0x4614f058920941A0a9a852e62485fbDE692D75E1 \
forge script script/generic-call/DeployGenericCallTemplate.s.sol:DeployGenericCallTemplate \
  --rpc-url robinhood --account sherwood-deployer --broadcast

STRATEGY_FACTORY=0xb06788F027268a9A06c3AD41a88559530D2E54b1 \
TIER_REGISTRY=0x4614f058920941A0a9a852e62485fbDE692D75E1 \
forge script script/generic-call/DeployGenericCallTemplate.s.sol:DeployGenericCallTemplate \
  --rpc-url robinhood --sig 'verify()'
```

Every step that broadcasts on 4663 is an owner GO item.

## Tests

| Suite | What it covers |
| --- | --- |
| `test/generic-call/GenericCallStrategy.t.sol` | Init rules, execute and settle flows, patches (identity, scaled, inside a dynamic argument), revocation, sweeps, recovery hooks, against mocks (`test/mocks/GenericCallMocks.sol`) |
| `test/generic-call/GenericCallStrategy_lifecycle.t.sol` | A real v1 vault, governor, guardian registry and sWOOD compiled from the pin: propose, vote, review, execute and settle with the runner's batch shape; a pull above the cap returned inside the leg passing the meter; an approve below the pull expiring the proposal; a reentering venue; NFT recovery and venue-held loss through the emergency path |
| `test/generic-call/DeployGenericCallTemplate.t.sol` | The deploy ceremony and `verifyDeployment` against the real v1 `StrategyFactory` and `TierRegistry` |
| `test/generic-call/fork/DeployGenericCallTemplateFork.t.sol` | The ceremony, the owner approval and `verify` against the live 4663 singletons; a clone bound to a live vault through the live factory, priced at tier 2, refusing every live protocol contract as a target |
| `test/generic-call/fork/GenericCallUniswapFork.t.sol` | A clone bound to live vault 1 buying WETH through the live `UniswapSwapAdapter` and selling it at settle with a balance patch and a scaled minimum: the round trip, and the floor refusing a moved pool. Execute and settle run as the vault with the governor binding mocked |

The lifecycle suite runs on a local stack rather than a 4663 fork because a fork lifecycle would have to clear the live factory's owner-only-proposal and restricted-deposit flags, the ExposureLedger coverage quorum (guardian stake priced through the live WOOD feed) and the proposer bond at an unpinned block, none of which is about the template. It uses three protocol test helpers copied from the pin, with a header naming their source: `test/helpers/GovEnvelope.sol`, `test/helpers/TierRegistryFixture.sol` and `test/mocks/MockAgentRegistry.sol`.
