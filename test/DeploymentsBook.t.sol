// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploymentsBook} from "../script/DeploymentsBook.sol";

/// @dev Writes to a scratch directory and pretends to be broadcasting, so the
///      record path can be exercised inside `forge test`.
contract BookHarness is DeploymentsBook {
    bool public broadcasting;
    string internal _dir;

    constructor(string memory dir_) {
        _dir = dir_;
    }

    function setBroadcasting(bool v) external {
        broadcasting = v;
    }

    function _deploymentsDir() internal view override returns (string memory) {
        return _dir;
    }

    function _isBroadcast() internal view override returns (bool) {
        return broadcasting;
    }

    function record(string memory key, address value) external {
        _recordAddress(key, value);
    }

    function recordMeta(string memory section, uint256 blockNumber) external {
        _recordMeta(section, vm.serializeUint(section, "block", blockNumber));
    }

    function deployed(string memory key) external view returns (address) {
        return _deployedAddress(key);
    }

    function protocol(string memory key) external view returns (address) {
        return _protocolAddress(key);
    }
}

contract DeploymentsBookTest is Test {
    string internal dir;
    BookHarness internal book;

    function setUp() public {
        vm.chainId(9994663);
    }

    /// @dev One scratch directory per test: the suite's tests run in parallel.
    function _book(string memory name) internal returns (BookHarness) {
        dir = string.concat(vm.projectRoot(), "/deployments/.test-", name);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        book = new BookHarness(dir);
        return book;
    }

    function _cleanup() internal {
        if (vm.exists(dir)) vm.removeDir(dir, true);
    }

    function test_record_isANoOpOutsideABroadcast() public {
        _book("noop");
        book.record("LAUNCHPAD_TEMPLATE", address(0xA1));
        assertFalse(vm.exists(book.deploymentsPath(9994663)), "a non-broadcast run wrote the book");
        _cleanup();
    }

    function test_record_mergesKeysFromSeparateScripts() public {
        _book("merge");
        book.setBroadcasting(true);
        book.record("LAUNCHPAD_TEMPLATE", address(0xA1));
        book.record("SUSHI_LAUNCH_ADAPTER", address(0xA2));
        // A second script writing the same chain's book keeps the first one's keys.
        book.record("LIGHTER_PERP_TEMPLATE", address(0xB1));
        book.recordMeta("lighter", 123);
        // A redeploy replaces its own key only.
        book.record("LAUNCHPAD_TEMPLATE", address(0xA3));

        assertEq(book.deployed("LAUNCHPAD_TEMPLATE"), address(0xA3));
        assertEq(book.deployed("SUSHI_LAUNCH_ADAPTER"), address(0xA2));
        assertEq(book.deployed("LIGHTER_PERP_TEMPLATE"), address(0xB1));
        string memory json = vm.readFile(book.deploymentsPath(9994663));
        assertEq(vm.parseJsonUint(json, "._meta.lighter.block"), 123, "provenance nested under _meta");
        _cleanup();
    }

    function test_deployed_isZeroWhenTheBookOrKeyIsMissing() public {
        _book("missing");
        assertEq(book.deployed("LAUNCHPAD_TEMPLATE"), address(0));
    }

    function test_protocol_readsThePinnedBookForThisChain() public {
        _book("protocol");
        // The pinned protocol's 9994663 book names the live vnet stack.
        assertEq(book.protocol("STRATEGY_FACTORY"), 0xb06788F027268a9A06c3AD41a88559530D2E54b1);
        assertEq(book.protocol("TIER_REGISTRY"), 0x4614f058920941A0a9a852e62485fbDE692D75E1);
    }
}
