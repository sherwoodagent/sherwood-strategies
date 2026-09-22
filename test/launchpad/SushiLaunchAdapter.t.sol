// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SushiLaunchAdapter} from "../../src/launchpad/adapters/SushiLaunchAdapter.sol";
import {ILaunchAdapter} from "../../src/launchpad/ILaunchAdapter.sol";
import {ISushiLaunchpadV2} from "../../src/launchpad/vendor/sushi/ISushiLaunchpadV2.sol";
import {MockSushiLaunchpadV2} from "../mocks/MockSushiLaunchpadV2.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Minimal WETH9: the adapter's declared native-fee source.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth: withdraw failed");
    }
}

/// @notice Force-sends its balance to `target`; no `receive()` guard can refuse it.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @notice Stands in for a `LaunchpadStrategy` clone: a CONTRACT with no
///         `receive()` or `fallback()`, like every `BaseStrategy`.
contract StrategyStub {
    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function launch(address adapter, ILaunchAdapter.LaunchParams calldata p)
        external
        returns (ILaunchAdapter.LaunchResult memory)
    {
        return ILaunchAdapter(adapter).launch(p);
    }

    function launchWithValue(address adapter, uint256 value, ILaunchAdapter.LaunchParams calldata p)
        external
        returns (ILaunchAdapter.LaunchResult memory)
    {
        return ILaunchAdapter(adapter).launch{value: value}(p);
    }

    receive() external payable {
        revert("strategy: no native");
    }
}

