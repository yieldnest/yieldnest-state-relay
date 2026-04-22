// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StateStore} from "src/StateStore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StateStoreTest is Test {
    StateStore public stateStore;
    bytes32 constant KEY = keccak256("test-key");

    function setUp() public {
        StateStore impl = new StateStore();
        bytes memory initData = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stateStore = StateStore(address(proxy));
        stateStore.grantRole(stateStore.WRITER_ROLE(), address(this));
    }

    function _update(uint256 v, uint64 ts) internal pure returns (StateStore.StateUpdate memory) {
        return StateStore.StateUpdate({value: abi.encode(v), version: 1, srcTimestamp: ts});
    }

    function test_write_sameTimestamp_no_revert() public {
        uint64 ts = uint64(block.timestamp);
        stateStore.write(KEY, _update(1e18, ts));
        stateStore.write(KEY, _update(2e18, ts));

        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(abi.decode(entry.value, (uint256)), 1e18);
        assertEq(entry.version, 1);
        assertEq(entry.srcTimestamp, ts);
        assertEq(entry.updatedAt, ts);
    }

    function test_write_lowerTimestamp_no_revert() public {
        uint64 ts = uint64(block.timestamp);
        stateStore.write(KEY, _update(1e18, ts));
        stateStore.write(KEY, _update(2e18, ts - 1));

        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(abi.decode(entry.value, (uint256)), 1e18);
        assertEq(entry.version, 1);
        assertEq(entry.srcTimestamp, ts);
        assertEq(entry.updatedAt, ts);
    }

    function test_write_strictlyIncreasingTimestamp_succeeds() public {
        uint64 ts = uint64(block.timestamp);
        stateStore.write(KEY, _update(1e18, ts));
        stateStore.write(KEY, _update(2e18, ts + 1));
        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(abi.decode(entry.value, (uint256)), 2e18);
    }
}
