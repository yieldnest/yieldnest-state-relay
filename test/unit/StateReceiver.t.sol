// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LayerZeroReceiverTransport} from "src/layerzero/LayerZeroReceiverTransport.sol";
import {StateReceiverHarness} from "test/mocks/StateReceiverHarness.sol";
import {StateStore} from "src/StateStore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract StateReceiverTest is Test, TestHelperOz5 {
    uint32 constant EID = 1;

    StateStore public stateStore;
    StateReceiverHarness public receiver;
    bytes32 constant KEY = keccak256("rate-key");

    function setUp() public override {
        TestHelperOz5.setUp();
        setUpEndpoints(1, LibraryType.UltraLightNode);

        StateStore impl = new StateStore();
        bytes memory storeInit = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        ERC1967Proxy storeProxy = new ERC1967Proxy(address(impl), storeInit);
        stateStore = StateStore(address(storeProxy));

        StateReceiverHarness recvImpl = new StateReceiverHarness(address(endpoints[EID]));
        bytes memory recvInit =
            abi.encodeCall(LayerZeroReceiverTransport.initialize, (address(this), address(stateStore)));
        ERC1967Proxy recvProxy = new ERC1967Proxy(address(recvImpl), recvInit);
        receiver = StateReceiverHarness(address(recvProxy));

        receiver.grantRole(receiver.PAUSER_ROLE(), address(this));
        stateStore.grantRole(stateStore.WRITER_ROLE(), address(receiver));
    }

    function test_receivePayload_supportedVersion_writesToStore() public {
        uint64 ts = uint64(block.timestamp);
        bytes memory value = abi.encode(uint256(1e18));
        bytes memory message = abi.encode(uint256(1), KEY, value, ts);

        receiver.receivePayload(message);

        bytes memory stored = stateStore.get(KEY).value;
        assertEq(stored, value);
        assertEq(abi.decode(stored, (uint256)), 1e18);
        assertEq(stateStore.length(KEY), 1);
    }

    function test_receivePayload_unsupportedVersion_reverts() public {
        uint64 ts = uint64(block.timestamp);
        bytes memory value = abi.encode(uint256(1e18));
        bytes memory message = abi.encode(uint256(99), KEY, value, ts);

        vm.expectRevert(abi.encodeWithSelector(StateStore.StateStore_UnsupportedVersion.selector, uint256(99)));
        receiver.receivePayload(message);

        assertEq(stateStore.length(KEY), 0);
        vm.expectRevert(abi.encodeWithSelector(StateStore.StateStore_EntryNotFound.selector, KEY));
        stateStore.get(KEY);
    }

    function test_receivePayload_setSupportedVersion_thenReceives() public {
        stateStore.setSupportedVersion(2, true);

        uint64 ts = uint64(block.timestamp);
        bytes memory value = abi.encode(uint256(2e18));
        bytes memory message = abi.encode(uint256(2), KEY, value, ts);

        receiver.receivePayload(message);

        bytes memory stored = stateStore.get(KEY).value;
        assertEq(abi.decode(stored, (uint256)), 2e18);
        assertEq(stateStore.length(KEY), 1);
    }

    function test_receivePayload_staleTimestamp_same_block_no_revert() public {
        uint64 ts = uint64(block.timestamp);
        uint256 writeBlock = block.number;
        receiver.receivePayload(abi.encode(uint256(1), KEY, abi.encode(uint256(1e18)), ts));

        receiver.receivePayload(abi.encode(uint256(1), KEY, abi.encode(uint256(2e18)), ts));

        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(abi.decode(entry.value, (uint256)), 1e18);
        assertEq(entry.version, 1);
        assertEq(entry.srcTimestamp, ts);
        assertEq(entry.updatedAt, ts);
        assertEq(entry.updatedAtBlock, writeBlock);
        assertEq(stateStore.length(KEY), 1);
    }

    function test_receivePayload_lowerTimestamp_future_block_no_revert(uint256 blocksPassed) public {
        vm.assume(blocksPassed < 100000);
        uint64 ts = uint64(block.timestamp);
        uint256 writeBlock = block.number;
        receiver.receivePayload(abi.encode(uint256(1), KEY, abi.encode(uint256(1e18)), ts));

        vm.roll(block.number + blocksPassed);

        receiver.receivePayload(abi.encode(uint256(1), KEY, abi.encode(uint256(2e18)), ts - 1));

        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(abi.decode(entry.value, (uint256)), 1e18);
        assertEq(entry.version, 1);
        assertEq(entry.srcTimestamp, ts);
        assertEq(entry.updatedAt, ts);
        assertEq(entry.updatedAtBlock, writeBlock);
        assertEq(stateStore.length(KEY), 1);
    }

    function test_receivePayload_whenPaused_reverts() public {
        receiver.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        receiver.receivePayload(abi.encode(uint256(1), KEY, abi.encode(uint256(1e18)), uint64(block.timestamp)));
    }
}
