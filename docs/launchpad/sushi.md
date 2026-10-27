# Sushi Launchpad V2

`SushiLaunchAdapter` fronts Sushi Launchpad V2 on Robinhood Chain (4663). It replaces
the V1 adapter from sherwood-protocol#277, which targeted Launchpad V1
(`0x104f1ab42674565ec3df0bfebccc4186f72fa7ed`).

## Venue

| | Address |
|---|---|
| Launchpad V2 proxy (ERC-1967, UUPS) | `0xF1716eBf85836ffE2985db9A50dd29e5814caBe9` |
| Implementation at writing: `SushiLaunchpadV2_2` (version 2, revision 2) | `0x230065BdF7D8d639dc921539f16ed2FFB0521E75` |
| Owner | `0x104Cf4b0631b88a242Fec0161055a7437708C223` |
| Sushi V3 factory (`v3Factory()`) | `0xE51960f1B45f1C9FB6D166E6a884F866fC70433B` |
| Sushi V3 position manager (`positionManager()`) | `0x51d0e5188afe12d502e29D982d20C190e7816107` |
| Custodian (holds every launch position, non-upgradeable) | `0xCb7c54EaC843cC632651D8603c095b77261b10f4` |
| Fee executor | `0x8Ec8161d64ED6E84D6ffA1628509e2A0133b0D3b` |
| WETH (`WETH()`, Arbitrum `aeWETH`) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

Source is verified on Sourcify (exact match). Robinhood Blockscout sits behind a
Cloudflare check, so read it from Sourcify:
`https://sourcify.dev/server/v2/contract/4663/<address>?fields=all`.

Launches index from block 38,395,704 (`TokenLaunched`, topic
`0x67d06515f05b601a4cc554da8c9a0f04285b38503d8bb9b49ae6e91d6640a123`). Sushi's
integrator docs: https://sushi-85per9xng.sushi.com/launchpad/integrators.

## What changed from V1, and why the adapter is now a clone

| | V1 | V2 |
|---|---|---|
| Who is paid LP fees | the creator, a role the creator can transfer | a separate `feeReceiver`, set to the launcher, changeable only by the venue owner |
| `launchAndBuy` | `(config, quote, deadline, buy)` | `(config, quote, liquidityMode, feeDisposition, buy)`, no deadline |
| Liquidity | one position | `STANDARD` (one position, $5k start) or `MOON` (seven, $10k start) |
| Fee handling | pay the creator | `DIRECT_PAYOUT`, `BURN_LAUNCH_TOKEN_FEES`, `BUYBACK_AND_BURN`, and in V2.2 `DISTRIBUTE_TO_HOLDERS` |

The V1 adapter was a stateless singleton. It launched, then handed the creator
role (and with it the fee stream) to the fund's vault in the same transaction.
On V2 that doesn't work: whoever calls `launchAndBuy` is the fee receiver for
the life of the launch, and no creator action changes it. A singleton would
become the fee receiver of every fund's launch, which is the shared custody
`ILaunchAdapter` forbids.

The adapter is therefore an implementation plus one ERC-1167 clone per launch,
the same shape as `StonkLaunchAdapter`:

- The clone calls `launchAndBuy`, so the venue records the clone as creator and
  fee receiver. `executeLaunch` asserts this and fails the launch if the venue
  says otherwise.
- The initial buy's recipient is the owning strategy, so the reserve never sits
  on the clone.
- `collectFees` calls the venue's permissionless `distributeFees` and forwards
  the clone's whole balance of quote and launch token to the vault, which is
  pinned at `initialize`. Anyone may call `distributeFees` on the venue
  directly, so the next sweep forwards whatever arrived in between.
- The clone keeps the creator role and exposes no creator lever. The fee mode
  chosen at launch stays the fee mode, as far as anything in this stack can
  affect.

## `venueData`

`abi.encode(SushiLaunchAdapter.VenueData({liquidityMode, feeDisposition}))`, or
empty for `(STANDARD, DIRECT_PAYOUT)`. Both are proposal parameters voters see.

