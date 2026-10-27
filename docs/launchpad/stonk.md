# StonkBrokers Smart Launch V2

`StonkLaunchAdapter` fronts the StonkBrokers Smart Launch V2 pads on Robinhood
Chain (4663). It is an implementation plus one ERC-1167 clone per launch, the
same shape as `SushiLaunchAdapter`.

Status (2026-10-27): not deployed on 4663. The fast-follow PR is open; the
broadcast comes after review. The readiness review's F-4 is applied.

## Venue

One pad per quote lane. The adapter uses the eight V2 pads, which mint the
launch token:

| Lane | `StonkSafeLaunchpadV2` pad |
|---|---|
| WETH | `0xFCd61B25BbF3AbD6cf0070D6328E351cc30EEC9f` |
| STONK | `0x8f6782c5Aa37804d08a9b7bf3984Ff3245Fd6cD4` |
| USDG | `0xd4F20033586977A2511f4A2DB4aF7C79a340D70a` |
| GME | `0x4B9Dcd6CCFAeF0f6D23065Dd78E79d5E20ec8cFD` |
| NVDA | `0xEe96d955d5634813374ecE4C74F2C0ff71B1F9fB` |
| AAPL | `0xB0453A81Cbf963903409FFF18AD92941e1c7a864` |
| SPCX | `0x0c3b4EDED41696eFF0ed70841f132B519d81c947` |
| USO | `0xDb3C81C841ff88db6cDFbDDB0eE049D162A6053B` |
| `SafeLaunchLensV2` (curve reads; held, never called on-chain) | `0x25b5Df581f4b2Ed450203f375ad8A28b17F115B3` |

The addresses, with their identity evidence, are in
`script/launchpad/addresses-4663.json`. Each pad's `quote()` was matched to its
lane on 2026-08-28. Source is verified on Robinhood Blockscout
(`StonkSafeLaunchpadV2` and `SafeLaunchLensV2`, solc 0.8.24).

Parameters on every pad, as read on 2026-08-28: `launchFeeWei() == 0`,
`creatorFeeBps() == 1650`, `protocolFeeBps() == 1650`, `lpFeeBps() == 5000`.
If any pad ever charges a launch fee, `launch` reverts `NativeFeeUnsupported`
before any capital moves; serving it would need a new implementation.

There are also eight V3 pads, which take a bring-your-own token. Using only the
V2 pads is a choice (`docs/launchpad/design.md`), not a safety constraint.

There is no WOOD lane. A lane is a pad deployment, and no owner action adds a
lane to an existing pad. If the venue deployed a WOOD pad, serving it would need
a new implementation and a fresh grant.

## Why a clone per launch

The venue pins the creator at `createLaunch` and has no creator transfer. The
creator is the fee recipient and the only caller of `arm` and `abort`. A shared
singleton would be the permanent creator of every fund's launch, holding every
fee stream in one contract. So each launch gets its own clone, owned by the
calling strategy:

- The clone calls `createLaunch` and receives the whole supply.
- It sends `reserveAmount` to the owning strategy, then arms the rest.
- A dev buy is delivered straight to the strategy (`buy(..., owner)`).
- `collectFees` forwards the clone's whole balance of lane quote and launch
  token to the `feeRecipient` pinned at `initialize`. The strategy always sets
  that to `vault()`.

The lane set is fixed at construction and has no setter. `padSetHash =
keccak256(abi.encode(quotes, pads))` is the on-chain witness of that
configuration, because the counterparty grant snapshots the codehash and a
codehash cannot see storage. A new lane means a new implementation and a new
grant.

## `venueData`

`abi.encode(StonkLaunchAdapter.VenueData({...}))`. The fields are passed to the
pad, which enforces its own economics rules and reverts `BadEconomics`
otherwise:

| Field | Meaning |
|---|---|
| `supply` | total supply to mint, in wei |
| `startMcapUsd8`, `gradMcapUsd8` | starting and graduation market cap, 8-decimal USD |
| `startTaxBps`, `taxDecayPerMinuteBps` | opening trade tax and its per-minute decay; together they derive the curve window |
| `sellsEnabled` | whether the curve accepts sells |
| `bufferSecs` | opening anti-snipe shield: trades pay 99.99% tax while it runs; folded into the deadline |
| `unsoldMode` | unsold-supply disposition at graduation |
| `openEnded` | no closing deadline |
| `postTaxBps` | tax after the decay schedule ends |
| `bondVenue` | AMM `bond()` mints the locked LP on |
| `maxBuyPpm` | per-wallet buy cap, ppm of supply |

