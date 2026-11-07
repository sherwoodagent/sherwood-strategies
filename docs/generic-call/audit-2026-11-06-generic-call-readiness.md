# Generic-call template (PR #21): light review and merge-readiness patch set

Date: 2026-11-06. Scope: `src/generic-call/GenericCallStrategy.sol`,
`script/generic-call/DeployGenericCallTemplate.s.sol`, `docs/generic-call/*.md`, the four generic-call test suites, the
three copied protocol test helpers, the CI change, at sherwood-strategies PR #21 head `c0d3468`
(branch `carlos/generic-call-template`), against the protocol pin `lib/sherwood-protocol @ 2a885c53` and
`sherwood-protocol v1-deploy @ a91fae2f` (HEAD at review time). Line numbers cite the PR head.

Method: Trail of Bits skills `entry-point-analyzer` (Slither printer plus manual classification),
`audit-context-building` (line-by-line read of the template, `BaseStrategy`, `BatchExecutorLib`, `AssetCallRules`,
`StrategyFactory.cloneAndInit`, `SyndicateVault.executeGovernorBatch` / `_guardBatchCalls` / `rescueERC20`,
`SyndicateGovernor.executeProposal` / `settleProposal` / `_scanCalls` / `_finishSettlement`, `GovernorEmergency`),
`sharp-edges` on the init ABI, `fp-check` gates on every candidate, Slither 0.11.3 detectors, live `cast` reads on
Robinhood Chain 4663, and a Sourcify pull of the live vault implementation. Semgrep did not run (the `p/smart-contracts`
registry was unreachable from this machine), so no semgrep result is claimed. This is a readiness review, not an
audit; nothing downstream may call the template "audited".

This document is the input for the follow-up commits on PR #21. Section 4 is the work list. Section 5 is the
decisions Carlos has to make.

Headline: no critical, high or medium finding in the template. The port is faithful (the contract, the mocks and the
unit suite are byte-identical to sherwood-protocol `d5452dc6` apart from import paths and one natspec pointer; the
three copied helpers differ only in import paths and a provenance header). Two things need fixing before merge, both
about what 4663 actually runs rather than about the Solidity: the docs and PR body state the live `rescueERC20`
behaviour backwards (F-2), and the pin is behind the live deployment in ways the lifecycle suite does not see (F-3).
One Low design limitation stands (F-1). The rest is hardening and disclosure.

---

## 1. Live 4663 facts (block 107,678,235)

Recorded once so the implementing session does not re-derive them. Protocol singletons, RPC and the beta flags
are unchanged from `docs/launchpad/audit-2026-10-19-mainnet-readiness.md` section 1.

| Fact | Value | How read |
| --- | --- | --- |
| `StrategyFactory` | `0xb06788F027268a9A06c3AD41a88559530D2E54b1`, owner `0x5A00afAecE9CF61A768E2AE2713084C8d354DF94` | `owner()` |
| `TierRegistry` | `0x4614f058920941A0a9a852e62485fbDE692D75E1` | `strategyFactory()` round-trips |
| `SyndicateFactory` | `0x619af1488F32B4797f6faDa3C3a8De72a5B693E0`; `depositsRestricted() == true`, `ownerOnlyProposals() == true` | `cast call` |
| Deployer of every booked template | `0x5A00…DF94`, which is also the `StrategyFactory` owner | `deployments/4663.json` `_meta.*.deployer`, `ownerStepsComplete: true` |
| Booked here | `LAUNCHPAD_TEMPLATE`, `SUSHI_LAUNCH_ADAPTER`, `LIGHTER_PERP_TEMPLATE`; no `GENERIC_CALL_TEMPLATE` | `deployments/4663.json` |
| Active vaults | 1 `0x7396CccbeC83fC06854Fcd307773da756b374ABc` (guard-mainnet-test, TVL 188.93 USDG, governor `0x6b52…71C5`, `tier2CallCapBps` 10,000); 2 `0x76A0d2A473DA41D9cCcfafa0D57D882e86Ed840e` (yield-generator, 36.39 USDG, governor `0x01FA…35aD`, 10,000); 3 `0x227F96F91Ad2078D445BFE690f60b445389846bC` (myxe, 1 wei, governor `0x964d…C0E3`, 7,500) | `SyndicateFactory.getActiveSyndicates(0,3)`, `governor()`, `tier2CallCapBps()`, `totalAssets()` |
| Live vault implementation | `0xdab4707c9997a84e931fe98f4688adafc70b6b95` (ERC-1967 slot of vault 1). Its Sourcify-verified `src/SyndicateVault.sol` (Sourcify reports `match`: source verified, metadata hash not exact) is byte-identical to `sherwood-protocol` `origin/v1-deploy` (`a91fae2f`) and differs from the pin by 88 diff lines | `cast implementation`, Sourcify v2 `?fields=sources`, `diff` |
| Live governor implementation | `0x58813BBC3bEf6A576C9d6A8893e67Bf84C20ce97` behind beacon `0x3cf45efe9fbddd6cb749384bf5c1ba5ec96af05d`. Not verified on Sourcify. Assumed to be at `a91fae2f` with the vault; see decision 4 | ERC-1967 beacon slot, `implementation()` |
| `rescueERC20` on live vaults 1 and 2 | `rescueERC20(sWOOD, 0xdead, 0)` simulated from each vault's owner reverts `RescueRecipientNotStrategy(0xdead)` (`0xbf3c2d4c…dead`) | `cast call --from <owner>` |
| Block gas limit | `2^50` (Arbitrum-style; per-transaction limits apply, not a block cap) | `cast block latest --field gasLimit` |

