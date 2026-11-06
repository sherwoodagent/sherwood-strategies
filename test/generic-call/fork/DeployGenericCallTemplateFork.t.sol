// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {BatchExecutorLib} from "@sherwood/BatchExecutorLib.sol";
import {IStrategy} from "@sherwood/interfaces/IStrategy.sol";
import {GenericCallStrategy, IProtocolPath} from "../../../src/generic-call/GenericCallStrategy.sol";
import {DeployGenericCallTemplate} from "../../../script/generic-call/DeployGenericCallTemplate.s.sol";
import {MockCallVenue} from "../../mocks/GenericCallMocks.sol";

/// @dev The one `SyndicateFactory` read this suite needs, to find a live vault.
interface ISyndicateList {
    struct Syndicate {
        uint256 id;
        address vault;
        address creator;
        string metadataURI;
        uint256 createdAt;
        bool active;
        string subdomain;
    }

    function getActiveSyndicates(uint256 offset, uint256 limit)
        external
        view
        returns (Syndicate[] memory result, uint256 total);
}

/**
 * @title DeployGenericCallTemplateForkTest
 * @notice FORK REHEARSAL of `script/generic-call/DeployGenericCallTemplate.s.sol`
 *         against the live v1 stack on Robinhood 4663: the script's ceremony
 *         against the live `StrategyFactory` and `TierRegistry`, the owner's
 *         approval landing afterwards, and a clone of the template binding to a
 *         live vault through the live factory. The binding is the point: the
 *         template's `_initialize` walks the vault's protocol contracts
 *         fail-closed, and the unit and lifecycle suites prove that walk only
 *         against code compiled from the pin, not against what 4663 runs.
 *
 * @dev The governor lifecycle (propose, vote, review, execute, settle) is
 *      covered by `test/generic-call/GenericCallStrategy_lifecycle.t.sol` on a
 *      local v1 stack, not here: on 4663 it would have to clear the factory's
 *      owner-only-proposal and restricted-deposit flags, the ExposureLedger's
 *      coverage quorum (guardian stake priced through the live WOOD feed) and
 *      the proposer bond at an unpinned block, none of which is about the
 *      template.
 *
 *      NOTHING HERE WRITES TO DISK: the script records on a real broadcast
 *      only, and `test_run_ceremonyCompletesOnTheFork` checks the committed
 *      book is unchanged.
 *
 *      Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention).
 *
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        forge test --match-contract DeployGenericCallTemplateFork -vv
 */
