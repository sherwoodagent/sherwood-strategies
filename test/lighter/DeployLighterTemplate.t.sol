// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {IStrategy} from "@sherwood/interfaces/IStrategy.sol";
import {DeployLighterTemplate} from "../../script/lighter/DeployLighterTemplate.s.sol";
import {MockZkLighter} from "../mocks/MockZkLighter.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Drives the v1 template ceremony against the REAL v1 `StrategyFactory`
///         and `TierRegistry` (compiled from the pinned protocol), with the venue
///         mocked at its constant address.
contract DeployLighterTemplateTest is Test {
    address internal constant ZK = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;
    address internal constant USDG_ADDR = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    DeployLighterTemplate internal script;
    StrategyFactory internal factory;
    TierRegistry internal registry;

    function setUp() public {
        vm.chainId(4663);
        ERC20Mock usdgImpl = new ERC20Mock("USDG", "USDG", 6);
        vm.etch(USDG_ADDR, address(usdgImpl).code);
        MockZkLighter zkImpl = new MockZkLighter(IERC20(USDG_ADDR));
        vm.etch(ZK, address(zkImpl).code);

        script = new DeployLighterTemplate();
        // The script contract is the owner here, standing in for the broadcaster.
        factory = new StrategyFactory(makeAddr("syndicateFactory"), address(script));
        registry = new TierRegistry(address(script));
        vm.prank(address(script));
        registry.setStrategyFactory(address(factory));
    }

    function test_ceremony_asOwner_approvesAndAllows() public {
        (address template, bool complete) = script.ceremony(address(factory), address(registry), ZK, address(script));
        assertTrue(complete);
        assertTrue(template.code.length != 0);
        assertTrue(factory.approvedTemplate(template));
        assertTrue(registry.isCounterpartyAllowed(ZK));
        (uint8 t, uint16 b) = registry.classTierOf(template, IStrategy.execute.selector);
        assertEq(t, 2);
        assertEq(b, 10_000);
        (t, b) = registry.classTierOf(template, IStrategy.settle.selector);
        assertEq(t, 2);
        assertEq(b, 10_000);
    }

    /// @dev The Safe owns both: the template still deploys, nothing owner-gated
    ///      is attempted, and the run reports itself incomplete.
    function test_ceremony_notOwner_degradesToRunbook() public {
        address stranger = makeAddr("deployerKey");
        (address template, bool complete) = script.ceremony(address(factory), address(registry), ZK, stranger);
        assertFalse(complete);
        assertTrue(template.code.length != 0);
        assertFalse(factory.approvedTemplate(template));
        assertFalse(registry.isCounterpartyAllowed(ZK));
    }

    function test_ceremony_venueAlreadyAllowed_isIdempotent() public {
        vm.prank(address(script));
        registry.setCounterpartyAllowed(ZK, true);
        (, bool complete) = script.ceremony(address(factory), address(registry), ZK, address(script));
        assertTrue(complete);
    }

    function test_ceremony_registryWiredToAnotherFactory_reverts() public {
        TierRegistry other = new TierRegistry(address(script));
        StrategyFactory otherFactory = new StrategyFactory(makeAddr("sf2"), address(script));
        vm.prank(address(script));
        other.setStrategyFactory(address(otherFactory));
        vm.expectRevert(bytes("TIER_REGISTRY.strategyFactory() is not STRATEGY_FACTORY - wrong address book"));
        script.ceremony(address(factory), address(other), ZK, address(script));
    }

    /// @dev A certified money-moving selector must fail the post-flight: the
    ///      template would be priced as a bounded adapter, which it is not.
    function test_ceremony_certifiedExecute_isRefused() public {
        // Pre-certify the class of the template the ceremony is about to deploy:
        // CREATE from the script at its current nonce.
        address predicted = vm.computeCreateAddress(address(script), vm.getNonce(address(script)));
        vm.etch(predicted, hex"00"); // any code, so proposeClassCertification accepts it
        vm.startPrank(address(script));
        registry.proposeClassCertification(
            predicted, IStrategy.execute.selector, 0, 1, address(script), predicted.codehash
        );
        vm.warp(block.timestamp + registry.certifyDelay());
        vm.stopPrank();
        registry.certifyClass(predicted, IStrategy.execute.selector);
        vm.etch(predicted, ""); // clear it so the CREATE can land

        vm.expectRevert(bytes("execute()/settle() must stay UNCERTIFIED"));
        script.ceremony(address(factory), address(registry), ZK, address(script));
    }

    function test_venue_readsTheBook() public view {
        DeployLighterTemplate.Venue memory v = script.venue();
        assertEq(v.zkLighter, ZK);
        assertEq(v.usdg, USDG_ADDR);
        assertEq(v.usdgAssetIndex, 3);
        script.assertVenue(v);
    }

    function test_venue_wrongAssetIndex_reverts() public {
        DeployLighterTemplate.Venue memory v = script.venue();
        v.usdgAssetIndex = 4;
        vm.expectRevert();
        script.assertVenue(v);
    }
}
