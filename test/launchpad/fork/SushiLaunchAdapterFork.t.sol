// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SushiLaunchAdapter} from "../../../src/launchpad/adapters/SushiLaunchAdapter.sol";
import {ILaunchAdapter} from "../../../src/launchpad/ILaunchAdapter.sol";
import {ISushiLaunchpadV2} from "../../../src/launchpad/vendor/sushi/ISushiLaunchpadV2.sol";

interface ISushiV3PoolLike {
    function token0() external view returns (address);
    function fee() external view returns (uint24);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice A contract caller with no `receive()`, standing in for a
///         `LaunchpadStrategy` clone.
contract ForkStrategyStub {
    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function launch(address adapter, ILaunchAdapter.LaunchParams calldata p)
        external
        returns (ILaunchAdapter.LaunchResult memory)
    {
        return ILaunchAdapter(adapter).launch(p);
    }
}

/// @notice Trades a launch pool directly so fees accrue to its positions.
contract PoolTrader {
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    address internal _pool;

    function trade(address pool, address tokenIn, uint256 amountIn) external {
        _pool = pool;
        bool zeroForOne = tokenIn == ISushiV3PoolLike(pool).token0();
        ISushiV3PoolLike(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                abi.encode(tokenIn)
            );
        _pool = address(0);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == _pool, "trader: not the pool");
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).transfer(msg.sender, owed);
    }
}