The F-4 rule. A launch that carries capital is a dev buy: `LaunchpadStrategy`
passes its whole post-swap quote balance as `quoteIn`. `arm` and `buy` run in
one transaction, so no time passes between them. Therefore:

- `bufferSecs` must be 0. Otherwise the dev buy would pay the 99.99% shield,
  and `executeLaunch` reverts `DevBuyInsideBuffer(bufferSecs)`.
- `minTokensOut` must be a non-zero floor quoted through the lens. Otherwise
  `executeLaunch` reverts `DevBuyWithoutFloor(quoteIn)`.

Both reverts fire before `createLaunch`, so no funds move. They do fire at
execute, after the vote, so a proposal that breaks the rule is a wasted vote.

With a zero buffer the dev buy fills at the curve's opening tax. The fork test
`test_fork_adapterDevBuy_refusedInsideTheBufferAndFilledAtTheOpeningTax`
observed this on the live WETH pad: `currentTaxBps == 1000 == startTaxBps` in
the buy's own block. The pad pushes the creator share of that tax back to the
clone during the buy, and `executeLaunch` forwards it to the vault (the pinned
`feeRecipient`) in the same transaction.

## Trust in the venue owner

The pad owner controls the fee split and the tax schedule bounds the pad
enforces. A fund launching here trusts that owner with its fee stream and with
the economics a launch is accepted under. It does not trust it with its
reserve, which reaches the strategy inside the launch transaction, or with the
vault's capital, which the venue never holds.

The pad makes `createLaunch`, `arm` and `buy` `nonReentrant`, and its token is a
plain ERC20 with no transfer hook (F-3 addendum, 2026-10-20, in
`docs/launchpad/audit-2026-10-19-mainnet-readiness.md`). The tax split's calls
into venue-owner contracts sit inside the venue-owner trust accepted under F-6.

`abort` is unreachable (G-6, Info, from the 2026-10-08 slice-G review, Linear
SHE-365). The clone's `abort` is owner-only, the owner is the strategy, and the
strategy never calls it. This is accepted as design. `Failed` is therefore not
a phase a fund launch reaches through this stack. A closed window is one
permissionless `graduate()` plus `bond()` away from a locked LP, which the
adapter reports as `Closing`.

## Quote support

`quoteSupported(q)` is true for the eight lane quotes: WETH, STONK, USDG, GME,
NVDA, AAPL, SPCX and USO. WOOD answers false. Ask the implementation: a clone
answers false for everything, because the lane map is implementation storage.

Stock lanes revert `StalePrice` on oracle gaps, such as weekends and market
holidays. The adapter lets that revert through unchanged on the dev buy. A
stock-quoted launch may have to wait for the market.

## Deploy

On a chain that already runs the Sushi-only ceremony, the Stonk fast-follow is
one script run:

```bash
forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
  --rpc-url robinhood --account sherwood-agent \
  --sender 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94 --broadcast --slow --sig 'runStonk()'
```

Dry run it first, without `--broadcast`. `runStonk()`:

- deploys `new StonkLaunchAdapter(quotes, pads, lens)` over the book's eight V2
  lanes and `SAFE_LAUNCH_LENS_V2`;
- grants the adapter (after its deploy, because the grant snapshots the
  codehash), the eight V2 pads and the lens with `setCounterpartyAllowed`. The
  grants run in-run when the broadcaster owns the TierRegistry, as
  `0x5A00…DF94` does on 4663, and are printed as owner transactions otherwise;
- records `STONK_LAUNCH_ADAPTER` and `_meta.stonkFastFollow` (`block`,
  `deployer`, `tierRegistry`, `lens`, `padSetHash`, `granted`) in
  `deployments/4663.json`. It never writes `_meta.launchpad`, so the Sushi
  ceremony's record stays whole;
- leaves the template, its factory approval, the Sushi adapter and the Sushi
  grants untouched.

