// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {DeploymentsBook} from "../DeploymentsBook.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {IStrategy} from "@sherwood/interfaces/IStrategy.sol";
import {GenericCallStrategy} from "../../src/generic-call/GenericCallStrategy.sol";

/**
 * @title  DeployGenericCallTemplate
 * @notice Deploy the `GenericCallStrategy` template on a protocol-v1 stack and
 *         approve it on `StrategyFactory`. That is the whole v1 ceremony, and it
 *         is ONE broadcast.
 *
 *   WHAT v1 NEEDS, AND WHERE EACH STEP COMES FROM.
 *     1. `new GenericCallStrategy()`: the template. Plain CREATE from the
 *        broadcaster, like every template in this repo. The protocol-side
 *        version of this script (sherwood-protocol PR #414) minted it through
 *        the protocol's Create3Factory under a `GENERIC_CALL_TEMPLATE` salt;
 *        that mechanism did not move, so the address it predicted is void.
 *        The address is whatever this broadcast lands on, read back from
 *        `deployments/<chainid>.json`.
 *     2. `StrategyFactory.setTemplateApproval(template, true)`: the only way a
 *        template reaches a vault on v1. `cloneAndInit` refuses an unapproved
 *        template, records provenance (`cloneTemplate(clone) == template`, the
 *        first thing a guardian checks) and REGISTERS the clone; the vault's
 *        batch guard admits a non-asset target only if the factory reports it
 *        registered (`SyndicateVault._guardBatchCalls`).
 *
 *   WHAT IT DOES NOT NEED: NO `TierRegistry` COUNTERPARTY STEP. The template
 *   has no venue and never reads `isCounterpartyAllowed`. Every target arrives
 *   per clone in the call lists fixed at `initialize`, checked there against a
 *   denylist of the protocol contracts around the vault. The gate is step 2:
 *   the factory owner's approval, then tier-2 coverage and the guardian
 *   review on each proposal.
 *
 *   WHAT STAYS DELIBERATE: `execute()` AND `settle()` ARE UNCERTIFIED, FOREVER.
 *   The template is an arbitrary-call forwarder whose destinations are set by
 *   calldata, the surface the protocol's adapter-onboarding checklist §2.1
 *   refuses at tier 0 or 1 (`lib/sherwood-protocol/docs/adapter-onboarding-checklist.md`).
 *   Leaving both selectors uncertified is what makes `tierOf` price a clone at
 *   the tier-2 / full-notional default, so a proposal's coverage is the full
 *   cap on `clone.execute()`. The post-flight below REQUIRES
 *   `classTierOf(template, execute/settle) == (2, 10_000)`: anything else
 *   means someone certified the money-moving selectors.
 *
 *   THE OWNER-GATED STEP DEGRADES TO A RUNBOOK LINE, NEVER A SILENT SKIP. When
 *   the broadcaster does not own `StrategyFactory`, the script still deploys
 *   and prints the template, then prints the exact call the owner owes and
 *   exits non-complete (`_meta.genericCall.ownerStepsComplete == false`).
 *
 *   ADDRESSES. `STRATEGY_FACTORY` and `TIER_REGISTRY` come from the env if set,
 *   else from the pinned protocol's address book
 *   (`lib/sherwood-protocol/chains/{chainId}.json`). On 4663 the book at the
 *   current pin (`a91fae2f`) names both; an exported value still wins
 *   (`deployments/README.md` lists the live values), and the script refuses
 *   to run when neither resolves. The deployed
 *   template is recorded as `GENERIC_CALL_TEMPLATE` in THIS repo's book,
 *   `deployments/<chainid>.json`, on a real broadcast only (see
 *   `DeploymentsBook`); this repo never edits the protocol's book.
 *   `--sig 'verify()'` re-reads that entry and checks the deployment against
 *   the chain without redeploying.
 *
 *   Usage — Robinhood mainnet (4663):
 *     STRATEGY_FACTORY=<addr> TIER_REGISTRY=<addr> \
 *     forge script script/generic-call/DeployGenericCallTemplate.s.sol:DeployGenericCallTemplate \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 *
 *   Usage — Tenderly Robinhood fork (9994663), whose pinned book names both:
 *     forge script script/generic-call/DeployGenericCallTemplate.s.sol:DeployGenericCallTemplate \
 *       --rpc-url "$TENDERLY_ROBINHOOD_RPC_URL" --unlocked --sender <factory owner> --broadcast --slow
 *
 *   `--slow` IS MANDATORY UNDER `--unlocked`, for the reason
 *   `DeployLighterTemplate` gives: without it the node assigns the nonces and
 *   `setTemplateApproval` can approve the SIMULATED template address.
 */
