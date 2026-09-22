# Lighter integration — testing against the real venue

How to exercise `LighterPerpStrategy` against the **real** ZkLighter contract before
anything ships to 4663: on a fork of Robinhood mainnet (the public RPC, or the Tenderly
vnet, chain 9994663), and live on 4663 with the canary harness.

> **Status after the v1 port.** The venue-level facts below (§1–§3) do not depend on the
> protocol version and still hold; `script/lighter/LighterSlotProbe.s.sol` re-checks the
> maturity-slot derivation against live 4663 state. The v1 template ceremony is §4. The
> full lifecycle bench (§5) was written against — and proven on — the **post-audit** stack
> deployed on vnet a3fb16 and has **not been ported**; §5 records what it proved and what a
> v1 bench needs.

## 1. Why a fork works for Lighter

A fork of Robinhood mainnet carries the real ZkLighter rollup contract:

| Fact | Value |
|---|---|
| ZkLighter proxy | `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d` |
| `desertMode()` | `false` |
| USDG asset index | `tokenToAssetIndex(USDG) = 3` (checked by `DeployLighterTemplate --sig 'checkVenue()'`) |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6 dp) |
| Mainnet canary harness | `0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E` (account 623) |

These constants are recorded in `script/lighter/addresses-4663.json`.

**The split that matters:** Lighter's off-chain sequencer does **not** watch a fork. L1-side
effects work for real; L2-side effects never arrive on their own.

| Works on a fork (real contract) | Never happens on a fork |
|---|---|
| `deposit` (pulls USDG, registers the account — `addressToAccountIndex` is synchronous) | order fills / positions / PnL |
| `changePubKey` (key registration enqueues) | L2 balance credits |
| `createOrder` / `cancelAllOrders` / `withdraw` (priority requests enqueue + emit) | `pendingBalance` maturing by itself |
| `withdrawPendingBalance` (real USDG transfer — the forked contract holds real TVL) | anything driven by the API/sequencer |

API-driven trading (the agent leg) is tested separately against the `rh-testnet` Lighter
domain (see `test/lighter/harness/LighterCanary.md` §keygen/trade) — a fork is the bench for
the **contract/custody** half.

**Proof that a guardrail reached the venue.** On a fork a no-op and a success are
indistinguishable from the return value, because the sequencer never answers. Count the
venue's own priority-queue event instead: `NewPriorityRequest`, topic0
`0xefdd379e3e15772fcc7d2a67fa5bbb0790b932724153aded4648307094733b2f` (taken off a real
receipt; `IZkLighter` does not declare it). Expect 1 per `CANCEL_ALL`, 1 per
`changePubKey`, `1 + 2 × markets` per `initiateReturn`, 1 per `queueWithdraw`.

## 2. Simulating withdrawal maturity (the one missing L2 effect)

A withdraw only becomes claimable when the sequencer's batch executes, which never happens
on a fork. Simulate it by writing the venue's own storage:

- Pending claims live in `pendingAssetBalances[assetIndex][masterAccountIndex]
  .balanceToWithdraw` (`ExtendableStorage` in the verified ZkLighter source).
- **The base slot is 498, and `balanceToWithdraw` is at offset 0.** Derived, not guessed:
  `script/lighter/LighterSlotProbe.s.sol` runs `vm.record()` around a real
  `getPendingBalance(owner, 3)` and checks that the derived slot is among the SLOADs.
  (`debug_traceCall` is **not supported** on the Tenderly vnets — `-32002` — which is why
  the probe uses `vm.record`.)

```
slot = keccak256( accountIndex || keccak256( assetIndex || 498 ) )
```

```bash
# Re-check the derivation against live 4663 (read-only; account 623 is registered).
forge script script/lighter/LighterSlotProbe.s.sol:LighterSlotProbe \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

`LighterSlotProbe.pendingSlot(accountIndex)` computes the slot. On a Tenderly vnet write it
with `tenderly_setStorageAt`; in a `forge test --fork-url` suite, with `vm.store`:

```bash
cast rpc tenderly_setStorageAt $ZK_LIGHTER <slot> <ticksAsBytes32> \
  --rpc-url "$TENDERLY_ROBINHOOD_RPC_URL"   # params positional — never a JSON array
```

After the write, `getPendingBalance(owner, 3)` returns the ticks and
`withdrawPendingBalance(owner, 3, ticks)` pays real forked USDG — the full claim path
executes for real. **The cheat fabricates value**: ticks the venue was never funded for are
paid out of the fork's real TVL, so a vault that settles against them books a gain nobody
deposited (and pays a real performance fee on it). Read settle deltas with that in mind.

## 3. Smoke test with the canary harness

The mainnet canary harness is replayed on any fork with its USDG and account 623. On a
Tenderly vnet the admin RPC accepts `eth_sendTransaction` from any sender, so impersonate
its owner and drive the real venue for free:

```bash
export RPC=<admin rpc>   # TENDERLY_ROBINHOOD_RPC_URL
H=0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E
OWNER=0xC37037e2A9c8Eb30cB9D8021C6c85D299f2B8b95

