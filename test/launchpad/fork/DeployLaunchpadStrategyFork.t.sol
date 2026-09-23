// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";

import {DeployLaunchpadStrategy} from "../../../script/launchpad/DeployLaunchpadStrategy.s.sol";
import {LaunchpadStrategy} from "../../../src/launchpad/LaunchpadStrategy.sol";
import {SushiLaunchAdapter} from "../../../src/launchpad/adapters/SushiLaunchAdapter.sol";
import {StonkLaunchAdapter} from "../../../src/launchpad/adapters/StonkLaunchAdapter.sol";
import {IStonkSafeLaunchpadV2} from "../../../src/launchpad/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";
import {MockSwapAdapter} from "../../mocks/MockSwapAdapter.sol";

/// @dev Lifts the `internal view` lane gates into reach, so the rules are
///      tested directly rather than by staging mis-filed books on disk.
contract DeployLaunchpadHarness is DeployLaunchpadStrategy {
    function exposed_stonkLaneSet() external view returns (address[] memory quotes, address[] memory pads) {
        return _stonkLaneSet();
    }

    function exposed_requireNoV3Pads(address[] memory pads, string[8] memory lanes) external view {
        _requireNoV3Pads(pads, lanes);
    }
}

/// @dev The two hops `LaunchpadStrategy` walks to find its registry, and the
///      vault surface `_initialize` reads. Enough to prove the ceremony leaves
///      the template BINDABLE, which is the property the grants exist for.
contract ForkStubGovernor {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }
}

contract ForkStubVault {
    address public asset;
    address public governor;

    constructor(address asset_, address governor_) {
        asset = asset_;
        governor = governor_;
    }

    function isAgent(address) external pure returns (bool) {
        return true;
    }
}

/**
 * @title DeployLaunchpadStrategyForkTest
 * @notice FORK REHEARSAL of `script/launchpad/DeployLaunchpadStrategy.s.sol`.
 *         The script is mainnet-only by construction — the venues exist on
 *         4663 and nowhere else — so a 4663 fork is the only place its guards
 *         and its happy path can be exercised at all.
 *
 * @dev NOTHING HERE WRITES TO DISK. The script records deployments in its own
 *      public state rather than patching an address book, so every test reads
 *      the books and none mutates them, and the suite is safe under Foundry's
 *      concurrent test execution.
 *
 *      Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention).
 *
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        forge test --match-contract DeployLaunchpadStrategyFork -vv
 */
