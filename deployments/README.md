# Deployments

One file per chain, `<chainid>.json`, naming what this repo deployed there. The deploy scripts write these files on a real broadcast (`forge script ... --broadcast`), never on a dry run or in tests. Commit each file together with the `broadcast/` log of the run that produced it.

The format matches the protocol's `chains/<chainid>.json`: flat `KEY: address` pairs, so consumers (the CLI's address overrides) read both files the same way. Provenance sits under `_meta.<script>` and is not an address.

| Key | Contract | Script |
| --- | --- | --- |
| `LAUNCHPAD_TEMPLATE` | `LaunchpadStrategy` template | `script/launchpad/DeployLaunchpadStrategy.s.sol` |
| `STONK_LAUNCH_ADAPTER` | `StonkLaunchAdapter` implementation | same |
| `SUSHI_LAUNCH_ADAPTER` | `SushiLaunchAdapter` implementation | same |
| `LIGHTER_PERP_TEMPLATE` | `LighterPerpStrategy` template | `script/lighter/DeployLighterTemplate.s.sol` |

`_meta.launchpad` records the block, deployer, the protocol singletons used, the Stonk `padSetHash`, the Sushi launchpad's ERC-1967 implementation at deploy, and whether the owner steps (grants, template approval) landed in the same run. `_meta.lighter` records the same minus the venue fields. A Stonk fast-follow (`--sig 'runStonk()'`) records its hash under `_meta.stonkFastFollow.padSetHash` instead, with `block`, `deployer`, `tierRegistry`, `lens` and `granted`, and leaves `_meta.launchpad` alone.

`STONK_LAUNCH_ADAPTER` may be absent on a chain. A Sushi-only ceremony (`--sig 'runSushi()'`) records only `LAUNCHPAD_TEMPLATE` and `SUSHI_LAUNCH_ADAPTER`, and its `_meta.launchpad` has no `stonkPadSetHash`. Verify such a chain with `--sig 'verifySushi()'`; `verify()` requires every Stonk counterparty, so it fails there by design. Stonk arrives on such a chain through the fast-follow `--sig 'runStonk()'`, which records `STONK_LAUNCH_ADAPTER`; from then on `verify()` is the chain's check.

On 4663 the launchpad script reads the protocol singletons from the env first, then `lib/sherwood-protocol/chains/4663.json`, then `script/launchpad/addresses-4663.json`, which carries them with provenance (F-9 in `docs/launchpad/audit-2026-10-19-mainnet-readiness.md`):

| Key | 4663 address |
| --- | --- |
| `TIER_REGISTRY` | `0x4614f058920941A0a9a852e62485fbDE692D75E1` |
| `STRATEGY_FACTORY` | `0xb06788F027268a9A06c3AD41a88559530D2E54b1` |
| `UNISWAP_SWAP_ADAPTER` | `0x54e6a7af53143556973493fdec9d7837a77c67ef` |

Check a recorded deployment against the chain without redeploying:

```bash
forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy --rpc-url <rpc> --sig 'verify()'
forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy --rpc-url <rpc> --sig 'verifySushi()'
forge script script/lighter/DeployLighterTemplate.s.sol:DeployLighterTemplate --rpc-url <rpc> --sig 'verify()'
```

Verification treats owner steps as facts: a deployment still owed Safe transactions fails it until they land.

On Robinhood mainnet 4663, `deployments/4663.json` holds the Lighter template (`LIGHTER_PERP_TEMPLATE`, block 93,563,127) and, since 2026-10-20, the Sushi-only launchpad ceremony: `LAUNCHPAD_TEMPLATE` `0xbc4fDF5949caa74c730bed632E368cEa4ea5832D` and `SUSHI_LAUNCH_ADAPTER` `0x52901614748ACFDC083D305Aa5301E484d4B15F8`, blocks 93,737,582 to 93,737,603, broadcast by the registry and factory owner so the grants and the approval were performed in-run (`_meta.launchpad.ownerStepsComplete` is script-written `true`). On 2026-10-22 the template was replaced by `0x1F8221c4176B8B017A6Ef699947BB4A33730Df32` (block 95,339,932, `--sig 'redeploySushiTemplate()'`, the `DeadlineInPast` fix); the first template is un-approved and `_meta.templateRedeploy` records the replacement, its codehash and that the owner steps landed in-run. Every source is an exact match on Sourcify. No Stonk adapter is deployed on 4663. The 9994663 fork book, `deployments/9994663.json`, holds the full Stonk and Sushi launchpad ceremony and no Lighter template: the fork has no Lighter sequencer, so Lighter withdrawals never mature there.