cast rpc tenderly_setBalance "[\"$OWNER\"]" 0xDE0B6B3A7640000 --rpc-url $RPC
cast send $H "depositUSDG(uint256)" 19979840 --rpc-url $RPC --unlocked --from $OWNER
cast call $H "accountIndex()(uint48)" --rpc-url $RPC        # still 623
cast send $H "initiateWithdraw(uint64)" 19979840 --rpc-url $RPC --unlocked --from $OWNER
# -> priority request enqueued; then simulate maturity (§2) and claim:
cast send $H "claim(uint128)" <ticks> --rpc-url $RPC --unlocked --from $OWNER
cast call $H "usdgBalance()(uint256)" --rpc-url $RPC
```

Fresh deploys of the harness: `forge script
script/lighter/DeployLighterCanary.s.sol:DeployLighterCanary --rpc-url <rpc> --unlocked
--sender <funded addr> --broadcast --slow`.

## 4. Registering the template (v1)

`script/lighter/DeployLighterTemplate.s.sol` does the whole v1 ceremony in **one**
broadcast: deploy the template, `StrategyFactory.setTemplateApproval(template, true)`,
`TierRegistry.setCounterpartyAllowed(ZK_LIGHTER, true)`. It reads `STRATEGY_FACTORY` and
`TIER_REGISTRY` from the env, falling back to `lib/sherwood-protocol/chains/{chainId}.json`.

```bash
# Read-only pre-flight; works on 4663 today.
forge script script/lighter/DeployLighterTemplate.s.sol:DeployLighterTemplate \
  --sig 'checkVenue()' --rpc-url https://rpc.mainnet.chain.robinhood.com

# Tenderly vnet. --slow IS MANDATORY under --unlocked (below).
forge script script/lighter/DeployLighterTemplate.s.sol:DeployLighterTemplate \
  --rpc-url "$TENDERLY_ROBINHOOD_RPC_URL" --unlocked --sender <factory+registry owner> \
  --broadcast --slow
