# sherwood-strategies

Strategy templates for [Sherwood](https://github.com/sherwoodagent/sherwood-protocol)
syndicates that live outside the core protocol repo.

The core repo ships the audited protocol and a small set of first-party templates.
This repo holds the rest: venue integrations that move faster than the protocol's
audit cycle and depend on third-party contracts (launchpads, perp venues). Each one
is an ordinary `BaseStrategy` template. Nothing here changes protocol behaviour: a
template reaches a vault only after the Sherwood owner approves it on
`StrategyFactory`, and every venue it calls must be on the `TierRegistry`
counterparty allowlist.

## Layout

```
src/<strategy>/            one directory per strategy family
  <Name>Strategy.sol       the BaseStrategy template
  adapters/                venue adapters the template calls, if any
  vendor/<venue>/          reduced interfaces transcribed from verified venue source
test/<strategy>/           unit suites (mocks) and fork suites (*Fork.t.sol)
script/<strategy>/         deploy scripts
docs/<strategy>/           design notes
```

## The protocol dependency

`lib/sherwood-protocol` is a git submodule pinned to a specific commit of
`sherwoodagent/sherwood-protocol`. Strategies import protocol sources through the
`@sherwood/` remapping (`@sherwood/strategies/BaseStrategy.sol`). OpenZeppelin and
forge-std resolve through the protocol's own vendored copies, so both repos compile
the shared sources against the same dependency versions.

Current pin: `v1-deploy` at `2a885c53`, the tree being deployed for protocol v1.
Re-pin when v1 lands on `main`:

```bash
git -C lib/sherwood-protocol fetch && git -C lib/sherwood-protocol checkout <commit>
git add lib/sherwood-protocol
```

## Build and test

```bash
git clone --recurse-submodules git@github.com:sherwoodagent/sherwood-strategies.git
forge build
forge test --no-match-contract Fork
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork
```

## Adding a strategy

1. Inherit `@sherwood/strategies/BaseStrategy.sol`. Derive the fund destination and
   counterparty set from `vault()`, and expose no payout, recipient or router
   address settable from `initialize` or `updateParams` data. `StrategyFactory`'s
   natspec states this template invariant.
2. Gate every venue and adapter the template calls through
   `vault() -> governor() -> tierRegistry() -> isCounterpartyAllowed`, the way
   `PortfolioStrategy` does upstream.
3. Settle all-or-revert: after `settle()` the clone holds nothing. Anything it cannot
   convert goes to the vault as-is. It is never left on the clone.
4. Ship unit tests against mocks and a fork suite against the live venue.

## License

MIT
