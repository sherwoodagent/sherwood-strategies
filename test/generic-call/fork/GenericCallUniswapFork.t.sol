// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {BatchExecutorLib} from "@sherwood/BatchExecutorLib.sol";
import {ISwapAdapter} from "@sherwood/interfaces/ISwapAdapter.sol";
import {IProposalStatus} from "@sherwood/interfaces/IProposalStatus.sol";
import {BaseStrategy} from "@sherwood/strategies/BaseStrategy.sol";
import {GenericCallStrategy, IProtocolPath} from "../../../src/generic-call/GenericCallStrategy.sol";

/**
 * @title GenericCallUniswapForkTest
 * @notice A generic-call clone bound to live vault 1 on Robinhood 4663 runs a
 *         round trip through the live `UniswapSwapAdapter`: buy WETH with USDG
 *         at execute, sell the whole WETH balance at settle with a scaled
 *         balance patch writing a proportional minimum out. Real venue
 *         bytecode, real pool, real patch words.
 *
 * @dev The governor's active-proposal binding is mocked (`getActiveProposal`,
 *      `strategyOf`) and `execute` / `settle` are called as the vault: this is
 *      about the template against a real venue, not the proposal lifecycle,
 *      which `GenericCallStrategy_lifecycle.t.sol` covers on a local stack.
 *      The vault is dealt the pull so the live TVL is never touched.
 *
 *      Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention).
 *
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        forge test --match-contract GenericCallUniswapFork -vv
 */
