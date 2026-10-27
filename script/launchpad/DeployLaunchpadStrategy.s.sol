// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {DeploymentsBook} from "../DeploymentsBook.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {LaunchpadStrategy} from "../../src/launchpad/LaunchpadStrategy.sol";
import {StonkLaunchAdapter} from "../../src/launchpad/adapters/StonkLaunchAdapter.sol";
import {IStonkSafeLaunchpadV2} from "../../src/launchpad/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";
import {SushiLaunchAdapter} from "../../src/launchpad/adapters/SushiLaunchAdapter.sol";
import {ISushiLaunchpadV2} from "../../src/launchpad/vendor/sushi/ISushiLaunchpadV2.sol";

/// @dev The one position-manager read the Sushi identity round trip needs.
interface IPositionManagerFactory {
    function factory() external view returns (address);
}

/**
 * @notice Deploy the LaunchpadStrategy template, the StonkBrokers launch
 *         adapter and the Sushi Launchpad V2 launch adapter to Robinhood Chain
 *         mainnet (chain 4663), and bring them to the state protocol v1 needs
 *         before any vault can use them.
 *
 *   TWO CEREMONIES, PLUS A FAST-FOLLOW. `run()` is the full one: template,
 *   Stonk adapter, Sushi adapter, twelve grants. `runSushi()` is the
 *   SUSHI-ONLY one: template and Sushi adapter, two grants. Mainnet 4663 ships Sushi only (readiness review
 *   `docs/launchpad/audit-2026-10-19-mainnet-readiness.md`, section 5
 *   decision 1), so `runSushi()` is the 4663 ceremony and `run()` is the
 *   9994663 fork ceremony, where Stonk is already live; `run()` REFUSES
 *   chain 4663, so forgetting `--sig 'runSushi()'` cannot deploy a Stonk
 *   adapter or print a twelve-grant runbook there. `runSushi()` refuses a book
 *   that already holds `STONK_LAUNCH_ADAPTER`, since it would rewrite
 *   `_meta.launchpad` without the pad-set hash. `verify()` requires
 *   every Stonk counterparty and fails a Sushi-only deployment by design; use
 *   `verifySushi()` there. Adding Stonk to a Sushi-only chain later is the
 *   fast-follow `runStonk()`: Stonk adapter, eight pads and lens, ten grants,
 *   template untouched (see `STONK FAST-FOLLOW` below).
 *
 *   MAINNET-ONLY BY CONSTRUCTION. The venues exist on 4663 and nowhere else,
 *   so the script refuses any other chain rather than deploying a template
 *   whose every clone would revert at init. Fork rehearsal happens on a 4663
 *   fork via ROBINHOOD_FORK_CHAIN_ID (see
 *   `test/launchpad/fork/DeployLaunchpadStrategyFork.t.sol`).
 *
 *   WHAT v1 NEEDS, and why each step is not optional:
 *     1. `TierRegistry.setCounterpartyAllowed(adapter, true)` for the Stonk
 *        AND the Sushi adapter.
 *        `LaunchpadStrategy._initialize` binds its launch adapter through
 *        `isCounterpartyAllowed`, so an un-granted adapter makes the template
 *        INERT, and the failure surfaces a governance cycle later, at
 *        clone-init. The grant snapshots the adapter's codehash, so it must
 *        follow the deploy (this script orders it so).
 *     2. `setCounterpartyAllowed` for each of the eight V2 pads, the lens and
 *        the Sushi Launchpad V2 proxy.
 *        No code path reads these today: the adapter pins its pads in
 *        constructor-written storage covered by `padSetHash`, and never calls
 *        the lens on-chain. They are granted anyway because `ILaunchAdapter`
 *        states that the venue contracts an adapter calls hold counterparty
 *        standing of their own; the registry is the one place a reviewer can
 *        see which venues the protocol vouched for, and its codehash snapshot
 *        flags a pad whose code changed after the grant.
 *     3. The swap adapter the template routes its quote leg through
 *        (`UNISWAP_SWAP_ADAPTER`) must already be granted. It is the
 *        protocol's own and `DeployPortfolioStrategy` grants it; this script
 *        only reads it back.
 *     4. `StrategyFactory.setTemplateApproval(template, true)`. Without it
 *        `cloneAndInit` refuses the template outright.
 *   Steps 1, 2 and 4 are PERFORMED when the broadcaster owns the registry /
 *   factory (as the deployer EOA does on 4663, see below), and otherwise
 *   PRINTED as owner transactions with their calldata. Either way the
 *   post-deploy reads at the end say what is actually true on-chain.
 *
 *   ADDRESSES. Protocol-owned keys (`TIER_REGISTRY`, `STRATEGY_FACTORY`,
 *   `UNISWAP_SWAP_ADAPTER`) resolve in this order: an env var of the same
 *   name, the protocol's own book for THIS chain
 *   (`lib/sherwood-protocol/chains/<chainid>.json`), then this repo's
 *   launchpad book. The v1 book at the current pin predates the 4663 core
 *   deploy and names none of the three for mainnet, so
 *   `script/launchpad/addresses-4663.json` carries them with their provenance
 *   (read on 2026-10-19 at block 92,984,658; the swap adapter was identified
 *   from the registry's `CounterpartyAllowedSet` logs and confirmed by its
 *   `quoter()` / `v4Quoter()` reads). The fallback is consulted on 4663 only;
 *   on the 9994663 fork the pinned protocol book names the live stack and no
 *   fallback exists. Setting the env vars still overrides both books:
 *     export TIER_REGISTRY=0x4614f058920941A0a9a852e62485fbDE692D75E1
 *     export STRATEGY_FACTORY=0xb06788F027268a9A06c3AD41a88559530D2E54b1
 *     export UNISWAP_SWAP_ADAPTER=0x54e6a7af53143556973493fdec9d7837a77c67ef
 *   Venue keys the protocol does not carry (the Stonk pads, the lens, Sushi)
 *   live in the same launchpad book with their identity evidence; the fork
 *   replays mainnet's venues, so it reads the same file.
 *
 *   RECORDING. On a real broadcast the deployed addresses are written to this
 *   repo's book, `deployments/<chainid>.json`, as `LAUNCHPAD_TEMPLATE`,
 *   `SUSHI_LAUNCH_ADAPTER` and (full ceremony only) `STONK_LAUNCH_ADAPTER`,
 *   with the `padSetHash` (full ceremony only) and the Sushi implementation
 *   slot under `_meta.launchpad` (see `DeploymentsBook`). The Stonk
 *   fast-follow records `STONK_LAUNCH_ADAPTER` and its own section,
 *   `_meta.stonkFastFollow`, never `_meta.launchpad`. `--sig 'verify()'`
 *   or `--sig 'verifySushi()'` re-reads them and checks the deployment against
 *   the chain without redeploying.
 *
 *   SUSHI IDENTITY. Before deploying the Sushi adapter the script asserts the
 *   launchpad is V2.2 (`implementationVersion() == 2`, `implementationRevision()
 *   == 2`, the revision the adapter was transcribed and fork-tested against),
 *   that its `v3Factory()` and `positionManager()` are the book's Sushi V3 pair,
 *   and that the position manager's own `factory()` names that factory.
 *   STATED LIMIT: the book's V3 pair was first read from this launchpad, so the
 *   round trip proves the graph is internally consistent, not that it is Sushi's.
 *   The independent anchor is Sushi's published V3 contract list; check the
 *   book against it when re-pinning. The proxy is UUPS: record the printed
 *   implementation slot with the grant, because the codehash snapshot pins the
 *   PROXY's code, not the implementation behind it, so a Sushi upgrade does not
 *   show up in `isCounterpartyAllowed`.
 *
 *   Record the printed `padSetHash` with the grant: the codehash snapshot pins
 *   the Stonk adapter's CODE, and that hash is the only on-chain witness of the
 *   lane CONFIGURATION the code was granted with.
 *
 *   Usage — Tenderly Robinhood fork (9994663), full ceremony:
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url "$TENDERLY_ROBINHOOD_RPC_URL" --account sherwood-deployer --broadcast --slow
 *   Usage — Robinhood mainnet (4663), SUSHI ONLY (dry run first, without
 *   `--broadcast`, and paste the printed runbook into the PR):
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast --sig 'runSushi()'
 *   Verify afterwards (`verify()` on the fork, `verifySushi()` on mainnet):
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url <same> --sig 'verifySushi()'
 *   On 4663 the deployer EOA `0x5A00afAecE9CF61A768E2AE2713084C8d354DF94`
 *   (keystore `sherwood-agent`) owns both the TierRegistry and the
 *   StrategyFactory, so the grants and the template approval are PERFORMED in
 *   the same run; every 4663 ceremony so far did so
 *   (`_meta.launchpad.ownerStepsComplete` is `true`). A broadcaster that does
 *   not own them gets them PRINTED as owner transactions with calldata
 *   instead, and `verifySushi()` fails until the owner has executed them.
 *
 *   STONK FAST-FOLLOW on a Sushi-only chain: `--sig 'runStonk()'`. The
 *   readiness review's F-4 is applied to `StonkLaunchAdapter` (a dev buy is
 *   refused inside the opening buffer or without a `minTokensOut` floor) and
 *   the Stonk fork suite re-run. The ceremony deploys `new StonkLaunchAdapter(quotes, pads, lens)`
 *   over `_stonkLaneSet()`, grants the adapter, the eight V2 pads and the lens
 *   (`setCounterpartyAllowed`, performed when the broadcaster owns the
 *   registry, printed as owner transactions otherwise), and records
 *   `STONK_LAUNCH_ADAPTER` and `_meta.stonkFastFollow` (`block`, `deployer`,
 *   `tierRegistry`, `lens`, `padSetHash`, `granted`). The template needs no
 *   change, no re-approval and no new class certification: it binds any
 *   granted adapter at clone-init, and the certification is keyed to the
 *   template's codehash and selector, neither of which changes. The Sushi
 *   adapter and its grants are untouched. It refuses a book that already
 *   holds `STONK_LAUNCH_ADAPTER` (use `redeployStonk()`) and one without the
 *   Sushi-only deployment. Afterwards the chain is checked with `verify()`,
 *   which now applies in place of `verifySushi()`.
 *   Usage — Robinhood mainnet (4663), STONK FAST-FOLLOW (dry run first, without
 *   `--broadcast`, and paste the printed runbook into the PR):
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url robinhood --account sherwood-agent \
 *       --sender 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94 --broadcast --slow --sig 'runStonk()'
 *   Verify afterwards:
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url <same> --sig 'verify()'
 *
 *   REPLACING ONLY THE STONK ADAPTER (a fix to `StonkLaunchAdapter`):
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url <same> --account sherwood-deployer --broadcast --slow --sig 'redeployStonk()'
 *   The template and the Sushi adapter are untouched, and so are the pads and
 *   the lens (already granted). See `redeployStonkAdapter` for why the old
 *   adapter is NOT revoked by the script.
 */
