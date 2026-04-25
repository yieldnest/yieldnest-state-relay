// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {LayerZeroSenderTransport} from "src/layerzero/LayerZeroSenderTransport.sol";
import {LayerZeroReceiverTransport} from "src/layerzero/LayerZeroReceiverTransport.sol";
import {IRelayTransport} from "src/interfaces/IRelayTransport.sol";
import {StateStore} from "src/StateStore.sol";

contract LayerZeroSenderTransportTest is Test, TestHelperOz5 {
    uint32 internal constant SRC_EID = 1;
    uint32 internal constant DST_EID = 2;
    uint256 internal constant DST_CHAIN_ID = 42161;
    bytes32 internal constant KEY = keccak256("rate-key");

    LayerZeroSenderTransport internal senderTransport;
    LayerZeroReceiverTransport internal receiverTransport;
    StateStore internal stateStore;

    function setUp() public override {
        TestHelperOz5.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        LayerZeroSenderTransport senderTransportImpl = new LayerZeroSenderTransport(address(endpoints[SRC_EID]));
        bytes memory senderTransportInit = abi.encodeCall(LayerZeroSenderTransport.initialize, (address(this)));
        senderTransport =
            LayerZeroSenderTransport(address(new ERC1967Proxy(address(senderTransportImpl), senderTransportInit)));
        senderTransport.grantRole(senderTransport.SENDER_ROLE(), address(this));

        StateStore stateStoreImpl = new StateStore();
        bytes memory storeInit = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        stateStore = StateStore(address(new ERC1967Proxy(address(stateStoreImpl), storeInit)));
        LayerZeroReceiverTransport receiverTransportImpl = new LayerZeroReceiverTransport(address(endpoints[DST_EID]));
        bytes memory receiverInit =
            abi.encodeCall(LayerZeroReceiverTransport.initialize, (address(this), address(stateStore)));
        receiverTransport =
            LayerZeroReceiverTransport(address(new ERC1967Proxy(address(receiverTransportImpl), receiverInit)));
        stateStore.grantRole(stateStore.WRITER_ROLE(), address(receiverTransport));

        wireOApps(_toAddressArray(address(senderTransport), address(receiverTransport)));

        LayerZeroSenderTransport.DestinationConfig[] memory destinationConfigs =
            new LayerZeroSenderTransport.DestinationConfig[](1);
        destinationConfigs[0] = LayerZeroSenderTransport.DestinationConfig({
            lzEid: DST_EID,
            peer: addressToBytes32(address(receiverTransport)),
            options: OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 500_000, 0),
            enabled: true
        });
        uint256[] memory destinationIds = new uint256[](1);
        destinationIds[0] = DST_CHAIN_ID;
        senderTransport.setDestination(destinationConfigs, destinationIds);
    }

    function test_quoteSend_returnsNativeFeeQuote() public view {
        IRelayTransport.TransportQuote memory quote = senderTransport.quoteSend(DST_CHAIN_ID, abi.encode("payload"));
        assertEq(quote.token, address(0));
        assertTrue(quote.nativeFee);
        assertTrue(quote.feeAmount > 0);
    }

    function test_send_deliversMessageToConfiguredPeer() public {
        bytes memory message = abi.encode(uint256(1), KEY, abi.encode(uint256(1e18)), uint64(block.timestamp));
        IRelayTransport.TransportQuote memory quote = senderTransport.quoteSend(DST_CHAIN_ID, message);

        senderTransport.send{value: quote.feeAmount}(DST_CHAIN_ID, message, address(this));
        verifyPackets(DST_EID, addressToBytes32(address(receiverTransport)));

        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(entry.version, 1);
        assertEq(entry.srcTimestamp, block.timestamp);
        assertEq(abi.decode(entry.value, (uint256)), 1e18);
    }

    function test_send_manySequentially_succeeds() public {
        uint256 N = 5;
        bytes32[] memory keys = new bytes32[](N);
        uint256[] memory values = new uint256[](N);
        uint64[] memory timestamps = new uint64[](N);

        for (uint256 i = 0; i < N; i++) {
            keys[i] = keccak256(abi.encodePacked("key-", i));
            values[i] = 1e18 + i;
            timestamps[i] = uint64(block.timestamp + i);

            bytes memory message = abi.encode(uint256(1), keys[i], abi.encode(values[i]), timestamps[i]);
            IRelayTransport.TransportQuote memory quote = senderTransport.quoteSend(DST_CHAIN_ID, message);

            senderTransport.send{value: quote.feeAmount}(DST_CHAIN_ID, message, address(this));
            verifyPackets(DST_EID, addressToBytes32(address(receiverTransport)));

            StateStore.Entry memory entry = stateStore.get(keys[i]);
            assertEq(entry.version, 1);
            assertEq(entry.srcTimestamp, timestamps[i]);
            assertEq(abi.decode(entry.value, (uint256)), values[i]);
        }
    }

    function test_send_disabledDestination_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(LayerZeroSenderTransport.LayerZeroSenderTransport_DestinationNotEnabled.selector, 999)
        );
        senderTransport.send(999, abi.encode("payload"), address(this));
    }

    function _toAddressArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