Protocol drift between the pin and what 4663 runs, checked with `git diff 2a885c53 origin/v1-deploy` in
sherwood-protocol. The PR compared the pin against `post-audit-v2` `d5452dc6` instead; the files below are what the
template actually meets on 4663:

- `BaseStrategy.sol`, `BatchExecutorLib.sol`, `StrategyFactory.sol`: zero lines. The template compiles and clones the same.
- `SyndicateVault.rescueERC20` (`:1134-1147` at HEAD) pays only a factory-made clone bound to that vault
  (`cloneTemplate(to) != 0 && to.vault() == this`), else `RescueRecipientNotStrategy`. The pin pays any non-zero
  recipient. Live is the restricted version (table above).
- `AssetCallRules.spenderOf` reverts `UnrecognizedAssetSelector` for any asset selector outside `transfer`,
  `transferFrom`, `approve` and the increase/decrease-allowance family. The batch shape
  `[asset.approve(clone, A), clone.execute()]` still passes.
- `SyndicateGovernor.settleProposal` and `GovernorEmergency.unstick` revert `StrategyNotSettled(strategy)` while
  the strategy still answers `executed() == true`. `BaseStrategy.settle` flips `_state` before `_settle`, so a
  settle batch that calls `clone.settle()` passes; a settle batch that does not (for example `[clone.rescueTo(asset)]`
  alone) now reverts at the governor.
- `GovernorEmergency.finalizeEmergencySettle` runs the owner's batch with `maxNetOutflow = 0` (the pin passed
  `effectiveMaxCapital`). An emergency unwind can no longer fund a venue repay from vault float.
- `SyndicateGovernor.propose` gates on `_requireLaunchProposer`: with `ownerOnlyProposals` on (live), only the vault
  owner proposes and co-proposers are refused. `strategyDuration` is also capped by the protocol-wide maximum.
- `TierRegistry` adds a Morpho market allowlist (`setMorphoMarketAllowed` / `isMorphoMarketAllowed`). Irrelevant to
  the template; it is why the copied `test/helpers/TierRegistryFixture.sol` no longer compiles at HEAD (F-3).

Baseline on the PR head: `forge test --no-match-contract Fork` 391 passed; fork suite 4 passed against live 4663;
deploy dry run simulates. Details in section 6.

---

## 2. Attack surface

State-changing entry points, from `slither --print entry-points` plus manual classification.

| Entry point | Who | Notes |
| --- | --- | --- |
| `initialize(vault, proposer, data)` | first caller; `StrategyFactory.cloneAndInit` does it atomically and pins `proposer == msg.sender` | `_initialize` (`:138-161`) fails closed on any unresolved hop of the seven mandatory protocol addresses (`:258-274`) |
| `execute()` | `onlyVault`, and the vault's governor's active proposal must name this clone (`BaseStrategy.execute`) | re-checks every pinned codehash of both legs before the pull (`:276-282`) |
| `settle()` | `onlyVault`; deliberately not bound to the active proposal (`BaseStrategy.settle` natspec) | no codehash check; strict asset push, best-effort sweeps (`:286-295`) |
| `rescueTo(token)`, `rescueERC721To(token, id)` | `onlyVault`, any state | reach only what the clone holds |
| `updateParams(bytes)` | `onlyProposer` | always reverts `NoTunableParams` (`:297-299`) |
| `onERC721Received` | anyone | `pure`, returns the selector |

