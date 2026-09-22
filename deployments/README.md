# Deployments

One file per chain, `<chainid>.json`, naming what this repo deployed there. The deploy scripts write these files on a real broadcast (`forge script ... --broadcast`), never on a dry run or in tests. Commit each file together with the `broadcast/` log of the run that produced it.

The format matches the protocol's `chains/<chainid>.json`: flat `KEY: address` pairs, so consumers (the CLI's address overrides) read both files the same way. Provenance sits under `_meta.<script>` and is not an address.

| Key | Contract | Script |
| --- | --- | --- |
| `LAUNCHPAD_TEMPLATE` | `LaunchpadStrategy` template | `script/launchpad/DeployLaunchpadStrategy.s.sol` |
| `STONK_LAUNCH_ADAPTER` | `StonkLaunchAdapter` implementation | same |
| `SUSHI_LAUNCH_ADAPTER` | `SushiLaunchAdapter` implementation | same |
| `LIGHTER_PERP_TEMPLATE` | `LighterPerpStrategy` template | `script/lighter/DeployLighterTemplate.s.sol` |

`_meta.launchpad` records the block, deployer, the protocol singletons used, the Stonk `padSetHash`, the Sushi launchpad's ERC-1967 implementation at deploy, and whether the owner steps (grants, template approval) landed in the same run. `_meta.lighter` records the same minus the venue fields.

Check a recorded deployment against the chain without redeploying:

```bash
forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy --rpc-url <rpc> --sig 'verify()'
forge script script/lighter/DeployLighterTemplate.s.sol:DeployLighterTemplate --rpc-url <rpc> --sig 'verify()'
```

Verification treats owner steps as facts: a deployment still owed Safe transactions fails it until they land.

Lighter is deployed on Robinhood mainnet only. The 9994663 fork has no Lighter sequencer, so its withdrawals never mature.
