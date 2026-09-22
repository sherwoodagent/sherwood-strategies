// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IZkLighter} from "../../src/lighter/IZkLighter.sol";

/// @notice Which storage slot does ZkLighter read for `getPendingBalance(owner, 3)`?
///         Run WITHOUT --broadcast, against 4663 or any fork of it:
///
///           forge script script/lighter/LighterSlotProbe.s.sol:LighterSlotProbe \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com
///
///         `vm.record` RATHER THAN `debug_traceCall`, which the Tenderly vnets
///         answer `-32002 not supported`. Forge runs the staticcall in its own
///         EVM against the forked state, so the SLOAD keys are the venue's real
///         ones. Two owners are probed on purpose: a REGISTERED account walks
///         `addressToAccountIndex -> pendingAssetBalances` and its third read is
///         the slot wanted; an unregistered one short-circuits and never reaches
///         it, which is what tells the two reads apart.
///
///         Solving `keccak(acct || keccak(asset || B)) == observed` over
///         `B in [0, 600)` yields B = 498, offset 0: the base slot of
///         `pendingAssetBalances[assetIndex][accountIndex]`. That is the figure a
///         fork test or bench writes to simulate the sequencer maturing a
///         withdrawal (`vm.store` / `tenderly_setStorageAt`), since nothing on a
///         fork ever matures one. `pendingSlot` below recomputes it for any
///         account index; `run()` checks the derivation against the live read.
contract LighterSlotProbe is Script {
    IZkLighter constant ZKL = IZkLighter(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);
    uint256 constant PENDING_BALANCES_BASE_SLOT = 498;
    uint16 constant USDG_ASSET_INDEX = 3;

    /// @dev The canary's contract-owned account on 4663 (registered), and an
    ///      address that has never deposited.
    address constant REGISTERED = 0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E;
    address constant UNREGISTERED = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        _probe(REGISTERED);
        _probe(UNREGISTERED);
    }

    /// @notice `pendingAssetBalances[USDG_ASSET_INDEX][accountIndex]`.
    function pendingSlot(uint48 accountIndex) public pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(uint256(USDG_ASSET_INDEX), PENDING_BALANCES_BASE_SLOT));
        return keccak256(abi.encode(uint256(accountIndex), inner));
    }

    function _probe(address owner) internal {
        uint48 acct = ZKL.addressToAccountIndex(owner);
        vm.record();
        uint128 v = ZKL.getPendingBalance(owner, USDG_ASSET_INDEX);
        (bytes32[] memory reads,) = vm.accesses(address(ZKL));
        console.log("owner", owner, "pending", uint256(v));
        console.log("accountIndex", uint256(acct));
        bool matched;
        for (uint256 i; i < reads.length; i++) {
            console.logBytes32(reads[i]);
            if (acct != 0 && reads[i] == pendingSlot(acct)) matched = true;
        }
        if (acct != 0) {
            console.log("derived slot (base 498) read by getPendingBalance:", matched);
            require(matched, "slot derivation no longer matches the venue - re-derive PENDING_BALANCES_BASE_SLOT");
        }
    }
}
