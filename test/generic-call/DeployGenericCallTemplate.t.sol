// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {StrategyFactory} from "@sherwood/StrategyFactory.sol";
import {TierRegistry} from "@sherwood/TierRegistry.sol";
import {BatchExecutorLib} from "@sherwood/BatchExecutorLib.sol";
import {BaseStrategy} from "@sherwood/strategies/BaseStrategy.sol";
import {IStrategy} from "@sherwood/interfaces/IStrategy.sol";
import {GenericCallStrategy} from "../../src/generic-call/GenericCallStrategy.sol";
import {DeployGenericCallTemplate} from "../../script/generic-call/DeployGenericCallTemplate.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {GCRegistryStub, GCGovernorStub, GCVaultStub, GCGuardianRegistryStub} from "../mocks/GenericCallMocks.sol";

/// @dev Another template's shape: no vault bound, a different `name()`.
contract NotGenericCall {
    function vault() external pure returns (address) {
        return address(0);
    }

    function name() external pure returns (string memory) {
        return "Lighter Perp";
    }
}

/// @notice Drives the v1 template ceremony against the REAL v1 `StrategyFactory`
///         and `TierRegistry` (compiled from the pinned protocol). The template
///         has no venue, so there is nothing to mock at a constant address.
contract DeployGenericCallTemplateTest is Test {
    DeployGenericCallTemplate internal script;
    StrategyFactory internal factory;
    TierRegistry internal registry;

    function setUp() public {
        script = new DeployGenericCallTemplate();
        // The script contract is the owner here, standing in for the broadcaster.
        factory = new StrategyFactory(makeAddr("syndicateFactory"), address(script));
        registry = new TierRegistry(address(script));
        vm.prank(address(script));
        registry.setStrategyFactory(address(factory));
    }

    function _emptyPlan() internal pure returns (bytes memory) {
        return abi.encode(
            uint256(0),
            new BatchExecutorLib.Call[](0),
            new BatchExecutorLib.Call[](0),
            new GenericCallStrategy.BalancePatch[](0),
            new address[](0)
        );
    }

    /// @dev The vault surface a clone's `_initialize` walks, all resolving.
    function _stubVault() internal returns (GCVaultStub) {
        GCRegistryStub reg = new GCRegistryStub();
        reg.setStrategyFactory(makeAddr("strategyFactory"));
        GCGovernorStub gov = new GCGovernorStub(address(reg));
        gov.setGuardianRegistry(address(new GCGuardianRegistryStub(makeAddr("swood"))));
        return new GCVaultStub(address(new ERC20Mock("USDG", "USDG", 6)), address(gov), makeAddr("syndicateFactory"));
    }

    function test_ceremony_asOwner_approves() public {
        (address template, bool complete) = script.ceremony(address(factory), address(registry), address(script));
        assertTrue(complete);
        assertTrue(template.code.length != 0);
        assertTrue(factory.approvedTemplate(template));
        (uint8 t, uint16 b) = registry.classTierOf(template, IStrategy.execute.selector);
        assertEq(t, 2);
        assertEq(b, 10_000);
        (t, b) = registry.classTierOf(template, IStrategy.settle.selector);
        assertEq(t, 2);
        assertEq(b, 10_000);
    }

    /// @dev The ceremony touches nothing on the counterparty axis: the template
    ///      has no venue to allow.
    function test_ceremony_grantsNoCounterparty() public {
        (address template,) = script.ceremony(address(factory), address(registry), address(script));
        assertFalse(registry.isCounterpartyAllowed(template));
    }

    /// @dev A Safe owns the factory: the template still deploys, the approval is
    ///      not attempted, and the run reports itself incomplete.
    function test_ceremony_notOwner_degradesToRunbook() public {
        address stranger = makeAddr("deployerKey");
        (address template, bool complete) = script.ceremony(address(factory), address(registry), stranger);
        assertFalse(complete);
        assertTrue(template.code.length != 0);
        assertFalse(factory.approvedTemplate(template));
    }

    function test_ceremony_registryWiredToAnotherFactory_reverts() public {
        TierRegistry other = new TierRegistry(address(script));
        StrategyFactory otherFactory = new StrategyFactory(makeAddr("sf2"), address(script));
        vm.prank(address(script));
        other.setStrategyFactory(address(otherFactory));
        vm.expectRevert(bytes("TIER_REGISTRY.strategyFactory() is not STRATEGY_FACTORY - wrong address book"));
        script.ceremony(address(factory), address(other), address(script));
    }

    function test_ceremony_codelessSingletons_revert() public {
        vm.expectRevert(bytes("STRATEGY_FACTORY holds no code on this chain"));
        script.ceremony(makeAddr("nothing"), address(registry), address(script));
        vm.expectRevert(bytes("TIER_REGISTRY holds no code on this chain"));
        script.ceremony(address(factory), makeAddr("nothing"), address(script));
    }

    function test_verify_acceptsACompleteCeremony() public {
        (address template,) = script.ceremony(address(factory), address(registry), address(script));
        script.verifyDeployment(address(factory), address(registry), template);
    }

    /// @dev The owner approves after a non-owner run, as the Safe does on 4663.
    function test_verify_acceptsTheApprovalLandingLater() public {
        (address template,) = script.ceremony(address(factory), address(registry), makeAddr("deployerKey"));
        vm.prank(address(script));
        factory.setTemplateApproval(template, true);
        script.verifyDeployment(address(factory), address(registry), template);
    }

    function test_verify_refusesADeploymentStillOwedTheApproval() public {
        (address template,) = script.ceremony(address(factory), address(registry), makeAddr("deployerKey"));
        vm.expectRevert(bytes("template not approved on StrategyFactory"));
        script.verifyDeployment(address(factory), address(registry), template);
    }

    function test_verify_refusesACodelessTemplate() public {
        vm.expectRevert(bytes("GENERIC_CALL_TEMPLATE holds no code"));
        script.verifyDeployment(address(factory), address(registry), makeAddr("nothing"));
    }

    function test_verify_refusesAClone() public {
        (address template,) = script.ceremony(address(factory), address(registry), address(script));
        GenericCallStrategy clone = GenericCallStrategy(Clones.clone(template));
        clone.initialize(address(_stubVault()), address(this), _emptyPlan());
        vm.expectRevert(bytes("GENERIC_CALL_TEMPLATE is a clone, not the template"));
        script.verifyDeployment(address(factory), address(registry), address(clone));
    }

    function test_verify_refusesAnotherTemplate() public {
        address other = address(new NotGenericCall());
        vm.expectRevert(bytes("GENERIC_CALL_TEMPLATE is not a GenericCallStrategy"));
        script.verifyDeployment(address(factory), address(registry), other);
    }

    /// @dev A certified money-moving selector must fail the post-flight: the
    ///      template would be priced as a bounded adapter, which it never is.
    ///      Certifies a template this test deployed and runs the post-flight on
    ///      it directly, rather than predicting the ceremony's CREATE address,
    ///      which differs across Foundry versions.
    function test_assertUncertified_refusesACertifiedExecute() public {
        address template = address(new GenericCallStrategy());
        vm.startPrank(address(script));
        registry.proposeClassCertification(
            template, IStrategy.execute.selector, 0, 1, address(script), template.codehash
        );
        vm.warp(block.timestamp + registry.certifyDelay());
        vm.stopPrank();
        registry.certifyClass(template, IStrategy.execute.selector);

        vm.expectRevert(bytes("execute()/settle() must stay UNCERTIFIED"));
        script.assertUncertified(address(registry), template);
    }

    /// @notice The template itself can never be initialized: only its clones can.
    function test_template_isLocked() public {
        (address template,) = script.ceremony(address(factory), address(registry), address(script));
        assertEq(GenericCallStrategy(template).name(), "Generic Call");
        assertEq(GenericCallStrategy(template).vault(), address(0), "a template binds no vault");
        GCVaultStub vault = _stubVault();
        bytes memory plan = _emptyPlan();
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        GenericCallStrategy(template).initialize(address(vault), address(this), plan);
    }

    /// @notice A clone of the deployed template initializes against a vault.
    function test_template_isClonable() public {
        (address template,) = script.ceremony(address(factory), address(registry), address(script));
        GCVaultStub vault = _stubVault();
        GenericCallStrategy clone = GenericCallStrategy(Clones.clone(template));
        clone.initialize(address(vault), address(this), _emptyPlan());
        assertEq(clone.vault(), address(vault));
        assertEq(clone.asset(), vault.asset());
    }
}
