// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {BatchExecutorLib} from "@sherwood/BatchExecutorLib.sol";
import {IProposalStatus} from "@sherwood/interfaces/IProposalStatus.sol";
import {ISyndicateGovernor} from "@sherwood/interfaces/ISyndicateGovernor.sol";
import {IExposureLedger} from "@sherwood/interfaces/IExposureLedger.sol";
import {BaseStrategy} from "@sherwood/strategies/BaseStrategy.sol";
import {GenericCallStrategy, IProtocolPath} from "../../../src/generic-call/GenericCallStrategy.sol";

/// @notice The Seaport 1.6 surface these tests use. Enums are `uint8` (same ABI).
interface ISeaport16 {
    struct OfferItem {
        uint8 itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
    }

    struct ConsiderationItem {
        uint8 itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
        address recipient;
    }

    struct OrderParameters {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        uint8 orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 totalOriginalConsiderationItems;
    }

    struct OrderComponents {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        uint8 orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 counter;
    }

    struct Order {
        OrderParameters parameters;
        bytes signature;
    }

    struct AdvancedOrder {
        OrderParameters parameters;
        uint120 numerator;
        uint120 denominator;
        bytes signature;
        bytes extraData;
    }

    struct CriteriaResolver {
        uint256 orderIndex;
        uint8 side;
        uint256 index;
        uint256 identifier;
        bytes32[] criteriaProof;
    }

    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool);
    function fulfillOrder(Order calldata order, bytes32 fulfillerConduitKey) external payable returns (bool);
    function validate(Order[] calldata orders) external returns (bool);
    function getOrderHash(OrderComponents calldata order) external view returns (bytes32);
    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize);
    function getCounter(address offerer) external view returns (uint256);
    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);
}

interface IVaultLite {
    function agentsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory);
    function owner() external view returns (address);
    function rescueERC721(address token, uint256 tokenId, address to) external;
}

interface IRegistryLite {
    function openReview(address governor, uint256 proposalId) external;
    function voteOnProposal(address governor, uint256 proposalId, uint8 support, uint256 lockWood) external;
}

interface IBondEscrowLite {
    function wood() external view returns (address);
}

interface IGovernorLite {
    function propose(
        address vault,
        address strategy,
        string calldata metadataURI,
        uint256 strategyDuration,
        ISyndicateGovernor.RiskEnvelope calldata envelope,
        BatchExecutorLib.Call[] calldata executeCalls,
        uint256[] calldata executeCallCaps,
        BatchExecutorLib.Call[] calldata settlementCalls,
        uint256[] calldata settlementCallCaps,
        ISyndicateGovernor.CoProposer[] calldata coProposers
    ) external returns (uint256);
    function stateOf(uint256 proposalId) external view returns (ISyndicateGovernor.ProposalState);
    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory);
    function getRequiredCoverage(uint256 proposalId) external view returns (uint256);
    function getProposalTier(uint256 proposalId) external view returns (uint8);
    function executeProposal(uint256 proposalId) external;
    function settleProposal(uint256 proposalId) external;
    function cancelProposal(uint256 proposalId) external;
    function reclaimProposerBond(uint256 proposalId) external;
    function openProposalCount() external view returns (uint256);
    function exposureLedger() external view returns (address);
    function bondEscrow() external view returns (address);
}

/**
 * @title GenericCallSeaportForkTest
 * @notice SHE-535 stage 0 spike: can a Generic Call proposal on Robinhood 4663 buy an ERC-721
 *         listed on OpenSea (Seaport 1.6)? Runs the DEPLOYED Generic Call template
 *         (0xee67…9833, approved on the live StrategyFactory) bound to live vault #4
 *         (hermes-fund), against live Seaport 1.6, OpenSea's live conduit and a live
 *         PixelMultiverse ERC-721. Nothing is broadcast.
 *
 *         Route A: fill an OPEN (zone-free) listing in the execute leg. The listing has the
 *         shape OpenSea writes on 4663 for its zone-free listings (orderType 0, zone 0,
 *         OpenSea conduit key, 1% fee item to OpenSea's fee recipient); the seller is a
 *         test key because a live listing's maker key is not ours.
 *         A second route A test replays a REAL zone-free OpenSea listing from a recent fill
 *         (env-gated, see its comment).
 *         Route B: the clone validates its own Seaport offer at execute and a seller fills
 *         it later.
 *         Guardian gate: a real propose on vault #4's governor. Guardians silent: Approved but
 *         not executable. Positive control: the three active guardians Approve, and the whole
 *         proposal executes and settles.
 *
 * @dev The route tests mock the governor's active-proposal binding (`getActiveProposal`,
 *      `strategyOf`) and call `execute` / `settle` as the vault, as
 *      `GenericCallUniswapFork.t.sol` does. The vault is dealt the pull so live TVL is not
 *      touched. Skips when ROBINHOOD_RPC_URL is unset.
 *
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        forge test --match-contract GenericCallSeaportFork -vv
 */
