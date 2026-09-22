// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {IStrategy} from "@sherwood/interfaces/IStrategy.sol";
import {IZkLighter} from "../../src/lighter/IZkLighter.sol";
import {LighterPerpStrategy} from "../../src/lighter/LighterPerpStrategy.sol";

/**
 * @title  DeployLighterTemplate
 * @notice Deploy the `LighterPerpStrategy` template on a protocol-v1 stack,
 *         approve it on `StrategyFactory`, and allow `ZK_LIGHTER` on the
 *         `TierRegistry` counterparty axis. That is the whole v1 ceremony, and
 *         it is ONE broadcast.
 *
 *   WHAT v1 NEEDS, AND WHERE EACH STEP COMES FROM.
 *     1. `new LighterPerpStrategy()` — the template. Its constructor refuses
 *        every chain but 4663 and the 9994663 fork.
 *     2. `StrategyFactory.setTemplateApproval(template, true)` — the only way a
 *        template reaches a vault on v1. `cloneAndInit` refuses an unapproved
 *        template, records provenance, and REGISTERS the clone; the vault's
 *        batch guard admits a non-asset target only if the factory reports it
 *        registered (`SyndicateVault._guardBatchCalls`).
 *     3. `TierRegistry.setCounterpartyAllowed(ZK_LIGHTER, true)` — REQUIRED, not
 *        a runbook nicety, for the reason `DeployPortfolioStrategy._attestAdapter`
 *        gives for its adapter: `LighterPerpStrategy._initialize` binds the venue
 *        through `isCounterpartyAllowed` and reverts otherwise, so an unlisted
 *        venue makes the template INERT and the failure surfaces a governance
 *        cycle later, at clone-init. The registry snapshots the venue's
 *        codehash on grant, so run this after any Lighter redeploy.
 *
 *   WHAT v1 DOES NOT NEED, AND WHY THIS SCRIPT NO LONGER DOES IT. The
 *   `post-audit` version of this script ran a two-phase class ceremony:
 *   `proposeClassCertification(template, name(), 0, 1, …)`, wait out
 *   `certifyDelay`, `certifyClass`, then `setClassAllowed(template, true)`. The
 *   certification of the inert `name()` selector existed ONLY to mint the class
 *   anchor `setClassAllowed` required, and `setClassAllowed` existed only to
 *   make clones legal batch callees. v1 deleted the class-allow axis — batch
 *   targets are admitted structurally through step 2 — so there is nothing
 *   left for the anchor to unlock, and `finalize()` is gone with it.
 *
 *   WHAT STAYS DELIBERATE: `execute()` AND `settle()` ARE UNCERTIFIED. This
 *   template moves the whole declared cap into an off-chain perp venue whose
 *   sequencer this protocol does not control and whose margin no on-chain
 *   reader can price. There is no honest sub-10_000 extractable bound for that
 *   call, and the class path cannot express tier 2 anyway
 *   (`proposeClassCertification` reverts `InvalidTier` on `tier >= 2` and
 *   `BoundRequired` on a bound of 0 or >= 10_000). Leaving both selectors
 *   uncertified is what makes `tierOf` price them at the tier-2 / full-notional
 *   default, so a proposal's `requiredCoverage` is the full `execCap +
 *   settleCap` and its `envelopeTier` is 2. The post-flight below REQUIRES
 *   `classTierOf(template, execute/settle) == (2, 10_000)`: anything else means
 *   someone certified the money-moving selectors.
 *
 *   EVERY OWNER-GATED STEP DEGRADES TO A RUNBOOK LINE, NEVER A SILENT SKIP. On
 *   4663 the `StrategyFactory` and `TierRegistry` belong to the parameter Safe
 *   by the time a template is added, so a deployer key running this script
 *   owns neither. The script still deploys and still prints the template, then
 *   prints the exact calls the Safe owes, and exits non-complete. It never
 *   finishes quietly having done half.
 *
 *   ADDRESSES. `STRATEGY_FACTORY` and `TIER_REGISTRY` come from the env if set,
 *   else from the pinned protocol's address book
 *   (`lib/sherwood-protocol/chains/{chainId}.json`) — the env wins because the
 *   submodule pin can lag a deployment. The venue constants come from
 *   `script/lighter/addresses-4663.json` and are checked against the live
 *   venue by IDENTITY, not code presence. The deployed template address is
 *   printed, not written back: this repo does not edit the protocol's book.
 *
 *   Usage — Robinhood mainnet (4663):
 *     forge script script/lighter/DeployLighterTemplate.s.sol:DeployLighterTemplate \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 *
 *   Usage — Tenderly Robinhood fork (9994663):
 *     forge script script/lighter/DeployLighterTemplate.s.sol:DeployLighterTemplate \
 *       --rpc-url "$TENDERLY_ROBINHOOD_RPC_URL" --unlocked --sender <factory owner> --broadcast --slow
 *
 *   `--slow` IS MANDATORY UNDER `--unlocked`. Without it forge pipelines the
 *   batch into `eth_sendTransaction` and the NODE assigns the nonces, so the
 *   CREATE does not necessarily land on the nonce the simulation assumed.
 *   Observed on vnet a3fb16 on 2026-08-22: `setTemplateApproval` approved the
 *   SIMULATED template address, which holds no code.
 */
