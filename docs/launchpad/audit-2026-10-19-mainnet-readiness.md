# Launchpad mainnet readiness: light audit and minimum patch set

Line numbers cite the sources at `8f8b349` (the review's base); the triage comments added by PR #10 shift the adapter files by a few lines.

Date: 2026-10-19. Scope: `src/launchpad/LaunchpadStrategy.sol`, `src/launchpad/adapters/SushiLaunchAdapter.sol`,
`src/launchpad/adapters/StonkLaunchAdapter.sol`, `src/launchpad/ILaunchAdapter.sol`,
`script/launchpad/DeployLaunchpadStrategy.s.sol`, at sherwood-strategies `8f8b349`, against the protocol pin
`lib/sherwood-protocol @ 2a885c53` and `sherwood-protocol v1-deploy @ 1d38a287`. Lighter (G-1, G-2, G-7, G-8)
is out of scope here. Method: Trail of Bits skills `entry-point-analyzer` (Slither printer), `audit-context-building`
(line-by-line read of all four contracts plus the verified Sushi V2.2 source from Sourcify), `fp-check` on every
candidate, Slither 0.11.3 detectors, and live `cast` reads on Robinhood Chain 4663. This is a readiness review, not an
audit; nothing downstream may call the template "audited".

This document is the input for the SHE-414 step-2 PR. Section 4 is the work list. Section 5 is the decisions
Carlos has to make before that PR is opened.

---

## 1. Live 4663 facts (block 92,984,658)

Recorded once so the implementing session does not re-derive them.

| Fact | Value | How read |
| --- | --- | --- |
| Public RPC | `https://rpc.mainnet.chain.robinhood.com` | `sherwood-protocol/addresses/4663.json` (`rpc` key); README of this repo uses it too |
| `TierRegistry` | `0x4614f058920941A0a9a852e62485fbDE692D75E1`, owner `0x5A00afAecE9CF61A768E2AE2713084C8d354DF94` | `owner()`, `strategyFactory()` round-trips to the factory below |
| `StrategyFactory` | `0xb06788F027268a9A06c3AD41a88559530D2E54b1`, owner `0x5A00…DF94`, not a proxy, 2,946 bytes | `owner()`, ERC-1967 slots zero |
| `SyndicateFactory` | `0x619af1488F32B4797f6faDa3C3a8De72a5B693E0` (proxy, impl `0xc8a5…69e3`), owner `0x5A00…DF94` | `StrategyFactory.syndicateFactory()` |
| Beta gates | `depositsRestricted() == true`, `ownerOnlyProposals() == true` | `cast call` on the SyndicateFactory |
| `UniswapSwapAdapter` | `0x54e6a7af53143556973493fdec9d7837a77c67ef`, granted at block 81,707,969 | Not in any address book I could find. Identified from the registry's `CounterpartyAllowedSet` logs and confirmed by `quoter() == UNISWAP_QUOTER_V2`, `v4Quoter() == UNISWAP_V4_QUOTER` |
| Price sources | USDG/USD `0x61B7…9aD2` and ETH/USD `0x78F3…d3A9` are both counterparty-granted and `isPriceSourceForToken` attested for USDG and WETH | `cast call` |
| Sushi Launchpad V2 | proxy `0xF1716eBf85836ffE2985db9A50dd29e5814caBe9`, `implementationVersion() == 2`, `implementationRevision() == 2`, impl slot `0x230065bdf7d8d639dc921539f16ed2ffb0521e75`, owner `0x104C…C223`, `launchFee() == 5e14` | `cast call`, matches `script/launchpad/addresses-4663.json` |
| Sushi quote feeds | USDG and WETH registered, WOOD zero | `quoteTokenPriceFeed(q)` |
| Sushi venue grant | `isCounterpartyAllowed(0xF1716e…) == false` | not yet vouched for |
| Fork-book addresses | `0x4435…2951`, `0x2034…7379`, `0x36C4…A5ab` have no code on 4663 | `cast code` |
| `approvedTemplate(0x4435…2951)` | false | nothing from this repo is live on mainnet |

Protocol drift between the pin and v1-deploy HEAD, checked with `git diff 2a885c53 v1-deploy`:

- `BaseStrategy.sol`, `StrategyFactory.sol`, `ISwapAdapter.sol`: zero lines.
- `ISyndicateGovernor.StrategyProposal`: field order unchanged (one comment edit). `_clampWindow` at
  `LaunchpadStrategy.sol:927-941` decodes it correctly on both.
- `SyndicateGovernor.settleProposal` now reverts `StrategyNotSettled` if the strategy still answers `executed()`
  (`SyndicateGovernor.sol:532-535` on v1-deploy). `BaseStrategy.settle` flips `_state` before `_settle`, so the
  template passes.
- `SyndicateVault.rescueERC20` now only moves a non-asset token to a strategy clone bound to the same vault
  (`SyndicateVault.sol:1134-1148`). Consequence for this template in section 3, finding F-5.
- `UniswapSwapAdapter` dropped mode 1 (V3 chained multi-hop). The live 4663 adapter answers `quoter()` and
  `v4Quoter()`, which the pin's ABI also exposes; `ISwapAdapter.swap`/`quote` are unchanged.

Baseline: `forge test --match-path "test/launchpad/*.t.sol"` passes (187 tests, 25 fork tests skipped without
an RPC). Fork-suite and deploy dry-run results are in section 6.

---

## 2. Attack surface

State-changing entry points, from `slither --print entry-points` plus manual classification.

| Contract | Entry point | Who | Notes |
| --- | --- | --- | --- |
| `LaunchpadStrategy` | `initialize` | first caller; `StrategyFactory.cloneAndInit` does it atomically and pins `proposer == msg.sender` | `_initialize` fails closed on an unresolved registry (`:588-589`) |
| | `execute`, `settle`, `rescueTo` | `onlyVault`; `execute` also requires the governor's active proposal to name this clone (`BaseStrategy.sol:127-135`) | |
| | `updateParams` | `onlyProposer`, Pending only, tightening only (`:639-669`) | `deadline` moves freely, including to 0 |
| | `claim`, `claimFor(holder)` | anyone; pays the holder (`:946-960`) | queue refused (`:1006-1007`) |
| `SushiLaunchAdapter` impl | `launch` | anyone, pays nothing to the caller; the clone it mints is owned by the caller | |
| | `collectFees(ref)` | anyone | routes to the clone's pinned `feeRecipient` only |
| | `finalize` | no-op | |
| `SushiLaunchAdapter` clone | `initialize`, `executeLaunch` | implementation only (`:406`, `:428`) | |
| | `cloneCollectFees` | anyone | pays `feeRecipient` (the vault) only |
| | `receive` | `weth` only (`:533-535`) | |
| `StonkLaunchAdapter` | same shape plus `cloneFinalize` (anyone) and `abort` (clone owner, which is the strategy, which never calls it) | | mainnet-irrelevant if Stonk is not deployed |

Actors: the vault (through governor batches), the proposer (in the beta: the vault owner, because
`ownerOnlyProposals` is on), share holders, anyone (`executeProposal` on the governor is permissionless,
`SyndicateGovernor.sol:461`), the Sushi venue owner (UUPS upgrade, `setFeeReceiver`, `transferCreator`,
`setLaunchFee`, feed registration), and the protocol's swap adapter.

Value paths: vault asset leaves only through `_pullFromVault` inside `execute` (bounded by `assetIn` and the
batch cap). Quote leaves the strategy only into the allowlisted swap adapter and the allowlisted launch adapter,
each approved for exactly the amount and reset to zero. Launch tokens leave the strategy only to holders of
`vault()` by snapshot weight or to the vault in kind. Fees never touch the strategy: the venue pays the per-launch
clone, which forwards to the vault pinned at `initialize`.

---

## 3. Findings

Each item went through the fp-check gates: restated claim, data-flow trace, preconditions, devil's advocate.
Severity is rated for the mainnet configuration in section 1 (owner-only proposals, restricted deposits).

### F-1. Quote-leg floor is a static voted number; execute is permissionless (G-4). Low. True positive, reachable now when `quoteToken != asset`.

- Where: `LaunchpadStrategy.sol:731-741`. `swap(asset, quote_, amountIn, minQuoteOut, _quoteSwapData)` with
  `minQuoteOut` fixed at init and only raisable (`:661`).
- Trace: `executeProposal` has no caller gate, so anyone may bracket the execute transaction. The asset to quote
  swap fills down to `minQuoteOut`; the attacker's profit is `fair - minQuoteOut` minus pool fees. The dev buy
  that follows cannot be sandwiched (token and pool are created in the same transaction,
  `SushiLaunchpadV2_2.launchAndBuy`), and the fee swap is capped by the voted `maxFeeIn` (`:851`).
- Recalibration: slice G's hostile-proposer route variant (a proposer routing through a pool they alone LP) is
  dead on mainnet while `ownerOnlyProposals` is on. What survives is the outside sandwich. It does not exist at
  all when the launch is quoted in the vault asset (a USDG vault launching against USDG runs no swap leg).
- Settle leg: `_convertQuote` at `:1131-1155` floors on the adapter's spot quote inside the settling
  transaction. On Sushi the venue consumes the initial buy in full or reverts `PartialInitialBuy`, and `_execute`
  sends the whole quote balance into the buy (`:752-755`), so what reaches settle is dust or a donation. Accept.
- Fix options, decision in section 5:
  - Option A, zero code. Launch only with `quoteToken == asset`, so no swap leg exists and there is nothing to
    sandwich. Raising `minQuoteOut` through `updateParams` right before executing is only a partial mitigation
    for `quoteToken != asset`: `executeProposal` is permissionless for the whole execution window, so a third
    party can execute against the stale voted floor before the proposer tightens it. Document the `quote == asset`
    rule in the CLI help and in `docs/launchpad/design.md` Decision 6.
    Status (2026-10-20, SHE-415): option A is superseded. The CLI now allows any `quoteSupported` quote and
    guards the swap leg itself (sherwood#693, CLI 0.99.0): `minQuoteOut` from the swap adapter's quote less
    `--max-slippage-bps` (default 50, max 100), a thin-pool refusal, `assetIn` at most 3,500 bps of
    `totalAssets`, a venue-feed staleness check, and a disarmed `deadline = 1` that only the proposer can open
    with `sherwood launchpad arm` (a window of at most 1h). That closes the third-party-executes-first gap above.
    Rules: `docs/launchpad/sushi.md` "Launch rules for mainnet". The on-chain follow-up is SHE-416 (option B
    plus the cap at `_initialize`).
  - Option B, code. A feed-anchored floor at execute, mirroring `PortfolioStrategy._buyFloor` and `_feedPrice`
    (`sherwood-protocol v1-deploy src/strategies/PortfolioStrategy.sol:367-392`). Add `assetFeed`, `quoteFeed`
    and `quoteSlippageBps` to `InitParams`; at init require both feeds pass `_isCounterpartyAllowed` and
    `isPriceSourceForToken(token, bytes32(uint160(feed)))` (the `PortfolioStrategy._requirePairedPriceSource`
    pattern); at execute compute `expected = amountIn * assetPrice * 10^quoteDec / (quotePrice * 10^assetDec)`
    and swap with `max(minQuoteOut, expected * (BPS - quoteSlippageBps) / BPS)`. Bound `quoteSlippageBps` in
    `[50, MAX_SLIPPAGE_BPS]` and let `updateParams` only lower it. Staleness: reuse `MAX_PUSH_PRICE_AGE` (26h on
    Portfolio). Both USDG/USD and ETH/USD are already granted and attested on 4663, which is what makes this
    cheap. This changes the `InitParams` ABI, so the SDK encoder, the CLI, and every fixture in
    `test/launchpad/LaunchpadStrategy.t.sol` and `test/launchpad/fork/LaunchpadSushiV2Fork.t.sol` change with it.
    Roughly 60 lines of Solidity plus tests.

### F-2. Permissionless `collectFees` lands fee income in the vault at a caller-chosen block (G-5). Low. True positive; reachable on mainnet only by approved depositors between proposals.

- Where: `SushiLaunchAdapter.sol:340-344` and `:494-521`; `StonkLaunchAdapter.sol:538-542` and `:1009-1041`.
- Trace: between proposals `redemptionsLocked()` is false, deposits and redeems are instant, and
  `totalAssets()` is the idle balance. Deposit, call `collectFees(launchRef)`, redeem, and capture
  `F * X / (TVL + X)` of the accrued quote-side fees `F`. `depositsRestricted` narrows the attacker set to the
  approved cohort; it does not remove it. Only applies when the launch quote is the vault asset.
- Second shape worth stating: a fee lump that lands while a later proposal is `Executed` reads as that
  proposal's profit (the governor measures P&L as the vault-asset balance delta), so it feeds that proposer's
  performance fee. With owner-only proposals the proposer is the owner.
- Recommendation: no code change. `ILaunchAdapter.collectFees` (`ILaunchAdapter.sol:183-186`) and
  `docs/launchpad/design.md` Decision 3 both make permissionless collection a stated contract, and the vault has no
  fee-smoothing or hold period for the template to lean on. Mitigation is a keeper that collects on a short
  cadence so no lump accrues (SHE-313's keeper is the natural home), plus a line in the cohort disclosure.
- If someone insists on code: gate `cloneCollectFees` to `msg.sender == owner || vault.owner() ||
  vault.isAgent(msg.sender)` read through length-checked staticcalls to `feeRecipient`, update the
  `ILaunchAdapter` natspec, the adapter headers, design.md, and five unit tests. It shrinks the attacker set to
  insiders; it does not close the mid-proposal P&L shape. Around 30 lines plus tests.

### F-3. Slither reentrancy flag on `SushiLaunchAdapter.executeLaunch`. False positive; triage, do not restructure.

- Where: `SushiLaunchAdapter.sol:433-447`. `IWETH.withdraw(fee)` and `launchAndBuy{value: fee}` run before the
  `launchToken` and `quoteToken` writes.
- Why it cannot be exploited: `executeLaunch` is callable only by the implementation (`:428`) and only once per
  clone (`:431`); every cross-function reader short-circuits on `launchToken == 0` (`clonePhase` `:469`,
  `cloneCollectFees` `:497`); `receive` accepts native only from `weth` (`:534`); every state-changing venue
  entry is `nonReentrant` (`ReentrancyGuardTransient`); the launch token has no transfer hook unless
  `DISTRIBUTE_TO_HOLDERS`, which `_decodeVenueData` refuses (`:553-555`); the quote is USDG or WETH, neither of
  which calls the recipient. There is no state a reentrant frame could read to its advantage.
- Fix: a `// slither-disable-next-line reentrancy-no-eth,reentrancy-benign` with the one-paragraph argument
  above, and a `slither.config.json` at the repo root that filters `lib/`, `test/`, `script/` so the gate is
  reproducible. The identical flag on `StonkLaunchAdapter.executeLaunch` (`:726-748`) has the same argument if
  Stonk ships.
- Other Slither output, one line each: "dangerous strict equality" on `probe == 0`, `out == 0`, `bal == 0`,
  `expected == 0`, `residue == 0`, `received == 0` are all zero-guards, not balance equalities; "locking ether"
  on `StonkLaunchAdapter` is the interface's `payable` with `msg.value != 0` refused at `:458`; "uninitialized
  local" `maxFee` is a zero-initialised accumulator; "unused return" on `launchAndBuy`, `buy`, `swap` is
  deliberate because every post-condition is re-read from balances.

### F-4. Stonk dev buy executes at the opening tax (G-3). Low on Stonk, nil if Stonk is not deployed.

- Where: `StonkLaunchAdapter.sol:758` (`arm`) and `:771` (`buy`) in one transaction, so elapsed time is zero;
  `:720` accepts `quoteIn != 0` with `minTokensOut == 0`.
- Fix if Stonk ships: in `executeLaunch` revert when `p.quoteIn != 0 && v.bufferSecs != 0`, and when
  `p.quoteIn != 0 && p.minTokensOut == 0`. Two reverts, two unit tests, one fork assertion. Otherwise defer with
  the venue.

### F-5. Launch tokens above `reserveAmount`, and the unclaimed reserve, are stranded in the vault in kind. Low, new.

- Where: `LaunchpadStrategy.sol:790` records `reserve = reserveAmount` while `held` (`:778`) may be larger;
  `_settle` pushes the whole remaining balance in kind (`:1113`).
- Why it matters more on v1-deploy than the design notes assume: `rescueERC20` can now move a non-asset token
  only to a clone of the same vault (`SyndicateVault.sol:1134-1148`), and no shipped template can take or sell an
  unfeeded launch token. The header's "a later proposal disposes of it" has no executor today. A 1,000 USDG dev
  buy returns about 164.56M tokens; if `reserveAmount` is set below that, the surplus is dead weight.
- Fix options: no code, the CLI sets `reserveAmount == minTokensOut` and both close to the lens or quoter
  estimate, and the SHE-313 `claimFor` sweep runs before `windowEnd` so the unclaimed remainder is small. Or one
  line, `reserve = Math.min(held, Math.mulDiv(launchSupply, MAX_RESERVE_BPS, BPS))`, which keeps the 20% cap and
  gives holders the surplus instead of the vault; it changes what voters read as the pot, so pair it with a
  natspec change and the `test_execute_*` assertions on `reserve`.

### F-6. Venue-owner trust is wider than "the fee stream". Informational.

- From the verified `SushiLaunchpadV2_2.sol`: `setFeeReceiver` (`:362-371`) is `onlyOwner` and does not read
  `feeReceiverLocked`; the lock is written by `lockFeeReceiver` (`:373-383`) and read nowhere else. The lock is
  advisory in V2.2. Do not propose "call `lockFeeReceiver` from the clone" as a mitigation; it does nothing
  against the owner. The adapter already degrades to `(0, 0)` on a re-point
  (`test_CollectFees_AfterVenueOwnerRepointsReceiverReturnsZero`).
- `transferCreator` admits the owner (`:348-360`). With the creator role the owner can call `setFeeDisposition`
  to `DISTRIBUTE_TO_HOLDERS` (`:385-418`), which installs a transfer hook on the launch token
  (`SushiLaunchpadTokenV2_2._update` calls the distributor on every transfer). A reverting hook would make
  `claim` and `_pushBalance(token)` revert, which wedges settlement until the owner's emergency path. The hook is
  Sushi's own contract and the owner is `0x104C…C223`; this is a trust statement for the docs, not a code change.
- The counterparty grant pins the proxy's codehash, not the implementation's, so a Sushi upgrade is invisible to
  `isCounterpartyAllowed`. The deploy ceremony records the impl slot; a pre-launch check of
  `implementationRevision() == 2` and the slot is the operational control.

### F-7. Init accepts `minTokensOut < reserveAmount`; execute then reverts. Informational.

- `LaunchpadStrategy._initialize` does not relate the two; `SushiLaunchAdapter.launch` reverts
  `ReserveFloorBelowReserve` (`:282`) at execute. A wasted vote, no capital at risk. The strategy cannot enforce
  it generically because on Stonk `minTokensOut` only floors the optional dev buy. Enforce it in the CLI encoder.

### F-8. `deadline` may be moved to zero after the vote. Informational, accepted by design (`:651-656`).

### F-9. Deploy script cannot find the 4663 protocol singletons. Ship blocker, not a vulnerability.

- `DeploymentsBook._protocolAddress` (`script/DeploymentsBook.sol:54-62`) reads
  `lib/sherwood-protocol/chains/4663.json` and falls back to an env var of the same name. Neither the pin nor
  v1-deploy HEAD carries `TIER_REGISTRY`, `STRATEGY_FACTORY` or `UNISWAP_SWAP_ADAPTER` for 4663 (only
  `chains/9994663.json` does). Without overrides, `run()` deploys with registry and factory zero, prints no Safe
  calldata, and records zeros under `_meta.launchpad`; `verify()` reverts on `_requireProtocolAddress`.
- Required for every dry run, broadcast and verify:

  ```bash
  export TIER_REGISTRY=0x4614f058920941A0a9a852e62485fbDE692D75E1
  export STRATEGY_FACTORY=0xb06788F027268a9A06c3AD41a88559530D2E54b1
  export UNISWAP_SWAP_ADAPTER=0x54e6a7af53143556973493fdec9d7837a77c67ef
  export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
  ```

- Better than env forever: add these three keys to a strategies-side book (`script/launchpad/addresses-4663.json`
  already holds venue keys with provenance notes) and have `_protocolAddress` consult it after the protocol book.
  Record the identification evidence for the swap adapter from section 1.

### F-10. `deployments/README.md` claims Lighter is on mainnet. Doc fix.

- Last paragraph of `deployments/README.md`. There is no `deployments/4663.json`, and the fork-book Lighter
  address has no code on 4663. Replace with: nothing from this repo is deployed on 4663 yet; the 9994663 fork has
  no Lighter sequencer.

### F-11. Test coverage gap for the governor path. Informational.

- Every Launchpad suite, fork suites included, runs against `MockFundVault` and `MockFundGovernor`
  (`test/launchpad/fork/LaunchpadSushiV2Fork.t.sol:11,32-34`). The real `getProposal` decode, the settle-price
  floor and `StrategyNotSettled` are not exercised. For an owner-only first launch this does not block; the first
  live launch is the test. If a cheap guard is wanted, a fork test that clones the template through the real
  `StrategyFactory` and reads `getProposal` from a real governor would close the decode half.

Rejected candidates, kept so they are not re-opened: proposer-settable fee or creator recipient
(`feeRecipient` is always `vault()`, `:770`; no `InitParams` member); snapshot sniping (deposits locked from
`propose`, votes equal balances by forced self-delegation, queue excluded); claim double-spend or reentrancy
(flag before transfer, `:1017-1020`); settle wedged by venue or registry (no venue or registry call in
`_settle`, raw calls on the swap leg); forged `launchRef` (ERC-1167 prefix, embedded implementation and suffix
all checked, and the strategy stores the adapter's own return value); fee-swap overspend (capped by
`maxFeeIn`); foreign-vault capital (`onlyVault` on every value-moving entry, `_pullFromVault` reads `_vault`);
a clone minted directly from the Sushi implementation (passes introspection, stays uninitialised, every verb
returns zero); `MAX_RESERVE_BPS` gaming (`SupplyMismatch` at `:785-786` against Sushi's fixed supply).

---

## 4. Minimum work to ship Sushi on 4663

Tier 0 blocks the broadcast. Tier 1 is cheap and recommended in the same PR. Tier 2 is accepted and disclosed.

### Tier 0

1. **Sushi-only deploy and verify path** (`script/launchpad/DeployLaunchpadStrategy.s.sol`).
   - Add `runSushi()` / `deploySushi(registry, factory)` that deploys `LaunchpadStrategy` and
     `SushiLaunchAdapter` only, builds the counterparty list as `[sushiAdapter, sushiLaunchpad]`, performs or
     prints the grants and the template approval exactly as `deploy` does (`:206-218`), and records
     `LAUNCHPAD_TEMPLATE` and `SUSHI_LAUNCH_ADAPTER` plus `_meta.launchpad` with `sushiLaunchpadImplementation`.
   - Add `verifySushi()` that skips the Stonk assertions in `verifyDeployment` (`:152-154`, `:160-164`) and
     the pad and lens grants (`:173-177`). `verify()` as written requires every Stonk counterparty and would fail
     a Sushi-only deployment.
   - `test/launchpad/fork/DeployLaunchpadStrategyFork.t.sol`: one case for the Sushi-only ceremony and one for
     its verify; keep the full-ceremony cases.
   - `deployments/README.md`: note that `STONK_LAUNCH_ADAPTER` may be absent on a chain.
   - Acceptance: `forge script ... --sig 'runSushi()'` dry run against 4663 with the section 1 env prints two
     `setCounterpartyAllowed` and one `setTemplateApproval` Safe transactions and writes nothing.
2. **Protocol address resolution** (F-9). Either document the three env exports in the script header and the
   README, or add the keys to the strategies-side book. Acceptance: the dry run above resolves registry and
   factory without env vars if the book route is taken.
3. **`deployments/README.md` Lighter claim** (F-10).
4. **Re-run unit and fork suites against the live venue.** `forge test --no-match-contract Fork`, then
   `ROBINHOOD_RPC_URL=... forge test --match-contract Fork`. Results of the run made for this review are in
   section 6; re-run on the PR branch.

### Tier 1

5. **Slither triage** (F-3): inline disable with justification on both `executeLaunch` functions and a
   `slither.config.json`. Acceptance: `slither . --config-file slither.config.json` reports no reentrancy
   findings in `src/launchpad/`.
6. **G-4 per the decision in section 5.** Option A is a doc and CLI-help change. Option B is the feed-anchored
   floor described in F-1, with tests: a mock feed pair, `test_execute_quoteFloorFromFeedBeatsLooseVote`,
   `test_execute_revertsWhenFeedStale`, `test_init_revertsWhenFeedNotAttested`, and the fixture updates.
7. **`reserve` surplus** (F-5): take the one-line change or the CLI rule, and say which in design.md Decision 4.
8. **Docs:** `docs/launchpad/design.md` Decision 3 (fee lump timing and keeper cadence, the mid-proposal P&L
   shape), Decision 6 (G-4 outcome), trust notes (F-6: the lock is advisory, the holder-rewards hook).
   `docs/launchpad/sushi.md` trust section: same two sentences.

### Tier 2, accept and disclose

9. G-5 as a keeper-cadence and disclosure item (F-2), unless the gate is chosen.
10. F-6 venue-owner trust, F-7 CLI validation, F-8 deadline, F-11 coverage gap.
11. Stonk: do not grant on 4663. If it is revisited, apply F-4 first and re-run `StonkLaunchRobinhoodFork`.

### Owner steps after the broadcast (unchanged from SHE-414)

`TierRegistry.setCounterpartyAllowed(sushiAdapter, true)`, `TierRegistry.setCounterpartyAllowed(0xF1716e…, true)`,
`StrategyFactory.setTemplateApproval(template, true)`, from the owner `0x5A00…DF94`. Then
`--sig 'verifySushi()'` must pass. The adapter grant must follow the adapter deploy because the grant snapshots
the codehash. Record the Sushi impl slot with the grant; a later Sushi upgrade does not change
`isCounterpartyAllowed`.

---

## 5. Decisions for Carlos

1. **Sushi only on 4663?** Recommend yes. It removes F-4, G-6 and the Stonk Slither items from the mainnet
   surface and halves the counterparty list. The cost is Tier 0 item 1.
2. **G-4: Option A or B?** For a first small owner-only launch quoted in the vault asset, A is sufficient. For
   the template to stay approved past the beta, B is the fix, and it is cheap now because both feeds are
   already granted and attested. If B, the CLI and SDK PR (SHE-414 step 6) must land the new `InitParams`
   encoder in the same release.
3. **G-5: accept with keeper cadence, or gate?** Recommend accept. The gate contradicts the interface contract
   and does not close the second shape.
4. **Pin bump to v1-deploy `1d38a287`?** Optional. The template's compiled dependencies are byte-identical
   between the pin and HEAD, so it changes nothing in the artifacts; it does make the repo's "current pin" README
   line true again.

---

## 6. Run results for this review

Filled in by the review session; see the end of this file for the exact commands.

### Unit suites

`forge test --match-path "test/launchpad/*.t.sol"`: 187 passed, 0 failed, 25 skipped (fork tests without RPC).

### Fork suites against live 4663

`ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork` at block ~92.98M:
33 passed, 0 failed across `LaunchpadSushiV2Fork` (1, the end-to-end launch, claim, collect, settle against the
live V2.2 venue), `StonkLaunchRobinhoodFork` (10), `SushiLaunchAdapterFork` (9), `DeployLaunchpadStrategyFork`
(13). SHE-414 step 2's "re-run fork tests against the live 4663 venue" is satisfied at this commit; re-run on the
PR branch.

### Deploy dry run against live 4663

`forge script ... DeployLaunchpadStrategy --rpc-url $RPC` with the three env exports from F-9, default foundry
sender (no key), no `--broadcast`. Simulation succeeded. Estimated gas 10,378,492 at 0.0401 gwei, about
0.00042 ETH for the full (Stonk plus Sushi) ceremony; a Sushi-only run will be well under half. Template
runtime size 14,917 bytes. The script resolved the registry and factory from the env, found the deployer does not
own them, and printed the owner runbook: twelve `setCounterpartyAllowed` (two adapters, eight pads, lens, Sushi
proxy) and one `setTemplateApproval`, each with calldata. The post-deploy reads confirmed
`swap adapter isCounterpartyAllowed: true` for `0x54e6…67eF`, which independently confirms the adapter identity in
section 1. The simulated addresses are sender-dependent and not the ones the real deployer key will produce.
Artifacts: `broadcast/DeployLaunchpadStrategy.s.sol/4663/dry-run/run-latest.json` and a cache entry; no
`deployments/4663.json` was written (dry runs never write the book). Expect the real run to print a Sushi-only
runbook once Tier 0 item 1 lands: two grants and one approval.

---

## Appendix: commands used

```bash
# Static
slither . --filter-paths "lib/|test/|script/|lighter/" --print entry-points
slither . --filter-paths "lib/|test/|script/|lighter/" --exclude-informational --exclude-optimization

# Live reads (RPC = https://rpc.mainnet.chain.robinhood.com)
cast call 0x619af1488F32B4797f6faDa3C3a8De72a5B693E0 'depositsRestricted()(bool)' --rpc-url $RPC
cast call 0x619af1488F32B4797f6faDa3C3a8De72a5B693E0 'ownerOnlyProposals()(bool)' --rpc-url $RPC
cast call 0x4614f058920941A0a9a852e62485fbDE692D75E1 'isCounterpartyAllowed(address)(bool)' <addr> --rpc-url $RPC
cast call 0x4614f058920941A0a9a852e62485fbDE692D75E1 'isPriceSourceForToken(address,bytes32)(bool)' <token> <feed-as-bytes32> --rpc-url $RPC
cast logs --address 0x4614f058920941A0a9a852e62485fbDE692D75E1 'CounterpartyAllowedSet(address,bool)' --from-block 80000000 --to-block 86000000 --rpc-url $RPC
cast call 0xF1716eBf85836ffE2985db9A50dd29e5814caBe9 'implementationRevision()(uint64)' --rpc-url $RPC
cast storage 0xF1716eBf85836ffE2985db9A50dd29e5814caBe9 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC

# Venue source
curl "https://sourcify.dev/server/v2/contract/4663/0x230065BdF7D8d639dc921539f16ed2FFB0521E75?fields=sources"

# Tests and dry run
forge test --no-match-contract Fork
ROBINHOOD_RPC_URL=$RPC forge test --match-contract Fork
TIER_REGISTRY=0x4614f058920941A0a9a852e62485fbDE692D75E1 STRATEGY_FACTORY=0xb06788F027268a9A06c3AD41a88559530D2E54b1 \
UNISWAP_SWAP_ADAPTER=0x54e6a7af53143556973493fdec9d7837a77c67ef \
forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy --rpc-url $RPC
```

## Addendum, 2026-10-20: F-3 triage corrections from the PR #10 review

The in-source comments above both `executeLaunch` functions now point here; the argument lives in this section.

- `SushiLaunchAdapter.executeLaunch`: the detector that fires is `reentrancy-eth`, not `reentrancy-no-eth`, because `launchAndBuy{value: fee}` carries the launch fee as native value. `IWETH.withdraw` and `launchAndBuy` run before the `launchToken` / `quoteToken` writes. It cannot be exploited: the function is callable only by the implementation and only once per clone; every cross-function reader short-circuits on `launchToken == 0`; `receive` accepts native only from `weth`; the venue's state-changing entry points are `nonReentrant`; and `launch` is permissionless but always makes a fresh clone, so a reentrant frame cannot reach the half-written one. Two inputs are venue-owner trust, not facts of the code: the quote set is whatever the venue's feed registry admits (USDG and WETH at writing, extendable by the Sushi owner), and the launch token has no transfer hook only while the fee disposition is not `DISTRIBUTE_TO_HOLDERS`, which `_decodeVenueData` refuses at launch but the venue owner can set later (F-6).
- `StonkLaunchAdapter.executeLaunch`: only `createLaunch` runs before the `launchId` / `launchToken` writes. `arm` and `buy` run after `launchToken` is set, so the "readers short-circuit on `launchToken == 0`" argument does not cover them; what covers them is that the pad (`StonkSafeLaunchpadV2`, verified source) makes all three `nonReentrant` and its token (`SafeLaunchV2Token`) is a plain ERC20 with no transfer hook, so no callback exists during `arm` or `buy`. The tax split's calls into venue-owner contracts sit inside the venue-owner trust accepted under F-6. Even a re-entered `cloneCollectFees` mid-`buy` would forward the creator fee to the same `feeRecipient` the split uses.
- The inline `slither-disable-next-line` comments are live, not inert: deleting them brings back `reentrancy-eth` (High) on the Sushi function and `reentrancy-no-eth` on the Stonk function. They suppress only the named detectors. `slither.config.json` also excludes `reentrancy-benign` and `reentrancy-events` repo-wide (3 and 21 findings without it, about half in `src/lighter`), a disclosed choice.

## Addendum, 2026-10-20: deployment and the class-certification decision

`runSushi()` was broadcast on 4663 from the registry and factory owner `0x5A00…DF94` at script commit `81cfc38`
(blocks 93,737,582 to 93,737,603): `LAUNCHPAD_TEMPLATE` `0xbc4fDF5949caa74c730bed632E368cEa4ea5832D`,
`SUSHI_LAUNCH_ADAPTER` `0x52901614748ACFDC083D305Aa5301E484d4B15F8`. The two grants and the template approval
were performed in the same run, `verifySushi()` passes, and both sources are exact matches on Sourcify. The
"Safe" in section 4 and in the owner-steps paragraph above was a wrong premise: the owner is an EOA at writing.

Carlos decided to class-certify the template at tier 0, 3,500 bps, for `execute()` and `settle()`, matching the
Portfolio class bound on 4663 (Morpho Supply is at 100 bps; Lighter is uncertified). Recorded with the decision:

- The template meets the SHE-209 class-review invariant on the adapter side: `launchAdapter` and `swapAdapter` are
  checked against `isCounterpartyAllowed` at `_initialize` and re-checked at execute, and no recipient, receiver or
  router parameter exists; fees and the reserve go to `vault()`.
- `quoteToken` is deliberately unbound (natspec above `_initialize`), and nothing in bytecode forces
  `quoteToken == asset` (G-4 option A). A hostile encoding with a swap leg and a loose `minQuoteOut` can extract
  the whole notional on that path. The class bound therefore holds under every honest initialization and rests on
  the CLI rule (sherwood#689) and guardian review under a hostile one. Any bound below 10,000 carries this.
  Status (2026-10-20, SHE-415): the CLI rule is no longer `quoteToken == asset`. A non-asset quote is allowed
  with swap-leg guardrails, and `assetIn` is capped at 3,500 bps of `totalAssets` so a total loss of the swap
  leg stays inside this bound (sherwood#693, CLI 0.99.0). The bound still rests on the CLI and guardian review
  under a hostile encoding until the on-chain follow-up, SHE-416, lands.
- Honest-case exposure with `quoteToken == asset` is fee-sized: the launch fee (bought in WETH up to `maxFeeIn`),
  the dev buy's pool fee, and MEV on the fee leg. The reserve is held in kind and never sold by the strategy;
  settlement pushes the unclaimed remainder unpriced. The fund is the first buyer on a fresh curve, so no one
  holds tokens bought below its entry.
- The governor prices tier 0 and tier 1 identically from the bps; the tier-2 per-call ceiling is the only
  tier-keyed gate. `certifyDelay` is 3 days live; `certifyClass` is permissionless with no bond.

Nothing here is an audit claim; the template and adapters are readiness-reviewed.

## Addendum, 2026-10-22: deadline check, template redeploy, disarm dropped

4663 proposal 6 (the first live launch, quoted in TSLA) was blocked by the guardian fleet: the CLI 0.99.0
"disarm" design proposed it with `deadline = 1`, the fleet's fork replay of `executeProposal` reverted
`DeadlineExpired` at the adapter, and every voter read `SIMULATION_FAILED`. Three changes followed:

- `LaunchpadStrategy` refuses a non-zero deadline that is not in the future, at `_initialize` and in
  `_updateParams` (`DeadlineInPast`, #14). A clone that can never execute is no longer creatable.
- The template was redeployed at `0x1F8221c4176B8B017A6Ef699947BB4A33730Df32` (block 95,339,932,
  `redeploySushiTemplate()`, #17); the first template is un-approved. Class certification was proposed again
  for the new codehash (`0xf9abcebf…c1e4`), tier 0, 3,500 bps, and landed on 2026-10-27 15:49 UTC for both
  selectors (`classTierOf` reads 0 / 3,500).
- The disarm design is dropped (sherwood#700, CLI 0.99.3): a non-asset-quoted launch is proposed with a live
  deadline and is executable as voted; `launchpad arm` is optional tightening. The stale-floor window the
  disarm closed is now bounded by the floor off the adapter's quote, the thin-pool refusal and the 3,500 bps
  `assetIn` cap, which is the class bound. Nothing here is an audit claim; the template remains readiness-reviewed.