contract GenericCallSeaportForkTest is Test {
    uint256 constant CHAIN_ROBINHOOD = 4663;

    address constant STRATEGY_FACTORY = 0xb06788F027268a9A06c3AD41a88559530D2E54b1;
    /// @dev The Generic Call template deployed on 4663.
    address constant TEMPLATE = 0xee67db9630fCB4F69C013928b2113C5489B39833;
    /// @dev Vault #4 (hermes-fund), a USDG vault; its governor is 0x52f0…C7CE.
    address constant VAULT = 0x2fD6056d9326e07Eec9Ba4499078C328E4F38b4A;
    address constant GOVERNOR = 0x52f0280ee76517A273038590C46E2fB2b6b9C7CE;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    /// @dev OpenSea SignedZone (Seaport 1.6) and fee recipient, as seen in live 4663 fills.
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant OPENSEA_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;
    /// @dev The conduit key on OpenSea's live 4663 listings; ConduitController resolves it to
    ///      0x963F…C300, the operator in live fills.
    bytes32 constant OPENSEA_CONDUIT_KEY = 0x61159fefdfada89302ed55f8b9e89e2d67d8258712b3a3f89aa88525877f1d5e;
    address constant OPENSEA_CONDUIT = 0x963F00d3ff000064fFCbA824b800c0000000C300;

    /// @dev PixelMultiverse, an ERC-721 traded for USDG on OpenSea on 4663. The tests prank
    ///      whoever holds TOKEN_ID at the fork block to hand it to the test seller.
    address constant NFT = 0x708c68526A6045ec3703A44B4F2c8e1f63fB84B6;
    uint256 constant TOKEN_ID = 111;

    /// @dev The three guardians active on the 4663 GuardianRegistry (from its GuardianVoteCast log).
    address constant GUARDIAN_A = 0x21bcF704D25Eca60Fdc428876Fc260f13a6297d3;
    address constant GUARDIAN_B = 0x6b0a8AEc688F61240dbe4Ab5baC9B3186eF3B861;
    address constant GUARDIAN_C = 0x5FF9c771e9B6bE570d555ed42c2ECb88751C93d7;

    uint8 constant ITEM_ERC20 = 1;
    uint8 constant ITEM_ERC721 = 2;
    uint8 constant FULL_OPEN = 0;
    uint8 constant FULL_RESTRICTED = 2;

    uint256 constant PULL = 10e6;
    uint256 constant PRICE = 7_800_000; // 7.8 USDG, the 4663 sale the notes cite

    bool forked;
    address seller;
    uint256 sellerKey;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 pin = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pin);
        }
        vm.chainId(CHAIN_ROBINHOOD);
        forked = true;
        (seller, sellerKey) = makeAddrAndKey("seller");
    }

    function _skipIfNoFork() internal {
        if (!forked) vm.skip(true);
    }

    // ── Seaport ABI sanity (selectors cross-checked with `cast sig`) ──

    function test_seaportSelectors() public pure {
        assertEq(ISeaport16.fulfillAdvancedOrder.selector, bytes4(0xe7acab24));
        assertEq(ISeaport16.fulfillOrder.selector, bytes4(0xb3a34c4c));
        assertEq(ISeaport16.validate.selector, bytes4(0x88147732));
        assertEq(ISeaport16.getOrderHash.selector, bytes4(0x79df72bd));
        assertEq(ISeaport16.getOrderStatus.selector, bytes4(0x46423aa7));
        assertEq(ISeaport16.getCounter.selector, bytes4(0xf07ec373));
    }

    // ── Route A ──

    /// @notice An open listing is filled by the deployed template inside the execute leg. The two
    ///         calls are encoded BEFORE the clone exists (recipient zero, fulfiller conduit key
    ///         zero, approve Seaport itself), so the clone address is never needed. Then settle,
    ///         and the NFT's way out through the vault.
    function test_routeA_openListingFilledFromFrozenCalls() public {
        _skipIfNoFork();
        _giveNft(seller);
        vm.prank(seller);
        IERC721(NFT).setApprovalForAll(OPENSEA_CONDUIT, true);
        ISeaport16.AdvancedOrder memory listing = _listing(FULL_OPEN, address(0));
        bytes32 orderHash = _hashOf(listing.parameters);

        // Frozen at propose: nothing below depends on the clone's address.
        bytes memory init = _routeAInit(listing, PRICE);
        GenericCallStrategy clone = _clone(init);

        uint256 vaultBefore = IERC20(USDG).balanceOf(VAULT);
        uint256 sellerBefore = IERC20(USDG).balanceOf(seller);
        uint256 feeBefore = IERC20(USDG).balanceOf(OPENSEA_FEE);
        _execute(clone);

        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), address(clone), "clone owns the NFT");
        assertEq(vaultBefore - IERC20(USDG).balanceOf(VAULT), PULL, "vault paid the pull");
        assertEq(IERC20(USDG).balanceOf(seller) - sellerBefore, PRICE - PRICE / 100, "seller paid");
        assertEq(IERC20(USDG).balanceOf(OPENSEA_FEE) - feeBefore, PRICE / 100, "OpenSea fee paid");
        assertEq(IERC20(USDG).balanceOf(address(clone)), PULL - PRICE, "change on the clone");
        assertEq(IERC20(USDG).allowance(address(clone), SEAPORT), 0, "execute grant revoked");
        (,, uint256 filled, uint256 size) = ISeaport16(SEAPORT).getOrderStatus(orderHash);
        assertEq(filled, 1, "order filled");
        assertEq(size, 1);

        // Settle returns only the asset: the vault ends PRICE short, the NFT stays on the clone.
        vm.prank(VAULT);
        clone.settle();
        assertEq(uint256(clone.state()), uint256(BaseStrategy.State.Settled));
        assertEq(vaultBefore - IERC20(USDG).balanceOf(VAULT), PRICE, "NAV short by the price");
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), address(clone), "NFT still on the clone after settle");
        console2.log("route A: price paid (USDG raw)", PRICE);
        console2.log("route A: vault asset short after settle (USDG raw)", vaultBefore - IERC20(USDG).balanceOf(VAULT));

        // Q7. Only the vault can call rescueERC721To; it works after settle too.
        vm.expectRevert();
        clone.rescueERC721To(NFT, TOKEN_ID);
        vm.prank(VAULT);
        clone.rescueERC721To(NFT, TOKEN_ID);
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), VAULT, "NFT moved to the vault");
        // In the vault, the owner's rescueERC721 sends it to any address (no proposal open).
        address pick = makeAddr("ownerPick");
        vm.prank(IVaultLite(VAULT).owner());
        IVaultLite(VAULT).rescueERC721(NFT, TOKEN_ID, pick);
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), pick, "owner rescued it out of the vault");
    }

    /// @notice Replays a REAL zone-free OpenSea listing that was filled on 4663: fork one block
    ///         before its fill, take the order and signature from the fill's calldata, and let a
    ///         clone of the deployed template on vault #4 buy it instead of the original buyer.
    ///         Skipped unless SEAPORT_REPLAY_ARGS (the fill's calldata without its selector),
    ///         SEAPORT_REPLAY_SELECTOR (0x87201b41, 0xe7acab24 or 0xb3a34c4c; a basic-order fill is
    ///         re-encoded as an Order first), SEAPORT_REPLAY_INDEX (the order's index for 0x87201b41)
    ///         and ROBINHOOD_FORK_BLOCK (fill block - 1) are set. Match fills are refused: their
    ///         zone-free half is the seller's own unsigned counter-order, not a listing.
    ///         The public RPC keeps only minutes of state, so this runs only right after a fill.
    function test_routeA_replayLiveOpenSeaListing() public {
        _skipIfNoFork();
        bytes memory args = vm.envOr("SEAPORT_REPLAY_ARGS", bytes(""));
        if (args.length == 0) vm.skip(true);
        uint256 sel = vm.envUint("SEAPORT_REPLAY_SELECTOR");
        ISeaport16.AdvancedOrder memory ao;
        if (sel == 0x87201b41) {
            ISeaport16.AdvancedOrder[] memory aos = abi.decode(args, (ISeaport16.AdvancedOrder[]));
            ao = aos[vm.envOr("SEAPORT_REPLAY_INDEX", uint256(0))];
        } else if (sel == 0xe7acab24) {
            ao = abi.decode(args, (ISeaport16.AdvancedOrder));
        } else {
            ISeaport16.Order memory o = abi.decode(args, (ISeaport16.Order));
            ao = ISeaport16.AdvancedOrder(o.parameters, 1, 1, o.signature, "");
        }
        ao.numerator = 1;
        ao.denominator = 1;
        assertGt(ao.signature.length, 0, "a signed listing, not a match counter-order");
        ISeaport16.OrderParameters memory p = ao.parameters;
        assertEq(p.zone, address(0), "zone-free");
        assertEq(p.orderType, FULL_OPEN, "open order");
        assertEq(p.offer.length, 1);
        assertEq(p.offer[0].itemType, ITEM_ERC721, "an ERC-721 listing");
        uint256 price;
        for (uint256 i; i < p.consideration.length; ++i) {
            assertEq(p.consideration[i].token, USDG, "priced in USDG");
            price += p.consideration[i].startAmount;
        }
        address nft = p.offer[0].token;
        uint256 id = p.offer[0].identifierOrCriteria;
        assertEq(IERC721(nft).ownerOf(id), p.offerer, "seller still holds it one block before the fill");
        bytes32 orderHash = _hashOf(p);
        (,, uint256 filledBefore,) = ISeaport16(SEAPORT).getOrderStatus(orderHash);
        assertEq(filledBefore, 0, "unfilled at the fork block");
        console2.log("replay: offerer", p.offerer);
        console2.log("replay: nft", nft);
        console2.log("replay: token id", id);
        console2.log("replay: price (USDG raw)", price);
        console2.log("replay: endTime - now (s)", p.endTime - block.timestamp);
        console2.log("replay: signature bytes", ao.signature.length);
        console2.logBytes32(orderHash);

        bytes memory init = _routeAInitPull(ao, price, price);
        address proposer = makeAddr("proposer");
        vm.prank(proposer);
        GenericCallStrategy clone =
            GenericCallStrategy(StrategyFactory(STRATEGY_FACTORY).cloneAndInit(TEMPLATE, VAULT, proposer, init));
        deal(USDG, VAULT, IERC20(USDG).balanceOf(VAULT) + price);
        _bind(clone);
        vm.prank(VAULT);
        IERC20(USDG).approve(address(clone), price);
        vm.prank(VAULT);
        clone.execute();
        assertEq(IERC721(nft).ownerOf(id), address(clone), "clone bought the live OpenSea listing");
        (,, uint256 filledAfter,) = ISeaport16(SEAPORT).getOrderStatus(orderHash);
        assertEq(filledAfter, 1);
    }

    /// @notice The same listing behind OpenSea's SignedZone (FULL_RESTRICTED). A frozen plan cannot
    ///         carry a zone signature valid at execute (it binds the fulfiller and lives ~5 min), so
    ///         it carries none: the zone refuses and the whole execute reverts.
    function test_routeA_signedZoneListingRevertsAtExecute() public {
        _skipIfNoFork();
        _giveNft(seller);
        vm.prank(seller);
        IERC721(NFT).setApprovalForAll(OPENSEA_CONDUIT, true);
        ISeaport16.AdvancedOrder memory listing = _listing(FULL_RESTRICTED, SIGNED_ZONE);
        GenericCallStrategy clone = _clone(_routeAInit(listing, PRICE));

        _bind(clone);
        vm.prank(VAULT);
        IERC20(USDG).approve(address(clone), PULL);
        vm.prank(VAULT);
        (bool ok, bytes memory ret) = address(clone).call(abi.encodeCall(BaseStrategy.execute, ()));
        assertFalse(ok, "execute must revert");
        assertEq(bytes4(ret), GenericCallStrategy.CallFailed.selector, "the Seaport call failed");
        console2.log("route A, SignedZone listing: execute reverted with CallFailed; revert data:");
        console2.logBytes(ret);
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), seller, "NFT not sold");
    }

    // ── Route B ──

    /// @notice The clone's address is predictable before the calls are frozen (CREATE2, salt bound
    ///         to the vault, init data not part of the address), so the clone can be the offerer in
    ///         its own frozen `validate`. The offer validates, but the template revokes every approve
    ///         its execute leg made, so no seller can fill it during the strategy window.
    function test_routeB_validatedOfferUnfillableAfterRevoke() public {
        _skipIfNoFork();
        bytes32 salt = keccak256("she-535-route-b");
        address predicted =
            Clones.predictDeterministicAddress(TEMPLATE, keccak256(abi.encode(VAULT, salt)), STRATEGY_FACTORY);

        ISeaport16.Order memory offer = _offer(predicted);
        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](2);
        e[0] = _call(USDG, abi.encodeCall(IERC20.approve, (SEAPORT, PRICE)));
        ISeaport16.Order[] memory orders = new ISeaport16.Order[](1);
        orders[0] = offer;
        e[1] = _call(SEAPORT, abi.encodeCall(ISeaport16.validate, (orders)));
        bytes memory init = abi.encode(
            PULL, e, new BatchExecutorLib.Call[](0), new GenericCallStrategy.BalancePatch[](0), _sweepAsset()
        );

        address proposer = makeAddr("proposer");
        vm.prank(proposer);
        GenericCallStrategy clone = GenericCallStrategy(
            StrategyFactory(STRATEGY_FACTORY).cloneAndInitDeterministic(TEMPLATE, VAULT, proposer, init, salt)
        );
        assertEq(address(clone), predicted, "clone address was predictable before the calls were frozen");
        deal(USDG, VAULT, IERC20(USDG).balanceOf(VAULT) + PULL);
        _execute(clone);

        bytes32 orderHash = _hashOf(offer.parameters);
        (bool validated, bool cancelled,,) = ISeaport16(SEAPORT).getOrderStatus(orderHash);
        assertTrue(validated, "offer validated on chain by the clone");
        assertFalse(cancelled);
        assertEq(IERC20(USDG).allowance(address(clone), SEAPORT), 0, "template revoked the approve after execute");

        // A holder accepts during the strategy window: Seaport cannot pull the clone's USDG.
        _giveNft(seller);
        vm.prank(seller);
        IERC721(NFT).setApprovalForAll(SEAPORT, true);
        vm.prank(seller);
        vm.expectRevert();
        ISeaport16(SEAPORT).fulfillOrder(offer, bytes32(0));
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), seller, "no sale");

        // Counterfactual: with the allowance back, the same fill goes through. The revoke is the blocker.
        vm.prank(address(clone));
        IERC20(USDG).approve(SEAPORT, PRICE);
        vm.prank(seller);
        ISeaport16(SEAPORT).fulfillOrder(offer, bytes32(0));
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), address(clone), "fills once the allowance exists");
    }

    // ── Guardian gate (Q1) and cancel / bond (Q8), real governor on vault #4 ──

    /// @notice A real propose on vault #4. With no guardian vote, the proposal reaches Approved after
    ///         voting and review, but executeProposal reverts: the ExposureLedger needs at least one
    ///         guardian Approve with a WOOD lock for a tier-2 (uncertified) clone. The proposer can
    ///         cancel from Approved and reclaim the whole bond.
    function test_guardianGate_silentGuardiansBlockExecute() public {
        _skipIfNoFork();
        IGovernorLite gov = IGovernorLite(GOVERNOR);
        address agent = IVaultLite(VAULT).agentsPaginated(0, 1)[0];
        _giveNft(seller);
        vm.prank(seller);
        IERC721(NFT).setApprovalForAll(OPENSEA_CONDUIT, true);
        ISeaport16.AdvancedOrder memory listing = _listing(FULL_OPEN, address(0));

        vm.prank(agent);
        address clone =
            StrategyFactory(STRATEGY_FACTORY).cloneAndInit(TEMPLATE, VAULT, agent, _routeAInit(listing, PRICE));
        address wood = IBondEscrowLite(gov.bondEscrow()).wood();
        uint256 bondNeed = IExposureLedger(gov.exposureLedger()).proposerBondWood(USDG, PULL);
        uint256 id = _proposeAsAgent(gov, agent, clone);
        ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(id);
        console2.log("proposal tier", gov.getProposalTier(id));
        console2.log("required coverage (USDG raw)", gov.getRequiredCoverage(id));
        console2.log("bond posted (WOOD wei)", p.proposerBondWood);
        console2.log("vote ends +s", p.voteEnd - block.timestamp);
        console2.log("review ends +s", p.reviewEnd - block.timestamp);
        console2.log("execute by +s", p.executeBy - block.timestamp);
        assertEq(gov.getProposalTier(id), 2, "uncertified clone is tier 2");
        assertEq(gov.getRequiredCoverage(id), PULL, "coverage = the pull at full notional");
        assertEq(IERC20(wood).balanceOf(agent), 0, "bond locked");

        vm.warp(p.voteEnd + 1);
        assertEq(uint256(gov.stateOf(id)), uint256(ISyndicateGovernor.ProposalState.GuardianReview));
        vm.warp(p.reviewEnd + 1);
        assertEq(
            uint256(gov.stateOf(id)),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "Approved with no guardian vote"
        );

        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        gov.executeProposal(id);
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), seller, "nothing bought");

        // Q8: the proposer cancels from Approved; the vault unlocks; the full bond comes back.
        vm.prank(agent);
        gov.cancelProposal(id);
        assertEq(uint256(gov.stateOf(id)), uint256(ISyndicateGovernor.ProposalState.Cancelled));
        assertEq(gov.openProposalCount(), 0, "vault no longer bound");
        gov.reclaimProposerBond(id);
        assertEq(IERC20(wood).balanceOf(agent), bondNeed, "whole bond returned");
    }

    /// @notice Positive control for the gate above: the same proposal, but the three active fleet
    ///         guardians Approve during review (with their WOOD locks). Then executeProposal buys the
    ///         open listing through the real governor and vault batch, and the proposer settles: the
    ///         vault's asset drops by the price (inside the 1000 bps floor) and the NFT stays on the
    ///         clone. This is the whole flow on today's contracts, guardians aside.
    function test_fullFlow_guardianApproveThenExecuteAndSettle() public {
        _skipIfNoFork();
        IGovernorLite gov = IGovernorLite(GOVERNOR);
        address agent = IVaultLite(VAULT).agentsPaginated(0, 1)[0];
        _giveNft(seller);
        vm.prank(seller);
        IERC721(NFT).setApprovalForAll(OPENSEA_CONDUIT, true);
        ISeaport16.AdvancedOrder memory listing = _listing(FULL_OPEN, address(0));

        vm.prank(agent);
        address clone =
            StrategyFactory(STRATEGY_FACTORY).cloneAndInit(TEMPLATE, VAULT, agent, _routeAInit(listing, PRICE));
        uint256 id = _proposeAsAgent(gov, agent, clone);
        ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(id);

        vm.warp(p.voteEnd + 1);
        IRegistryLite reg = IRegistryLite(IProtocolPath(GOVERNOR).guardianRegistry());
        reg.openReview(GOVERNOR, id);
        address[3] memory fleet = [GUARDIAN_A, GUARDIAN_B, GUARDIAN_C];
        for (uint256 i; i < 3; ++i) {
            vm.prank(fleet[i]);
            reg.voteOnProposal(GOVERNOR, id, 1, type(uint128).max); // Approve; lock clamps to free capacity
        }
        vm.warp(p.reviewEnd + 1);
        assertEq(uint256(gov.stateOf(id)), uint256(ISyndicateGovernor.ProposalState.Approved));

        uint256 vaultBefore = IERC20(USDG).balanceOf(VAULT);
        gov.executeProposal(id);
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), clone, "proposal bought the listing");
        assertEq(vaultBefore - IERC20(USDG).balanceOf(VAULT), PULL, "vault paid the pull");

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(id);
        assertEq(uint256(gov.stateOf(id)), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(IERC721(NFT).ownerOf(TOKEN_ID), clone, "NFT stays on the clone");
        console2.log("full flow: vault asset before execute (USDG raw)", vaultBefore);
        console2.log("full flow: vault asset after settle (USDG raw)", IERC20(USDG).balanceOf(VAULT));
    }

    // ── helpers ──

    /// @dev Propose `clone` on vault #4 as its agent with the governor-level batch the CLI builds for a
    ///      Generic Call proposal: execute [asset.approve(clone, pull), clone.execute()] with caps
    ///      [0, pull], settle [clone.settle()]. The WOOD bond is dealt (on mainnet the agent posts it).
    function _proposeAsAgent(IGovernorLite gov, address agent, address clone) internal returns (uint256 id) {
        BatchExecutorLib.Call[] memory ex = new BatchExecutorLib.Call[](2);
        ex[0] = _call(USDG, abi.encodeCall(IERC20.approve, (clone, PULL)));
        ex[1] = _call(clone, abi.encodeCall(BaseStrategy.execute, ()));
        uint256[] memory exCaps = new uint256[](2);
        exCaps[1] = PULL;
        BatchExecutorLib.Call[] memory st = new BatchExecutorLib.Call[](1);
        st[0] = _call(clone, abi.encodeCall(BaseStrategy.settle, ()));
        address escrow = gov.bondEscrow();
        address wood = IBondEscrowLite(escrow).wood();
        uint256 bondNeed = IExposureLedger(gov.exposureLedger()).proposerBondWood(USDG, PULL);
        deal(wood, agent, bondNeed);
        vm.prank(agent);
        IERC20(wood).approve(escrow, bondNeed);
        vm.prank(agent);
        id = gov.propose(
            VAULT,
            clone,
            "ipfs://she-535-fork",
            1 hours,
            ISyndicateGovernor.RiskEnvelope({maxCapital: PULL, maxDrawdownBps: 1000}),
            ex,
            exCaps,
            st,
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _giveNft(address to) internal {
        address holder = IERC721(NFT).ownerOf(TOKEN_ID);
        vm.prank(holder);
        IERC721(NFT).transferFrom(holder, to, TOKEN_ID);
    }

    /// @dev A listing in the shape OpenSea writes on 4663: ERC-721 for USDG, 99% to the seller and
    ///      1% to OpenSea, OpenSea's conduit, 90 days. Signed by the test seller (EIP-712, Seaport's
    ///      own domain separator and order hash).
    function _listing(uint8 orderType, address zone) internal view returns (ISeaport16.AdvancedOrder memory ao) {
        ISeaport16.OfferItem[] memory offer = new ISeaport16.OfferItem[](1);
        offer[0] = ISeaport16.OfferItem(ITEM_ERC721, NFT, TOKEN_ID, 1, 1);
        ISeaport16.ConsiderationItem[] memory cons = new ISeaport16.ConsiderationItem[](2);
        uint256 fee = PRICE / 100;
        cons[0] = ISeaport16.ConsiderationItem(ITEM_ERC20, USDG, 0, PRICE - fee, PRICE - fee, seller);
        cons[1] = ISeaport16.ConsiderationItem(ITEM_ERC20, USDG, 0, fee, fee, OPENSEA_FEE);
        ISeaport16.OrderParameters memory p = ISeaport16.OrderParameters({
            offerer: seller,
            zone: zone,
            offer: offer,
            consideration: cons,
            orderType: orderType,
            startTime: block.timestamp - 60,
            endTime: block.timestamp + 90 days,
            zoneHash: bytes32(0),
            salt: uint256(keccak256("she-535-listing")),
            conduitKey: OPENSEA_CONDUIT_KEY,
            totalOriginalConsiderationItems: 2
        });
        (, bytes32 domain,) = ISeaport16(SEAPORT).information();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, keccak256(abi.encodePacked(hex"1901", domain, _hashOf(p))));
        ao = ISeaport16.AdvancedOrder(p, 1, 1, abi.encodePacked(r, s, v), "");
    }

    /// @dev The clone offers PRICE USDG for TOKEN_ID, delivered to itself. No zone, no conduit, no
    ///      signature: validated on chain by the offerer.
    function _offer(address offerer) internal view returns (ISeaport16.Order memory o) {
        ISeaport16.OfferItem[] memory offer = new ISeaport16.OfferItem[](1);
        offer[0] = ISeaport16.OfferItem(ITEM_ERC20, USDG, 0, PRICE, PRICE);
        ISeaport16.ConsiderationItem[] memory cons = new ISeaport16.ConsiderationItem[](1);
        cons[0] = ISeaport16.ConsiderationItem(ITEM_ERC721, NFT, TOKEN_ID, 1, 1, offerer);
        o.parameters = ISeaport16.OrderParameters({
            offerer: offerer,
            zone: address(0),
            offer: offer,
            consideration: cons,
            orderType: FULL_OPEN,
            startTime: block.timestamp - 60,
            endTime: block.timestamp + 7 days,
            zoneHash: bytes32(0),
            salt: uint256(keccak256("she-535-offer")),
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: 1
        });
    }

    function _hashOf(ISeaport16.OrderParameters memory p) internal view returns (bytes32) {
        return ISeaport16(SEAPORT)
            .getOrderHash(
                ISeaport16.OrderComponents({
                offerer: p.offerer,
                zone: p.zone,
                offer: p.offer,
                consideration: p.consideration,
                orderType: p.orderType,
                startTime: p.startTime,
                endTime: p.endTime,
                zoneHash: p.zoneHash,
                salt: p.salt,
                conduitKey: p.conduitKey,
                counter: ISeaport16(SEAPORT).getCounter(p.offerer)
            })
            );
    }

    /// @dev The plugin's minimal NFT plan: approve Seaport, fill; no settle calls; sweep the asset.
    function _routeAInit(ISeaport16.AdvancedOrder memory listing, uint256 price) internal pure returns (bytes memory) {
        return _routeAInitPull(listing, price, PULL);
    }

    function _routeAInitPull(ISeaport16.AdvancedOrder memory listing, uint256 price, uint256 pull)
        internal
        pure
        returns (bytes memory)
    {
        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](2);
        e[0] = _call(USDG, abi.encodeCall(IERC20.approve, (SEAPORT, price)));
        e[1] = _call(
            SEAPORT,
            abi.encodeCall(
                ISeaport16.fulfillAdvancedOrder, (listing, new ISeaport16.CriteriaResolver[](0), bytes32(0), address(0))
            )
        );
        return
            abi.encode(
                pull, e, new BatchExecutorLib.Call[](0), new GenericCallStrategy.BalancePatch[](0), _sweepAsset()
            );
    }

    function _sweepAsset() internal pure returns (address[] memory s) {
        s = new address[](1);
        s[0] = USDG;
    }

    /// @dev Clone the DEPLOYED template on the live factory (no fresh template), dealt the pull.
    function _clone(bytes memory init) internal returns (GenericCallStrategy clone) {
        assertTrue(StrategyFactory(STRATEGY_FACTORY).approvedTemplate(TEMPLATE), "template approved on 4663");
        address proposer = makeAddr("proposer");
        vm.prank(proposer);
        clone = GenericCallStrategy(StrategyFactory(STRATEGY_FACTORY).cloneAndInit(TEMPLATE, VAULT, proposer, init));
        deal(USDG, VAULT, IERC20(USDG).balanceOf(VAULT) + PULL);
    }

    function _bind(GenericCallStrategy clone) internal {
        address gov = IProtocolPath(VAULT).governor();
        vm.mockCall(gov, abi.encodeCall(IProposalStatus.getActiveProposal, ()), abi.encode(uint256(1)));
        vm.mockCall(gov, abi.encodeCall(IProposalStatus.strategyOf, (uint256(1))), abi.encode(address(clone)));
    }

    function _execute(GenericCallStrategy clone) internal {
        _bind(clone);
        vm.prank(VAULT);
        IERC20(USDG).approve(address(clone), PULL);
        vm.prank(VAULT);
        clone.execute();
    }

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: target, data: data, value: 0});
    }
}