contract DeployLighterTemplate is Script {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170). Asserted
    ///      rather than assumed: a template over the limit deploys to a codeless
    ///      address on some clients and reverts on others.
    uint256 internal constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    /// @dev The same two chains `LighterPerpStrategy`'s constructor accepts.
    ///      46630 (robinhood-testnet) is absent on purpose: Lighter is not
    ///      deployed there.
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ROBINHOOD_FORK = 9994663;

    string internal constant VENUE_BOOK = "script/lighter/addresses-4663.json";

    struct Venue {
        address zkLighter;
        address usdg;
        uint16 usdgAssetIndex;
    }

    /// @notice Read-only pre-flight, runnable against 4663 before the v1 core
    ///         exists there: `--sig 'checkVenue()'` without `--broadcast`.
    function checkVenue() external view {
        _requireLighterChain();
        assertVenue(venue());
    }

    function run() external {
        _requireLighterChain();
        Venue memory v = venue();
        assertVenue(v);

        address factory = _protocolAddress("STRATEGY_FACTORY");
        address registry = _protocolAddress("TIER_REGISTRY");

        vm.startBroadcast();
        (address template, bool complete) = ceremony(factory, registry, v.zkLighter, msg.sender);
        vm.stopBroadcast();

        uint256 size = template.code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");
        console.log("LighterPerpStrategy template (record as LIGHTER_PERP_TEMPLATE):", template);
        if (!complete) console.log("INCOMPLETE: the RUNBOOK lines above are owed by the factory/registry owner");
    }

    /// @notice The ceremony, with the book passed in so a test can drive it
    ///         without the env or a broadcast.
    /// @param  operator The address the owner checks compare against — the
    ///         broadcaster under `run()`, the calling contract in a test.
    /// @return template The deployed template.
    /// @return complete True only when every owner-gated step landed.
    function ceremony(address factory, address registry, address zkLighter, address operator)
        public
        returns (address template, bool complete)
    {
        require(factory.code.length != 0, "STRATEGY_FACTORY holds no code on this chain");
        require(registry.code.length != 0, "TIER_REGISTRY holds no code on this chain");
        // A registry pointing at a different factory means clones from THIS one
        // are not registered strategies as far as the vault can tell, and every
        // batch naming one reverts `NotARegisteredStrategy`. That is a wrong
        // address book, not a runbook item.
        require(
            TierRegistry(registry).strategyFactory() == factory,
            "TIER_REGISTRY.strategyFactory() is not STRATEGY_FACTORY - wrong address book"
        );

        template = address(new LighterPerpStrategy());
        complete = true;

        if (StrategyFactory(factory).owner() == operator) {
            if (!StrategyFactory(factory).approvedTemplate(template)) {
                StrategyFactory(factory).setTemplateApproval(template, true);
            }
            console.log("approved on StrategyFactory:", factory);
        } else {
            complete = false;
            console.log("RUNBOOK: operator does not own STRATEGY_FACTORY - template NOT approved.");
            console.log("RUNBOOK:   StrategyFactory.setTemplateApproval(<template>, true):", template);
            console.log("RUNBOOK:   StrategyFactory:", factory);
        }

        if (TierRegistry(registry).isCounterpartyAllowed(zkLighter)) {
            console.log("ZK_LIGHTER already counterparty-allowed on TierRegistry:", registry);
        } else if (TierRegistry(registry).owner() == operator) {
            TierRegistry(registry).setCounterpartyAllowed(zkLighter, true);
            console.log("ZK_LIGHTER counterparty-allowed on TierRegistry:", registry);
        } else {
            complete = false;
            console.log("RUNBOOK: operator does not own TIER_REGISTRY - venue NOT allowed; clone-init will revert.");
            console.log("RUNBOOK:   TierRegistry.setCounterpartyAllowed(<ZK_LIGHTER>, true):", zkLighter);
            console.log("RUNBOOK:   TierRegistry:", registry);
        }

        assertUncertified(registry, template);
    }

    /// @notice THE READ THAT PROVES THE PRICING DECISION: `execute()` and
    ///         `settle()` must both price at the uncertified default (tier 2,
    ///         10000 bps); see the header. Separate from `ceremony` so it can be
    ///         checked against any template, not only one this run deployed.
    function assertUncertified(address registry, address template) public view {
        (uint8 te, uint16 be) = TierRegistry(registry).classTierOf(template, IStrategy.execute.selector);
        (uint8 ts, uint16 bs) = TierRegistry(registry).classTierOf(template, IStrategy.settle.selector);
        console.log("classTierOf(execute) tier / boundBps (expect 2 / 10000):", te, be);
        console.log("classTierOf(settle)  tier / boundBps (expect 2 / 10000):", ts, bs);
        require(te == 2 && be == 10_000 && ts == 2 && bs == 10_000, "execute()/settle() must stay UNCERTIFIED");
    }

    /// @notice The venue constants this repo records for 4663 (the fork replays them).
    function venue() public view returns (Venue memory v) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/", VENUE_BOOK));
        v.zkLighter = vm.parseJsonAddress(json, ".ZK_LIGHTER");
        v.usdg = vm.parseJsonAddress(json, ".USDG");
        v.usdgAssetIndex = uint16(vm.parseJsonUint(json, ".USDG_ASSET_INDEX"));
    }

    /// @notice IDENTITY, NOT CODE PRESENCE. `tokenToAssetIndex(USDG) == 3` is the
    ///         cheapest read only the real ZkLighter answers correctly, and it is
    ///         exactly the constant the template hardcodes as `USDG_ASSET_INDEX`:
    ///         if the venue ever reindexes USDG, every deposit and withdraw the
    ///         template makes would address the wrong asset.
    function assertVenue(Venue memory v) public view {
        require(v.zkLighter.code.length != 0, "ZK_LIGHTER holds no code on this chain");
        require(v.usdg.code.length != 0, "USDG holds no code on this chain");
        require(
            IZkLighter(v.zkLighter).tokenToAssetIndex(v.usdg) == v.usdgAssetIndex,
            "ZK_LIGHTER does not index USDG where addresses-4663.json says - the template's USDG_ASSET_INDEX is wrong"
        );
        console.log("venue verified: tokenToAssetIndex(USDG) ==", v.usdgAssetIndex);
    }

    /// @dev Env first, then the pinned protocol's address book. Reverts, naming
    ///      the key, when neither has it: on 4663 the v1 core ceremony has to
    ///      have run before a template can be added at all.
    function _protocolAddress(string memory key) internal view returns (address) {
        address fromEnv = vm.envOr(key, address(0));
        if (fromEnv != address(0)) return fromEnv;
        string memory path =
            string.concat(vm.projectRoot(), "/lib/sherwood-protocol/chains/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        string memory k = string.concat(".", key);
        require(vm.keyExistsJson(json, k), string.concat(key, " not in env or the protocol address book"));
        return vm.parseJsonAddress(json, k);
    }

    function _requireLighterChain() internal view {
        require(
            block.chainid == CHAIN_ROBINHOOD || block.chainid == CHAIN_ROBINHOOD_FORK,
            "wrong chain: LighterPerpStrategy exists only on Robinhood mainnet 4663 and its 9994663 fork"
        );
    }
}
