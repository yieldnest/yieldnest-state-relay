// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StateSender} from "src/StateSender.sol";
import {LayerZeroStateRelayTransport} from "src/LayerZeroStateRelayTransport.sol";
import {StateSenderQuoteHarness} from "test/mocks/StateSenderQuoteHarness.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";
import {MockRateTarget} from "test/mocks/MockRateTarget.sol";
import {MessageSink} from "test/mocks/MessageSink.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

contract StateSenderTest is Test, TestHelperOz5 {
    uint32 constant SRC_EID = 1;
    uint32 constant DST_EID = 2;
    uint256 constant DST_CHAIN_ID = 42161;

    StateSender public stateSender;
    LayerZeroStateRelayTransport public transport;
    StateSenderQuoteHarness public quoteHarness;
    MessageSink public messageSink;
    MockRateTarget public mockTarget;

    function setUp() public override {
        TestHelperOz5.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        mockTarget = new MockRateTarget();
        mockTarget.setRate(1e18);

        LayerZeroStateRelayTransport transportImpl = new LayerZeroStateRelayTransport(address(endpoints[SRC_EID]));
        bytes memory transportInitData = abi.encodeCall(LayerZeroStateRelayTransport.initialize, (address(this)));
        ERC1967Proxy transportProxy = new ERC1967Proxy(address(transportImpl), transportInitData);
        transport = LayerZeroStateRelayTransport(address(transportProxy));

        StateSender impl = new StateSender();
        bytes memory initData = abi.encodeCall(
            StateSender.initialize,
            (
                address(this),
                address(transport),
                address(mockTarget),
                abi.encodeWithSelector(MockRateTarget.getRate.selector),
                1
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stateSender = StateSender(address(proxy));

        StateSenderQuoteHarness quoteImpl = new StateSenderQuoteHarness(address(endpoints[SRC_EID]));
        bytes memory quoteInitData = abi.encodeCall(LayerZeroStateRelayTransport.initialize, (address(this)));
        ERC1967Proxy quoteProxy = new ERC1967Proxy(address(quoteImpl), quoteInitData);
        quoteHarness = StateSenderQuoteHarness(address(quoteProxy));

        // MessageSink: (endpoint, delegate)
        address sinkAddr =
            _deployOApp(type(MessageSink).creationCode, abi.encode(address(endpoints[DST_EID]), address(this)));
        messageSink = MessageSink(sinkAddr);

        wireOApps(toAddressArray(address(transportProxy), sinkAddr));

        transport.setDestination(
            DST_CHAIN_ID,
            DST_EID,
            addressToBytes32(address(messageSink)),
            OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0),
            true
        );

        quoteHarness.setDestination(
            DST_CHAIN_ID,
            DST_EID,
            addressToBytes32(address(messageSink)),
            OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0),
            true
        );
    }

    function toAddressArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function test_sendState_native_packetDelivered() public {
        uint256 fee = stateSender.quoteSendState(DST_CHAIN_ID);
        assertTrue(fee > 0, "expected non-zero native fee");

        stateSender.sendState{value: fee}(DST_CHAIN_ID);

        verifyPackets(DST_EID, addressToBytes32(address(messageSink)));

        // abi.encode(version, key, stateData, srcTimestamp): 32*4 + 32 (stateData len) + 32 (stateData) = 192
        assertEq(messageSink.lastMessage().length, 192, "message size");
        (uint8 msgVersion, bytes32 key, bytes memory stateData, uint64 ts) =
            abi.decode(messageSink.lastMessage(), (uint8, bytes32, bytes, uint64));
        assertEq(msgVersion, stateSender.version());
        assertEq(ts, block.timestamp);
        assertEq(stateData.length, 32);
        assertEq(abi.decode(stateData, (uint256)), 1e18);

        bytes32 expectedKey = KeyDerivation.deriveKey(
            block.chainid, address(mockTarget), abi.encodeWithSelector(MockRateTarget.getRate.selector)
        );
        assertEq(key, expectedKey);
    }

    function test_sendState_insufficientNativeFee_reverts() public {
        uint256 fee = stateSender.quoteSendState(DST_CHAIN_ID);
        vm.expectRevert(StateSender.StateSender_InsufficientNativeFee.selector);
        stateSender.sendState{value: fee - 1}(DST_CHAIN_ID);
    }

    function test_staticcallFailure_reverts() public {
        // Use a contract that reverts on getRate() so staticcall fails (0xdead has no code and returns success)
        StateSender badImpl = new StateSender();
        bytes memory initData = abi.encodeCall(
            StateSender.initialize,
            (
                address(this),
                address(transport),
                address(badImpl),
                abi.encodeWithSelector(MockRateTarget.getRate.selector),
                1
            )
        );
        ERC1967Proxy badProxy = new ERC1967Proxy(address(badImpl), initData);
        StateSender badSender = StateSender(address(badProxy));
        vm.expectRevert(StateSender.StateSender_StaticcallFailed.selector);
        badSender.quoteSendState(DST_CHAIN_ID);
    }

    function test_quoteSendState_lzTokenFee_reverts() public {
        quoteHarness.setMockFee(1, 1);
        stateSender.setTransport(address(quoteHarness));

        vm.expectRevert(LayerZeroStateRelayTransport.LayerZeroStateRelayTransport_LzTokenPaymentNotSupported.selector);
        stateSender.quoteSendState(DST_CHAIN_ID);
    }

    function test_sendState_lzTokenFee_reverts() public {
        quoteHarness.setMockFee(1, 1);
        stateSender.setTransport(address(quoteHarness));

        vm.expectRevert(LayerZeroStateRelayTransport.LayerZeroStateRelayTransport_LzTokenPaymentNotSupported.selector);
        stateSender.sendState{value: 1}(DST_CHAIN_ID);
    }

    function test_deriveKey_matchesStoredKey() public {
        uint256 fee = stateSender.quoteSendState(DST_CHAIN_ID);
        stateSender.sendState{value: fee}(DST_CHAIN_ID);
        verifyPackets(DST_EID, addressToBytes32(address(messageSink)));

        (, bytes32 key,,) = abi.decode(messageSink.lastMessage(), (uint8, bytes32, bytes, uint64));
        bytes32 expectedKey = KeyDerivation.deriveKey(
            block.chainid, address(mockTarget), abi.encodeWithSelector(MockRateTarget.getRate.selector)
        );
        assertEq(key, expectedKey);
    }
}