Actors: the vault (through governor batches), the proposer (in the beta: the vault owner, by `ownerOnlyProposals` and
HEAD's `_requireLaunchProposer`), guardians (review and the tier-2 full-notional coverage), anyone (`executeProposal`
within the execution window and `settleProposal` after `strategyDuration` are permissionless), the venues named in
the two legs (arbitrary code, reviewed per proposal), and the vault owner (emergency path).

Value paths: vault asset leaves only through `_pullFromVault(asset, pullAmount)` inside `execute`, bounded by the
batch's per-call gross-outflow cap on `clone.execute()` and by the asset selector rule (`:186-204`: on the asset only
`approve` and `transfer`, so the live vault allowance cannot be spent by `transferFrom` or a token extension). What
the clone holds leaves wherever the reviewed calls send it; that is the template's definition. The clone has no
privilege anywhere: at the pin and at v1-deploy HEAD, `isRegisteredStrategy` is read only by the vault's batch guard and
the governor's propose and mirror checks, never against `msg.sender`, so a denylist omission
(another vault, another clone, the template itself, WOOD) confers nothing a stranger lacks.

---

## 3. Findings

Each item went through the fp-check gates: restated claim, data-flow trace, preconditions, devil's advocate.
Severity is rated for the mainnet configuration in section 1 (owner-only proposals, restricted deposits, three
small vaults).

### F-1. A patched settle sell cannot carry a proportional minimum out. Low. True positive by construction, reachable the moment a proposal is settleable.

- Where: `_applyPatch` (`:319-328`) writes exactly one word, the clone's live balance, into one settle call. Every
  other word of the settle leg is fixed at `initialize` (`:138-161`, design D1). `settleProposal`
  (`SyndicateGovernor.sol:513-531` at the pin) is callable by anyone once `executedAt + strategyDuration` has passed,
  and by the proposer after `MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE` (1 hour, `:134`). The only price check is
  `_requireSettlePriceAboveFloorHook` (`:533-553`): price per share after the batch must stay above
  `ppsAtExecute * (1 - maxDrawdownBps)`, with `maxDrawdownBps` capped at `MAX_STAMP_DRAWDOWN_BPS = 9_000` (`:80`).
- Trace: a plan that buys token T at execute and sells the patched balance at settle has to fix the sell's
  `amountOutMin` at propose time. Set low, the sell is sandwichable at a block a third party chooses; the governor
  floor bounds the extraction to the declared drawdown of the whole vault, measured against PPS at execute (so a
  strategy in profit can lose the profit plus the allowance). Set at the propose-time quote, the sell reverts once
  the market moves, `settleProposal` and `unstick` replay the same leg (`CallFailed(1, i, …)`), and the owner's
  emergency path returns T to the vault in kind, which `_finishSettlement` books as a loss (design D6, D9). This is
  the generic-call shape of Launchpad G-4 (`docs/launchpad/audit-2026-10-19-mainnet-readiness.md` F-1): a static
  floor on a leg whose timing is not the proposer's.
- Calibration: with `ownerOnlyProposals` on, the proposer is not the adversary; the outside sandwich is. Three vaults
  hold under 230 USDG in total, so the beta exposure is nil. It becomes the main economic risk of the template once
  non-owner agents propose through Arena.
- Fix options, decision in section 5:
  - Option A, no code. `GenericCallStrategy.md` "Writing legs that work" gets a rule: a patched sell must carry a
    non-zero `amountOutMin` derived from a quote at propose time less a bounded slippage, and `strategyDuration`
    must be short enough for that quote to hold. The CLI encoder (sherwood, follow-up already listed in the PR)
    enforces it the way SHE-415 did for Launchpad (quote less `--max-slippage-bps`).
  - Option B, code. Give a patch a scale. Either extend `BalancePatch` with `uint256 mulNum, mulDen` (`0, 0` meaning
    identity) so a second patch on the same call writes `balance * mulNum / mulDen` into the min-out word, or add a
    separate `ScaledPatch[]` so the `BalancePatch` ABI stays as the SDK already encodes it. Lift the one-patch-per-call
    rule in `_storePatch` (`:207-218`) to one-patch-per-word. The guardian reads the implied floor price
    (`mulNum / mulDen` in output units per input unit). About 40 lines of Solidity, the `InvalidPatch` cases, two unit
    tests (a scaled min-out that holds, and one that reverts when the pool moves), design D13 and the integration
    guide. The CLI and SDK encoders change with it.
  - Option C, rejected: a tightening-only `updateParams` for designated min-out words. It contradicts D1 and has the
    same gap SHE-414 found for Launchpad option A: `settleProposal` is permissionless after `strategyDuration`, so a
    third party can settle against the stale floor before the proposer tightens it.