contract SushiLaunchAdapterTest is Test {
    MockWETH internal weth;
    MockSushiLaunchpadV2 internal pad;
    SushiLaunchAdapter internal adapter;
    ERC20Mock internal quote;
    ERC20Mock internal wood;
    StrategyStub internal stub;
    address internal strategy;

    address internal vault = makeAddr("vault");
    address internal keeper = makeAddr("keeper");
    address internal feed = makeAddr("priceFeed");

    uint256 internal constant FEE = 5e14; // the live venue's `launchFee()`
    uint256 internal constant QUOTE_IN = 10 ether;
    uint256 internal constant RESERVE = 5 ether; // at rate 1e18, 10 quote -> 10 tokens

    function setUp() public {
        vm.warp(1_000_000);
        weth = new MockWETH();
        pad = new MockSushiLaunchpadV2(address(weth));
        pad.setLaunchFee(FEE);
        adapter = new SushiLaunchAdapter(address(pad));

        quote = new ERC20Mock("USD Global", "USDG", 18);
        wood = new ERC20Mock("Wood", "WOOD", 18);
        pad.setQuoteTokenPriceFeed(address(quote), feed);

        stub = new StrategyStub();
        strategy = address(stub);
        _fund(strategy, QUOTE_IN * 10, 1 ether);
    }

    // ── helpers ──

    function _fund(address who, uint256 quoteAmount, uint256 wethAmount) internal {
        quote.mint(who, quoteAmount);
        vm.deal(address(this), wethAmount);
        weth.deposit{value: wethAmount}();
        weth.transfer(who, wethAmount);
        vm.startPrank(who);
        IERC20(address(quote)).approve(address(adapter), type(uint256).max);
        IERC20(address(weth)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function _params() internal view returns (ILaunchAdapter.LaunchParams memory p) {
        p = ILaunchAdapter.LaunchParams({
            name: "Fund Token",
            symbol: "FUND",
            quoteToken: address(quote),
            quoteIn: QUOTE_IN,
            minTokensOut: RESERVE,
            reserveAmount: RESERVE,
            deadline: 0,
            feeRecipient: vault,
            venueData: ""
        });
    }

    function _venue(ISushiLaunchpadV2.LiquidityMode mode, ISushiLaunchpadV2.FeeDisposition disposition)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(SushiLaunchAdapter.VenueData({liquidityMode: mode, feeDisposition: disposition}));
    }

    function _launch() internal returns (ILaunchAdapter.LaunchResult memory) {
        return stub.launch(address(adapter), _params());
    }

    function _clone(ILaunchAdapter.LaunchResult memory r) internal pure returns (address) {
        return address(uint160(uint256(r.launchRef)));
    }

    function _assertHoldsNothing(address who, address token) internal view {
        assertEq(IERC20(token).balanceOf(who), 0, "launch token");
        assertEq(quote.balanceOf(who), 0, "quote");
        assertEq(weth.balanceOf(who), 0, "weth");
        assertEq(who.balance, 0, "native");
    }

    // ── launch: custody ──

    function test_Launch_ReserveLandsOnStrategyAndNeitherAdapterRoleHoldsAnything() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        address clone = _clone(r);

        assertEq(IERC20(r.token).balanceOf(strategy), QUOTE_IN, "reserve delivered to the strategy");
        assertEq(r.reserveHeld, QUOTE_IN, "reported reserve is the strategy's balance");
        assertEq(r.quoteSpent, QUOTE_IN, "venue consumes the buy in full");
        _assertHoldsNothing(address(adapter), r.token);
        _assertHoldsNothing(clone, r.token);
        assertEq(pad.collectedNative(), FEE, "the venue received exactly the fee");
    }

    function test_Launch_CloneIsVenueCreatorAndFeeReceiver() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        address clone = _clone(r);
        ISushiLaunchpadV2.LaunchInfoV2 memory info = pad.launchInfo(r.token);

        assertEq(info.creator, clone, "creator is the clone");
        assertEq(info.feeReceiver, clone, "fee receiver is the clone");
        assertTrue(adapter.isClone(clone), "ref is one of our clones");
        SushiLaunchAdapter c = SushiLaunchAdapter(payable(clone));
        assertEq(c.owner(), strategy, "owned by the calling strategy");
        assertEq(c.feeRecipient(), vault, "fees forward to the vault");
        assertEq(c.launchToken(), r.token, "pinned token");
        assertEq(c.quoteToken(), address(quote), "pinned quote");
    }

    function test_Launch_EachLaunchGetsItsOwnCloneAndFeeRecipient() public {
        ILaunchAdapter.LaunchResult memory a = _launch();
        ILaunchAdapter.LaunchParams memory p = _params();
        address otherVault = makeAddr("otherVault");
        p.feeRecipient = otherVault;
        ILaunchAdapter.LaunchResult memory b = stub.launch(address(adapter), p);

        assertTrue(_clone(a) != _clone(b), "distinct clones");
        assertEq(SushiLaunchAdapter(payable(_clone(a))).feeRecipient(), vault);
        assertEq(SushiLaunchAdapter(payable(_clone(b))).feeRecipient(), otherVault);
    }

    function test_Launch_EmitsLaunchCloned() public {
        vm.recordLogs();
        ILaunchAdapter.LaunchResult memory r = _launch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = SushiLaunchAdapter.LaunchCloned.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(adapter) && logs[i].topics[0] == topic) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), _clone(r));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), strategy);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), r.token);
                found = true;
            }
        }
        assertTrue(found, "LaunchCloned emitted by the implementation");
    }

    // ── launch: rejections, all before any transfer ──

    function test_RevertWhen_FeeRecipientIsZero_NoFundsMove() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.feeRecipient = address(0);
        uint256 before = quote.balanceOf(strategy);
        vm.expectRevert(SushiLaunchAdapter.ZeroFeeRecipient.selector);
        stub.launch(address(adapter), p);
        assertEq(quote.balanceOf(strategy), before);
    }

    function test_RevertWhen_MinTokensOutBelowReserve() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.minTokensOut = RESERVE - 1;
        vm.expectRevert(
            abi.encodeWithSelector(SushiLaunchAdapter.ReserveFloorBelowReserve.selector, RESERVE - 1, RESERVE)
        );
        stub.launch(address(adapter), p);
    }

    function test_RevertWhen_InitialBuyUnderDeliversAgainstVenueFloor() public {
        pad.setRate(0.4e18); // 10 quote -> 4 tokens < floor 5
        vm.expectRevert(MockSushiLaunchpadV2.InsufficientInitialBuyOutput.selector);
        _launch();
    }

    function test_RevertWhen_VenueUnderDeliversPastItsOwnFloor() public {
        pad.setRate(0.4e18);
        pad.setSkipOutputFloor(true);
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.ReserveNotDelivered.selector, 4 ether, RESERVE));
        _launch();
    }

    function test_RevertWhen_ZeroQuoteIn() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.quoteIn = 0;
        vm.expectRevert(SushiLaunchAdapter.ZeroQuoteIn.selector);
        stub.launch(address(adapter), p);
    }

    function test_RevertWhen_QuoteFeedUnregistered_NoFundsMove() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.quoteToken = address(wood);
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.UnsupportedQuote.selector, address(wood)));
        stub.launch(address(adapter), p);
    }

    function test_Launch_WoodQuoteSucceedsOnceVenueRegistersFeed() public {
        assertFalse(adapter.quoteSupported(address(wood)));
        pad.setQuoteTokenPriceFeed(address(wood), feed);
        assertTrue(adapter.quoteSupported(address(wood)));

        wood.mint(strategy, QUOTE_IN);
        vm.prank(strategy);
        IERC20(address(wood)).approve(address(adapter), type(uint256).max);
        ILaunchAdapter.LaunchParams memory p = _params();
        p.quoteToken = address(wood);
        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), p);
        assertEq(IERC20(r.token).balanceOf(strategy), QUOTE_IN);
    }

    function test_RevertWhen_NativeValueAttached() public {
        vm.deal(strategy, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.NativeValueRejected.selector, 1));
        stub.launchWithValue(address(adapter), 1, _params());
    }

    function test_RevertWhen_DeadlinePassed() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.deadline = uint64(block.timestamp - 1);
        vm.expectRevert(
            abi.encodeWithSelector(SushiLaunchAdapter.DeadlineExpired.selector, p.deadline, block.timestamp)
        );
        stub.launch(address(adapter), p);
    }

    function test_Launch_DeadlineAtNowOrZeroIsAccepted() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.deadline = uint64(block.timestamp);
        stub.launch(address(adapter), p);
        p.deadline = 0;
        stub.launch(address(adapter), p);
    }

    // ── venueData ──

    function test_VenueData_EmptyMeansStandardDirectPayout() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        ISushiLaunchpadV2.LaunchInfoV2 memory info = pad.launchInfo(r.token);
        assertEq(uint8(info.liquidityMode), uint8(ISushiLaunchpadV2.LiquidityMode.STANDARD));
        assertEq(uint8(info.feeDisposition), uint8(ISushiLaunchpadV2.FeeDisposition.DIRECT_PAYOUT));
    }

    function test_VenueData_ModeAndDispositionPassThrough() public {
        ISushiLaunchpadV2.FeeDisposition[3] memory allowed = [
            ISushiLaunchpadV2.FeeDisposition.DIRECT_PAYOUT,
            ISushiLaunchpadV2.FeeDisposition.BURN_LAUNCH_TOKEN_FEES,
            ISushiLaunchpadV2.FeeDisposition.BUYBACK_AND_BURN
        ];
        for (uint256 i; i < allowed.length; ++i) {
            ILaunchAdapter.LaunchParams memory p = _params();
            p.venueData = _venue(ISushiLaunchpadV2.LiquidityMode.MOON, allowed[i]);
            ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), p);
            ISushiLaunchpadV2.LaunchInfoV2 memory info = pad.launchInfo(r.token);
            assertEq(uint8(info.liquidityMode), uint8(ISushiLaunchpadV2.LiquidityMode.MOON));
            assertEq(uint8(info.feeDisposition), uint8(allowed[i]));
        }
    }

    function test_RevertWhen_DistributeToHolders_NoFundsMove() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.venueData =
            _venue(ISushiLaunchpadV2.LiquidityMode.STANDARD, ISushiLaunchpadV2.FeeDisposition.DISTRIBUTE_TO_HOLDERS);
        uint256 before = quote.balanceOf(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                SushiLaunchAdapter.DispositionUnsupported.selector,
                ISushiLaunchpadV2.FeeDisposition.DISTRIBUTE_TO_HOLDERS
            )
        );
        stub.launch(address(adapter), p);
        assertEq(quote.balanceOf(strategy), before);
    }

    function test_RevertWhen_VenueDataIsMalformed() public {
        ILaunchAdapter.LaunchParams memory p = _params();
        p.venueData = abi.encode(uint256(0));
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.InvalidVenueData.selector, 32));
        stub.launch(address(adapter), p);

        p.venueData = abi.encode(uint256(0), uint256(7)); // out-of-range enum
        vm.expectRevert();
        stub.launch(address(adapter), p);
    }

    // ── the fee ──

    function test_NativeFeeSource_ReportsWethAndTheLiveFee() public {
        (address token, uint256 amount) = adapter.nativeFeeSource();
        assertEq(token, address(weth));
        assertEq(amount, FEE);
        pad.setLaunchFee(7e14);
        (, amount) = adapter.nativeFeeSource();
        assertEq(amount, 7e14, "repriced fee read live");
    }

    function test_Launch_PullsExactlyTheLiveFeeInWeth() public {
        pad.setLaunchFee(7e14);
        uint256 before = weth.balanceOf(strategy);
        _launch();
        assertEq(before - weth.balanceOf(strategy), 7e14);
        assertEq(pad.collectedNative(), 7e14);
    }

    function test_Launch_WithZeroFeePullsNoWeth() public {
        pad.setLaunchFee(0);
        uint256 before = weth.balanceOf(strategy);
        _launch();
        assertEq(weth.balanceOf(strategy), before);
    }

    /// @dev WETH as quote AND fee: the strategy approves `quoteIn + fee` of one
    ///      token and the adapter pulls the two amounts separately.
    function test_Launch_WethQuotedLaunchPullsQuoteAndFeeFromOneAllowance() public {
        pad.setQuoteTokenPriceFeed(address(weth), feed);
        vm.deal(address(this), QUOTE_IN);
        weth.deposit{value: QUOTE_IN}();
        weth.transfer(strategy, QUOTE_IN);
        uint256 before = weth.balanceOf(strategy);

        ILaunchAdapter.LaunchParams memory p = _params();
        p.quoteToken = address(weth);
        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), p);

        assertEq(before - weth.balanceOf(strategy), QUOTE_IN + FEE);
        _assertHoldsNothing(_clone(r), r.token);
    }

    // ── native handling ──

    function test_RevertWhen_PlainNativeSendToImplementationOrClone() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        vm.deal(address(this), 2);
        (bool ok,) = address(adapter).call{value: 1}("");
        assertFalse(ok, "implementation refuses native");
        (ok,) = _clone(r).call{value: 1}("");
        assertFalse(ok, "clone refuses native");
    }

    function test_Launch_SurvivesNativeForceSentToTheImplementation() public {
        vm.deal(address(this), 1 wei);
        new ForceSender{value: 1 wei}(payable(address(adapter)));
        ILaunchAdapter.LaunchResult memory r = _launch();
        assertEq(IERC20(r.token).balanceOf(strategy), QUOTE_IN, "one force-sent wei cannot brick launches");
    }

    // ── roles ──

    function test_RevertWhen_AnyoneButTheImplementationInitializesOrLaunchesAClone() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        SushiLaunchAdapter c = SushiLaunchAdapter(payable(_clone(r)));
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.NotImplementation.selector, address(this)));
        c.initialize(address(this), address(this));

        SushiLaunchAdapter.VenueData memory v;
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.NotImplementation.selector, address(this)));
        c.executeLaunch(_params(), v, 0);
    }

    function test_AttackerMintedCloneIsRecognisedButInert() public {
        address rogue = Clones.clone(address(adapter));
        assertTrue(adapter.isClone(rogue), "introspection matches the code");
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.NotImplementation.selector, address(this)));
        SushiLaunchAdapter(payable(rogue)).initialize(address(this), address(this));

        bytes32 ref = bytes32(uint256(uint160(rogue)));
        assertEq(uint8(adapter.phase(ref)), uint8(ILaunchAdapter.LaunchPhase.None));
        (uint256 q, uint256 t) = adapter.collectFees(ref);
        assertEq(q + t, 0);
    }

    function test_RevertWhen_LaunchCalledOnAClone() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        address clone = _clone(r);
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.WrongRole.selector, clone, address(adapter)));
        stub.launch(clone, _params());
    }

    /// @dev A venue upgrade that paid someone other than the launcher would leave
    ///      the clone with nothing to forward. The launch refuses instead.
    function test_RevertWhen_VenueRecordsAnotherFeeReceiver() public {
        address elsewhere = makeAddr("elsewhere");
        pad.setRecordReceiverAs(elsewhere);
        vm.expectRevert(); // FeeReceiverNotClone(clone, elsewhere); clone address unknown up front
        _launch();
    }

    // ── phase / finalize ──

    function test_Phase_IssuedLaunchIsLive() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        assertEq(uint8(adapter.phase(r.launchRef)), uint8(ILaunchAdapter.LaunchPhase.Live));
    }

    function test_Phase_UnknownRefsReturnNoneWithoutReverting() public {
        assertEq(uint8(adapter.phase(bytes32(0))), uint8(ILaunchAdapter.LaunchPhase.None), "zero");
        assertEq(uint8(adapter.phase(bytes32(type(uint256).max))), uint8(ILaunchAdapter.LaunchPhase.None), "dirty");
        bytes32 notAClone = bytes32(uint256(uint160(address(quote))));
        assertEq(uint8(adapter.phase(notAClone)), uint8(ILaunchAdapter.LaunchPhase.None), "a contract, not a clone");
        SushiLaunchAdapter other = new SushiLaunchAdapter(address(pad));
        bytes32 foreign = bytes32(uint256(uint160(Clones.clone(address(other)))));
        assertEq(uint8(adapter.phase(foreign)), uint8(ILaunchAdapter.LaunchPhase.None), "another implementation");
    }

    function test_Finalize_IsANoOp() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        adapter.finalize(r.launchRef);
        adapter.finalize(bytes32(0));
        assertEq(uint8(adapter.phase(r.launchRef)), uint8(ILaunchAdapter.LaunchPhase.Live));
    }

    function test_QuoteSupported_NeverReverts() public {
        assertFalse(adapter.quoteSupported(address(0)));
        assertFalse(adapter.quoteSupported(makeAddr("notAContract")));
        assertTrue(adapter.quoteSupported(address(quote)));
    }

    // ── fees ──

    function test_CollectFees_PaysTheVaultAndNeverTheStrategyOrCaller() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        quote.mint(address(pad), 3 ether);
        pad.setFeesOwed(r.token, 3 ether, 2 ether);

        uint256 strategyTokenBefore = IERC20(r.token).balanceOf(strategy);
        vm.prank(keeper);
        (uint256 q, uint256 t) = adapter.collectFees(r.launchRef);

        assertEq(q, 3 ether);
        assertEq(t, 2 ether);
        assertEq(quote.balanceOf(vault), 3 ether, "quote fees to the vault");
        assertEq(IERC20(r.token).balanceOf(vault), 2 ether, "token fees to the vault");
        assertEq(IERC20(r.token).balanceOf(strategy), strategyTokenBefore, "strategy untouched");
        assertEq(quote.balanceOf(keeper), 0, "caller paid nothing");
        _assertHoldsNothing(_clone(r), r.token);
    }

    function test_CollectFees_ForwardsFeesAThirdPartyAlreadyDistributed() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        quote.mint(address(pad), 3 ether);
        pad.setFeesOwed(r.token, 3 ether, 0);
        // Sushi's `distributeFees` is permissionless: anyone can land fees on the clone.
        vm.prank(keeper);
        pad.distributeFees(r.token);
        assertEq(quote.balanceOf(_clone(r)), 3 ether, "fees resting on the clone");

        (uint256 q,) = adapter.collectFees(r.launchRef);
        assertEq(q, 3 ether, "the next sweep moves the whole balance");
        assertEq(quote.balanceOf(vault), 3 ether);
        assertEq(quote.balanceOf(_clone(r)), 0);
    }

    function test_CollectFees_ReturnsZeroesWhenNothingAccruedAndEmitsNoFailure() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        vm.recordLogs();
        (uint256 q, uint256 t) = adapter.collectFees(r.launchRef);
        assertEq(q + t, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != SushiLaunchAdapter.VenueCallFailed.selector, "honest zero is silent");
        }
    }

    function test_CollectFees_VenueRefusalIsAnnouncedAndReturnsZeroes() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        pad.setDistributeReverts(true);
        vm.expectEmit(true, true, false, true, _clone(r));
        emit SushiLaunchAdapter.VenueCallFailed(
            "distributeFees", MockSushiLaunchpadV2.DistributeFailed.selector, r.launchRef, false
        );
        (uint256 q, uint256 t) = adapter.collectFees(r.launchRef);
        assertEq(q + t, 0);
    }

    function test_CollectFees_OutOfGasVenueCallIsDistinguishable() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        pad.setDistributeBurnsGas(true);
        vm.expectEmit(true, true, false, true, _clone(r));
        emit SushiLaunchAdapter.VenueCallFailed("distributeFees", bytes4(0), r.launchRef, true);
        adapter.collectFees{gas: 3_000_000}(r.launchRef);
    }

    function test_CollectFees_UnknownRefMakesNoCall() public {
        (uint256 q, uint256 t) = adapter.collectFees(bytes32(uint256(uint160(address(pad)))));
        assertEq(q + t, 0);
    }

    /// @dev Pins the stated trust assumption: the venue owner can re-point a
    ///      launch's fee receiver, after which the clone has nothing to forward.
    ///      The adapter cannot prevent this; it must not revert because of it.
    function test_CollectFees_AfterVenueOwnerRepointsReceiverReturnsZero() public {
        ILaunchAdapter.LaunchResult memory r = _launch();
        address sushiChosen = makeAddr("sushiChosen");
        pad.setFeeReceiver(r.token, sushiChosen); // this test contract deployed the mock: it is the owner
        quote.mint(address(pad), 1 ether);
        pad.setFeesOwed(r.token, 1 ether, 0);

        (uint256 q,) = adapter.collectFees(r.launchRef);
        assertEq(q, 0, "nothing reached the clone");
        assertEq(quote.balanceOf(sushiChosen), 1 ether);
    }

    // ── construction ──

    function test_LaunchTargetAndImmutables() public view {
        assertEq(adapter.launchTarget(), address(pad));
        assertEq(address(adapter.launchpad()), address(pad));
        assertEq(adapter.weth(), address(weth));
        assertEq(adapter.implementation(), address(adapter));
        assertEq(adapter.owner(), address(0), "implementation owns nothing");
    }

    function test_RevertWhen_ImplementationIsInitialized() public {
        vm.prank(address(adapter));
        vm.expectRevert(SushiLaunchAdapter.AlreadyInitialized.selector);
        adapter.initialize(address(this), address(this));
    }

    function test_RevertWhen_ConstructedWithACodelessLaunchpad() public {
        vm.expectRevert(SushiLaunchAdapter.InvalidLaunchpad.selector);
        new SushiLaunchAdapter(makeAddr("codeless"));
    }

    function test_RevertWhen_LaunchpadReportsNoWeth() public {
        MockSushiLaunchpadV2 broken = new MockSushiLaunchpadV2(address(0));
        vm.expectRevert(SushiLaunchAdapter.InvalidWeth.selector);
        new SushiLaunchAdapter(address(broken));
    }
}
