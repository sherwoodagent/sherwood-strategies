// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, VmSafe} from "forge-std/Script.sol";

/**
 * @title  DeploymentsBook
 * @notice The address books every deploy script in this repo reads and writes.
 *
 *   TWO BOOKS, TWO OWNERS.
 *     - READ: the protocol's book, `lib/sherwood-protocol/chains/<chainid>.json`,
 *       for the v1 singletons a template is wired into (`STRATEGY_FACTORY`,
 *       `TIER_REGISTRY`, ...). An env var of the same name wins, because the
 *       submodule pin can lag a protocol deployment. This repo never writes it.
 *     - WRITE: this repo's book, `deployments/<chainid>.json`, for what this repo
 *       deploys. Same flat `KEY -> address` shape as the protocol's book, so the
 *       CLI maps it the way it already maps `chains/<chainid>.json`. Provenance
 *       goes under `_meta.<script>`, never at the top level, so a consumer that
 *       reads every top-level key as an address stays correct.
 *
 *   WRITES HAPPEN ONLY ON A REAL BROADCAST (`forge script --broadcast` or
 *   `--resume`). A dry run, a `forge test` driving a script, and a simulation
 *   all leave the book untouched, so the committed file only ever names
 *   contracts that exist on-chain. The commit that adds a book entry carries the
 *   `broadcast/` log and the submodule pin it was built against, which is why
 *   neither is copied into the file.
 *
 *   MERGE, NOT OVERWRITE. Each key is written on its own (`vm.writeJson` with a
 *   key path inserts or replaces that key alone), so the launchpad and Lighter
 *   scripts share one file per chain without either erasing the other's keys.
 */
abstract contract DeploymentsBook is Script {
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ROBINHOOD_FORK = 9994663;

    /// @notice Where this repo's book for `chainId` lives.
    function deploymentsPath(uint256 chainId) public view returns (string memory) {
        return string.concat(_deploymentsDir(), "/", vm.toString(chainId), ".json");
    }

    /// @dev Overridable so a test can write to a scratch directory.
    function _deploymentsDir() internal view virtual returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments");
    }

    /// @dev True only for `forge script --broadcast` / `--resume`.
    function _isBroadcast() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    /// @dev A protocol singleton: env override first, then the pinned protocol
    ///      book for THIS chain. `address(0)` when neither names it; the caller
    ///      decides whether that is fatal.
    function _protocolAddress(string memory key) internal view returns (address) {
        address fromEnv = vm.envOr(key, address(0));
        if (fromEnv != address(0)) return fromEnv;
        string memory path =
            string.concat(vm.projectRoot(), "/lib/sherwood-protocol/chains/", vm.toString(block.chainid), ".json");
        return _optionalFrom(path, key);
    }

    /// @dev Like `_protocolAddress`, but the key must resolve.
    function _requireProtocolAddress(string memory key) internal view returns (address a) {
        a = _protocolAddress(key);
        require(a != address(0), string.concat(key, " not in env or the protocol address book for this chain"));
    }

    /// @dev An address this repo deployed on this chain, from its own book.
    ///      `address(0)` when the book or the key is missing.
    function _deployedAddress(string memory key) internal view returns (address) {
        return _optionalFrom(deploymentsPath(block.chainid), key);
    }

    /// @dev Like `_deployedAddress`, but the key must resolve.
    function _requireDeployedAddress(string memory key) internal view returns (address a) {
        a = _deployedAddress(key);
        require(a != address(0), string.concat(key, " missing from ", deploymentsPath(block.chainid)));
    }

    /// @dev Record `key -> value` in this chain's book, on a real broadcast only.
    function _recordAddress(string memory key, address value) internal {
        if (!_isBroadcast()) return;
        string memory path = _ensureBook();
        vm.writeJson(string.concat('"', vm.toString(value), '"'), path, string.concat(".", key));
    }

    /// @dev Record a serialized provenance object under `_meta.<section>`, on a
    ///      real broadcast only.
    function _recordMeta(string memory section, string memory json) internal {
        if (!_isBroadcast()) return;
        string memory path = _ensureBook();
        vm.writeJson(json, path, string.concat("._meta.", section));
    }

    function _ensureBook() private returns (string memory path) {
        path = deploymentsPath(block.chainid);
        if (!vm.exists(path)) {
            vm.createDir(_deploymentsDir(), true);
            vm.writeFile(path, "{}");
        }
    }

    function _optionalFrom(string memory path, string memory key) internal view returns (address) {
        if (!vm.exists(path)) return address(0);
        string memory json = vm.readFile(path);
        string memory jsonKey = string.concat(".", key);
        if (!vm.keyExistsJson(json, jsonKey)) return address(0);
        return vm.parseJsonAddress(json, jsonKey);
    }

    function _isRobinhood() internal view returns (bool) {
        return block.chainid == CHAIN_ROBINHOOD || block.chainid == CHAIN_ROBINHOOD_FORK;
    }
}