### F-2. The docs and PR body state the live `rescueERC20` behaviour backwards. Low, merge blocker (documentation). True positive, verified live.

- Where: `docs/generic-call/GenericCallStrategy.md:7` and `:97`, `docs/generic-call/design.md:44` and `:98`, PR #21
  body decision 1. All say that v1-deploy, "which 4663 runs", pays any non-zero recipient, and that the owner must
  check the recipient's provenance by hand.
- Evidence: the live vault implementation's Sourcify-verified `SyndicateVault.sol` (a `match`, not an
  `exact_match`) equals v1-deploy `a91fae2f` line for line, and `rescueERC20` there (`:1134-1147`) requires `cloneTemplate(to) != 0` and `to.vault() == this`.
  Simulating `rescueERC20(sWOOD, 0xdead, 0)` from the owner of vault 1 and of vault 2 reverts
  `RescueRecipientNotStrategy(0xdead)`. The 2026-10-19 Launchpad review already recorded the restriction on
  v1-deploy `1d38a287` (its F-5). The PR read the pin (`2a885c53`, which is unrestricted) as "v1-deploy".
- Consequence: no capital risk; live is the safer behaviour, and a generic-call clone minted by `cloneAndInit` passes
  both checks, so the "sell swept tokens later" flow in the guide works as the ported text originally described.
  The error is in the operator guidance and in the PR's stated reason for leaving the pin alone.