It refuses a book that already holds `STONK_LAUNCH_ADAPTER` and a book without
`LAUNCHPAD_TEMPLATE` and `SUSHI_LAUNCH_ADAPTER`.

Afterwards, `--sig 'verify()'` is the chain's check, in place of
`verifySushi()`. A later fix to the adapter is `--sig 'redeployStonk()'`: it
deploys and grants a new adapter over the same lanes and prints, but does not
send, the revoke of the old one.

Record the printed `padSetHash` with the grant.

## Class certification

No new certification is owed. The template was class-certified at tier 0,
3,500 bps, on 2026-10-27 for `execute()` and `settle()` (see "Class
certification" in `docs/launchpad/sushi.md`). The certification is keyed to the
clone codehash, anchored to the template's, and the selector; the fast-follow
changes neither. The template binds any granted adapter at clone-init. A Stonk
launch prices at tier 0 like a Sushi one: coverage and the proposer bond are
sized on 35% of `assetIn`.

That bound was argued for Sushi on a fee-sized honest-case loss. On Stonk the
honest-case loss is the opening tax: F-4 makes the dev buy fill at
`startTaxBps` (elapsed time is zero), and the pad accepts `startTaxBps` up to
9,900. A launch with a high opening tax would lose most of its capital to tax
by design, with only the 16.5% creator share coming back to the vault. The
launch rule below caps it; the contracts do not.

## Launch rules for mainnet

- The F-4 rule above: with a dev buy, `bufferSecs == 0` and a non-zero,
  lens-quoted `minTokensOut`. Every capitalised Stonk launch is a dev buy.
- `startTaxBps` is the dev buy's loss, paid in the launch transaction. Keep it
  at or below 1,000 bps (the value the Stonk fork suite launches with) until
  the CLI enforces a ceiling; a 3,500 bps opening tax would eat the
  whole tier bound before the curve opens.
- `reserveAmount` is minted to the fund for free before `arm`; `minTokensOut`
  floors only the dev buy. So the Sushi rule `minTokensOut >= reserveAmount`
  (F-7) does not apply here, and nothing reverts if they differ.
- The dev buy's tokens land on the strategy on top of the reserve. The strategy
  records `reserve = reserveAmount`, so those tokens are F-5's surplus and reach
  the vault in kind at settle. Size the dev buy with that in mind.
- Quote all curve numbers through the lens. The tax changes every minute.
- The stock-lane `StalePrice` behaviour is unchanged (see Quote support).
- The template-level rules (swap leg guardrails, the 3,500 bps `assetIn` cap,
  the live deadline, the keeper sweep) apply unchanged. See "Launch rules for
  mainnet" in `docs/launchpad/sushi.md`.

These rules are enforced by the CLI, not by the contracts, except the two F-4
reverts. Finding ids refer to
`docs/launchpad/audit-2026-10-19-mainnet-readiness.md`.

## Tests

- `test/launchpad/StonkLaunchAdapter.t.sol`: 65 unit tests against a mock pad,
  including `test_RevertWhen_DevBuyHasNoFloor_NoFundsMove` and
  `test_RevertWhen_DevBuyInsideTheOpeningBuffer_NoFundsMove`.
- `test/launchpad/fork/StonkLaunchRobinhoodFork.t.sol`: 11 tests against the
  live pads, public RPC.
- `test/launchpad/fork/DeployLaunchpadStrategyFork.t.sol`: 31 deploy rehearsal
  tests, including `test_runStonk_fastFollowCompletesOnA4663Fork` and
  `test_runStonk_refusesABookThatAlreadyHoldsAStonkAdapter`.

The adapter is readiness-reviewed, not audited.

## Follow-ups

- The CLI encoder must refuse a dev buy with `bufferSecs != 0` or
  `minTokensOut == 0`, and cap `startTaxBps` (1,000 bps is the working ceiling),
  so the proposal never reaches a vote.
- Consumer sync once the adapter is deployed: CLI, SDK, app, skill, docs and
  address pointers need `STONK_LAUNCH_ADAPTER`.
- `deployments/README.md` and `docs/launchpad/design.md` say no Stonk adapter
  is deployed on 4663; update them with the broadcast.