/// @title  SushiLaunchAdapterFork
/// @notice Drives `SushiLaunchAdapter` against the LIVE Sushi Launchpad V2 on
///         Robinhood Chain 4663: real token deployment, real V3 pool, real fee
///         distribution. Skips when `ROBINHOOD_RPC_URL` is unset.
contract SushiLaunchAdapterForkTest is Test {
    address internal constant LAUNCHPAD = 0xF1716eBf85836ffE2985db9A50dd29e5814caBe9;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WOOD = 0xF8BC08092C06dB6148114DCf82AF881F1085f92b;
    address internal constant SUSHI_V3_FACTORY = 0xE51960f1B45f1C9FB6D166E6a884F866fC70433B;

    uint256 internal constant SUPPLY = 1e9 * 1e18;
    uint256 internal constant QUOTE_IN = 100e6; // 100 USDG
    uint256 internal constant RESERVE = 1_000_000e18; // far below what 100 USDG buys at a $5k FDV

    SushiLaunchAdapter internal adapter;
    ForkStrategyStub internal stub;
    PoolTrader internal trader;
    address internal vault = makeAddr("vault");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        adapter = new SushiLaunchAdapter(LAUNCHPAD);
        stub = new ForkStrategyStub();
        trader = new PoolTrader();

        deal(USDG, address(stub), 10_000e6);
        deal(WETH, address(stub), 10 ether);
        stub.approve(USDG, address(adapter), type(uint256).max);
        stub.approve(WETH, address(adapter), type(uint256).max);
    }

    function _params(address quote_, uint256 quoteIn, bytes memory venueData)
        internal
        view
        returns (ILaunchAdapter.LaunchParams memory)
    {
        return ILaunchAdapter.LaunchParams({
            name: "Sherwood Fork Fund",
            symbol: "SFF",
            quoteToken: quote_,
            quoteIn: quoteIn,
            minTokensOut: RESERVE,
            reserveAmount: RESERVE,
            deadline: uint64(block.timestamp + 1 hours),
            feeRecipient: vault,
            venueData: venueData
        });
    }

    function _venue(ISushiLaunchpadV2.LiquidityMode mode, ISushiLaunchpadV2.FeeDisposition disposition)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(SushiLaunchAdapter.VenueData({liquidityMode: mode, feeDisposition: disposition}));
    }

    function _clone(ILaunchAdapter.LaunchResult memory r) internal pure returns (address) {
        return address(uint160(uint256(r.launchRef)));
    }

    function _trade(address pool, address tokenIn, uint256 amountIn) internal {
        deal(tokenIn, address(trader), IERC20(tokenIn).balanceOf(address(trader)) + amountIn);
        trader.trade(pool, tokenIn, amountIn);
    }

    // ── venue identity ──

    function test_Fork_VenueIsTheImplementationThisAdapterWasWrittenAgainst() public view {
        ISushiLaunchpadV2 pad = ISushiLaunchpadV2(LAUNCHPAD);
        assertEq(pad.implementationVersion(), 2, "V2");
        assertEq(pad.implementationRevision(), 2, "V2.2");
        assertEq(pad.WETH(), WETH);
        assertEq(pad.v3Factory(), SUSHI_V3_FACTORY, "Sushi V3, not the Uniswap factory");
        assertEq(adapter.weth(), WETH);
        assertTrue(adapter.quoteSupported(USDG), "USDG feed registered");
        assertTrue(adapter.quoteSupported(WETH), "WETH feed registered");
        assertFalse(adapter.quoteSupported(WOOD), "no WOOD/USD feed yet");
    }

    // ── launch ──

    function test_Fork_UsdgLaunch_ReserveToStrategyCloneIsCreatorAndFeeReceiver() public {
        (, uint256 fee) = adapter.nativeFeeSource();
        uint256 wethBefore = IERC20(WETH).balanceOf(address(stub));
        uint256 usdgBefore = IERC20(USDG).balanceOf(address(stub));

        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), _params(USDG, QUOTE_IN, ""));
        address clone = _clone(r);

        assertEq(IERC20(r.token).totalSupply(), SUPPLY, "fixed 1e9 supply");
        assertEq(IERC20(r.token).balanceOf(address(stub)), r.reserveHeld, "reserve on the strategy");
        assertGe(r.reserveHeld, RESERVE, "at least the reserve");
        assertEq(usdgBefore - IERC20(USDG).balanceOf(address(stub)), QUOTE_IN, "exactly quoteIn spent");
        assertEq(wethBefore - IERC20(WETH).balanceOf(address(stub)), fee, "exactly the live fee in WETH");

        ISushiLaunchpadV2.LaunchInfoV2 memory info = ISushiLaunchpadV2(LAUNCHPAD).launchInfo(r.token);
        assertEq(info.creator, clone, "creator is the clone");
        assertEq(info.feeReceiver, clone, "fee receiver is the clone, not the shared implementation");
        assertEq(info.quoteToken, USDG);
        assertEq(uint8(info.feeDisposition), uint8(ISushiLaunchpadV2.FeeDisposition.DIRECT_PAYOUT));
        assertEq(uint8(adapter.phase(r.launchRef)), uint8(ILaunchAdapter.LaunchPhase.Live));

        address[2] memory holders = [address(adapter), clone];
        for (uint256 i; i < holders.length; ++i) {
            assertEq(IERC20(r.token).balanceOf(holders[i]), 0, "no launch token on the adapter");
            assertEq(IERC20(USDG).balanceOf(holders[i]), 0, "no quote on the adapter");
            assertEq(IERC20(WETH).balanceOf(holders[i]), 0, "no weth on the adapter");
            assertEq(holders[i].balance, 0, "no native on the adapter");
        }
    }

    function test_Fork_WethLaunch() public {
        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), _params(WETH, 0.05 ether, ""));
        assertGe(IERC20(r.token).balanceOf(address(stub)), RESERVE);
        assertEq(IERC20(WETH).balanceOf(_clone(r)), 0);
    }

    function test_Fork_MoonModeCreatesSevenPositions() public {
        bytes memory v = _venue(ISushiLaunchpadV2.LiquidityMode.MOON, ISushiLaunchpadV2.FeeDisposition.DIRECT_PAYOUT);
        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), _params(USDG, QUOTE_IN, v));
        ISushiLaunchpadV2.LaunchInfoV2 memory info = ISushiLaunchpadV2(LAUNCHPAD).launchInfo(r.token);
        assertEq(uint8(info.liquidityMode), uint8(ISushiLaunchpadV2.LiquidityMode.MOON));
        (bool ok, bytes memory ret) = LAUNCHPAD.staticcall(abi.encodeWithSignature("positionCount(address)", r.token));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 7, "Moon Mode is seven positions");
    }

    function test_Fork_RevertWhen_WoodQuote() public {
        vm.expectRevert(abi.encodeWithSelector(SushiLaunchAdapter.UnsupportedQuote.selector, WOOD));
        stub.launch(address(adapter), _params(WOOD, QUOTE_IN, ""));
    }

    function test_Fork_RevertWhen_DistributeToHolders() public {
        bytes memory v =
            _venue(ISushiLaunchpadV2.LiquidityMode.STANDARD, ISushiLaunchpadV2.FeeDisposition.DISTRIBUTE_TO_HOLDERS);
        vm.expectRevert(
            abi.encodeWithSelector(
                SushiLaunchAdapter.DispositionUnsupported.selector,
                ISushiLaunchpadV2.FeeDisposition.DISTRIBUTE_TO_HOLDERS
            )
        );
        stub.launch(address(adapter), _params(USDG, QUOTE_IN, v));
    }

    // ── fees ──

    function test_Fork_DirectPayout_KeeperCollectsBothLegsToTheVault() public {
        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), _params(USDG, QUOTE_IN, ""));
        address pool = ISushiLaunchpadV2(LAUNCHPAD).launchInfo(r.token).pool;
        assertEq(ISushiV3PoolLike(pool).fee(), 10_000, "1% tier");

        _trade(pool, USDG, 500e6);
        trader.trade(pool, r.token, IERC20(r.token).balanceOf(address(trader)) / 2);

        uint256 strategyTokenBefore = IERC20(r.token).balanceOf(address(stub));
        vm.prank(keeper);
        (uint256 quoteOut, uint256 tokenOut) = adapter.collectFees(r.launchRef);

        // 1% of the 500 USDG buy (plus the 100 USDG dev buy) is ~6 USDG gross; 70% is the fund's.
        assertGt(quoteOut, 3e6, "quote fees reached the vault");
        assertLt(quoteOut, 6e6, "and only the non-Sushi share");
        assertGt(tokenOut, 0, "launch-token fees from the sell");
        assertEq(IERC20(USDG).balanceOf(vault), quoteOut);
        assertEq(IERC20(r.token).balanceOf(vault), tokenOut);
        assertEq(IERC20(USDG).balanceOf(keeper), 0, "the caller is paid nothing");
        assertEq(IERC20(r.token).balanceOf(address(stub)), strategyTokenBefore, "strategy untouched");
        assertEq(IERC20(USDG).balanceOf(_clone(r)), 0, "nothing rests on the clone");
        assertEq(IERC20(r.token).balanceOf(_clone(r)), 0, "nothing rests on the clone");
    }

    function test_Fork_ThirdPartyDistributionIsForwardedOnTheNextSweep() public {
        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), _params(USDG, QUOTE_IN, ""));
        address pool = ISushiLaunchpadV2(LAUNCHPAD).launchInfo(r.token).pool;
        _trade(pool, USDG, 500e6);

        vm.prank(keeper);
        ISushiLaunchpadV2(LAUNCHPAD).distributeFees(r.token);
        uint256 resting = IERC20(USDG).balanceOf(_clone(r));
        assertGt(resting, 0, "fees landed on the clone, the venue's fee receiver");

        (uint256 quoteOut,) = adapter.collectFees(r.launchRef);
        assertEq(quoteOut, resting, "the sweep moves the whole clone balance");
        assertEq(IERC20(USDG).balanceOf(_clone(r)), 0);
    }

    /// @dev BUYBACK_AND_BURN refuses distribution until the pool oracle has 120s
    ///      of history, then pays the fund nothing: the quote share buys the
    ///      launch token back and burns it, and the launch-token share burns.
    function test_Fork_BuybackAndBurn_RefusalIsAnnouncedThenSupplyBurns() public {
        bytes memory v =
            _venue(ISushiLaunchpadV2.LiquidityMode.STANDARD, ISushiLaunchpadV2.FeeDisposition.BUYBACK_AND_BURN);
        ILaunchAdapter.LaunchResult memory r = stub.launch(address(adapter), _params(USDG, QUOTE_IN, v));
        address pool = ISushiLaunchpadV2(LAUNCHPAD).launchInfo(r.token).pool;
        _trade(pool, USDG, 500e6);

        vm.recordLogs();
        (uint256 q, uint256 t) = adapter.collectFees(r.launchRef);
        assertEq(q + t, 0, "refused while the oracle is young");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool announced;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SushiLaunchAdapter.VenueCallFailed.selector) announced = true;
        }
        assertTrue(announced, "the refusal is announced, not silent");

        vm.warp(block.timestamp + 10 minutes);
        _trade(pool, USDG, 1e6); // write a fresh observation
        vm.warp(block.timestamp + 5 minutes);
        (q, t) = adapter.collectFees(r.launchRef);
        assertEq(q + t, 0, "buyback mode pays the receiver nothing");
        assertLt(IERC20(r.token).totalSupply(), SUPPLY, "fees bought back and burned");
    }
}