contract DeployGenericCallTemplateForkTest is Test {
    uint256 constant CHAIN_ROBINHOOD = 4663;
    uint256 constant CHAIN_ROBINHOOD_FORK = 9994663;
    /// @dev Robinhood Chain MaxCodeSize, 4x EIP-170. Mirrors the script.
    uint256 constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    /// @dev Protocol v1 singletons on 4663, as `deployments/README.md` and the
    ///      `_meta` sections of `deployments/4663.json` record them. The pinned
    ///      protocol book for 4663 names both since `a91fae2f`; the constants
    ///      keep this suite independent of the book.
    address constant STRATEGY_FACTORY = 0xb06788F027268a9A06c3AD41a88559530D2E54b1;
    address constant TIER_REGISTRY = 0x4614f058920941A0a9a852e62485fbDE692D75E1;
    /// @dev `StrategyFactory.syndicateFactory()` on 4663, read 2026-10-19
    ///      (`script/launchpad/addresses-4663.json`).
    address constant SYNDICATE_FACTORY = 0x619af1488F32B4797f6faDa3C3a8De72a5B693E0;

    bool forked;
    DeployGenericCallTemplate script;

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
        // vnet that reports a different id against the mainnet addresses.
        vm.chainId(CHAIN_ROBINHOOD);
        script = new DeployGenericCallTemplate();
        forked = true;
    }

    function _skipIfNoFork() internal {
        // `vm.skip` from the TEST BODY, never `setUp`: the setUp form reports
        // `[FAIL: skipped]` on some forge versions.
        if (!forked) vm.skip(true);
    }

    /// @notice `run()` completes on the fork. It resolves the singletons from
    ///         the pinned 9994663 book (the same live addresses), deploys, passes
    ///         the wiring and uncertified checks against the live registry, and
    ///         fits the code-size limit. The test contract does not own the
    ///         factory, so the approval is printed, not performed, and the
    ///         committed book is left as it was.
    function test_run_ceremonyCompletesOnTheFork() public {
        _skipIfNoFork();
        vm.chainId(CHAIN_ROBINHOOD_FORK);
        bytes32 bookBefore = _bookHash();
        script.run();
        assertEq(_bookHash(), bookBefore, "a test run wrote the deployments book");
    }

    /// @notice The 4663 path: a deployer key that does not own the factory runs
    ///         the ceremony (incomplete), the owner approves afterwards, and the
    ///         deployment then verifies against the live singletons.
    function test_ceremony_thenOwnerApproval_verifiesOnLive4663() public {
        _skipIfNoFork();
        (address template, bool complete) = script.ceremony(STRATEGY_FACTORY, TIER_REGISTRY, makeAddr("deployerKey"));
        assertFalse(complete, "the deployer key does not own the live factory");
        assertFalse(StrategyFactory(STRATEGY_FACTORY).approvedTemplate(template));
        assertLt(template.code.length, ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");

        vm.expectRevert(bytes("template not approved on StrategyFactory"));
        script.verifyDeployment(STRATEGY_FACTORY, TIER_REGISTRY, template);

        _approve(template);
        script.verifyDeployment(STRATEGY_FACTORY, TIER_REGISTRY, template);
    }

    /// @notice A clone cut through the live factory for a live vault binds,
    ///         is registered with its provenance, and prices at tier 2 / full
    ///         notional on the live registry.
    function test_clone_bindsToALiveVault() public {
        _skipIfNoFork();
        address vault = _liveVault();
        address template = _deployApproved();
        MockCallVenue venue = new MockCallVenue();
        address asset = _asset(vault);

        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](2);
        e[0] = _call(asset, abi.encodeCall(IERC20.approve, (address(venue), 1e6)));
        e[1] = _call(address(venue), abi.encodeCall(MockCallVenue.deposit, (asset, 1e6)));
        BatchExecutorLib.Call[] memory s = new BatchExecutorLib.Call[](1);
        s[0] = _call(address(venue), abi.encodeCall(MockCallVenue.withdraw, (asset, 1e6)));
        GenericCallStrategy clone = _clone(template, vault, abi.encode(uint256(1e6), e, s, _noPatch(), _noSweep()));

        StrategyFactory factory = StrategyFactory(STRATEGY_FACTORY);
        assertEq(factory.cloneTemplate(address(clone)), template, "provenance");
        assertTrue(factory.isRegisteredStrategy(address(clone)), "registered at clone time");
        assertEq(clone.vault(), vault);
        assertEq(clone.asset(), asset);
        assertEq(clone.pinnedCodehash(address(venue)), address(venue).codehash);
        (uint8 tier, uint16 bound) = TierRegistry(TIER_REGISTRY).tierOf(address(clone), IStrategy.execute.selector);
        assertEq(tier, 2, "uncertified clone prices at tier 2");
        assertEq(bound, 10_000, "full notional");
    }

    /// @notice Every protocol contract around a live vault resolves through the
    ///         template's walk and is refused as a call target. The three hops
    ///         this repo books independently are checked against the book.
    function test_denylist_refusesEveryLiveProtocolContract() public {
        _skipIfNoFork();
        address vault = _liveVault();
        address template = _deployApproved();

        address gov = IProtocolPath(vault).governor();
        address ledger = IProtocolPath(gov).exposureLedger();
        address guardianRegistry = IProtocolPath(gov).guardianRegistry();
        address[10] memory denied = [
            vault,
            gov,
            IProtocolPath(vault).factory(),
            IProtocolPath(gov).tierRegistry(),
            IProtocolPath(IProtocolPath(gov).tierRegistry()).strategyFactory(),
            guardianRegistry,
            IProtocolPath(guardianRegistry).swood(),
            IProtocolPath(vault).withdrawalQueue(),
            ledger,
            ledger == address(0) ? address(0) : IProtocolPath(ledger).coverageFreezer()
        ];
        assertEq(denied[2], SYNDICATE_FACTORY, "vault.factory()");
        assertEq(denied[3], TIER_REGISTRY, "governor.tierRegistry()");
        assertEq(denied[4], STRATEGY_FACTORY, "tierRegistry.strategyFactory()");

        for (uint256 k; k < denied.length; ++k) {
            // The first seven are fail-closed and must resolve; the queue, the
            // ledger and the game may be unset, and then deny nothing.
            if (k < 7) assertTrue(denied[k] != address(0), vm.toString(k));
            if (denied[k] == address(0)) continue;
            BatchExecutorLib.Call[] memory bad = new BatchExecutorLib.Call[](1);
            bad[0] = _call(denied[k], hex"12345678");
            bytes memory data = abi.encode(uint256(0), bad, new BatchExecutorLib.Call[](0), _noPatch(), _noSweep());
            address proposer = makeAddr("proposer");
            vm.prank(proposer);
            vm.expectRevert(abi.encodeWithSelector(GenericCallStrategy.ForbiddenTarget.selector, 0, 0, denied[k]));
            StrategyFactory(STRATEGY_FACTORY).cloneAndInit(template, vault, proposer, data);
        }
    }

    // ── helpers ──

    function _deployApproved() internal returns (address template) {
        (template,) = script.ceremony(STRATEGY_FACTORY, TIER_REGISTRY, makeAddr("deployerKey"));
        _approve(template);
    }

    /// @dev The live factory's owner approves, as it would after the deploy.
    function _approve(address template) internal {
        StrategyFactory factory = StrategyFactory(STRATEGY_FACTORY);
        vm.prank(factory.owner());
        factory.setTemplateApproval(template, true);
    }

    function _clone(address template, address vault, bytes memory data) internal returns (GenericCallStrategy) {
        address proposer = makeAddr("proposer");
        vm.prank(proposer);
        return GenericCallStrategy(StrategyFactory(STRATEGY_FACTORY).cloneAndInit(template, vault, proposer, data));
    }

    /// @dev The first active syndicate's vault; skips if 4663 has none.
    function _liveVault() internal returns (address) {
        (ISyndicateList.Syndicate[] memory list, uint256 total) =
            ISyndicateList(SYNDICATE_FACTORY).getActiveSyndicates(0, 1);
        if (total == 0) vm.skip(true);
        return list[0].vault;
    }

    function _asset(address vault) internal view returns (address) {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSignature("asset()"));
        require(ok && ret.length == 32, "vault has no asset()");
        return abi.decode(ret, (address));
    }

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _noPatch() internal pure returns (GenericCallStrategy.BalancePatch[] memory) {
        return new GenericCallStrategy.BalancePatch[](0);
    }

    function _noSweep() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Hash of this chain's committed deployments book (zero if absent).
    function _bookHash() internal view returns (bytes32) {
        string memory path = script.deploymentsPath(block.chainid);
        return vm.exists(path) ? keccak256(bytes(vm.readFile(path))) : bytes32(0);
    }
}