contract GenericCallUniswapForkTest is Test {
    uint256 constant CHAIN_ROBINHOOD = 4663;

    address constant STRATEGY_FACTORY = 0xb06788F027268a9A06c3AD41a88559530D2E54b1;
    /// @dev Vault 1 (guard-mainnet-test), the first active syndicate on 4663.
    address constant VAULT = 0x7396CccbeC83fC06854Fcd307773da756b374ABc;
    /// @dev `UNISWAP_SWAP_ADAPTER` in the pinned `chains/4663.json`.
    address constant ADAPTER = 0x54E6A7af53143556973493fDeC9d7837A77c67eF;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev Mode 0 (Uniswap v3 single hop) through the 5 bps USDG/WETH pool.
    uint24 constant FEE_500 = 500;
    uint256 constant PULL = 50e6;
    /// @dev The proposer's slippage allowance off the propose-time quote.
    uint256 constant SLIPPAGE_BPS = 100;

    bool forked;
    bytes route;
    GenericCallStrategy clone;
    uint256 mulNum;
    uint256 mulDen;

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
        route = abi.encodePacked(uint8(0), abi.encode(FEE_500));
    }

    function _skipIfNoFork() internal {
        if (!forked) vm.skip(true);
    }

    /// @notice Execute buys WETH, settle sells the patched balance with a patched floor; the vault
    ///         gets its USDG back less two pool fees, and the clone ends empty.
    function test_liveVenue_roundTripWithScaledFloor() public {
        _skipIfNoFork();
        _cloneRoundTrip();
        uint256 vaultBefore = IERC20(USDG).balanceOf(VAULT);
        _execute();
        assertEq(vaultBefore - IERC20(USDG).balanceOf(VAULT), PULL, "vault paid exactly the pull");
        uint256 bought = IERC20(WETH).balanceOf(address(clone));
        assertGt(bought, 0, "bought WETH");
        assertEq(IERC20(USDG).balanceOf(address(clone)), 0, "whole pull spent");
        assertEq(IERC20(USDG).allowance(address(clone), ADAPTER), 0, "execute grant revoked");

        // Both settle words are written at settle time: amountIn from the live balance, the
        // minimum out from the same balance at the propose-time floor price.
        uint256 floor = Math.mulDiv(bought, mulNum, mulDen);
        vm.expectCall(ADAPTER, abi.encodeCall(ISwapAdapter.swap, (WETH, USDG, bought, floor, route)));
        vm.prank(VAULT);
        clone.settle();

        uint256 back = IERC20(USDG).balanceOf(VAULT) - (vaultBefore - PULL);
        console2.log("pull (USDG raw)", PULL);
        console2.log("WETH bought (wei)", bought);
        console2.log("settle floor (USDG raw)", floor);
        console2.log("returned (USDG raw)", back);
        assertGe(back, floor, "sold at or above the floor");
        assertGt(back, (PULL * 99) / 100, "round trip costs about two pool fees");
        assertEq(IERC20(WETH).balanceOf(address(clone)), 0, "position fully sold");
        assertEq(IERC20(USDG).balanceOf(address(clone)), 0, "clone empty");
        assertEq(IERC20(WETH).allowance(address(clone), ADAPTER), 0, "settle grant revoked");
        assertEq(uint256(clone.state()), uint256(BaseStrategy.State.Settled));
    }

    /// @notice Someone sells WETH into the pool between execute and settle until the clone's position
    ///         is worth less than the floor: the scaled minimum makes the settle sell revert rather
    ///         than fill at the moved price. Without the scale, a fixed minimum of 0 would have filled.
    function test_liveVenue_scaledFloorRevertsWhenThePoolMoves() public {
        _skipIfNoFork();
        _cloneRoundTrip();
        _execute();
        uint256 bought = IERC20(WETH).balanceOf(address(clone));
        uint256 floor = Math.mulDiv(bought, mulNum, mulDen);

        address whale = makeAddr("whale");
        uint256 dump = 1e18;
        uint256 quoteNow = ISwapAdapter(ADAPTER).quote(WETH, USDG, bought, route);
        for (uint256 k; k < 12 && quoteNow >= floor; ++k) {
            deal(WETH, whale, dump);
            vm.startPrank(whale);
            IERC20(WETH).approve(ADAPTER, dump);
            ISwapAdapter(ADAPTER).swap(WETH, USDG, dump, 0, route);
            vm.stopPrank();
            quoteNow = ISwapAdapter(ADAPTER).quote(WETH, USDG, bought, route);
            dump *= 2;
        }
        console2.log("settle floor (USDG raw)", floor);
        console2.log("position after the move (USDG raw)", quoteNow);
        assertLt(quoteNow, floor, "the pool did not move below the floor");

        // The v3 router refuses the fill below the patched minimum; the template reports leg 1, call 1.
        vm.prank(VAULT);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenericCallStrategy.CallFailed.selector,
                uint8(1),
                1,
                abi.encodeWithSignature("Error(string)", "Too little received")
            )
        );
        clone.settle();
        assertEq(IERC20(WETH).balanceOf(address(clone)), bought, "nothing sold below the floor");
        assertEq(uint256(clone.state()), uint256(BaseStrategy.State.Executed));
    }

    // ── helpers ──

    /// @dev Approve a fresh template on the live factory and clone it for vault 1 with the round
    ///      trip, the floor priced from quotes taken now, as a proposer would at propose time. The
    ///      vault is then dealt the pull on top of its live balance.
    function _cloneRoundTrip() internal {
        assertEq(IERC4626(VAULT).asset(), USDG, "vault 1 is a USDG vault");
        StrategyFactory factory = StrategyFactory(STRATEGY_FACTORY);
        address template = address(new GenericCallStrategy());
        vm.prank(factory.owner());
        factory.setTemplateApproval(template, true);

        uint256 wethQuoted = ISwapAdapter(ADAPTER).quote(USDG, WETH, PULL, route);
        uint256 usdgQuoted = ISwapAdapter(ADAPTER).quote(WETH, USDG, wethQuoted, route);
        mulNum = usdgQuoted * (10_000 - SLIPPAGE_BPS);
        mulDen = wethQuoted * 10_000;

        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](2);
        e[0] = _call(USDG, abi.encodeCall(IERC20.approve, (ADAPTER, PULL)));
        e[1] = _call(
            ADAPTER,
            abi.encodeCall(
                ISwapAdapter.swap, (USDG, WETH, PULL, (wethQuoted * (10_000 - SLIPPAGE_BPS)) / 10_000, route)
            )
        );
        BatchExecutorLib.Call[] memory s = new BatchExecutorLib.Call[](2);
        s[0] = _call(WETH, abi.encodeCall(IERC20.approve, (ADAPTER, type(uint256).max)));
        s[1] = _call(ADAPTER, abi.encodeCall(ISwapAdapter.swap, (WETH, USDG, 0, 0, route)));
        GenericCallStrategy.BalancePatch[] memory p = new GenericCallStrategy.BalancePatch[](2);
        p[0] = GenericCallStrategy.BalancePatch({callIndex: 1, wordIndex: 2, token: WETH, mulNum: 0, mulDen: 0});
        p[1] =
            GenericCallStrategy.BalancePatch({callIndex: 1, wordIndex: 3, token: WETH, mulNum: mulNum, mulDen: mulDen});

        address proposer = makeAddr("proposer");
        vm.prank(proposer);
        clone = GenericCallStrategy(
            factory.cloneAndInit(template, VAULT, proposer, abi.encode(PULL, e, s, p, new address[](0)))
        );
        assertEq(factory.cloneTemplate(address(clone)), template, "provenance");
        deal(USDG, VAULT, IERC20(USDG).balanceOf(VAULT) + PULL);
    }

    /// @dev Bind the clone as the active proposal's strategy and run the execute batch's two calls
    ///      as the vault.
    function _execute() internal {
        address gov = IProtocolPath(VAULT).governor();
        vm.mockCall(gov, abi.encodeCall(IProposalStatus.getActiveProposal, ()), abi.encode(uint256(1)));
        vm.mockCall(gov, abi.encodeCall(IProposalStatus.strategyOf, (uint256(1))), abi.encode(address(clone)));
        vm.prank(VAULT);
        IERC20(USDG).approve(address(clone), PULL);
        vm.prank(VAULT);
        clone.execute();
    }

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: target, data: data, value: 0});
    }
}
