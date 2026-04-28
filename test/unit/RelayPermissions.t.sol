// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {StateSender} from "src/StateSender.sol";
import {StateStore} from "src/StateStore.sol";
import {LayerZeroSenderTransport} from "src/layerzero/LayerZeroSenderTransport.sol";
import {LayerZeroReceiverTransport} from "src/layerzero/LayerZeroReceiverTransport.sol";
import {StateReceiverHarness} from "test/mocks/StateReceiverHarness.sol";
import {MockRateTarget} from "test/mocks/MockRateTarget.sol";

contract RelayPermissionsTest is Test, TestHelperOz5 {
    uint32 internal constant SRC_EID = 1;
    uint32 internal constant DST_EID = 2;
    uint256 internal constant DST_CHAIN_ID = 42161;
    bytes4 internal constant ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR =
        bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
    bytes4 internal constant OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR =
        bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    address internal constant ATTACKER = address(0xBEEF);

    StateSender internal stateSender;
    StateStore internal stateStore;
    LayerZeroSenderTransport internal senderTransport;
    StateReceiverHarness internal receiverTransport;
    MockRateTarget internal mockTarget;

    function setUp() public override {
        TestHelperOz5.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        mockTarget = new MockRateTarget();
        mockTarget.setRate(1e18);

        LayerZeroSenderTransport senderTransportImpl = new LayerZeroSenderTransport(address(endpoints[SRC_EID]));
        bytes memory senderTransportInit = abi.encodeCall(LayerZeroSenderTransport.initialize, (address(this)));
        senderTransport =
            LayerZeroSenderTransport(address(new ERC1967Proxy(address(senderTransportImpl), senderTransportInit)));

        StateSender senderImpl = new StateSender();
        bytes memory senderInit = abi.encodeCall(
            StateSender.initialize,
            (
                address(this),
                address(senderTransport),
                address(mockTarget),
                abi.encodeWithSelector(MockRateTarget.getRate.selector),
                1
            )
        );
        stateSender = StateSender(address(new ERC1967Proxy(address(senderImpl), senderInit)));
        senderTransport.grantRole(senderTransport.SENDER_ROLE(), address(stateSender));
        LayerZeroSenderTransport.DestinationConfig[] memory destinationConfigs =
            new LayerZeroSenderTransport.DestinationConfig[](1);
        destinationConfigs[0] = LayerZeroSenderTransport.DestinationConfig({
            lzEid: DST_EID,
            peer: bytes32(uint256(uint160(address(0x1234)))),
            options: OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 300_000, 0),
            enabled: true
        });
        uint256[] memory destinationIds = new uint256[](1);
        destinationIds[0] = DST_CHAIN_ID;
        senderTransport.setDestination(destinationConfigs, destinationIds);

        StateStore storeImpl = new StateStore();
        bytes memory storeInit = abi.encodeCall(StateStore.initialize, (address(this), new address[](0)));
        stateStore = StateStore(address(new ERC1967Proxy(address(storeImpl), storeInit)));

        StateReceiverHarness receiverImpl = new StateReceiverHarness(address(endpoints[DST_EID]));
        bytes memory receiverInit =
            abi.encodeCall(LayerZeroReceiverTransport.initialize, (address(this), address(stateStore)));
        receiverTransport = StateReceiverHarness(address(new ERC1967Proxy(address(receiverImpl), receiverInit)));
        stateStore.grantRole(stateStore.WRITER_ROLE(), address(receiverTransport));
    }

    function test_permissions_stateSender_setTransport_requiresTransportManagerRole() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateSender.TRANSPORT_MANAGER_ROLE()
            )
        );
        stateSender.setTransport(address(senderTransport));
        vm.stopPrank();
    }

    function test_permissions_stateSender_pause_requiresDefaultAdminRole() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateSender.PAUSER_ROLE()
            )
        );
        stateSender.pause();
        vm.stopPrank();
    }

    function test_permissions_stateSender_configMutators_requireConfigManagerRole() public {
        vm.startPrank(ATTACKER);

        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateSender.CONFIG_MANAGER_ROLE()
            )
        );
        stateSender.setTarget(address(0x123));

        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateSender.CONFIG_MANAGER_ROLE()
            )
        );
        stateSender.setCallData(hex"1234");

        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateSender.CONFIG_MANAGER_ROLE()
            )
        );
        stateSender.setVersion(2);

        vm.stopPrank();
    }

    function test_permissions_stateStore_setSupportedVersion_requiresVersionManagerRole() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateStore.VERSION_MANAGER_ROLE()
            )
        );
        stateStore.setSupportedVersion(2, true);
        vm.stopPrank();
    }

    function test_permissions_stateStore_pause_requiresDefaultAdminRole() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateStore.PAUSER_ROLE()
            )
        );
        stateStore.pause();
        vm.stopPrank();
    }

    function test_permissions_stateStore_writeBytes_requiresWriterRole() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateStore.WRITER_ROLE())
        );
        stateStore.write(abi.encode(uint256(1), bytes32("k"), abi.encode(uint256(1e18)), uint64(block.timestamp)));
        vm.stopPrank();
    }

    function test_permissions_stateStore_writeDecoded_requiresWriterRole() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, stateStore.WRITER_ROLE())
        );
        stateStore.write(
            bytes32("k"), StateStore.StateUpdate({value: abi.encode(uint256(1e18)), version: 1, srcTimestamp: 1})
        );
        vm.stopPrank();
    }

    function test_permissions_senderTransport_setDestination_requiresConfigManagerRole() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, senderTransport.CONFIG_MANAGER_ROLE()
            )
        );
        senderTransport.setDestination(new LayerZeroSenderTransport.DestinationConfig[](0), new uint256[](0));
        vm.stopPrank();
    }

    function test_permissions_senderTransport_setPeer_requiresOwner() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER));
        senderTransport.setPeer(DST_EID, bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_permissions_senderTransport_grantRole_requiresDefaultAdminRole() public {
        bytes32 senderRole = senderTransport.SENDER_ROLE();
        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, senderTransport.DEFAULT_ADMIN_ROLE()
            )
        );
        senderTransport.grantRole(senderRole, ATTACKER);
        vm.stopPrank();
    }

    function test_permissions_receiverTransport_setPeer_requiresOwner() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER));
        receiverTransport.setPeer(SRC_EID, bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_permissions_receiverTransport_pause_requiresOwner() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER));
        receiverTransport.pause();
        vm.stopPrank();
    }

    function test_permissions_senderTransport_send_rejectsDirectPublicCaller() public {
        bytes memory forgedMessage = abi.encode(uint256(1), bytes32("forged"), abi.encode(uint256(123)), uint64(1));

        vm.startPrank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, ATTACKER, senderTransport.SENDER_ROLE()
            )
        );
        senderTransport.send(DST_CHAIN_ID, forgedMessage, ATTACKER);
        vm.stopPrank();
    }
}