contract DeployLaunchpadStrategy is DeploymentsBook {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170).
    uint256 internal constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`.
    bytes32 internal constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    string internal constant LAUNCHPAD_BOOK = "/script/launchpad/addresses-4663.json";

    /// @notice What the last `deploy` produced, for the fork rehearsal to read.
    StonkLaunchAdapter public stonkAdapter;
    SushiLaunchAdapter public sushiAdapter;
    LaunchpadStrategy public template;

    /// @notice The FULL ceremony (template, Stonk adapter, Sushi adapter).
    ///         The 9994663 fork path; mainnet uses `runSushi()`.
    function run() external {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        require(block.chainid != CHAIN_ROBINHOOD, "4663 is Sushi-only: use --sig 'runSushi()'");
        deploy(_protocolAddress("TIER_REGISTRY"), _protocolAddress("STRATEGY_FACTORY"));
    }

    /// @notice The SUSHI-ONLY ceremony (template, Sushi adapter): the 4663
    ///         mainnet path. `--sig 'runSushi()'`.
    function runSushi() external {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        deploySushi(_protocolAddress("TIER_REGISTRY"), _protocolAddress("STRATEGY_FACTORY"));
    }

    /// @notice Check a recorded FULL deployment against the chain, without
    ///         deploying: `--sig 'verify()'`. Requires `STONK_LAUNCH_ADAPTER`
    ///         and every Stonk counterparty, so it fails a Sushi-only chain by
    ///         design; use `verifySushi()` there.
    function verify() external view {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        verifyDeployment(
            _requireProtocolAddress("TIER_REGISTRY"),
            _requireProtocolAddress("STRATEGY_FACTORY"),
            _requireDeployedAddress("LAUNCHPAD_TEMPLATE"),
            _requireDeployedAddress("STONK_LAUNCH_ADAPTER"),
            _requireDeployedAddress("SUSHI_LAUNCH_ADAPTER")
        );
    }

    /// @notice Check a recorded SUSHI-ONLY deployment against the chain,
    ///         without deploying: `--sig 'verifySushi()'`. Reads nothing about
    ///         Stonk: no adapter key, no pad or lens grant.
    function verifySushi() external view {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        verifySushiDeployment(
            _requireProtocolAddress("TIER_REGISTRY"),
            _requireProtocolAddress("STRATEGY_FACTORY"),
            _requireDeployedAddress("LAUNCHPAD_TEMPLATE"),
            _requireDeployedAddress("SUSHI_LAUNCH_ADAPTER")
        );
    }

    /// @notice Every property a correct FULL deployment has, asserted. Owner
    ///         steps are checked as FACTS: a deployment still owed Safe
    ///         transactions fails verification until they land.
    /// @dev    The Sushi-only core first (`verifySushiDeployment`), then the
    ///         Stonk half, so a Sushi-only chain that later adds Stonk verifies
    ///         the same set of facts this does.
    function verifyDeployment(address registry, address factory, address template_, address stonk, address sushi)
        public
        view
    {
        verifySushiDeployment(registry, factory, template_, sushi);

        require(stonk.code.length != 0, "STONK_LAUNCH_ADAPTER holds no code");
        require(StonkLaunchAdapter(stonk).implementation() == stonk, "STONK_LAUNCH_ADAPTER is not an implementation");
        (address[] memory quotes, address[] memory pads) = _stonkLaneSet();
        require(
            StonkLaunchAdapter(stonk).padSetHash() == keccak256(abi.encode(quotes, pads)),
            "STONK_LAUNCH_ADAPTER padSetHash does not match the book's eight V2 lanes"
        );
        address[] memory counterparties = _stonkCounterparties(stonk, pads, _launchpadAddress("SAFE_LAUNCH_LENS_V2"));
        for (uint256 i; i < counterparties.length; ++i) {
            require(
                TierRegistry(registry).isCounterpartyAllowed(counterparties[i]), "a Stonk counterparty is not allowed"
            );
        }
        console.log("verified: STONK_LAUNCH_ADAPTER", stonk);
    }

    /// @notice Every property a correct SUSHI-ONLY deployment has, asserted:
    ///         the template is a template and approved, the adapter is an
    ///         implementation fronting the book's V2.2 launchpad, the registry
    ///         points at the factory, and both the adapter and the launchpad
    ///         proxy are allowed counterparties.
    function verifySushiDeployment(address registry, address factory, address template_, address sushi) public view {
        require(template_.code.length != 0, "LAUNCHPAD_TEMPLATE holds no code");
        require(LaunchpadStrategy(template_).vault() == address(0), "LAUNCHPAD_TEMPLATE is a clone, not the template");
        require(sushi.code.length != 0, "SUSHI_LAUNCH_ADAPTER holds no code");
        require(
            SushiLaunchAdapter(payable(sushi)).implementation() == sushi,
            "SUSHI_LAUNCH_ADAPTER is not an implementation"
        );
        address sushiLaunchpad = _sushiLaunchpad();
        require(
            address(SushiLaunchAdapter(payable(sushi)).launchpad()) == sushiLaunchpad,
            "SUSHI_LAUNCH_ADAPTER does not front the book's Sushi Launchpad V2"
        );

        require(TierRegistry(registry).strategyFactory() == factory, "TIER_REGISTRY does not point at STRATEGY_FACTORY");
        require(StrategyFactory(factory).approvedTemplate(template_), "template not approved on StrategyFactory");
        address[] memory counterparties = _sushiCounterparties(sushi, sushiLaunchpad);
        for (uint256 i; i < counterparties.length; ++i) {
            require(TierRegistry(registry).isCounterpartyAllowed(counterparties[i]), "a counterparty is not allowed");
        }
        console.log("verified: LAUNCHPAD_TEMPLATE", template_);
        console.log("verified: SUSHI_LAUNCH_ADAPTER", sushi);
    }

    /// @notice The FULL ceremony, with the two protocol singletons passed in.
    /// @dev    Split from `run()` so the fork rehearsal can hand it a registry
    ///         and factory it controls without touching the environment, which
    ///         concurrently running tests would share. Either may be zero: the
    ///         matching steps are then printed instead of performed.
    function deploy(address registry, address factory) public {
        (address[] memory quotes, address[] memory pads) = _stonkLaneSet();
        address lens = _launchpadAddress("SAFE_LAUNCH_LENS_V2");
        address sushiLaunchpad = _sushiLaunchpad();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        stonkAdapter = new StonkLaunchAdapter(quotes, pads, lens);
        template = new LaunchpadStrategy();

        sushiAdapter = new SushiLaunchAdapter(sushiLaunchpad);

        address[] memory counterparties =
            _counterparties(address(stonkAdapter), pads, lens, address(sushiAdapter), sushiLaunchpad);

        bool ownsRegistry = _grantIfOwner(registry, deployer, counterparties);
        bool ownsFactory = _approveIfOwner(factory, deployer);

        vm.stopBroadcast();

        _requireTemplateFits();

        console.log("StonkLaunchAdapter:   ", address(stonkAdapter));
        console.log("LaunchpadStrategy:    ", address(template));
        console.log("SushiLaunchAdapter:   ", address(sushiAdapter));
        console.log("Sushi Launchpad V2 implementation (record with the grant):");
        console.logBytes32(vm.load(sushiLaunchpad, _ERC1967_IMPLEMENTATION_SLOT));
        console.log("StonkLaunchAdapter padSetHash:");
        console.logBytes32(stonkAdapter.padSetHash());

        _printRunbook(registry, factory, counterparties, ownsRegistry, ownsFactory);
        _printValidation(registry, factory, counterparties);

        _recordAddress("LAUNCHPAD_TEMPLATE", address(template));
        _recordAddress("STONK_LAUNCH_ADAPTER", address(stonkAdapter));
        _recordAddress("SUSHI_LAUNCH_ADAPTER", address(sushiAdapter));
        vm.serializeUint("launchpad", "block", block.number);
        vm.serializeAddress("launchpad", "deployer", deployer);
        vm.serializeAddress("launchpad", "strategyFactory", factory);
        vm.serializeAddress("launchpad", "tierRegistry", registry);
        vm.serializeBytes32("launchpad", "stonkPadSetHash", stonkAdapter.padSetHash());
        vm.serializeBytes32(
            "launchpad", "sushiLaunchpadImplementation", vm.load(sushiLaunchpad, _ERC1967_IMPLEMENTATION_SLOT)
        );
        _recordMeta("launchpad", vm.serializeBool("launchpad", "ownerStepsComplete", ownsRegistry && ownsFactory));
    }

    /// @notice The SUSHI-ONLY ceremony, with the two protocol singletons
    ///         passed in: the template and the Sushi adapter, and the two
    ///         grants plus the template approval, performed or printed exactly
    ///         as `deploy` does them. Nothing Stonk is deployed, granted, read
    ///         or recorded; `stonkAdapter` stays zero.
    /// @dev    Same split as `deploy`, for the same fork-rehearsal reason.
    function deploySushi(address registry, address factory) public {
        // A Sushi-only run rewrites `_meta.launchpad` whole and would drop the
        // full ceremony's `stonkPadSetHash`; a chain with Stonk uses `run()`.
        require(
            _deployedAddress("STONK_LAUNCH_ADAPTER") == address(0),
            "book already holds STONK_LAUNCH_ADAPTER: a Sushi-only run would drop its provenance, use run()"
        );
        address sushiLaunchpad = _sushiLaunchpad();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        template = new LaunchpadStrategy();
        sushiAdapter = new SushiLaunchAdapter(sushiLaunchpad);

        address[] memory counterparties = _sushiCounterparties(address(sushiAdapter), sushiLaunchpad);

        bool ownsRegistry = _grantIfOwner(registry, deployer, counterparties);
        bool ownsFactory = _approveIfOwner(factory, deployer);

        vm.stopBroadcast();

        _requireTemplateFits();

        console.log("LaunchpadStrategy:    ", address(template));
        console.log("SushiLaunchAdapter:   ", address(sushiAdapter));
        console.log("Sushi Launchpad V2 implementation (record with the grant):");
        console.logBytes32(vm.load(sushiLaunchpad, _ERC1967_IMPLEMENTATION_SLOT));

        _printRunbook(registry, factory, counterparties, ownsRegistry, ownsFactory);
        _printValidation(registry, factory, counterparties);

        _recordAddress("LAUNCHPAD_TEMPLATE", address(template));
        _recordAddress("SUSHI_LAUNCH_ADAPTER", address(sushiAdapter));
        vm.serializeUint("launchpad", "block", block.number);
        vm.serializeAddress("launchpad", "deployer", deployer);
        vm.serializeAddress("launchpad", "strategyFactory", factory);
        vm.serializeAddress("launchpad", "tierRegistry", registry);
        vm.serializeBytes32(
            "launchpad", "sushiLaunchpadImplementation", vm.load(sushiLaunchpad, _ERC1967_IMPLEMENTATION_SLOT)
        );
        _recordMeta("launchpad", vm.serializeBool("launchpad", "ownerStepsComplete", ownsRegistry && ownsFactory));
    }

    /// @dev Grant every counterparty not yet allowed, if and only if the
    ///      broadcaster owns the registry. Returns whether it does, which is
    ///      what the runbook prints on. Must run inside the broadcast.
    function _grantIfOwner(address registry, address deployer, address[] memory counterparties)
        internal
        returns (bool ownsRegistry)
    {
        ownsRegistry = registry != address(0) && TierRegistry(registry).owner() == deployer;
        if (!ownsRegistry) return false;
        for (uint256 i; i < counterparties.length; ++i) {
            if (!TierRegistry(registry).isCounterpartyAllowed(counterparties[i])) {
                TierRegistry(registry).setCounterpartyAllowed(counterparties[i], true);
            }
        }
    }

    /// @dev Approve the template, if and only if the broadcaster owns the
    ///      factory. Returns whether it does. Must run inside the broadcast.
    function _approveIfOwner(address factory, address deployer) internal returns (bool ownsFactory) {
        ownsFactory = factory != address(0) && StrategyFactory(factory).owner() == deployer;
        if (ownsFactory && !StrategyFactory(factory).approvedTemplate(address(template))) {
            StrategyFactory(factory).setTemplateApproval(address(template), true);
        }
    }

    function _requireTemplateFits() internal view {
        uint256 size = address(template).code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");
    }

    /// @notice Replace ONLY the template: `--sig 'redeploySushiTemplate()'`.
    ///         The Sushi adapter and every registry grant stay as they are.
    function redeploySushiTemplate() external {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        redeployTemplate(_protocolAddress("STRATEGY_FACTORY"), _requireDeployedAddress("LAUNCHPAD_TEMPLATE"));
    }

    /// @notice Deploy a new `LaunchpadStrategy` template, approve it and revoke
    ///         the one it replaces when the broadcaster owns the factory (print
    ///         both transactions otherwise), and record it as `LAUNCHPAD_TEMPLATE`.
    /// @dev    Revoking the old template stops NEW clones only: `approvedTemplate`
    ///         is read at clone time and never by a live clone, so no proposal in
    ///         flight is affected. The class certification is keyed on the
    ///         template's codehash, so the new template needs its own
    ///         `proposeClassCertification`; the codehash is printed for it.
    /// @param  replaces The template this one supersedes; revoked, never called.
    function redeployTemplate(address factory, address replaces) public {
        if (replaces.code.length != 0) {
            require(LaunchpadStrategy(replaces).vault() == address(0), "replaces is a clone, not the template");
        }

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        template = new LaunchpadStrategy();
        bool ownsFactory = _approveIfOwner(factory, deployer);
        bool revoked = ownsFactory && _revokeIfApproved(factory, replaces);

        vm.stopBroadcast();

        _requireTemplateFits();

        console.log("LaunchpadStrategy (new):", address(template));
        console.log("Replaces:               ", replaces);
        console.log("Template codehash (proposeClassCertification expects it):");
        console.logBytes32(address(template).codehash);
        if (ownsFactory) {
            console.log("Approved on StrategyFactory", factory);
            console.log(revoked ? "Revoked the old template" : "Old template was not approved; nothing to revoke");
        } else {
            console.log("OWNER STEPS OWED on StrategyFactory", factory);
            console.log("  setTemplateApproval(new, true):");
            console.logBytes(abi.encodeCall(StrategyFactory.setTemplateApproval, (address(template), true)));
            console.log("  setTemplateApproval(old, false):");
            console.logBytes(abi.encodeCall(StrategyFactory.setTemplateApproval, (replaces, false)));
        }

        _recordAddress("LAUNCHPAD_TEMPLATE", address(template));
        vm.serializeUint("templateRedeploy", "block", block.number);
        vm.serializeAddress("templateRedeploy", "deployer", deployer);
        vm.serializeAddress("templateRedeploy", "replaces", replaces);
        vm.serializeAddress("templateRedeploy", "strategyFactory", factory);
        vm.serializeBytes32("templateRedeploy", "codehash", address(template).codehash);
        vm.serializeBool("templateRedeploy", "oldRevoked", revoked);
        _recordMeta("templateRedeploy", vm.serializeBool("templateRedeploy", "approved", ownsFactory));
    }

    /// @dev Revoke `old` on the factory if it is still approved. Must run inside
    ///      the broadcast, by the factory owner.
    function _revokeIfApproved(address factory, address old) internal returns (bool revoked) {
        if (old == address(0) || old == address(template)) return false;
        if (!StrategyFactory(factory).approvedTemplate(old)) return false;
        StrategyFactory(factory).setTemplateApproval(old, false);
        return true;
    }

    /// @notice Replace ONLY the Stonk adapter: `--sig 'redeployStonk()'`.
    function redeployStonk() external {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        redeployStonkAdapter(_protocolAddress("TIER_REGISTRY"), _requireDeployedAddress("STONK_LAUNCH_ADAPTER"));
    }

    /// @notice Deploy a new `StonkLaunchAdapter` over the book's eight V2 lanes,
    ///         grant it when the broadcaster owns the registry (print the Safe
    ///         transaction otherwise), and record it as `STONK_LAUNCH_ADAPTER`.
    /// @dev    THE OLD ADAPTER IS LEFT ALLOWED, and its revoke is printed, not
    ///         sent. `LaunchpadStrategy` checks `isCounterpartyAllowed` at init
    ///         and at `_execute`, never at `_settle`/`claim`, so a revoke cannot
    ///         strand a launch that already executed. It DOES make every clone
    ///         bound to the old adapter that has not executed yet revert at
    ///         execute, and a live vnet sim can hold such proposals. Revoking is
    ///         therefore the owner's call, made once those have drained.
    /// @param  replaces The adapter this one supersedes; recorded, never called
    ///         except to read its lane configuration for comparison.
    function redeployStonkAdapter(address registry, address replaces) public {
        (address[] memory quotes, address[] memory pads) = _stonkLaneSet();
        address lens = _launchpadAddress("SAFE_LAUNCH_LENS_V2");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        stonkAdapter = new StonkLaunchAdapter(quotes, pads, lens);

        bool ownsRegistry = registry != address(0) && TierRegistry(registry).owner() == deployer;
        if (ownsRegistry && !TierRegistry(registry).isCounterpartyAllowed(address(stonkAdapter))) {
            TierRegistry(registry).setCounterpartyAllowed(address(stonkAdapter), true);
        }

        vm.stopBroadcast();

        bytes32 padSetHash = stonkAdapter.padSetHash();
        require(padSetHash == keccak256(abi.encode(quotes, pads)), "new adapter padSetHash does not match the book");
        if (replaces.code.length != 0) {
            // Same lanes as the adapter it replaces: a redeploy fixes code, it
            // does not re-route launches.
            require(
                StonkLaunchAdapter(replaces).padSetHash() == padSetHash,
                "new adapter's lanes differ from the adapter it replaces"
            );
        }

        console.log("StonkLaunchAdapter (new):", address(stonkAdapter));
        console.log("Replaces:                ", replaces);
        console.log("padSetHash:");
        console.logBytes32(padSetHash);
        if (ownsRegistry) {
            console.log("Granted on TierRegistry", registry);
        } else {
            console.log("OWNER STEP OWED on TierRegistry", registry);
            console.log("  setCounterpartyAllowed(new, true):");
            console.logBytes(abi.encodeCall(TierRegistry.setCounterpartyAllowed, (address(stonkAdapter), true)));
        }
        if (replaces != address(0) && replaces != address(stonkAdapter)) {
            console.log("NOT SENT: revoke the old adapter once no unexecuted proposal binds it:");
            console.log("  setCounterpartyAllowed(old, false):");
            console.logBytes(abi.encodeCall(TierRegistry.setCounterpartyAllowed, (replaces, false)));
        }

        _recordAddress("STONK_LAUNCH_ADAPTER", address(stonkAdapter));
        vm.serializeUint("stonkRedeploy", "block", block.number);
        vm.serializeAddress("stonkRedeploy", "deployer", deployer);
        vm.serializeAddress("stonkRedeploy", "replaces", replaces);
        vm.serializeAddress("stonkRedeploy", "tierRegistry", registry);
        vm.serializeBytes32("stonkRedeploy", "padSetHash", padSetHash);
        _recordMeta("stonkRedeploy", vm.serializeBool("stonkRedeploy", "granted", ownsRegistry));
    }

    /// @notice The STONK FAST-FOLLOW on a Sushi-only chain: `--sig 'runStonk()'`.
    ///         Deploys one `StonkLaunchAdapter` over the book's eight V2 lanes and
    ///         grants the adapter, the eight pads and the lens (see `deployStonk`).
    ///         The template needs no change, no re-approval and no new class
    ///         certification: it binds any granted adapter at clone-init, and
    ///         the certification is keyed to the template's codehash and
    ///         selector, neither of which this run touches. Afterwards the chain
    ///         is checked with `verify()`, not `verifySushi()`.
    /// @dev    Refuses a book that already holds `STONK_LAUNCH_ADAPTER` (a
    ///         second adapter would silently sit beside the first; replacing it
    ///         is `redeployStonk()`), and a book without the Sushi-only
    ///         ceremony's `LAUNCHPAD_TEMPLATE` and `SUSHI_LAUNCH_ADAPTER` (a
    ///         fast-follow lands on a chain that already runs `runSushi()`).
    function runStonk() external {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        require(
            _deployedAddress("STONK_LAUNCH_ADAPTER") == address(0),
            "book already holds STONK_LAUNCH_ADAPTER: use --sig 'redeployStonk()'"
        );
        _requireDeployedAddress("LAUNCHPAD_TEMPLATE");
        _requireDeployedAddress("SUSHI_LAUNCH_ADAPTER");
        deployStonk(_protocolAddress("TIER_REGISTRY"));
    }

    /// @notice The Stonk fast-follow with the registry passed in. DEPLOYS
    ///         `new StonkLaunchAdapter(quotes, pads, lens)` over `_stonkLaneSet()`
    ///         and `SAFE_LAUNCH_LENS_V2`. GRANTS the adapter (after its deploy:
    ///         codehash snapshot), the eight V2 pads and the lens when the
    ///         broadcaster owns the registry, and otherwise prints the ten
    ///         `setCounterpartyAllowed` calls as owner transactions. RECORDS
    ///         `STONK_LAUNCH_ADAPTER` and `_meta.stonkFastFollow` (`block`,
    ///         `deployer`, `tierRegistry`, `lens`, `padSetHash`, `granted`).
    ///         DOES NOT TOUCH the template, its factory approval, the Sushi
    ///         adapter, the Sushi grants, `_meta.launchpad`, or the class
    ///         certification: the template needs no change, no re-approval and
    ///         no new certification, since certification is keyed to the
    ///         template's codehash and selector. `verify()` is the chain's check
    ///         once the grants have landed.
    /// @dev    Same split as `deploy`, for the same fork-rehearsal reason.
    ///         Records under its own `_meta` section because `_recordMeta`
    ///         replaces a section whole, and writing `_meta.launchpad` would drop
    ///         the Sushi ceremony's `sushiLaunchpadImplementation`.
    function deployStonk(address registry) public {
        (address[] memory quotes, address[] memory pads) = _stonkLaneSet();
        address lens = _launchpadAddress("SAFE_LAUNCH_LENS_V2");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        stonkAdapter = new StonkLaunchAdapter(quotes, pads, lens);

        address[] memory counterparties = _stonkCounterparties(address(stonkAdapter), pads, lens);
        bool ownsRegistry = _grantIfOwner(registry, deployer, counterparties);

        vm.stopBroadcast();

        bytes32 padSetHash = stonkAdapter.padSetHash();
        require(padSetHash == keccak256(abi.encode(quotes, pads)), "new adapter padSetHash does not match the book");

        console.log("StonkLaunchAdapter:   ", address(stonkAdapter));
        console.log("SafeLaunchLensV2:     ", lens);
        console.log("StonkLaunchAdapter padSetHash (record with the grant):");
        console.logBytes32(padSetHash);

        console.log("");
        console.log("== REGISTRY OWNER RUNBOOK (Stonk fast-follow) ==");
        _printGrantRunbook(registry, counterparties, ownsRegistry);
        console.log("");
        console.log("== POST-DEPLOY VALIDATION READS (Stonk fast-follow) ==");
        if (registry != address(0)) {
            _printGrantValidation(registry, counterparties);
        } else {
            console.log("TIER_REGISTRY unresolved - verify the grants by hand");
        }

        _recordAddress("STONK_LAUNCH_ADAPTER", address(stonkAdapter));
        vm.serializeUint("stonkFastFollow", "block", block.number);
        vm.serializeAddress("stonkFastFollow", "deployer", deployer);
        vm.serializeAddress("stonkFastFollow", "tierRegistry", registry);
        vm.serializeAddress("stonkFastFollow", "lens", lens);
        vm.serializeBytes32("stonkFastFollow", "padSetHash", padSetHash);
        _recordMeta("stonkFastFollow", vm.serializeBool("stonkFastFollow", "granted", ownsRegistry));
    }

    /// @dev Every address the FULL ceremony vouches for, adapters first.
    function _counterparties(address stonk, address[] memory pads, address lens, address sushi, address sushiLaunchpad)
        internal
        pure
        returns (address[] memory list)
    {
        list = new address[](pads.length + 4);
        list[0] = stonk;
        list[1] = sushi;
        for (uint256 i; i < pads.length; ++i) {
            list[i + 2] = pads[i];
        }
        list[pads.length + 2] = lens;
        list[pads.length + 3] = sushiLaunchpad;
    }

    /// @dev What the SUSHI-ONLY ceremony vouches for: the adapter, then the
    ///      launchpad proxy. The adapter comes first because its grant must
    ///      follow its deploy (codehash snapshot); the proxy's grant pins the
    ///      PROXY's code, so record the implementation slot alongside it.
    function _sushiCounterparties(address sushi, address sushiLaunchpad) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = sushi;
        list[1] = sushiLaunchpad;
    }

    /// @dev The Stonk half of the full set: the adapter, the pads, the lens.
    ///      What a Stonk fast-follow on a Sushi-only chain grants.
    function _stonkCounterparties(address stonk, address[] memory pads, address lens)
        internal
        pure
        returns (address[] memory list)
    {
        list = new address[](pads.length + 2);
        list[0] = stonk;
        for (uint256 i; i < pads.length; ++i) {
            list[i + 1] = pads[i];
        }
        list[pads.length + 1] = lens;
    }

    /// @dev The Sushi Launchpad V2 proxy from the book, asserted by IDENTITY
    ///      before anything is deployed against it. See the contract header.
    function _sushiLaunchpad() internal view returns (address launchpad) {
        launchpad = _launchpadAddress("SUSHI_LAUNCHPAD_V2");
        address factory = _launchpadAddress("SUSHI_V3_FACTORY");
        address positionManager = _launchpadAddress("SUSHI_V3_POSITION_MANAGER");
        ISushiLaunchpadV2 lp = ISushiLaunchpadV2(launchpad);
        require(lp.implementationVersion() == 2, "Sushi launchpad is not a V2 implementation");
        // The adapter's vendored interface was transcribed from V2.2. A later
        // revision may still be compatible, but it has to be re-checked (re-run
        // the Sushi fork suite) before this ceremony vouches for it.
        require(lp.implementationRevision() == 2, "Sushi launchpad is not V2.2: re-run the fork suite and re-pin");
        require(lp.v3Factory() == factory, "Sushi launchpad v3Factory() is not the book's Sushi V3 factory");
        require(
            lp.positionManager() == positionManager,
            "Sushi launchpad positionManager() is not the book's Sushi V3 position manager"
        );
        require(
            IPositionManagerFactory(positionManager).factory() == factory,
            "Sushi V3 position manager does not name the Sushi V3 factory"
        );
    }

    /// @dev The eight V2 (mint-launch) lanes, read from the launchpad book.
    ///
    ///      MINT PADS ONLY. The V3 pads exist for EXTERNAL tokens — a launch
    ///      that brings its own ERC-20 — and this template always mints, so
    ///      serving a V3 lane would be dead configuration that still widened
    ///      the allowlisted surface. A future BYO-token template gets its own
    ///      implementation and its own grant, which is exactly the granularity
    ///      `padSetHash` is designed to make checkable.
    ///
    ///      WHAT ACTUALLY CATCHES A MIS-FILED PAD, stated precisely because the
    ///      obvious answer is wrong. Since this function DERIVES `quotes[i]`
    ///      from `pads[i].quote()`, the adapter constructor's `PadQuoteMismatch`
    ///      compares a value against itself and can never fire from here. The
    ///      guard that does bite is `DuplicateQuote`: a pad filed under the
    ///      wrong lane key reports the quote of its REAL lane, collides with
    ///      that lane's own entry, and aborts the deploy. That is not
    ///      theoretical — it is how a transcribed USDG address was caught
    ///      during the address-book work.
    ///
    ///      `DuplicateQuote` only fires on a COLLISION, though, and a V3 pad
    ///      reports the same `quote()` as its V2 sibling — so a V3 pad filed
    ///      under a V2 key collides with nothing and would sail through, giving
    ///      this always-minting template a lane pointed at a bring-your-own-
    ///      token pad it can never use. Codehashes cannot separate the families
    ///      (every pad's differs, since its lane is an immutable), so the check
    ///      below is explicit: no chosen pad may be any V3 pad the book knows.
    function _stonkLaneSet() internal view returns (address[] memory quotes, address[] memory pads) {
        string[8] memory lanes = _lanes();
        quotes = new address[](8);
        pads = new address[](8);
        for (uint256 i; i < 8; ++i) {
            pads[i] = _launchpadAddress(string.concat("STONK_SAFE_LAUNCHPAD_V2_", lanes[i]));
            // The pad is the authority on its own lane; the book only says
            // WHICH pad. Reading the quote off the pad keeps the two from
            // drifting.
            quotes[i] = IStonkSafeLaunchpadV2(pads[i]).quote();
            require(quotes[i] != address(0), "stonk pad reports no quote token");
        }
        _requireNoV3Pads(pads, lanes);
    }

    /// @dev Refuse any pad that the book files as a V3 (external-token) pad.
    ///      See `_stonkLaneSet` for why `DuplicateQuote` cannot cover this
    ///      case. Compares against every V3 lane, not just the matching one, so
    ///      a V3 pad filed under a DIFFERENT lane's V2 key is caught too.
    function _requireNoV3Pads(address[] memory pads, string[8] memory lanes) internal view {
        for (uint256 j; j < 8; ++j) {
            address v3 = _optionalLaunchpadAddress(string.concat("STONK_SAFE_LAUNCHPAD_V3_", lanes[j]));
            if (v3 == address(0)) continue;
            for (uint256 i; i < 8; ++i) {
                require(pads[i] != v3, "a V3 (external-token) pad is filed under a V2 lane key");
            }
        }
    }

    /// @dev The lane order is part of `padSetHash`, so it is fixed here.
    function _lanes() internal pure returns (string[8] memory) {
        return ["WETH", "STONK", "USDG", "GME", "NVDA", "AAPL", "SPCX", "USO"];
    }

    /// @dev Printed only for the steps this run could not perform: the
    ///      deployer does not own the registry / factory on mainnet once the
    ///      Safe has accepted ownership, so those become Safe transactions.
    function _printRunbook(
        address registry,
        address factory,
        address[] memory counterparties,
        bool ownsRegistry,
        bool ownsFactory
    ) internal view {
        console.log("");
        console.log("== REGISTRY / FACTORY OWNER RUNBOOK ==");
        _printGrantRunbook(registry, counterparties, ownsRegistry);
        if (ownsFactory) {
            console.log("StrategyFactory template approval PERFORMED by this run:", factory);
        } else {
            console.log("StrategyFactory:", factory);
            if (factory == address(0)) {
                console.log(
                    "  STRATEGY_FACTORY unresolved: set it in the env, the protocol book or script/launchpad/addresses-4663.json"
                );
            }
            console.log("  setTemplateApproval(template, true):", address(template));
            console.logBytes(abi.encodeCall(StrategyFactory.setTemplateApproval, (address(template), true)));
        }
        address swapAdapter = _protocolAddress("UNISWAP_SWAP_ADAPTER");
        console.log("Swap adapter must already be a granted counterparty (DeployPortfolioStrategy):", swapAdapter);
    }

    function _printValidation(address registry, address factory, address[] memory counterparties) internal view {
        console.log("");
        console.log("== POST-DEPLOY VALIDATION READS ==");
        if (registry != address(0)) {
            _printGrantValidation(registry, counterparties);
            address swapAdapter = _protocolAddress("UNISWAP_SWAP_ADAPTER");
            if (swapAdapter != address(0)) {
                console.log(
                    "swap adapter isCounterpartyAllowed:", TierRegistry(registry).isCounterpartyAllowed(swapAdapter)
                );
            }
        } else {
            console.log("TIER_REGISTRY unresolved - verify the grants by hand");
        }
        if (factory != address(0)) {
            console.log("template approvedTemplate:", StrategyFactory(factory).approvedTemplate(address(template)));
        } else {
            console.log("STRATEGY_FACTORY unresolved - verify the template approval by hand");
        }
    }

    /// @dev The registry half of the runbook: the grants this run performed,
    ///      or each `setCounterpartyAllowed` as an owner transaction with its
    ///      calldata. Shared by `_printRunbook` and the Stonk fast-follow.
    function _printGrantRunbook(address registry, address[] memory counterparties, bool ownsRegistry) internal pure {
        if (ownsRegistry) {
            console.log("TierRegistry grants PERFORMED by this run:", registry);
        } else {
            console.log("TierRegistry:", registry);
            if (registry == address(0)) {
                console.log(
                    "  TIER_REGISTRY unresolved: set it in the env, the protocol book or script/launchpad/addresses-4663.json"
                );
            }
            for (uint256 i; i < counterparties.length; ++i) {
                console.log("  setCounterpartyAllowed(counterparty, true):", counterparties[i]);
                console.logBytes(abi.encodeCall(TierRegistry.setCounterpartyAllowed, (counterparties[i], true)));
            }
        }
    }

    /// @dev One `isCounterpartyAllowed` read per counterparty. `registry` must
    ///      be nonzero. Shared by `_printValidation` and the Stonk fast-follow.
    function _printGrantValidation(address registry, address[] memory counterparties) internal view {
        for (uint256 i; i < counterparties.length; ++i) {
            console.log(
                counterparties[i],
                "isCounterpartyAllowed:",
                TierRegistry(registry).isCounterpartyAllowed(counterparties[i])
            );
        }
    }

    // ── address books ──

    /// @dev The launchpad book doubles as the fallback for the three protocol
    ///      keys the pinned `chains/4663.json` lacks (see the header and
    ///      `DeploymentsBook._protocolAddress`). On 4663 only: the fork's pinned
    ///      protocol book is complete, and a future pin that drops a key must
    ///      not silently resolve a mainnet address there.
    function _protocolFallbackBook() internal view override returns (string memory) {
        return block.chainid == CHAIN_ROBINHOOD ? LAUNCHPAD_BOOK : "";
    }

    /// @dev A venue key from this repo's launchpad book. Mandatory.
    function _launchpadAddress(string memory key) internal view returns (address a) {
        a = _optionalLaunchpadAddress(key);
        require(a != address(0), string.concat(key, " missing from script/launchpad/addresses-4663.json"));
    }

    function _optionalLaunchpadAddress(string memory key) internal view returns (address) {
        return _optionalFrom(string.concat(vm.projectRoot(), LAUNCHPAD_BOOK), key);
    }
}
