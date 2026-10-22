# Pons

`PonsLaunchAdapter` fronts the Pons launch venue (`PonsLaunchFactory` v2 and its
`PonsLaunchLocker`) on Robinhood Chain (4663). It moved here from
sherwood-protocol#282.

**It is inert on mainnet today.** Every launch reverts at the venue until Pons
opens its launcher gate for us. See [The gate](#the-gate).

## Venue

| | Address |
|---|---|
| `PonsLaunchFactory` v2 (the active one) | `0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB` |
| `PonsLaunchLocker` v2 (`factory.locker()`) | `0x736D76699C26D0d966744cAe304C000d471f7F35` |
| Owner of both, and the locker's `protocolFeeRecipient` | `0x263ed295dAFaE1d9AAdD6E56c4B6F9f38eE019Dd` |
| Legacy v1 factory (out of scope, same gate, same owner) | `0x0c37a24F5D23A486FA692d1500881d698B1F77a4` |
| WETH (config 0's `pairToken`) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Dex config 0: canonical Uniswap V3 factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| Dex config 0: position manager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| Dex config 0: swap router | `0xCaf681a66D020601342297493863E78C959E5cb2` |

Both venue contracts are verified on `robinhoodchain.blockscout.com` (solc
0.8.30). Neither is a proxy: they hold 24 KB and 5 KB of runtime code and the
EIP-1967 implementation slot is empty. The factory and locker name each other
(`factory.locker()` and `locker.factory()`), which the adapter's constructor
checks.

Live state (2026-08-31, re-read 2026-09-22 at block ~69.86M):

- `launchEnabled() == false`.
- `launchFee() == 5e14` wei of native.
- One launch config and one dex config. Launch config 0 is `{pairToken: WETH,
  graduationThreshold: 4.2e18, initialTick: -204200, supply: 1e27,
  maxWalletBps: 500, maxTxBps: 550, restrictionBlocks: 2, reservedFee: 0,
  enabled: true, routerRequiresDeadline: false}`. Dex config 0 is `uniswap v3`,
  1% fee tier, tick spacing 200.
- `locker.protocolFeeShare() == 30` (percent).

## The gate

`launchToken` opens with

```solidity
if (!launchEnabled && !whitelistedLaunchers[msg.sender]) revert NotWhitelisted();
```

and `launchEnabled()` is false. Until Pons either flips that flag or whitelists
the adapter's address, `launch` validates everything it can and then reverts
`NotWhitelisted()` at the venue before anything moves. The v1 factory has the
same gate under the same owner, so it is no way around this. Nothing on our side
can lift the gate. Our `TierRegistry` allowlist does not.

Either Pons action opens it:

- `setWhitelistedLauncher(<PonsLaunchAdapter>, true)`. Scoped to our adapter,
  but it pins the adapter's address, so every redeploy needs a fresh approval
  from Pons.
- `setLaunchEnabled(true)`. Opens launching to everyone and leaves our deploy
  cadence independent of theirs.

#282 disagrees with itself on which to prefer: its runbook calls the whitelist
"preferred, scoped", while its task list prefers `launchEnabled` for the cadence
reason. Both work. The fork suite proves each one
(`test_gate_blocksUntilPonsWhitelistsTheAdapter`,
`test_gate_alsoOpensWhenPonsFlipsLaunchEnabled`) by pranking the factory owner.

The gate also fixes the adapter's shape. The whitelist is per address, so
per-launch clones would each need their own Pons approval, in the middle of a
governance execution. The adapter is therefore one stateless singleton,
whitelisted once, allowlisted once, serving every fund.

## `feeWallet` does double duty

Inside `launchToken`, the one field `params.feeWallet` decides two things:

- `initialBuyRecipient = feeWallet == 0 ? msg.sender : feeWallet`: who receives
  the dev buy. The whole supply goes into a one-sided V3 position that the
  locker holds and locks, so the creator gets zero tokens and the dev buy is the
  fund's entire reserve.
- `locker.setFeeRedirect(token, feeWallet)`: where LP fees are paid.

The template needs those at different addresses. The reserve belongs to the
calling strategy, where holders claim it pro rata. The fee stream belongs to the
vault (`LaunchParams.feeRecipient`), so fees never enter strategy custody.

`launch` splits them in one transaction:

1. `launchToken` with `feeWallet = msg.sender`, the strategy. The venue delivers
   the dev buy straight to the strategy, so it is never an adapter balance.
2. Immediately after, `locker.setFeeRedirect(token, p.feeRecipient)`, which the
   locker allows because it authorises `launched.deployer`, and the deployer is
   the adapter. The adapter then reads `feeRedirects(token)` back and reverts
   `FeeRedirectNotApplied` if it is not the vault.

Swap the order and there is nothing to redirect yet. Drop step 2 and the vault
never sees a fee. Name the vault in step 1 and the reserve lands where holders
cannot claim it.

## The residual `deployer` power, and why it is contained

The adapter is `launched.deployer` of every launch it issues, permanently. The
locker offers no way to transfer or renounce that role, so the adapter could in
principle re-point any of those fee streams, and the venue would allow it.
Handing the role to the vault, which the Sushi Launchpad V1 adapter did with
`transferCreator`, is not available here.

The custody invariant holds because the adapter exposes no path to use the
power:

- `setFeeRedirect` is called exactly once, inside `launch`, with the
  caller-supplied `p.feeRecipient`. No other function reaches the locker's
  redirect.
- `collectFees` calls the locker's `collectFees` and nothing else. The payee is
  whatever the locker has stored, so any caller can drive it and no caller can
  steer it.
- There is no owner, no admin function, no arbitrary-call sink, no
  `delegatecall`, no upgrade path, and no storage. Factory, locker and WETH are
  immutables.

A compromise would therefore have to be a change of code, and a consuming
strategy notices one. `LaunchpadStrategy` admits the adapter only while
`TierRegistry.isCounterpartyAllowed(adapter)` holds, at init and again at
execute. That check compares the adapter's live codehash with the one
snapshotted at `setCounterpartyAllowed`, and the immutables are part of the
codehash. Every counterparty a v1 strategy binds rests on the same assumption.

Both suites test the narrower claim directly
(`test_NoExternalPathRepointsTheFeeRedirectAfterLaunch`,
`test_launch_noExternalPathRepointsTheFeeRedirect`): every adapter verb is
driven by an attacker, the redirect does not move, and the locker refuses the
strategy and outsiders directly.

## Venue facts that changed the code

Building against the verified source turned up four facts that the venue docs
did not give, and each one changed code:

1. **`Socials` has five members, not four** (`twitter`, `telegram`, `discord`,
   `website`, `farcaster`). The arity is part of the `launchToken` selector and
   of the CREATE2 init-code hash, so a four-string guess compiles to a selector
   the deployed factory does not have.
2. **The venue enforces no slippage floor.** The factory passes
   `amountOutMinimum: 0` on the dev buy. The adapter's post-launch balance
   check (`SlippageFloorNotMet`) is the only protection for `p.minTokensOut`,
   the reverse of Sushi, where the venue's own floor fires first. `launch` also
   requires `minTokensOut >= reserveAmount` up front.
3. **A CREATE2 collision is a cross-fund hazard for a singleton.** The token
   address derives from the metadata, the config and the deployer, and a shared
   adapter is one deployer. Two funds with the same name, symbol and salt would
   predict the same address and the second would revert `PoolAlreadyExists`.
   The adapter hashes the caller into the salt
   (`keccak256(abi.encode(msg.sender, v.salt))`), so each strategy has its own
   salt space and no fund can squat another's launch.
4. **The locker returns the gross and pays the net.** `collectFees` returns the
   whole V3 `collect`, then keeps the 30% protocol share before paying the
   recipient. The adapter reports the vault's balance deltas, never the return
   tuple, which would overstate the fund's take by exactly Pons's cut.

Other facts the adapter relies on:

- The dev buy is funded in native: `initialBuyAmount = msg.value - launchFee`.
  The adapter pulls `p.quoteIn + launchFee()` of WETH from the caller, unwraps
  all of it and forwards it as one `msg.value`. The strategy attaches no value.
  This is also why the quote must be WETH (below).
- `getLaunchedToken` does not revert on an unknown token. It returns a zero
  struct with `exists == false`. `graduationStatus` is the one that reverts.
  `phase` reads `getLaunchedToken` by length-checked staticcall and also
  requires `deployer == address(this)`, so Pons launches made by anyone else
  report `None`.
- Graduation (paired principal crossing `graduationThreshold`) is a Pons-side
  milestone, not a lifecycle phase. The pool is tradable before and after it.
  An issued launch is `Live` from its first block, and `finalize` is a no-op.
- The launch's own dev buy already accrues LP fees, so the first `collectFees`
  after launch pays the vault.
- `maxWalletBps` does not cap the reserve: the factory exempts the atomic
  launch buy for that one call.
- `collectFees` at the locker admits only its owner, the launch's deployer, the
  current recipient or an allowlisted collector. The adapter is the deployer,
  so driving it through the adapter is permissionless on our side. The adapter
  returns `(0, 0)` instead of reverting on `NoFeesToCollect()`, an unknown ref,
  or a redirect that reads back as zero or as the adapter.

## `venueData`

`abi.encode(PonsLaunchAdapter.VenueData({launchConfigId, dexId, salt}))`,
exactly 96 bytes. The ids are proposal parameters, not pinned, so a new Pons
pairing is reachable without a redeploy. `launch` validates all of them before
any transfer: config in range, enabled, `pairToken == p.quoteToken`; dex in
range, enabled, router set. The venue's own `RouterNotSet` fires only after the
token has been minted. `salt` only needs to tell one fund's retries apart,
because the adapter namespaces it by caller.

## Quote support

`quoteSupported(q)` is true only when both of these hold:

1. **The venue's gate:** some enabled launch config has `pairToken == q`. This
   is read live, with the scan bounded at 256 configs and failing closed. Only
   WETH is configured today, so USDG, WOOD or a stock token would become
   possible through a Pons configuration change alone.
2. **This adapter's own limit:** `q` is the wrapped native. The venue funds the
   dev buy from `msg.value`, so a non-native pairing cannot be funded from a
   strategy's ERC-20 holdings. If Pons adds one, the fix is a new adapter, not
   an internal swap inside `launch`.

`nativeFeeSource()` returns `(WETH, launchFee())`, read live. It names only the
fee. The caller approves the adapter for `p.quoteIn + fee` of WETH, which is
one allowance because both legs are the same token.

## Deploy

The deploy script lives on the LaunchpadStrategy branch and is not part of this
port. For Pons it must add the following.

**Address book** (from #282's `addresses/4663.json` and `chains/4663.json`
diff):

| Key | Address |
|---|---|
| `PONS_LAUNCH_FACTORY_V2` | `0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB` |
| `PONS_LAUNCH_LOCKER_V2` | `0x736D76699C26D0d966744cAe304C000d471f7F35` |
| `WETH` (already present) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `PONS_LAUNCH_ADAPTER` (written by the script) | the deployed adapter |

**Pre-broadcast identity check.** #282's `_assertIsPonsFactory` did this, and
the port should keep it:

- Both addresses hold code.
- `factory.locker()`, read by raw staticcall so a non-Pons address fails with a
  message instead of a decode panic, returns exactly 32 bytes equal to
  `PONS_LAUNCH_LOCKER_V2`.
- `locker.factory() == PONS_LAUNCH_FACTORY_V2`.
- `launchConfigCount() != 0` and `dexConfigCount() != 0`.
- `getLaunchConfig(0).pairToken == WETH` and `getLaunchConfig(0).enabled`.
  Without this, the adapter's constructor reverts `InvalidWeth` with no
  explanation.

#282 made Pons optional: if either key was missing, the script printed a note
and skipped the Pons adapter so the other venues could still ship. Keep that
behaviour if the ported script deploys several venues together.

**Deploy:**

```solidity
new PonsLaunchAdapter(
    0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB, // factory_
    0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73  // weth_
);
```

The constructor reads the locker from the factory, checks that the locker names
the factory back (`InvalidFactory` / `InvalidLocker`), and checks that WETH is
the `pairToken` of some enabled config (`InvalidWeth`). No other arguments, no
owner, nothing to initialize.

**Our approvals** (TierRegistry owner, printed as a runbook, not executed):

1. `TierRegistry.setCounterpartyAllowed(<PonsLaunchAdapter>, true)`. This is the
   one that gates. `LaunchpadStrategy` reverts `LaunchAdapterNotAllowed` at init
   and execute without it. Grant it after the final deploy, because the grant
   snapshots the codehash.
2. `TierRegistry.setCounterpartyAllowed(0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB, true)`
   for the factory, which `launchTarget()` names. This gives the venue its
   counterparty standing, following the `ILaunchAdapter` convention and the
   Sushi deploy. Nothing on the v1 launch path reads it today, since the
   strategy never calls the factory, so it is bookkeeping rather than a gate.
   The locker's standing follows from the factory's through the round trip
   above.
3. `StrategyFactory.setTemplateApproval(LaunchpadStrategy, true)`, if not done
   already for the other venues.

**The Pons-side ask** (only the factory owner `0x263ed295…19Dd` can do it). The
script should print this prominently, because until it happens the adapter is
deployed but inert:

- `setWhitelistedLauncher(<PonsLaunchAdapter>, true)`, or
- `setLaunchEnabled(true)`.

Verify before announcing the venue:

```bash
cast call 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB 'launchEnabled()(bool)' --rpc-url $ROBINHOOD_RPC_URL
cast call 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB 'whitelistedLaunchers(address)(bool)' <adapter> --rpc-url $ROBINHOOD_RPC_URL
cast call <TIER_REGISTRY> 'isCounterpartyAllowed(address)(bool)' <adapter> --rpc-url $ROBINHOOD_RPC_URL
```

## Tests

- `test/launchpad/PonsLaunchAdapter.t.sol`: 38 unit tests against
  `MockPonsFactory` / `MockPonsLocker`.
- `test/launchpad/fork/PonsLaunchAdapterFork.t.sol`: 9 tests against the live
  venue over the public RPC. They prank the factory owner to open the gate, and
  first assert that the gate is closed without that prank.

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-contract PonsLaunchAdapterForkTest -vv
```

`ROBINHOOD_FORK_BLOCK` pins a block (unset means latest). The public RPC keeps
only a short window of state, so no pin is written into the file.
