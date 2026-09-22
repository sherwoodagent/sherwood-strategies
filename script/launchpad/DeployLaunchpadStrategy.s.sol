// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console, Script} from "forge-std/Script.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {LaunchpadStrategy} from "../../src/launchpad/LaunchpadStrategy.sol";
import {StonkLaunchAdapter} from "../../src/launchpad/adapters/StonkLaunchAdapter.sol";
import {IStonkSafeLaunchpadV2} from "../../src/launchpad/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";

/**
 * @notice Deploy the LaunchpadStrategy template and the StonkBrokers launch
 *         adapter to Robinhood Chain mainnet (chain 4663), and bring them to
 *         the state protocol v1 needs before any vault can use them.
 *
 *   MAINNET-ONLY BY CONSTRUCTION. The venues exist on 4663 and nowhere else,
 *   so the script refuses any other chain rather than deploying a template
 *   whose every clone would revert at init. Fork rehearsal happens on a 4663
 *   fork via ROBINHOOD_FORK_CHAIN_ID (see
 *   `test/launchpad/fork/DeployLaunchpadStrategyFork.t.sol`).
 *
 *   WHAT v1 NEEDS, and why each step is not optional:
 *     1. `TierRegistry.setCounterpartyAllowed(stonkAdapter, true)`.
 *        `LaunchpadStrategy._initialize` binds its launch adapter through
 *        `isCounterpartyAllowed`, so an un-granted adapter makes the template
 *        INERT, and the failure surfaces a governance cycle later, at
 *        clone-init. The grant snapshots the adapter's codehash, so it must
 *        follow the deploy (this script orders it so).
 *     2. `setCounterpartyAllowed` for each of the eight V2 pads and the lens.
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
 *   `UNISWAP_SWAP_ADAPTER`) are read from the protocol's own book,
 *   `lib/sherwood-protocol/chains/4663.json`, and may be overridden by an env
 *   var of the same name (the v1 book at the current pin predates the 4663
 *   core deploy, so they are absent there until it lands). Venue keys the
 *   protocol does not carry (the Stonk pads and lens) live in
 *   `script/launchpad/addresses-4663.json`, with their identity evidence.
 *
 *   Record the printed `padSetHash` with the grant: the codehash snapshot pins
 *   the Stonk adapter's CODE, and that hash is the only on-chain witness of the
 *   lane CONFIGURATION the code was granted with.
 *
 *   Usage:
 *     forge script script/launchpad/DeployLaunchpadStrategy.s.sol:DeployLaunchpadStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 */
contract DeployLaunchpadStrategy is Script {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170).
    uint256 internal constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    string internal constant PROTOCOL_BOOK = "/lib/sherwood-protocol/chains/4663.json";
    string internal constant LAUNCHPAD_BOOK = "/script/launchpad/addresses-4663.json";

    /// @notice What the last `deploy` produced, for the fork rehearsal to read.
    StonkLaunchAdapter public stonkAdapter;
    LaunchpadStrategy public template;

    function run() external {
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );
        deploy(_protocolAddress("TIER_REGISTRY"), _protocolAddress("STRATEGY_FACTORY"));
    }

    /// @notice The ceremony, with the two protocol singletons passed in.
    /// @dev    Split from `run()` so the fork rehearsal can hand it a registry
    ///         and factory it controls without touching the environment, which
    ///         concurrently running tests would share. Either may be zero: the
    ///         matching steps are then printed instead of performed.
    function deploy(address registry, address factory) public {
        (address[] memory quotes, address[] memory pads) = _stonkLaneSet();
        address lens = _launchpadAddress("SAFE_LAUNCH_LENS_V2");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood Chain (chain ID 4663)");

        stonkAdapter = new StonkLaunchAdapter(quotes, pads, lens);
        template = new LaunchpadStrategy();

        // SUSHI V2: added on the sushi-v2 branch. Deploy the Sushi Launchpad V2
        // adapter here, after the Stonk adapter and before the grants below, and
        // append it and the venue contract(s) it calls to `counterparties`.

        address[] memory counterparties = _counterparties(address(stonkAdapter), pads, lens);

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
        console.log("StonkLaunchAdapter padSetHash:");
        console.logBytes32(stonkAdapter.padSetHash());

        _printRunbook(registry, factory, counterparties, ownsRegistry, ownsFactory);
        _printValidation(registry, factory, counterparties);
    }

    /// @dev Every address this ceremony vouches for, adapter first.
    function _counterparties(address adapter, address[] memory pads, address lens)
        internal
        pure
        returns (address[] memory list)
    {
        list = new address[](pads.length + 2);
        list[0] = adapter;
        for (uint256 i; i < pads.length; ++i) {
            list[i + 1] = pads[i];
        }
        list[pads.length + 1] = lens;
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

    /// @dev A protocol-owned key: env override first, then the protocol's own
    ///      book. `address(0)` when neither has it — the caller decides whether
    ///      that is fatal.
    function _protocolAddress(string memory key) internal view returns (address) {
        address fromEnv = vm.envOr(key, address(0));
        if (fromEnv != address(0)) return fromEnv;
        return _optionalFrom(string.concat(vm.projectRoot(), PROTOCOL_BOOK), key);
    }

    /// @dev A venue key from this repo's launchpad book. Mandatory.
    function _launchpadAddress(string memory key) internal view returns (address a) {
        a = _optionalLaunchpadAddress(key);
        require(a != address(0), string.concat(key, " missing from script/launchpad/addresses-4663.json"));
    }

    function _optionalLaunchpadAddress(string memory key) internal view returns (address) {
        return _optionalFrom(string.concat(vm.projectRoot(), LAUNCHPAD_BOOK), key);
    }

    function _optionalFrom(string memory path, string memory key) internal view returns (address) {
        string memory json;
        try vm.readFile(path) returns (string memory contents) {
            json = contents;
        } catch {
            return address(0);
        }
        string memory jsonKey = string.concat(".", key);
        if (!vm.keyExistsJson(json, jsonKey)) return address(0);
        return vm.parseJsonAddress(json, jsonKey);
    }
}