contract DeployGenericCallTemplate is DeploymentsBook {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170). Asserted
    ///      rather than assumed: a template over the limit deploys to a codeless
    ///      address on some clients and reverts on others.
    uint256 internal constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    /// @dev `GenericCallStrategy.name()`: the identity `verifyDeployment` reads,
    ///      so a book entry pointing at another template fails verification.
    bytes32 internal constant TEMPLATE_NAME_HASH = keccak256("Generic Call");

    function run() external {
        address factory = _requireProtocolAddress("STRATEGY_FACTORY");
        address registry = _requireProtocolAddress("TIER_REGISTRY");

        vm.startBroadcast();
        (address template, bool complete) = ceremony(factory, registry, msg.sender);
        vm.stopBroadcast();

        uint256 size = template.code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");
        console.log("GenericCallStrategy template (GENERIC_CALL_TEMPLATE):", template);
        if (!complete) console.log("INCOMPLETE: the RUNBOOK lines above are owed by the factory owner");

        _recordAddress("GENERIC_CALL_TEMPLATE", template);
        vm.serializeUint("genericCall", "block", block.number);
        vm.serializeAddress("genericCall", "deployer", msg.sender);
        vm.serializeAddress("genericCall", "strategyFactory", factory);
        vm.serializeAddress("genericCall", "tierRegistry", registry);
        _recordMeta("genericCall", vm.serializeBool("genericCall", "ownerStepsComplete", complete));
    }

    /// @notice Check a recorded deployment against the chain, without
    ///         deploying: `--sig 'verify()'`. Reads `GENERIC_CALL_TEMPLATE` from
    ///         this repo's book and the v1 singletons from the env or the
    ///         protocol's book, as `run()` does.
    function verify() external view {
        verifyDeployment(
            _requireProtocolAddress("STRATEGY_FACTORY"),
            _requireProtocolAddress("TIER_REGISTRY"),
            _requireDeployedAddress("GENERIC_CALL_TEMPLATE")
        );
    }

    /// @notice Every property a correct deployment has, asserted. The owner
    ///         step is checked as a FACT here (unlike `ceremony`, which degrades
    ///         it to a runbook line): a deployment still owed the approval fails
    ///         verification until it lands.
    function verifyDeployment(address factory, address registry, address template) public view {
        require(template.code.length != 0, "GENERIC_CALL_TEMPLATE holds no code");
        require(
            GenericCallStrategy(template).vault() == address(0), "GENERIC_CALL_TEMPLATE is a clone, not the template"
        );
        require(
            keccak256(bytes(GenericCallStrategy(template).name())) == TEMPLATE_NAME_HASH,
            "GENERIC_CALL_TEMPLATE is not a GenericCallStrategy"
        );
        require(TierRegistry(registry).strategyFactory() == factory, "TIER_REGISTRY does not point at STRATEGY_FACTORY");
        require(StrategyFactory(factory).approvedTemplate(template), "template not approved on StrategyFactory");
        assertUncertified(registry, template);
        console.log("verified: GENERIC_CALL_TEMPLATE", template);
    }

    /// @notice The ceremony, with the singletons passed in so a test can drive
    ///         it without the env or a broadcast.
    /// @param  operator The address the owner check compares against: the
    ///         broadcaster under `run()`, the calling contract in a test.
    /// @return template The deployed template.
    /// @return complete True only when the owner-gated approval landed.
    function ceremony(address factory, address registry, address operator)
        public
        returns (address template, bool complete)
    {
        require(factory.code.length != 0, "STRATEGY_FACTORY holds no code on this chain");
        require(registry.code.length != 0, "TIER_REGISTRY holds no code on this chain");
        // A registry pointing at a different factory means clones from THIS
        // one are not registered strategies as far as the vault can tell, and
        // every batch naming one reverts `NotARegisteredStrategy`. That is a
        // wrong address book, not a runbook item.
        require(
            TierRegistry(registry).strategyFactory() == factory,
            "TIER_REGISTRY.strategyFactory() is not STRATEGY_FACTORY - wrong address book"
        );

        template = address(new GenericCallStrategy());
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
            console.log("RUNBOOK:   calldata:");
            console.logBytes(abi.encodeCall(StrategyFactory.setTemplateApproval, (template, true)));
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
}
