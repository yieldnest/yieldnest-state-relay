// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StateReceiver} from "src/StateReceiver.sol";
import {StateReceiverHarness} from "test/mocks/StateReceiverHarness.sol";
import {StateStore} from "src/StateStore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";

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
        bytes memory recvInit = abi.encodeCall(StateReceiver.initialize, (address(this), address(stateStore)));
        ERC1967Proxy recvProxy = new ERC1967Proxy(address(recvImpl), recvInit);
        receiver = StateReceiverHarness(address(recvProxy));

        stateStore.grantRole(stateStore.WRITER_ROLE(), address(receiver));
    }

    function test_receivePayload_supportedVersion_writesToStore() public {
        uint64 ts = uint64(block.timestamp);
        bytes memory value = abi.encode(uint256(1e18));
        bytes memory message = abi.encode(uint8(1), KEY, value, ts);

        receiver.receivePayload(message);

        (bytes memory stored,,) = stateStore.get(KEY);
        assertEq(stored, value);
        assertEq(abi.decode(stored, (uint256)), 1e18);
    }

    function test_receivePayload_unsupportedVersion_ignoresMessage() public {
        uint64 ts = uint64(block.timestamp);
        bytes memory value = abi.encode(uint256(1e18));
        bytes memory message = abi.encode(uint8(99), KEY, value, ts);

        receiver.receivePayload(message);

        (bytes memory stored, uint64 srcTs, uint64 updatedAt) = stateStore.get(KEY);
        assertEq(stored.length, 0);
        assertEq(srcTs, 0);
        assertEq(updatedAt, 0);
    }

    function test_receivePayload_setSupportedVersion_thenReceives() public {
        receiver.setSupportedVersion(2, true);

        uint64 ts = uint64(block.timestamp);
        bytes memory value = abi.encode(uint256(2e18));
        bytes memory message = abi.encode(uint8(2), KEY, value, ts);

        receiver.receivePayload(message);

        (bytes memory stored,,) = stateStore.get(KEY);
        assertEq(abi.decode(stored, (uint256)), 2e18);
    }

    function test_receivePayload_staleTimestamp_same_block_no_revert() public {
        uint64 ts = uint64(block.timestamp);
        receiver.receivePayload(abi.encode(uint8(1), KEY, abi.encode(uint256(1e18)), ts));

        receiver.receivePayload(abi.encode(uint8(1), KEY, abi.encode(uint256(2e18)), ts));
    }

    function test_receivePayload__non_staleTimestamp_future_block_no_revert(uint256 blocksPassed) public {
        vm.assume(blocksPassed < 100000);
        uint64 ts = uint64(block.timestamp);
        receiver.receivePayload(abi.encode(uint8(1), KEY, abi.encode(uint256(1e18)), ts));

        vm.roll(block.number + blocksPassed);
   
        receiver.receivePayload(abi.encode(uint8(1), KEY, abi.encode(uint256(2e18)), ts));
    }
}
