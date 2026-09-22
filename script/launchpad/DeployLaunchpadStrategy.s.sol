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
 *   factory (a fresh-deploy ceremony before ownership moves to the Safe), and
 *   otherwise PRINTED as Safe transactions with their calldata. Either way the
 *   post-deploy reads at the end say what is actually true on-chain.
 *
 *   ADDRESSES. Protocol-owned keys (`TIER_REGISTRY`, `STRATEGY_FACTORY`,
 *   `UNISWAP_SWAP_ADAPTER`) are read from the protocol's own book for THIS
 *   chain, `lib/sherwood-protocol/chains/<chainid>.json`, and may be
 *   overridden by an env var of the same name (the v1 book at the current pin
 *   predates the 4663 core deploy, so on mainnet they are absent until it
 *   lands; on the 9994663 fork the pinned book already names the live stack).
 *   Venue keys the protocol does not carry (the Stonk pads, the lens, Sushi)
 *   live in `script/launchpad/addresses-4663.json`, with their identity
 *   evidence; the fork replays mainnet's venues, so it reads the same file.
 *
 *   RECORDING. On a real broadcast the deployed addresses are written to this
 *   repo's book, `deployments/<chainid>.json`, as `LAUNCHPAD_TEMPLATE`,
 *   `SUSHI_LAUNCH_ADAPTER` and `STONK_LAUNCH_ADAPTER`, with the `padSetHash`
 *   and the Sushi implementation slot under `_meta.launchpad` (see
 *   `DeploymentsBook`). `--sig 'verify()'` re-reads them and checks the whole
 *   deployment against the chain without redeploying.
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
 *   Usage — Tenderly Robinhood fork (9994663):
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url "$TENDERLY_ROBINHOOD_RPC_URL" --account sherwood-deployer --broadcast --slow
 *   Usage — Robinhood mainnet (4663):
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 *   Verify either afterwards:
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url <same> --sig 'verify()'
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

    function run() external {
        require(_isRobinhood(), "wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork");
        deploy(_protocolAddress("TIER_REGISTRY"), _protocolAddress("STRATEGY_FACTORY"));
    }

    /// @notice Check a recorded deployment against the chain, without
    ///         deploying: `--sig 'verify()'`.
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

    /// @notice Every property a correct deployment has, asserted. Owner steps
    ///         are checked as FACTS: a deployment still owed Safe transactions
    ///         fails verification until they land.
    function verifyDeployment(address registry, address factory, address template_, address stonk, address sushi)
        public
        view
    {
        require(template_.code.length != 0, "LAUNCHPAD_TEMPLATE holds no code");
        require(LaunchpadStrategy(template_).vault() == address(0), "LAUNCHPAD_TEMPLATE is a clone, not the template");
        require(stonk.code.length != 0, "STONK_LAUNCH_ADAPTER holds no code");
        require(StonkLaunchAdapter(stonk).implementation() == stonk, "STONK_LAUNCH_ADAPTER is not an implementation");
        require(sushi.code.length != 0, "SUSHI_LAUNCH_ADAPTER holds no code");
        require(
            SushiLaunchAdapter(payable(sushi)).implementation() == sushi,
            "SUSHI_LAUNCH_ADAPTER is not an implementation"
        );

        (address[] memory quotes, address[] memory pads) = _stonkLaneSet();
        require(
            StonkLaunchAdapter(stonk).padSetHash() == keccak256(abi.encode(quotes, pads)),
            "STONK_LAUNCH_ADAPTER padSetHash does not match the book's eight V2 lanes"
        );
        address sushiLaunchpad = _sushiLaunchpad();
        require(
            address(SushiLaunchAdapter(payable(sushi)).launchpad()) == sushiLaunchpad,
            "SUSHI_LAUNCH_ADAPTER does not front the book's Sushi Launchpad V2"
        );

        require(TierRegistry(registry).strategyFactory() == factory, "TIER_REGISTRY does not point at STRATEGY_FACTORY");
        require(StrategyFactory(factory).approvedTemplate(template_), "template not approved on StrategyFactory");
        address[] memory counterparties =
            _counterparties(stonk, pads, _launchpadAddress("SAFE_LAUNCH_LENS_V2"), sushi, sushiLaunchpad);
        for (uint256 i; i < counterparties.length; ++i) {
            require(TierRegistry(registry).isCounterpartyAllowed(counterparties[i]), "a counterparty is not allowed");
        }
        console.log("verified: LAUNCHPAD_TEMPLATE", template_);
        console.log("verified: STONK_LAUNCH_ADAPTER", stonk);
        console.log("verified: SUSHI_LAUNCH_ADAPTER", sushi);
    }

    /// @notice The ceremony, with the two protocol singletons passed in.
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

        bool ownsRegistry = registry != address(0) && TierRegistry(registry).owner() == deployer;
        if (ownsRegistry) {
            for (uint256 i; i < counterparties.length; ++i) {
                if (!TierRegistry(registry).isCounterpartyAllowed(counterparties[i])) {
                    TierRegistry(registry).setCounterpartyAllowed(counterparties[i], true);
                }
            }
        }

        bool ownsFactory = factory != address(0) && StrategyFactory(factory).owner() == deployer;
        if (ownsFactory && !StrategyFactory(factory).approvedTemplate(address(template))) {
            StrategyFactory(factory).setTemplateApproval(address(template), true);
        }

        vm.stopBroadcast();

        uint256 size = address(template).code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");

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

    /// @dev Every address this ceremony vouches for, adapters first.
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
        if (ownsRegistry) {
            console.log("TierRegistry grants PERFORMED by this run:", registry);
        } else {
            console.log("TierRegistry:", registry);
            if (registry == address(0)) {
                console.log("  TIER_REGISTRY unresolved: set it in the env or the protocol book");
            }
            for (uint256 i; i < counterparties.length; ++i) {
                console.log("  setCounterpartyAllowed(counterparty, true):", counterparties[i]);
                console.logBytes(abi.encodeCall(TierRegistry.setCounterpartyAllowed, (counterparties[i], true)));
            }
        }
        if (ownsFactory) {
            console.log("StrategyFactory template approval PERFORMED by this run:", factory);
        } else {
            console.log("StrategyFactory:", factory);
            if (factory == address(0)) {
                console.log("  STRATEGY_FACTORY unresolved: set it in the env or the protocol book");
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
            for (uint256 i; i < counterparties.length; ++i) {
                console.log(
                    counterparties[i],
                    "isCounterpartyAllowed:",
                    TierRegistry(registry).isCounterpartyAllowed(counterparties[i])
                );
            }
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

    // ── address books ──

    /// @dev A venue key from this repo's launchpad book. Mandatory.
    function _launchpadAddress(string memory key) internal view returns (address a) {
        a = _optionalLaunchpadAddress(key);
        require(a != address(0), string.concat(key, " missing from script/launchpad/addresses-4663.json"));
    }

    function _optionalLaunchpadAddress(string memory key) internal view returns (address) {
        return _optionalFrom(string.concat(vm.projectRoot(), LAUNCHPAD_BOOK), key);
    }
}