| Disposition | What the vault receives from `collectFees` |
|---|---|
| `DIRECT_PAYOUT` | 70% of fees in both assets (80% on a canonical-SUSHI quote) |
| `BURN_LAUNCH_TOKEN_FEES` | the quote share; the launch-token share is burned |
| `BUYBACK_AND_BURN` | nothing; the quote share buys the token back and burns it. Distribution also refuses (announced by `VenueCallFailed`) until the pool oracle has 120 s of history and while price has moved past the venue's deviation bound |
| `DISTRIBUTE_TO_HOLDERS` | refused at launch |

`DISTRIBUTE_TO_HOLDERS` routes the quote share to a per-token `HolderRewards`
contract that pays through `claim(holder)`. The vault would be paid only by a
claim nothing in this stack drives, and `collectFees` could not report it.
Supporting it would need its own collection path, so it is left as a product
follow-up.

## Trust in the venue owner

The Sushi owner can re-point any launch's `feeReceiver` (`setFeeReceiver`),
take its creator role (`transferCreator` admits the owner), reprice the launch
fee, change the Sushi fee share per token, and upgrade the proxy. A fund
launching here trusts Sushi's owner with its **fee stream**. It does not trust
it with its **reserve**, which reaches the strategy inside the launch
transaction, or with the vault's capital, which the venue never holds.
`test_CollectFees_AfterVenueOwnerRepointsReceiverReturnsZero` pins that
`collectFees` degrades to `(0, 0)` rather than reverting if that happens.