```

> **`--slow` or the ceremony approves the wrong address.** Under `--unlocked` forge
> pipelines the batch into `eth_sendTransaction` and the NODE assigns nonces, so the
> CREATE need not land on the nonce the simulation assumed. Hit for real on 2026-08-22 on
> the post-audit script: `setTemplateApproval` approved the **simulated** address (no code).
> Recovery is `setTemplateApproval(<phantom>, false)` then a re-run with `--slow`.

`run()` asserts before it spends anything: the chain is 4663 or 9994663 (46630 is **not**
valid — Lighter has no deployment there), `ZK_LIGHTER` answers `tokenToAssetIndex(USDG) == 3`,
and `TierRegistry.strategyFactory()` is the factory being approved on (otherwise clones from
it are not registered strategies as far as the vault can tell). After the broadcast it checks
the template's runtime size against Robinhood's 98,304-byte `MaxCodeSize`. Any owner-gated
step the broadcaster cannot perform degrades to a `RUNBOOK:` console line — read the log —
and the run prints `INCOMPLETE`. The template address is printed; record it, since this repo
does not patch the protocol's address book.

**`setCounterpartyAllowed` is mandatory and skipping it is silent** until the first
clone-init reverts `CounterpartyNotAllowed`. The registry snapshots the venue's codehash at
grant; re-grant after any Lighter *redeploy* (a proxy *upgrade* does not change the codehash
and so does not drop the grant — review it anyway).

**Nothing is certified, deliberately.** `execute()` and `settle()` must resolve to the
uncertified `(tier 2, 10_000 bps)` default, so a proposal's `requiredCoverage` is the full
notional of every cap across both legs. The script requires it:

```bash
cast call "$TIERS" 'classTierOf(address,bytes4)(uint8,uint16)' "$TEMPLATE" 0x61461954  # execute() -> 2 10000
cast call "$TIERS" 'classTierOf(address,bytes4)(uint8,uint16)' "$TEMPLATE" 0x11da60b4  # settle()  -> 2 10000
cast call "$SFACTORY" 'approvedTemplate(address)(bool)' "$TEMPLATE"                     # -> true
cast call "$TIERS" 'isCounterpartyAllowed(address)(bool)' 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d  # -> true
```

**What the post-audit ceremony did that v1 does not need.** It certified the inert `name()`
selector at tier 0 / bound 1 to mint the class anchor that `setClassAllowed` required, then
ran a second `finalize()` after `certifyDelay`. v1 deleted the class-allow axis — the vault
admits a clone because the factory registered it — so the anchor, `finalize()` and the
three-day wait are gone.

**Retiring a template.** `setTemplateApproval(old, false)` stops new clones
(`TemplateNotApproved`); clones already minted stay registered and settle normally.
`setCounterpartyAllowed(ZK_LIGHTER, false)` is the instant, template-wide stop for NEW
deployments: every clone-init and every execute reverts, while the exit path is untouched.

## 5. Full strategy lifecycle — NOT PORTED

**What existed.** sherwood-protocol PR #3 shipped `script/fork/LighterForkBench.s.sol` and
`script/fork/lighter-bench.sh`: a phased broadcast bench that created a USDG fund, cloned and
proposed, LP-voted, guardian-approved, executed, exercised every guardrail, removed the agent
and unwound from the vault owner, simulated maturity (§2), settled, and drove the residue
path. It ran against the **post-audit stack deployed on vnet a3fb16** — it read that stack's
governor, guardian registry, exposure ledger and a named bench vault out of
`chains/9994663.json`, and it needed Tenderly admin cheats (`evm_increaseTime`,
`tenderly_setStorageAt`, `--unlocked`).

**Why it is not here.** Every one of those dependencies is protocol-version-specific, and
several of its phases (`residue`, `queueRest`'s `collectResidue`, `hasUnvaluedResidue`
assertions) test machinery v1 deleted. Porting it means rewriting it against a deployed v1
stack, which is a separate piece of work.

**What it proved on 2026-08-22 (post-audit, historical):**

| pid | declared | **deployed** | what it proved |
|---|---|---|---|
| 4 | 2,000e6 | **1,239,622,687** | **coverage scaling**: `effectiveMaxCapital / maxCapital` was `6,507,989,262 / 10,499,951,846`; `execute()` deployed the scaled figure instead of reverting `CallCapExceeded` |
| 5 | 2,000e6 | **2,000,000,000** | **fully covered**: `deployedAmount == depositAmount` |
| 6 | 2,000e6 | **2,000,000,000** | the **liveness** leg: after `removeAgent(proposer)` the proposer lost every door (`ProposerNoLongerAgent` on `updateParams`, `NotAuthorized` elsewhere) and the vault owner kept every one, each proven by `NewPriorityRequest`; an outsider then settled |

The strategy-side behaviour those rows cover is unchanged by the port and is pinned by unit
tests (`LighterPerpStrategyCoverageTest`, `LighterPerpStrategyAuthTest`). What was proven
**only** on that stack, and is therefore open for v1: the real governor's scaling and cap
metering against this template, the real vault's batch guard admitting the clone, and a real
end-to-end settle.

**What a v1 bench needs**, in the order the old one hit them (the post-audit gotchas that
are about the fork rather than the stack):

1. A deployed v1 core on the fork with `STRATEGY_FACTORY` / `TIER_REGISTRY` in its address
   book, and §4 run against it.
2. A USDG fund. The fund's ERC-4626 asset **must be USDG** (`AssetMismatch`).
3. Clone via `cloneAndInitDeterministic` with an explicit `depositAmount`. A skipped §4
   surfaces here as `CounterpartyNotAllowed` / `TierRegistryUnresolved`.
4. Guardian coverage for `2 × deployAmount`, or accept a scaled execute and assert
   `deployedAmount == mulDiv(depositAmount, effectiveMaxCapital, maxCapital)` — one
   statement that covers both regimes.
5. **Fork clock quirks** (observed on the Tenderly vnet, independent of protocol version):
   - `vote` weighs `getPastVotes(voter, snapshotTimestamp)`, so an LP vote in the propose
     block weighs zero — it needs its own later transaction.
   - `block.number` as contracts see it is not the counter `evm_increaseTime` moves;
     `_settle`'s `block.number <= returnsInitiatedAt` guard clears on real seconds. Retry
     the settle, and drive it with `cast` rather than a forked forge run.
   - even the proposer waits `MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE` (1h) before
     `settleProposal`.
6. Guardian-stack specifics from the old bench (stake age at propose, pledge retirement
   between legs) were measured on post-audit and need re-checking against v1's
   `GuardianRegistry` / `ExposureLedger` before being relied on.

What no fork bench can prove — real fills, funding, API-leg behaviour — is covered by the
rh-testnet API loop and the small-notional 4663 canaries. **H2 is CLOSED, both directions
(2026-08-23 long, 2026-08-26 short):** the 4663 canary
(`test/lighter/harness/LighterH2Canary.md`) proved every cell of the ordered close pair on
real filled positions on account 623. The both-side close is sound as written.