contract DeployLaunchpadStrategyForkTest is Test {
    /// @dev Robinhood Chain MaxCodeSize — 4x EIP-170. Mirrors the script.
    uint256 constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev The eight V2 (mint-launch) lanes in the SCRIPT'S OWN ORDER. The
    ///      order is part of `padSetHash`, which is why it is pinned here
    ///      independently rather than read back off the adapter.
    string[8] LANES = ["WETH", "STONK", "USDG", "GME", "NVDA", "AAPL", "SPCX", "USO"];

    string book;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 pin = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pin);
        }
        // NORMALISE THE CHAIN ID, so the same suite rehearses on an archive
        // vnet that reports a different id against the mainnet books.
        vm.chainId(4663);
        book = vm.readFile(string.concat(vm.projectRoot(), "/script/launchpad/addresses-4663.json"));
        forked = true;
    }

    function _skipIfNoFork() internal {
        // `vm.skip` from the TEST BODY, never `setUp` — the setUp form reports
        // `[FAIL: skipped]` on some forge versions.
        if (!forked) vm.skip(true);
    }

    // ── the happy path: the whole ceremony ──

    /// @notice `run()` completes on a 4663 fork: the adapter and the template
    ///         are deployed, the template fits Robinhood's 98,304-byte limit,
    ///         and the `padSetHash` it prints is reproducible from the book by
    ///         anyone holding it. With no registry or factory resolvable at
    ///         this pin, every owner step is printed rather than performed.
    function test_run_ceremonyCompletesOnA4663Fork() public {
        _skipIfNoFork();

        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.run();

        address stonk = address(script.stonkAdapter());
        address template = address(script.template());
        assertTrue(stonk.code.length != 0, "StonkLaunchAdapter deployed");
        assertTrue(template.code.length != 0, "LaunchpadStrategy template deployed");
        assertEq(StonkLaunchAdapter(stonk).implementation(), stonk, "the deployed Stonk adapter IS the implementation");
        address sushi = address(script.sushiAdapter());
        assertEq(
            SushiLaunchAdapter(payable(sushi)).implementation(),
            sushi,
            "the deployed Sushi adapter IS the implementation"
        );
        assertEq(
            address(SushiLaunchAdapter(payable(sushi)).launchpad()),
            _bookAddress("SUSHI_LAUNCHPAD_V2"),
            "Sushi adapter fronts the V2 launchpad"
        );

        // ── the Robinhood code-size limit ──
        uint256 size = template.code.length;
        console2.log("LaunchpadStrategy runtime size:", size);
        console2.log("Robinhood MaxCodeSize:         ", ROBINHOOD_MAX_CODE_SIZE);
        assertLt(size, ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");
        // And it really is the template: a locked, vault-less clone source.
        assertEq(LaunchpadStrategy(template).vault(), address(0), "a template binds no vault");

        // ── padSetHash, recomputed from the book by an independent path ──
        (address[] memory quotes, address[] memory pads) = _laneSetFromBook();
        bytes32 expected = keccak256(abi.encode(quotes, pads));
        assertEq(
            StonkLaunchAdapter(stonk).padSetHash(),
            expected,
            "padSetHash is not keccak256(abi.encode(quotes, pads)) over the book's eight V2 lanes"
        );
        (address[] memory onChainQuotes, address[] memory onChainPads) = StonkLaunchAdapter(stonk).lanes();
        assertEq(onChainQuotes.length, 8, "eight V2 lanes, no V3 pads");
        for (uint256 i; i < 8; ++i) {
            assertEq(onChainQuotes[i], quotes[i], "lane quote order");
            assertEq(onChainPads[i], pads[i], "lane pad order");
        }
        console2.log("padSetHash:");
        console2.logBytes32(expected);
    }

    /// @notice When the broadcaster OWNS the registry and the factory, the
    ///         ceremony performs every v1 step itself: the adapter, the eight
    ///         pads and the lens become allowed counterparties, and the template
    ///         is approved on the factory. Then the proof that matters — a clone
    ///         of the template BINDS against that registry and the live venue.
    function test_deploy_performsTheV1StepsWhenTheBroadcasterOwnsThem() public {
        _skipIfNoFork();

        (TierRegistry registry, StrategyFactory factory) = _ownedSingletons(_broadcaster());
        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.deploy(address(registry), address(factory));

        address stonk = address(script.stonkAdapter());
        address template = address(script.template());
        assertTrue(registry.isCounterpartyAllowed(stonk), "adapter granted");
        (, address[] memory pads) = _laneSetFromBook();
        for (uint256 i; i < pads.length; ++i) {
            assertTrue(registry.isCounterpartyAllowed(pads[i]), "pad granted");
        }
        assertTrue(registry.isCounterpartyAllowed(_bookAddress("SAFE_LAUNCH_LENS_V2")), "lens granted");
        assertTrue(registry.isCounterpartyAllowed(address(script.sushiAdapter())), "Sushi adapter granted");
        assertTrue(registry.isCounterpartyAllowed(_bookAddress("SUSHI_LAUNCHPAD_V2")), "Sushi launchpad granted");
        assertTrue(factory.approvedTemplate(template), "template approved");

        // The template binds: a WETH-quoted clone initializes against the
        // granted adapter on the live WETH pad.
        MockSwapAdapter swap = new MockSwapAdapter();
        vm.prank(_broadcaster());
        registry.setCounterpartyAllowed(address(swap), true);
        ForkStubVault vault = new ForkStubVault(WETH, address(new ForkStubGovernor(address(registry))));

        LaunchpadStrategy clone = LaunchpadStrategy(Clones.clone(template));
        clone.initialize(address(vault), address(this), abi.encode(_initParams(stonk, address(swap))));
        assertEq(address(clone.launchAdapter()), stonk, "bound to the granted adapter");
    }

    /// @notice `verifyDeployment` accepts exactly what a complete owned ceremony
    ///         produced, and a run inside `forge test` records nothing in the
    ///         deployments book (writes happen on a real broadcast only).
    function test_verify_acceptsACompleteDeploymentAndTestsWriteNoBook() public {
        _skipIfNoFork();

        (TierRegistry registry, StrategyFactory factory) = _ownedSingletons(_broadcaster());
        vm.prank(_broadcaster());
        registry.setStrategyFactory(address(factory));
        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.deploy(address(registry), address(factory));

        script.verifyDeployment(
            address(registry),
            address(factory),
            address(script.template()),
            address(script.stonkAdapter()),
            address(script.sushiAdapter())
        );
        assertFalse(vm.exists(script.deploymentsPath(block.chainid)), "a test run wrote the deployments book");
    }

    /// @notice A deployment still owed its Safe transactions fails verification.
    function test_verify_refusesADeploymentStillOwedOwnerSteps() public {
        _skipIfNoFork();

        (TierRegistry registry, StrategyFactory factory) = _ownedSingletons(makeAddr("ownerSafe"));
        vm.prank(makeAddr("ownerSafe"));
        registry.setStrategyFactory(address(factory));
        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.deploy(address(registry), address(factory));

        // Read the addresses first: `expectRevert` applies to the very next
        // call, and the getters would otherwise consume it.
        address template = address(script.template());
        address stonk = address(script.stonkAdapter());
        address sushi = address(script.sushiAdapter());
        vm.expectRevert(bytes("template not approved on StrategyFactory"));
        script.verifyDeployment(address(registry), address(factory), template, stonk, sushi);
    }

    /// @notice A broadcaster that does NOT own the registry or the factory
    ///         (mainnet, once the Safe has accepted ownership) writes nothing:
    ///         the steps are printed as Safe transactions, and the template
    ///         stays unbindable until the Safe executes them.
    function test_deploy_writesNothingWhenTheBroadcasterDoesNotOwnThem() public {
        _skipIfNoFork();

        address safe = makeAddr("ownerSafe");
        (TierRegistry registry, StrategyFactory factory) = _ownedSingletons(safe);
        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.deploy(address(registry), address(factory));

        assertFalse(registry.isCounterpartyAllowed(address(script.stonkAdapter())), "no grant without ownership");
        assertFalse(registry.isCounterpartyAllowed(address(script.sushiAdapter())), "no Sushi grant without ownership");
        assertFalse(factory.approvedTemplate(address(script.template())), "no approval without ownership");
    }

    // ── replacing only the Stonk adapter ──

    /// @notice `redeployStonkAdapter` over a complete owned deployment: a new
    ///         adapter with the same lanes is granted, the old one stays
    ///         allowed (its revoke is the owner's call), the template and the
    ///         Sushi adapter are untouched, the deployment verifies with the new
    ///         address, and a test run writes no book.
    function test_redeployStonk_grantsTheNewAdapterAndLeavesTheRestAlone() public {
        _skipIfNoFork();

        (TierRegistry registry, StrategyFactory factory) = _ownedSingletons(_broadcaster());
        vm.prank(_broadcaster());
        registry.setStrategyFactory(address(factory));
        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.deploy(address(registry), address(factory));
        address oldStonk = address(script.stonkAdapter());
        address template = address(script.template());
        address sushi = address(script.sushiAdapter());

        script.redeployStonkAdapter(address(registry), oldStonk);
        address newStonk = address(script.stonkAdapter());

        assertTrue(newStonk != oldStonk, "a new adapter was deployed");
        assertEq(StonkLaunchAdapter(newStonk).implementation(), newStonk, "the new adapter IS the implementation");
        assertEq(
            StonkLaunchAdapter(newStonk).padSetHash(),
            StonkLaunchAdapter(oldStonk).padSetHash(),
            "same lanes as the adapter it replaces"
        );
        assertTrue(registry.isCounterpartyAllowed(newStonk), "new adapter granted");
        assertTrue(registry.isCounterpartyAllowed(oldStonk), "old adapter left allowed");
        assertEq(address(script.template()), template, "template untouched");
        assertEq(address(script.sushiAdapter()), sushi, "Sushi adapter untouched");

        script.verifyDeployment(address(registry), address(factory), template, newStonk, sushi);
        assertFalse(vm.exists(script.deploymentsPath(block.chainid)), "a test run wrote the deployments book");
    }

    /// @notice Without registry ownership the new adapter is deployed but not
    ///         granted; the Safe executes the printed transaction.
    function test_redeployStonk_grantsNothingWhenTheBroadcasterDoesNotOwnTheRegistry() public {
        _skipIfNoFork();

        address safe = makeAddr("ownerSafe");
        (TierRegistry registry, StrategyFactory factory) = _ownedSingletons(safe);
        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.deploy(address(registry), address(factory));
        address oldStonk = address(script.stonkAdapter());

        script.redeployStonkAdapter(address(registry), oldStonk);
        assertFalse(registry.isCounterpartyAllowed(address(script.stonkAdapter())), "no grant without ownership");
    }

    function test_redeployStonk_rejectsAWrongChainId() public {
        _skipIfNoFork();
        vm.chainId(1);

        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        vm.expectRevert(bytes("wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork"));
        script.redeployStonk();
    }

    // ── the Stonk lane set ──

    /// @notice The lanes the book actually names are internally consistent:
    ///         each pad claims its own lane's quote, and the eight quotes are
    ///         distinct. This is the precondition the mis-file tests perturb.
    function test_stonkLaneSet_theBooksLanesAreConsistent() public {
        _skipIfNoFork();

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        (address[] memory quotes, address[] memory pads) = harness.exposed_stonkLaneSet();
        (address[] memory bookQuotes, address[] memory bookPads) = _laneSetFromBook();

        assertEq(quotes.length, 8, "eight lanes");
        for (uint256 i; i < 8; ++i) {
            assertEq(pads[i], bookPads[i], "pad from the book");
            assertEq(quotes[i], bookQuotes[i], "quote read off the pad");
            for (uint256 j; j < i; ++j) {
                assertTrue(quotes[i] != quotes[j], "two lanes claim the same quote");
            }
        }
    }

    /// @notice A MIS-FILED PAD MUST FAIL THE DEPLOY rather than ship a mis-wired
    ///         lane. The V2 USDG pad filed under the GME key makes two lanes
    ///         claim USDG, and `StonkLaunchAdapter`'s constructor refuses the
    ///         second — so the ceremony aborts with nothing deployed.
    ///
    /// @dev    WHICH GUARD FIRES MATTERS. `_stonkLaneSet` DERIVES each
    ///         `quotes[i]` by asking `pads[i].quote()`, so the constructor's
    ///         `PadQuoteMismatch` compares a value against itself and is
    ///         UNREACHABLE from this call path. What actually catches the
    ///         mis-file is `DuplicateQuote` — and only when the mis-filed pad
    ///         collides with another lane. See the next test for the case that
    ///         therefore slips through the adapter.
    function test_stonkLaneSet_misfiledV2PadFailsTheDeploy() public {
        _skipIfNoFork();

        // Lane 3 is GME; file the USDG pad there, the way a copy-paste would.
        (address[] memory quotes, address[] memory pads) = _laneSetWithPadSubstitutedAt(3, _bookPad("USDG"));
        assertEq(quotes[3], quotes[2], "premise: the mis-filed pad claims lane 2's quote");

        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.DuplicateQuote.selector, quotes[2]));
        new StonkLaunchAdapter(quotes, pads, _bookAddress("SAFE_LAUNCH_LENS_V2"));
    }

    /// @dev THE ADAPTER CANNOT CATCH THIS, AND THAT IS NOT ITS JOB. A V3
    ///      (external-token) pad reports the same `quote()` as its V2 sibling,
    ///      so filing one under a V2 key collides with no other lane and the
    ///      constructor's `DuplicateQuote` never fires; `PadQuoteMismatch`
    ///      cannot fire either, since the script derives each quote from the
    ///      pad itself. The deploy script has to carry the check — see the
    ///      test below, which is the one that matters.
    function test_stonkLaneSet_theAdapterAloneCannotSeeAV3Pad() public {
        _skipIfNoFork();

        address v3Usdg = _bookAddress("STONK_SAFE_LAUNCHPAD_V3_USDG");
        address v2Usdg = _bookPad("USDG");
        assertEq(
            IStonkSafeLaunchpadV2(v3Usdg).quote(),
            IStonkSafeLaunchpadV2(v2Usdg).quote(),
            "premise: the V3 pad claims the same quote as its V2 sibling"
        );

        (address[] memory quotes, address[] memory pads) = _laneSetWithPadSubstitutedAt(2, v3Usdg);
        StonkLaunchAdapter misWired = new StonkLaunchAdapter(quotes, pads, _bookAddress("SAFE_LAUNCH_LENS_V2"));
        assertEq(misWired.padOf(quotes[2]), v3Usdg, "the adapter wires it in without complaint");
    }

    /// @dev THE SCRIPT DOES catch it — the guard that closes the hole the test
    ///      above documents.
    function test_stonkLaneSet_scriptRejectsAV3PadFiledUnderAV2Key() public {
        _skipIfNoFork();

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        string[8] memory lanes = ["WETH", "STONK", "USDG", "GME", "NVDA", "AAPL", "SPCX", "USO"];

        // Sanity: the book's own lane set passes the guard untouched.
        (, address[] memory goodPads) = _laneSetFromBook();
        harness.exposed_requireNoV3Pads(goodPads, lanes);

        // Substituting ANY V3 pad, under ANY lane key, is refused.
        (, address[] memory badPads) = _laneSetWithPadSubstitutedAt(2, _bookAddress("STONK_SAFE_LAUNCHPAD_V3_USDG"));
        vm.expectRevert(bytes("a V3 (external-token) pad is filed under a V2 lane key"));
        harness.exposed_requireNoV3Pads(badPads, lanes);

        // ...including one whose own lane differs from the key it sits under,
        // which is the case `DuplicateQuote` would also have missed.
        (, address[] memory crossPads) = _laneSetWithPadSubstitutedAt(4, _bookAddress("STONK_SAFE_LAUNCHPAD_V3_GME"));
        vm.expectRevert(bytes("a V3 (external-token) pad is filed under a V2 lane key"));
        harness.exposed_requireNoV3Pads(crossPads, lanes);
    }

    // ── the chain guard ──

    /// @notice A script that can only work on 4663 must refuse to run anywhere
    ///         else, before it reads a book or deploys anything.
    function test_run_rejectsAWrongChainId() public {
        _skipIfNoFork();
        vm.chainId(1);

        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        vm.expectRevert(bytes("wrong chain: expected Robinhood mainnet 4663 or its 9994663 fork"));
        script.run();
    }

    // ── helpers ──

    /// @dev The address `vm.startBroadcast()` (no arguments) signs as inside a
    ///      test: the test's `tx.origin`.
    function _broadcaster() internal view returns (address) {
        return tx.origin;
    }

    /// @dev A real v1 `TierRegistry` and `StrategyFactory`, both owned by
    ///      `owner`. The factory's syndicate-factory hop is never exercised
    ///      here, so any nonzero address satisfies its constructor.
    function _ownedSingletons(address owner) internal returns (TierRegistry registry, StrategyFactory factory) {
        registry = new TierRegistry(owner);
        factory = new StrategyFactory(makeAddr("syndicateFactory"), owner);
    }

    function _initParams(address stonk, address swap) internal view returns (LaunchpadStrategy.InitParams memory) {
        return LaunchpadStrategy.InitParams({
            launchAdapter: stonk,
            swapAdapter: swap,
            assetIn: 1 ether,
            quoteToken: WETH,
            minQuoteOut: 0,
            quoteSwapData: "",
            feeSwapData: "",
            launchSupply: 1_000_000_000e18,
            reserveAmount: 100_000_000e18,
            minTokensOut: 0,
            claimWindow: 7 days,
            deadline: uint64(block.timestamp + 1 days),
            settleSlippageBps: 500,
            maxFeeIn: 0,
            name: "Fork Fund",
            symbol: "FORK",
            venueData: ""
        });
    }

    function _bookAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(book, string.concat(".", key));
    }

    function _bookPad(string memory lane) internal view returns (address) {
        return _bookAddress(string.concat("STONK_SAFE_LAUNCHPAD_V2_", lane));
    }

    /// @dev `_stonkLaneSet`, reproduced from the book by an independent path —
    ///      so `padSetHash` is checked against the CONFIGURATION rather than
    ///      against the code that produced it.
    function _laneSetFromBook() internal view returns (address[] memory quotes, address[] memory pads) {
        quotes = new address[](8);
        pads = new address[](8);
        for (uint256 i; i < 8; ++i) {
            pads[i] = _bookPad(LANES[i]);
            quotes[i] = IStonkSafeLaunchpadV2(pads[i]).quote();
            assertTrue(quotes[i] != address(0), "pad reports no quote token");
        }
    }

    /// @dev The same derivation with ONE pad swapped — a mis-filed book,
    ///      without writing a mis-filed book.
    function _laneSetWithPadSubstitutedAt(uint256 index, address pad)
        internal
        view
        returns (address[] memory quotes, address[] memory pads)
    {
        (quotes, pads) = _laneSetFromBook();
        pads[index] = pad;
        quotes[index] = IStonkSafeLaunchpadV2(pad).quote();
    }
}
