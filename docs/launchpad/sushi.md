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

## Quote support

`quoteSupported(q)` is `quoteTokenPriceFeed(q) != 0` on the venue. At writing,
USDG and WETH are registered and WOOD is not. WOOD becomes launchable the moment
Sushi registers a WOOD/USD feed, with no change here. A supported quote can
still be refused at launch if its feed's latest round is older than the venue's
3-day bound (`StalePriceFeedRound`).

## Deploy

1. `new SushiLaunchAdapter(0xF1716eBf85836ffE2985db9A50dd29e5814caBe9)`. The
   constructor reads `WETH()` from the venue and locks the implementation's
   initializer.
2. `TierRegistry.setCounterpartyAllowed(adapter, true)`. The strategy gates the
   adapter on this.
3. `TierRegistry.setCounterpartyAllowed(0xF1716eBf…caBe9, true)` for the venue.
4. Record `implementationVersion()`, `implementationRevision()` and the
   implementation slot at deploy time. If Sushi upgrades the proxy, re-run the
   fork suite before the next launch.

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