The owner's reach is wider than the fee stream (F-6 in
`docs/launchpad/audit-2026-10-19-mainnet-readiness.md`). `lockFeeReceiver` is
advisory in V2.2: `setFeeReceiver` is `onlyOwner` and does not read
`feeReceiverLocked`. With the creator role the owner can call
`setFeeDisposition` to `DISTRIBUTE_TO_HOLDERS`, which installs a transfer hook
on the launch token (Sushi's own `HolderRewards` contract). The owner cannot
take the reserve, but a reverting hook would make `claim` and the in-kind push
at settle revert, which wedges settlement until the vault owner's emergency
path.

The counterparty grant on the venue pins the proxy's codehash, not the
implementation's, so a Sushi upgrade is invisible to `isCounterpartyAllowed`.
Before each launch, check `implementationRevision() == 2` and that the ERC-1967
implementation slot still matches the one recorded at deploy.

## Quote support

`quoteSupported(q)` is `quoteTokenPriceFeed(q) != 0` on the venue. At writing,
USDG and WETH are registered and WOOD is not. WOOD becomes launchable the moment
Sushi registers a WOOD/USD feed, with no change here. A supported quote can
still be refused at launch if its feed's latest round is older than the venue's
3-day bound (`StalePriceFeedRound`).

## Deploy

On mainnet the steps below are one script run:
`forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy --rpc-url <rpc> --sig 'runSushi()'`
deploys the template and the adapter, performs or prints the two grants and the
template approval, and records the implementation slot under
`_meta.launchpad.sushiLaunchpadImplementation` in `deployments/4663.json`.
`--sig 'verifySushi()'` checks the recorded deployment against the chain.
`--sig 'redeploySushiTemplate()'` replaces only the template: it deploys a
new one, approves it on the factory, revokes the one it replaces (new clones
only; a live clone never reads `approvedTemplate`), leaves the adapter and
every grant alone, and prints the codehash the class certification is keyed on.

Deployed on 4663 on 2026-10-20 (blocks 93,737,582 to 93,737,603, from the registry
and factory owner, grants and approval performed in-run, `verifySushi()` passing,
Sourcify exact match on both):

| | Address |
|---|---|
| `LAUNCHPAD_TEMPLATE` (since 2026-10-22, block 95,339,932; replaces `0xbc4fDF59…832D`, now un-approved) | `0x1F8221c4176B8B017A6Ef699947BB4A33730Df32` |
| `SUSHI_LAUNCH_ADAPTER` (implementation; one clone per launch) | `0x52901614748ACFDC083D305Aa5301E484d4B15F8` |
| Implementation slot recorded with the venue grant | `0x230065BdF7D8d639dc921539f16ed2FFB0521E75` |

The template was redeployed on 2026-10-22 with the `DeadlineInPast` check (#14):
a clone refuses a non-zero deadline that is not in the future, at init and in
`updateParams`. The first template was deployed on 2026-10-20 at
`0xbc4fDF5949caa74c730bed632E368cEa4ea5832D` (blocks 93,737,582 to 93,737,603)
and is un-approved since the redeploy; `_meta.templateRedeploy` in the book
records the replacement. Both templates are exact matches on Sourcify.

### Class certification

Decision (2026-10-20): the template class is to be certified at tier 0 with a
3,500 bps extractable bound for `execute()` and `settle()`, the bound the
Portfolio class carries on 4663. `proposeClassCertification` from the registry
owner, `certifyClass` after the 3-day `certifyDelay`. The honest-case loss on a
launch with `quoteToken == asset` is fee-sized: the reserve is held in kind and
never sold by the strategy, and the fund is the first buyer on a fresh curve.
A launch quoted in another token adds a swap leg. Under the CLI guardrails
below, its honest loss is at most the declared slippage plus price impact
(each at most 100 bps), and the leg's notional is capped at 3,500 bps of
`totalAssets`, so even a total loss of that leg stays inside the bound. The
bound is not code-enforced on that path: `quoteToken` is unbound by design and
a hostile encoding with a loose `minQuoteOut` can extract the whole swap
notional, so the CLI rules and guardian review hold it. Tier 0 and tier 1 are
priced identically by the governor; the bps is the operative number.

Status (2026-10-27): certified. `certifyClass` landed for the redeployed
template `0x1F8221c4…0Df32` (codehash
`0xf9abcebf1e6072b88a75d10558eaef22c00e7ba0ac8dc4ffaea867cee2f2c1e4`) on
2026-10-27 15:49 UTC, both selectors (execute tx `0x319d8f5f…55d6`, settle tx
`0xbf3967d8…d50f`); `classTierOf` reads tier 0, 3,500 bps for each. A launch
now prices at tier 0: coverage and the proposer bond are sized on 35% of
`assetIn`. The proposals made on 2026-10-20 for the first template are moot
and are left to expire.

1. `new SushiLaunchAdapter(0xF1716eBf85836ffE2985db9A50dd29e5814caBe9)`. The
   constructor reads `WETH()` from the venue and locks the implementation's
   initializer.
2. `TierRegistry.setCounterpartyAllowed(adapter, true)`. The strategy gates the
   adapter on this.
3. `TierRegistry.setCounterpartyAllowed(0xF1716eBf…caBe9, true)` for the venue.
4. Record `implementationVersion()`, `implementationRevision()` and the
   implementation slot at deploy time. If Sushi upgrades the proxy, re-run the
   fork suite before the next launch.

### Launch rules for mainnet

- The quote is any token the adapter reports `quoteSupported`
  (`SushiLaunchAdapter.sol:357-370`, which mirrors the venue's
  `quoteTokenPriceFeed(q) != 0`). The strategy checks it at init
  (`LaunchpadStrategy.sol:595`). TSLA, NVDA and SPCX have feeds on the venue
  today. The default is the vault asset (a USDG vault launches against USDG),
  which runs no swap leg.
- A quote other than the asset runs a swap leg through the allowlisted swap
  adapter (`LaunchpadStrategy.sol:731-741`), floored by the voted
  `minQuoteOut`. `executeProposal` is permissionless, so that floor is what a
  sandwich can take (G-4, F-1). The CLI guards that leg:
  - `minQuoteOut` = the swap adapter's quote for `assetIn` less the held-back
    fee, times (1 − `--max-slippage-bps`). The default is 50 bps and the
    maximum is 100; a higher value is refused, not clamped. A lower explicit
    `--min-quote-out` is refused.
  - Thin pool: the price impact of the full size against a 1-unit probe on the
    same route must not exceed `--max-slippage-bps`. A thinner pool is refused.
  - On Sushi, the quote at size may sit at most 300 bps under the output the
    venue's own asset and quote feeds imply.
  - `assetIn ≤ 3,500 bps × totalAssets`, the class bound. This caps the loss
    if the floor ever fails as a floor.
  - The venue's quote feed must have updated within 3 days, or the venue
    reverts `StalePriceFeedRound`. Stock feeds do not update on weekends or
    market holidays, so a stock-quoted launch may have to wait for the market.
  - The launch carries the same live deadline as an asset-quoted one: an
    explicit `--deadline`, otherwise the governor windows plus one day; 0 is
    no deadline. A non-zero deadline not in the future is refused at init and
    in `updateParams` (`DeadlineInPast`, #14). The "disarmed" design of CLI
    0.99.0, which proposed with `deadline = 1` so that only an `arm` step could
    make the launch executable, was dropped on 2026-10-22: the guardian fleet
    replays execute during review and blocked every disarmed launch as
    `SIMULATION_FAILED` (4663 proposal 6). `sherwood launchpad arm <strategy>`
    remains an optional tightening the proposer may send right before execute
    (`minQuoteOut` raised to a fresh floor, never lowered; a short deadline);
    `updateParams` is proposer-only and pre-execute (`LaunchpadStrategy.sol:639-641`).
- `minTokensOut >= reserveAmount`. The adapter reverts
  `ReserveFloorBelowReserve` at execute otherwise: a wasted vote, no capital at
  risk (F-7).
- `reserveAmount == minTokensOut`, both sized near the dev buy's expected
  output, so little surplus launch token reaches the vault in kind at settle
  (F-5). Sushi V2 has no quoter for the dev buy (the pool is created inside
  `launchAndBuy`); size from a measured launch (about 164.56M tokens per
  1,000 USDG at writing) and re-measure if Sushi reprices its opening.
- A keeper calls `collectFees` on a short cadence, so no fee lump accrues for
  a depositor to time (G-5, F-2). The keeper sweep shipped in sherwood#691.

Settle on a launch quoted in another token:

- The reserve is held in the launch token and the unclaimed remainder goes to
  the vault in kind, as on an asset-quoted launch.
- Leftover quote is dust or a donation: the venue consumes `quoteIn` in full.
  `_convertQuote` swaps it back to the asset at the in-tx quote less
  `settleSlippageBps`, and skips on failure (`LaunchpadStrategy.sol:1131-1155`).
- Creator fees arrive at the vault in the quote token and the launch token
  (`feeRecipient: vault()`, `LaunchpadStrategy.sol:770`). Nothing converts
  them to the asset, and v1 `totalAssets` books no value for them. Only a later
  governance batch can dispose of them.

These rules are enforced by the CLI (sherwood repo,
`cli/src/strategies/launchpad-template.ts` and `cli/src/commands/launchpad.ts`,
sherwood#693, CLI 0.99.0), not by the contracts. A proposer who encodes
calldata directly bypasses them; guardian review of the proposal is the
backstop, and `quoteToken` is fixed at clone init so a permissionless
`executeProposal` cannot change it afterwards. Enforcing the floor and the cap
on-chain is SHE-416. Finding ids refer to
`docs/launchpad/audit-2026-10-19-mainnet-readiness.md`.

## Tests

- `test/launchpad/SushiLaunchAdapter.t.sol`: 43 unit tests against
  `MockSushiLaunchpadV2`.
- `test/launchpad/fork/SushiLaunchAdapterFork.t.sol`: 9 tests against the live
  venue, public RPC.

## Follow-ups

- Sushi V4 (the CL-only PancakeSwap Infinity deployment, same addresses on every
  chain: Vault `0xeb4f1e157d18b1a4d09a5207a96e17601ea354b2`, CL Pool Manager
  `0x81d732702f87d2d652ae79e9f52bf44928eca210`, CL Position Manager
  `0xd3d35fbc4e44523ca3cd383c1948322ddb42f644`, CL Quoter
  `0x2a0819373b09ec553e7b15808f76601362b1c291`) is not used by the launchpad,
  whose pools are Sushi V3. A Sushi V4 swap adapter is a separate follow-up.
- Token metadata (logo, description, links) is set off-chain with an EIP-712
  signature from the current creator, verified through EIP-1271 when the
  creator is a contract. The clone implements no `isValidSignature`, so fund
  tokens launch without Sushi-side metadata. Adding it means deciding who may
  sign for the clone.
- `DISTRIBUTE_TO_HOLDERS`, above.