- Fix: restore the ported wording in both docs ("`rescueERC20` only pays a factory-made clone bound to that vault,
  on 4663 as on `post-audit-v2`"), delete the "the owner checks the recipient" sentences, and correct decision 1 in
  the PR body. Keep one sentence saying the pin is older than live and listing the drift in section 1 above.

### F-3. The pin is behind the live deployment; the lifecycle suite does not see the live governor. Low. True positive; fixed by a one-file bump.

- Where: `lib/sherwood-protocol @ 2a885c53`; `test/generic-call/GenericCallStrategy_lifecycle.t.sol` compiles the
  governor, vault, registry and sWOOD from the pin.
- What the pin lacks (section 1): the `StrategyNotSettled` guard on `settleProposal` and `unstick`, the zero-egress
  emergency finalize, `UnrecognizedAssetSelector`, the restricted `rescueERC20`, the owner-only propose gate.
- Verified: with the submodule at `a91fae2f` and only `test/helpers/TierRegistryFixture.sol` re-copied from HEAD (it
  gains `setMorphoMarketAllowed` / `isMorphoMarketAllowed` stubs so `PermissiveTierRegistry` is concrete again),
  `forge test --no-match-contract Fork` passes 391/391 on the PR head and `forge build --sizes --skip test` reports
  the template at the same 10,309 bytes. Independently, the template, mocks, unit suite and lifecycle suite dropped
  into a sherwood-protocol worktree at `a91fae2f` pass 48/48. `BaseStrategy`, `BatchExecutorLib` and
  `StrategyFactory` are zero-diff, so the compiled template is unchanged.
- Fix: bump the submodule to `a91fae2f`, re-copy `TierRegistryFixture.sol` (keep the provenance header, update the
  commit it names), update the "pinned to v1-deploy `2a885c53`" lines in both generic-call docs and the README, and
  re-run the Launchpad and Lighter suites (they pass in the experiment above). The Launchpad review's optional
  "pin bump" decision becomes this item.

### F-4. Return-data amplification in the hygiene reads. Informational, cheap to close.

- Where: `_readWord` (`:348-355`) does `target.staticcall{gas: HYGIENE_GAS}(data)` and lets Solidity copy the whole
  return buffer into memory before checking `ret.length != 32`; the revoke at `:342` is the same shape.
- Trace: the 100,000-gas cap bounds what the callee does, but a callee can spend its budget expanding memory to
  return a large buffer (on the order of 200 KB), and the clone then pays comparable memory expansion to copy it.
  Up to 32 grants and 16 sweep reads per settle, so a few million gas of griefing at most. It does not wedge settle
  on 4663 and every such token is in the reviewed plan. Slither's `return-bomb` detector flags exactly these two
  sites.
- Fix: read with assembly, `staticcall(gas, target, add(data, 32), mload(data), 0, 0)`, require
  `returndatasize() == 32`, then `returndatacopy` one word; do the revoke call with out-size zero and ignore
  returndata. About ten lines, and the two Slither results go away on their own.

### F-5. A sweep whose balance read fails is skipped silently. Informational.

- Where: `_settle` (`:290-294`) emits `SweepFailed` only when the transfer fails; `_readWord` returns zero both for a
  zero balance and for a reverted, codeless or over-budget read, so a receipt token with a `balanceOf` above
  100,000 gas stays on the clone with no event.
- Fix: have `_readWord` return `(bool ok, uint256 word)` (or add a `_tryReadBalance`) and emit `SweepFailed(t)` on
  `!ok`; update the spec sentence in design.md ("counts as zero and is skipped") to say the event fires. Two lines
  plus the assertion in `test_settle_unreadableSweepTokenIsSkipped`.

### F-6. Sweep transfers run with full gas. Informational, accept.

- Where: `:293`, `trySafeTransfer` is uncapped by design (D6: "a legitimate token with transfer hooks should not fail
  for want of gas"). A sweep token that burns gas on `transfer` can push the settle transaction out of gas where the
  revoke path (capped) cannot. The same token could wedge the settle leg directly, and sweep tokens are in the
  reviewed plan, so this adds no surface a guardian is not already looking at. Keep as is; one sentence in Risks.

### F-7. Timing is not only the proposer's. Informational, docs.

- `GenericCallStrategy.md:143` ("The proposer controls settle timing. The proposer may settle early") understates
  it: `executeProposal` is permissionless inside the execution window and `settleProposal` is permissionless after
  `strategyDuration`. Calldata is fixed, so router deadlines and any time-bound argument in the execute leg must
  cover vote plus review plus the execution window, and in the settle leg `strategyDuration` plus however long a
  settle takes to be sent. A stale deadline at execute is recoverable (the proposal expires); at settle it is the
  F-1 wedge. Add both sentences to Risks.

### F-8. Codehash pinning and EIP-7702. Informational, docs.

- Design D4 says a changed 7702 delegation is covered. It is: the pinned hash is of the 23-byte delegation
  designator. What is not covered is a delegated EOA whose delegate is itself a proxy or is redeployed, the same
  class as the proxy caveat. One clause in D4 and in the guide's Risks.

### F-9. Emergency path at HEAD. Informational, docs.

- With `finalizeEmergencySettle` at zero net egress on live, a venue-held position that needs a repay (a borrow,
  a margin top-up) cannot be freed with vault float; an outside donor must fund the clone first (for example by
  transferring the asset to the clone before the batch, which `rescueTo(asset)` then returns). D9 and the guide's
  "A venue-held position can be lost" bullet should say so, and should add that a settle batch must call
  `clone.settle()` (`StrategyNotSettled` otherwise).

### F-10. Slither triage. All false positives; disable with a reason.

`slither . --config-file slither.config.json` on the PR head: 11 results under `src/generic-call/` (results outside
that directory were not re-counted; the Launchpad triage from October covers them).

- `calls-loop` (8): `_runLeg`, `_applyPatch`, `_revokeGrants`, `_readWord` reached from `execute` and `settle`. The
  loops are the template's purpose and are bounded by `MAX_CALLS_PER_LEG`, `MAX_SWEEP_TOKENS` (16 each) and the
  grants those calls record. Disable inline.
- `return-bomb` (2): the F-4 sites. Closed by F-4, or disabled with the bound stated there.
- `uninitialized-local` (1): `size` in `_storeLeg` (`:172`) is a zero-initialised accumulator. Disable inline.

The entry-points printer output is section 2. Semgrep was not run (registry unreachable); if the implementing session
has access, `semgrep --config p/smart-contracts src/generic-call/` is the one command to add to the appendix.

### F-11. Test coverage. Informational.

What the suites prove is solid: init rules, the asset selector rule by fuzz, loss bounded by the pull by fuzz, codehash
pinning, revocation under gas burners and selector collisions, sweeps, patches on address words, NFT recovery and
the venue-held-loss path through the real emergency flow, the deploy ceremony and the denylist against live 4663.
Gaps, none blocking:

1. Lifecycle: no case pins design D3's statement that a plan with `approve == pull > cap` that sends the excess back
   inside the execute leg passes the per-call meter while the clone commands the whole pull, and no case shows
   `approve < pullAmount` reverting in `_pullFromVault` (`ERC20InsufficientAllowance`, proposal expires). Both are
   ten-line additions to `GenericCallStrategy_lifecycle.t.sol` and would make the guardian rule in D10.2 testable.
2. No test exercises a real venue. A fork test that binds a clone to live vault 1, `deal`s it USDG, and drives
   `execute` / `settle` with `vm.prank(vault)` through the live `UniswapSwapAdapter`
   (`0x54e6a7af53143556973493fdec9d7837a77c67ef`, counterparty-granted, not denied) with a balance patch on the
   return swap would test the template against real bytecode and a real patch. It also gives F-1 a concrete number.
3. No patch test targets a word inside a dynamic argument (the guide tells agents to count ABI offsets by hand).
4. After the F-3 bump the lifecycle suite runs on the live-shaped governor; until then nothing checks
   `StrategyNotSettled` or the zero-egress emergency against this template. Both pass in the experiment in F-3.

### Deploy script and CI. Verified, accept.

- `DeployGenericCallTemplate.run()` dry run against live 4663 with `STRATEGY_FACTORY` and `TIER_REGISTRY` exported
  and forge's default sender: simulation succeeded, 2,996,930 gas estimated at 0.0413 gwei, about 0.000124 ETH,
  template runtime 10,309 bytes, `classTierOf(execute/settle) == (2, 10000)`, runbook lines printed because the
  default sender does not own the factory. `deployments/4663.json` was untouched by the dry run and by the fork
  suite. With `--account sherwood-deployer` resolving to `0x5A00…DF94`, which owns the factory, the approval lands
  in the same broadcast and `_meta.genericCall.ownerStepsComplete` is `true`; `--sig 'verify()'` then passes
  without a Safe step.
- CI decision 5: `forge build --sizes` on the PR head fails on `SyndicateGovernor` (35,832 bytes) and `SyndicateVault`
  (25,634), both compiled only by the lifecycle suite and both under Robinhood's 98,304. `forge build --sizes
  --skip test` passes and still reports every contract under `src/` and `script/` plus the non-`.t.sol` files under
  `test/` (`--skip test` filters `*.t.sol`, not the directory). The gate still covers every deployable. Accept.

Rejected candidates, kept so they are not re-opened: spending the vault's live allowance beyond `pullAmount` (the
asset selector rule blocks `transferFrom` and extensions on the asset; a venue cannot spend the vault's allowance
because it is granted to the clone, and `executeGovernorBatch` resets every batch-named spender); reaching the
asset through its implementation address (separate storage, no allowance); reentrancy into the vault or governor
from either leg (direct targets denied, every lifecycle entry `nonReentrant`, the lifecycle test records 18 refused
attempts); a venue calling back into the clone (`onlyVault` everywhere, `updateParams` always reverts); a clone of
vault V used in a proposal on vault W (`NotVault`); a clone whose `proposer()` is not the proposer (the governor does
not check it and the template never reads it); look-alike clones (`cloneTemplate == 0`); denylist omissions (other
vaults, other clones, the template, WOOD, the swap adapter: no privilege attaches to the clone's identity);
`settle()` unbound to the active proposal (inherited, load-bearing for recovery, argued in `BaseStrategy`); proxy
upgrades at a target (disclosed in D4); a patch aimed at an offset or length word of a dynamic argument (corrupts
only the clone's own call, loss still bounded by what the clone holds); ERC-721 `approve(to, id)` recorded as a
grant (the `allowance` read fails and the grant is skipped); native value and ERC-1155 receipts (refused at init /
no hook); `configHash` non-canonical encodings (hashed over decoded values); coverage scaling pushing the effective
cap below `pullAmount` (execute reverts `CallCapExceeded`, recoverable, and D10.2 already says "after any coverage
scaling"); the transient use of the whole pull inside one transaction (the vault's net loss is still cap-bounded;
third parties, not LPs, bear a same-block manipulation).

---

## 4. Work list for PR #21

Tier 0 blocks the merge. Tier 1 is cheap and recommended in the same PR. Tier 2 is accepted and disclosed.

### Tier 0

1. **F-2 docs correction.** `docs/generic-call/GenericCallStrategy.md:7` and `:97`, `docs/generic-call/design.md:44`
   and `:98`, PR body decision 1. Restore the clone-only `rescueERC20` wording, drop the manual recipient check, keep
   one sentence on the pin-versus-live drift pointing at section 1 of this document.
2. **F-3 pin bump.** `lib/sherwood-protocol` to `a91fae2f`; re-copy `test/helpers/TierRegistryFixture.sol` from
   HEAD with its header updated; update every "`2a885c53`" in `README.md`, `docs/generic-call/*.md` and the three
   helper headers. Acceptance: `forge fmt --check`, `forge build --sizes --skip test`, `forge test --no-match-contract
   Fork` (391), `ROBINHOOD_RPC_URL=… forge test --match-contract Fork` (50) all green on the bumped pin.
3. **Docs drift lines (F-7, F-8, F-9).** Risks in the guide and D4 / D9 in design.md: permissionless execute and
   settle timing with the calldata-deadline consequence; 7702 delegate caveat; zero-egress emergency finalize and
   the `clone.settle()` requirement of `StrategyNotSettled`.

### Tier 1

4. **F-1 per the decision in section 5.** Option A is a docs paragraph here plus a CLI rule in sherwood. Option B is
   the scaled patch with its two unit tests, the D13 text, and the encoder change.
5. **F-4 and F-5 hardening.** Assembly reads with a fixed 32-byte out buffer; `SweepFailed` on an unreadable
   balance. Acceptance: `test_settle_unreadableSweepTokenIsSkipped` asserts the event; `slither . --config-file
   slither.config.json` reports no `return-bomb`.
6. **F-10 Slither disables** with one-line reasons on `_runLeg`, `_applyPatch`, `_revokeGrants`, `_readWord` and
   `size`. Acceptance: the config run reports nothing under `src/generic-call/`.
7. **F-11 items 1 and 2.** The two lifecycle cases and the live-venue fork test. Item 3 if cheap.

### Tier 2, accept and disclose

8. F-6 sweep gas (one sentence in Risks). F-11 item 4 is closed by the bump.

### Owner steps after the broadcast

One broadcast from `0x5A00…DF94` with `STRATEGY_FACTORY` and `TIER_REGISTRY` exported: deploy and
`setTemplateApproval(template, true)` in the same run. Then commit `deployments/4663.json` with the `broadcast/` log,
run `--sig 'verify()'`, and verify the source on Sourcify. If the broadcast is sent from a key that does not own the
factory, the script prints the `setTemplateApproval` calldata and `verify()` fails until the owner sends it.
Every step that broadcasts on 4663 is an owner GO item; the follow-ups in the PR body (CLI address override, Arena
docs, SHE-522 checklist) stand.

---

## 5. Decisions for Carlos

1. **Bump the pin to v1-deploy `a91fae2f` in this PR?** Recommend yes. One fixture file changes, every suite passes,
   the template bytes do not move, and the lifecycle suite then runs on the governor 4663 actually has. The
   alternative is to keep the pin and accept that `StrategyNotSettled` and the zero-egress emergency are untested here.
2. **F-1: option A or B?** For the owner-only beta on three sub-250-USDG vaults, A is enough. B is the fix that lets
   the template stay approved once Arena agents propose, and it is cheapest now, before the SDK encoder for
   `BalancePatch` is written against the current ABI. If B, land it with the sherwood encoder change in the same
   release.
3. **Take F-4 and F-5 now?** Recommend yes; both are small and remove the only Slither results with substance.
4. **Sourcify-verify the live governor implementation `0x5881…ce97` before the GO?** Recommend yes. The vault
   implementation is verified and matches HEAD; the governor is assumed to. A verified governor source lets this and
   future reviews diff live code instead of inferring it.
5. **Accept CI decision 5?** Yes. Verified that the literal gate fails only on the two over-EIP-170 protocol contracts
   the lifecycle suite compiles, and that the skip keeps every deployable under the gate.

---

## 6. Run results for this review

All runs in a scratch worktree at PR head `c0d3468` with the submodule at the pin unless stated.

### Unit suites

`forge test --no-match-contract Fork`: 391 passed, 0 failed, 0 skipped (13 suites); of these 62 are generic-call
(43 unit, 5 lifecycle, 14 deploy-script). `forge build --sizes --skip test`: `GenericCallStrategy` 10,309 bytes
runtime. `forge build --sizes`: fails on `SyndicateGovernor` 35,832 and `SyndicateVault` 25,634.

### Pin-bump experiment (F-3)

Submodule at `a91fae2f`, `test/helpers/TierRegistryFixture.sol` re-copied from HEAD: 391 passed, template 10,309
bytes. In a sherwood-protocol worktree at `a91fae2f` with the template, mocks, unit and lifecycle suites dropped
into `src/strategies/` and `test/strategies/`: 48 passed (20 init, 23 execute/settle, 5 lifecycle).

### Fork suite against live 4663

`ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract DeployGenericCallTemplateFork`
at block about 107.67M: 4 passed. The committed book was unchanged afterwards.

### Deploy dry run against live 4663

Section 3, "Deploy script and CI". Artifacts stayed in the scratch worktree; the main checkout has no new
`broadcast/` or `cache/` entries.

### Static

Slither 0.11.3 with `slither.config.json`: 11 results under `src/generic-call/`, all triaged in F-10. Entry-points printer: six state-changing
entry points, section 2. Semgrep: not run.

### Port fidelity

`diff` of `src/generic-call/GenericCallStrategy.sol` against sherwood-protocol `d5452dc6:src/strategies/GenericCallStrategy.sol`:
two import lines and one natspec path. `test/mocks/GenericCallMocks.sol`: identical. `test/generic-call/GenericCallStrategy.t.sol`
body past the imports: identical. `GovEnvelope.sol`, `TierRegistryFixture.sol`, `MockAgentRegistry.sol` against the
pin's copies: import paths and the provenance header only.

---

## Appendix: commands used

```bash
# Worktree
git worktree add <scratch>/pr21 origin/carlos/generic-call-template && cd <scratch>/pr21 && git submodule update --init --recursive

# Static
slither src/generic-call/GenericCallStrategy.sol --print entry-points
slither . --config-file slither.config.json

# Tests and build
forge test --no-match-contract Fork
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract DeployGenericCallTemplateFork -vv
forge build --sizes --skip test ; forge build --sizes

# Dry run (no broadcast)
STRATEGY_FACTORY=0xb06788F027268a9A06c3AD41a88559530D2E54b1 TIER_REGISTRY=0x4614f058920941A0a9a852e62485fbDE692D75E1 \
forge script script/generic-call/DeployGenericCallTemplate.s.sol:DeployGenericCallTemplate --rpc-url $RPC

# Live reads (RPC = https://rpc.mainnet.chain.robinhood.com)
cast call 0x619af1488F32B4797f6faDa3C3a8De72a5B693E0 'getActiveSyndicates(uint256,uint256)((uint256,address,address,string,uint256,bool,string)[],uint256)' 0 3 --rpc-url $RPC
cast call <vault> 'owner()(address)' --rpc-url $RPC ; cast call <vault> 'governor()(address)' --rpc-url $RPC
cast call <governor> 'tier2CallCapBps()(uint256)' --rpc-url $RPC
cast call <vault> 'rescueERC20(address,address,uint256)' <sWOOD> 0x000000000000000000000000000000000000dEaD 0 --from <vault owner> --rpc-url $RPC
cast implementation <vault> --rpc-url $RPC
cast storage <governor> 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50 --rpc-url $RPC   # beacon slot
curl "https://sourcify.dev/server/v2/contract/4663/0xdab4707c9997a84e931fe98f4688adafc70b6b95?fields=sources,compilation"

# Drift (in sherwood-protocol)
git diff --stat 2a885c53 origin/v1-deploy -- src/strategies/BaseStrategy.sol src/BatchExecutorLib.sol src/StrategyFactory.sol src/SyndicateVault.sol src/SyndicateGovernor.sol src/AssetCallRules.sol src/GovernorEmergency.sol src/TierRegistry.sol
git show origin/v1-deploy:src/SyndicateVault.sol | diff - <live SyndicateVault.sol from Sourcify>

# Pin-bump experiment (in the scratch worktree, then restored)
(cd lib/sherwood-protocol && git checkout origin/v1-deploy) && cp lib/sherwood-protocol/test/helpers/TierRegistryFixture.sol test/helpers/ && forge test --no-match-contract Fork
```
