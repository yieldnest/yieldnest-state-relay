// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StateSender} from "src/StateSender.sol";
import {KeyDerivation} from "src/KeyDerivation.sol";
import {MockRateTarget} from "test/mocks/MockRateTarget.sol";
import {MessageSink} from "test/mocks/MessageSink.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StateSenderTest is Test, TestHelperOz5 {
    uint32 constant SRC_EID = 1;
    uint32 constant DST_EID = 2;

    StateSender public stateSender;
    MessageSink public messageSink;
    MockRateTarget public mockTarget;

    function setUp() public override {
        TestHelperOz5.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        mockTarget = new MockRateTarget();
        mockTarget.setRate(1e18);

        // StateSender is upgradeable: deploy impl + proxy, initialize via proxy
        StateSender impl = new StateSender(address(endpoints[SRC_EID]));
        bytes memory initData = abi.encodeCall(
            StateSender.initialize,
            (address(this), address(mockTarget), address(this), abi.encodeWithSelector(MockRateTarget.getRate.selector), 1)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stateSender = StateSender(address(proxy));

        // MessageSink: (endpoint, delegate)
        address sinkAddr =
            _deployOApp(type(MessageSink).creationCode, abi.encode(address(endpoints[DST_EID]), address(this)));
        messageSink = MessageSink(sinkAddr);

        wireOApps(toAddressArray(address(proxy), sinkAddr));
    }

    function toAddressArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function test_sendState_native_packetDelivered() public {
        MessagingFee memory fee = stateSender.quoteSendState(DST_EID);
        assertTrue(fee.nativeFee > 0, "expected non-zero native fee");

        stateSender.sendState{value: fee.nativeFee}(DST_EID);

        verifyPackets(DST_EID, addressToBytes32(address(messageSink)));

        // abi.encode(chainId, key, stateData, timestamp): 32*4 + 32 (stateData len) + 32 (stateData) = 192
        assertEq(messageSink.lastMessage().length, 192, "message size");
        (uint256 chainId, bytes32 key, bytes memory stateData, uint256 ts) =
            abi.decode(messageSink.lastMessage(), (uint256, bytes32, bytes, uint256));
        assertEq(chainId, block.chainid);
        assertEq(ts, block.timestamp);
        assertEq(stateData.length, 32);
        assertEq(abi.decode(stateData, (uint256)), 1e18);

        bytes32 expectedKey = KeyDerivation.deriveKey(
            block.chainid, address(mockTarget), abi.encodeWithSelector(MockRateTarget.getRate.selector)
        );
        assertEq(key, expectedKey);
    }

    function test_sendState_insufficientNativeFee_reverts() public {
        MessagingFee memory fee = stateSender.quoteSendState(DST_EID);
        vm.expectRevert("StateSender: insufficient native fee");
        stateSender.sendState{value: fee.nativeFee - 1}(DST_EID);
    }

    function test_staticcallFailure_reverts() public {
        // Use a contract that reverts on getRate() so staticcall fails (0xdead has no code and returns success)
        StateSender badImpl = new StateSender(address(endpoints[SRC_EID]));
        bytes memory initData = abi.encodeCall(
            StateSender.initialize,
            (address(this), address(badImpl), address(this), abi.encodeWithSelector(MockRateTarget.getRate.selector), 1)
        );
        ERC1967Proxy badProxy = new ERC1967Proxy(address(badImpl), initData);
        StateSender badSender = StateSender(address(badProxy));
        vm.expectRevert("StateSender: staticcall failed");
        badSender.quoteSendState(DST_EID);
    }

    function test_deriveKey_matchesStoredKey() public {
        MessagingFee memory fee = stateSender.quoteSendState(DST_EID);
        stateSender.sendState{value: fee.nativeFee}(DST_EID);
        verifyPackets(DST_EID, addressToBytes32(address(messageSink)));

        (, bytes32 key,,) = abi.decode(messageSink.lastMessage(), (uint256, bytes32, bytes, uint256));
        bytes32 expectedKey = KeyDerivation.deriveKey(
            block.chainid, address(mockTarget), abi.encodeWithSelector(MockRateTarget.getRate.selector)
        );
        assertEq(key, expectedKey);
    }
}
