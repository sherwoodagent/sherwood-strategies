// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LaunchpadStrategy} from "../../../src/launchpad/LaunchpadStrategy.sol";
import {SushiLaunchAdapter} from "../../../src/launchpad/adapters/SushiLaunchAdapter.sol";
import {ISushiLaunchpadV2} from "../../../src/launchpad/vendor/sushi/ISushiLaunchpadV2.sol";
import {MockSwapAdapter} from "../../mocks/MockSwapAdapter.sol";
import {MockFundVault, MockFundGovernor, MockFundRegistry} from "../LaunchpadStrategy.t.sol";
import {PoolTrader} from "./SushiLaunchAdapterFork.t.sol";

/// @title  LaunchpadSushiV2Fork
/// @notice `LaunchpadStrategy` driving the LIVE Sushi Launchpad V2 on Robinhood
///         4663 end to end: execute launches through the clone adapter, holders
///         claim pro rata, trading fees reach the vault, and settle leaves the
///         strategy holding nothing. The vault, governor and registry are the
///         unit suite's stand-ins; only the venue is real. Skips when
///         `ROBINHOOD_RPC_URL` is unset.
contract LaunchpadSushiV2ForkTest is Test {
    address internal constant LAUNCHPAD = 0xF1716eBf85836ffE2985db9A50dd29e5814caBe9;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    uint256 internal constant SUPPLY = 1e9 * 1e18;
    uint256 internal constant ASSET_IN = 0.05 ether;
    uint256 internal constant RESERVE = 1_000_000e18;
    uint256 internal constant CLAIM_WINDOW = 3 days;
    uint256 internal constant DURATION = 30 days;

    SushiLaunchAdapter internal adapter;
    MockFundRegistry internal registry;
    MockFundGovernor internal governor;
    MockFundVault internal vault;
    LaunchpadStrategy internal strategy;
    PoolTrader internal trader;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        adapter = new SushiLaunchAdapter(LAUNCHPAD);
        MockSwapAdapter swap = new MockSwapAdapter();
        registry = new MockFundRegistry();
        registry.setAllowed(address(adapter), true);
        registry.setAllowed(address(swap), true);
        governor = new MockFundGovernor(address(registry));
        vault = new MockFundVault(WETH, address(governor));
        trader = new PoolTrader();

        deal(WETH, address(vault), 1 ether);
        vault.setVotes(alice, 60e18);
        vault.setVotes(bob, 40e18);

        strategy = LaunchpadStrategy(Clones.clone(address(new LaunchpadStrategy())));
        strategy.initialize(
            address(vault),
            address(this),
            abi.encode(
                LaunchpadStrategy.InitParams({
                    launchAdapter: address(adapter),
                    swapAdapter: address(swap),
                    assetIn: ASSET_IN,
                    // WETH quote on a WETH vault: no quote swap, and the
                    // venue's WETH fee is held back out of the budget.
                    quoteToken: WETH,
                    minQuoteOut: 0,
                    quoteSwapData: "",
                    feeSwapData: "",
                    launchSupply: SUPPLY,
                    reserveAmount: RESERVE,
                    minTokensOut: RESERVE,
                    claimWindow: CLAIM_WINDOW,
                    deadline: uint64(block.timestamp + 1 days),
                    settleSlippageBps: 100,
                    name: "Sherwood Fork Fund",
                    symbol: "SFF",
                    venueData: ""
                })
            )
        );
    }

    function _execute() internal {
        governor.setProposal(block.timestamp, DURATION);
        vault.approveToken(WETH, address(strategy), ASSET_IN);
        vault.callStrategy(address(strategy), abi.encodeWithSignature("execute()"));
    }

    function _clone() internal view returns (address) {
        return address(uint160(uint256(strategy.launchRef())));
    }

    function test_Fork_LaunchClaimCollectSettle_StrategyEndsEmpty() public {
        uint256 vaultBefore = IERC20(WETH).balanceOf(address(vault));
        (, uint256 fee) = adapter.nativeFeeSource();

        _execute();
        address token = strategy.launchToken();
        uint256 held = IERC20(token).balanceOf(address(strategy));

        // ── launch ──
        assertEq(IERC20(token).totalSupply(), SUPPLY, "fixed supply");
        assertGe(held, RESERVE, "the whole initial buy lands on the strategy");
        ISushiLaunchpadV2.LaunchInfoV2 memory info = ISushiLaunchpadV2(LAUNCHPAD).launchInfo(token);
        assertEq(info.feeReceiver, _clone(), "the per-launch clone receives the venue's fees");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "the whole budget was spent (fee + buy)");
        assertEq(vaultBefore - IERC20(WETH).balanceOf(address(vault)), ASSET_IN, "the vault funded exactly assetIn");
        assertGt(ASSET_IN, fee, "fee held back out of the budget");

        // ── claims: the snapshot is the execute timestamp ──
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        uint256 aliceGot = strategy.claim();
        assertEq(aliceGot, (RESERVE * 60) / 100, "60% of the reserve");
        assertEq(IERC20(token).balanceOf(alice), aliceGot);

        // ── fees: real trades on the pool, collected by anyone, paid to the vault ──
        deal(WETH, address(trader), 0.5 ether);
        trader.trade(info.pool, WETH, 0.5 ether);
        uint256 vaultMid = IERC20(WETH).balanceOf(address(vault));
        (uint256 quoteFees,) = adapter.collectFees(strategy.launchRef());
        assertGt(quoteFees, 0, "WETH fees accrued");
        assertEq(IERC20(WETH).balanceOf(address(vault)) - vaultMid, quoteFees, "fees went to the vault");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "and never through the strategy");

        // ── settle after the window: all-or-revert, nothing left on the clone ──
        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        uint256 vaultTokenBefore = IERC20(token).balanceOf(address(vault));
        vault.callStrategy(address(strategy), abi.encodeWithSignature("settle()"));

        assertEq(IERC20(token).balanceOf(address(strategy)), 0, "no launch token left on the strategy");
        assertEq(IERC20(WETH).balanceOf(address(strategy)), 0, "no WETH left on the strategy");
        assertEq(
            IERC20(token).balanceOf(address(vault)) - vaultTokenBefore,
            held - aliceGot,
            "bob's unclaimed share and the buy's surplus reach the vault in kind"
        );

        // ── the v1 P&L this template accepts: the launch reads as a loss ──
        // The governor measures settlement as the vault-asset delta. The
        // reserve left as a dividend in kind and the launch token is not
        // priced, so the vault is down assetIn, offset only by fees.
        assertEq(
            IERC20(WETH).balanceOf(address(vault)),
            vaultBefore - ASSET_IN + quoteFees,
            "vault asset delta = -assetIn + fees"
        );
    }
}
