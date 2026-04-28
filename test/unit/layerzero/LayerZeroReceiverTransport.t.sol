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

contract LayerZeroReceiverTransportTest is Test, TestHelperOz5 {
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
            options: OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0),
            enabled: true
        });
        uint256[] memory destinationIds = new uint256[](1);
        destinationIds[0] = DST_CHAIN_ID;
        senderTransport.setDestination(destinationConfigs, destinationIds);
    }

    function test_receive_deliveryWritesToStateStore() public {
        bytes memory message = abi.encode(uint256(1), KEY, abi.encode(uint256(1e18)), uint64(block.timestamp));
        IRelayTransport.TransportQuote memory quote = senderTransport.quoteSend(DST_CHAIN_ID, message);

        senderTransport.send{value: quote.feeAmount}(DST_CHAIN_ID, message, address(this));
        verifyPackets(DST_EID, addressToBytes32(address(receiverTransport)));

        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(entry.version, 1);
        assertEq(entry.srcTimestamp, block.timestamp);
        assertEq(entry.updatedAt, block.timestamp);
        assertEq(entry.updatedAtBlock, block.number);
        assertEq(abi.decode(entry.value, (uint256)), 1e18);
        assertEq(stateStore.length(KEY), 1);
    }

    function test_receive_staleDeliveryDoesNotAppendHistory() public {
        bytes memory latestMessage = abi.encode(uint256(1), KEY, abi.encode(uint256(1e18)), uint64(block.timestamp));
        IRelayTransport.TransportQuote memory latestQuote = senderTransport.quoteSend(DST_CHAIN_ID, latestMessage);
        senderTransport.send{value: latestQuote.feeAmount}(DST_CHAIN_ID, latestMessage, address(this));
        verifyPackets(DST_EID, addressToBytes32(address(receiverTransport)));

        bytes memory staleMessage = abi.encode(uint256(1), KEY, abi.encode(uint256(2e18)), uint64(block.timestamp - 1));
        IRelayTransport.TransportQuote memory staleQuote = senderTransport.quoteSend(DST_CHAIN_ID, staleMessage);
        senderTransport.send{value: staleQuote.feeAmount}(DST_CHAIN_ID, staleMessage, address(this));
        verifyPackets(DST_EID, addressToBytes32(address(receiverTransport)));

        StateStore.Entry memory entry = stateStore.get(KEY);
        assertEq(abi.decode(entry.value, (uint256)), 1e18);
        assertEq(stateStore.length(KEY), 1);
    }

    function _toAddressArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
